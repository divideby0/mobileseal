The change is not ready to ship: separate unlock sessions can create independent writers over the same stale inventory and silently lose committed files, while session teardown and the bounded lock path do not consistently revoke all key/plaintext capabilities. The local rate limiter is also bypassable by concurrent attempts, and a post-commit durability error can leave the live actor behind disk state. Static inspection additionally found three narrower conformance gaps. `swift test` could not get past manifest evaluation in this review environment because the host denied SwiftPM's nested `sandbox-exec`, including on the required single retry.

| #   | Severity | Location                                                                                                                       | Finding                                                                                                                                                                 |
| --- | -------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | blocker  | `Sources/VaultCore/SealedVault.swift:172`; `Sources/VaultCore/KeyCustodian.swift:111`; `Sources/VaultCore/Gallery.swift:251`   | Writer exclusivity is scoped to one unlock session, so two sessions can commit from the same stale inventory and the later HEAD swap silently drops the earlier import. |
| 2   | major    | `Sources/VaultCore/UnlockSession.swift:8`                                                                                      | Destroying an `UnlockSession` does not lock its shared custodian, so an escaped reader or gallery remains able to decrypt indefinitely.                                 |
| 3   | major    | `Sources/VaultCore/KeyCustodian.swift:47`; `Sources/VaultCore/KeyCustodian.swift:85`; `Sources/VaultCore/ChunkReader.swift:67` | The drain deadline zeroes only the custodian's key and does not reliably fail or revoke straggling reads and DEK leases.                                                |
| 4   | major    | `Sources/VaultCore/SealedVault.swift:172`; `Sources/VaultCore/RateLimiter.swift:69`                                            | Unlock throttling is a non-atomic check/read/write sequence, so concurrent guesses can all run the KDF and overwrite one another's failure counts.                      |
| 5   | major    | `Sources/VaultCore/Store.swift:222`; `Sources/VaultCore/Gallery.swift:264`                                                     | An error after the HEAD rename leaves disk committed but the Gallery actor on its pre-commit inventory, enabling a later mutation to erase the committed entry.         |
| 6   | minor    | `.swift-version:1`; `Package.swift:1`                                                                                          | The claimed exact Swift toolchain pin and CI invocation are not present; both files select only the 6.2 release line and no CI workflow enforces the stated build.      |
| 7   | minor    | `Sources/VaultCore/GalleryMeta.swift:76`                                                                                       | The v0 parser accepts a sole keyring entry at any epoch even though v0 normatively requires epoch 0.                                                                    |
| 8   | minor    | `Sources/VaultCore/SecureBytes.swift:10`                                                                                       | The documented warning on `mlock` failure is not implemented, so degraded page-locking is silent.                                                                       |

## 1. Multiple unlock sessions bypass the single-writer invariant

Evidence: `SealedVault.unlock` creates a fresh `KeyCustodian` on every call (`Sources/VaultCore/SealedVault.swift:172-190`). The one-shot writer bit lives on that custodian (`Sources/VaultCore/KeyCustodian.swift:108-117`), so each session can successfully call `openGallery`. Each resulting actor retains the inventory loaded at its own unlock and constructs the next inventory from that private value (`Sources/VaultCore/Gallery.swift:251-265`).

Why it matters: unlock sessions A and B can both load generation N, then each append a different file and publish generation N+1. Both commits are individually valid, but the second HEAD swap makes only B's inventory reachable; A's successfully returned file becomes an orphan. This is silent data loss in the vault's supposed single-writer mutation plane, and the documented single-process assumption does not exclude multiple sessions/tasks in that process.

Suggested fix: enforce writer ownership in a coordinator shared by every `SealedVault`/session for a canonical gallery path or UUID, not inside a per-unlock custodian. Also persist the inventory address/generation a Gallery opened from and compare it with HEAD at commit so stale writers fail explicitly (or reload/merge) instead of overwriting newer state. Add a regression test that unlocks twice before either import and proves both successful mutations remain visible or the second writer is rejected.

## 2. Dropping the session does not revoke escaped capabilities

Evidence: `UnlockSession` has no `deinit` (`Sources/VaultCore/UnlockSession.swift:8-60`). `makeReader` returns a `ChunkReader` that strongly retains the custodian (`Sources/VaultCore/UnlockSession.swift:49-52`, `Sources/VaultCore/ChunkReader.swift:36-53`), and `openGallery` returns another strong custodian owner. The custodian therefore does not deinitialize and zero its key when the session value goes out of scope.

Why it matters: a caller can unlock, return a reader (or gallery) from a scope, and simply let the move-only session be destroyed without calling `lock()`. The escaped capability then continues decrypting. This contradicts the referenced API contract's explicit "deinit self-zeroes" guarantee and makes the session cease to be the root lifetime authority.

Suggested fix: give `UnlockSession` a destructor/owned revocation token whose destruction idempotently calls `lockAndDrain`, so session teardown locks the shared custodian even while readers retain it. Add a test that returns only a reader from a scope containing a session and verifies the reader is locked once that scope exits.

## 3. Bounded drain leaves usable key copies and successful stragglers

Evidence: `leaseKey` copies the DEK to a new `SecureBytes` allocation (`Sources/VaultCore/KeyCustodian.swift:85-98`), but `lockAndDrain` zeroes only `key` after the deadline (`Sources/VaultCore/KeyCustodian.swift:121-133`); an outstanding lease remains intact until its eventual deinit. Separately, `withKey` only remaps an error thrown by its callback and performs no locked/generation check after a successful callback (`Sources/VaultCore/KeyCustodian.swift:47-73`). Finally, `withDecryptedChunk` and `readRange` invoke the caller's plaintext callback after `decryptChunk` has already released `withKey` custody (`Sources/VaultCore/ChunkReader.swift:67-77`, `83-117`). The lock test for leases releases its lease before the deadline and therefore does not exercise the force path (`Tests/VaultCoreTests/LockRaceTests.swift:125-144`).

Why it matters: after the 500 ms deadline, `lock()` can return while a lease still contains the real DEK. A straggling read that completed AEAD before the zero but finishes later can also return successfully, and a plaintext callback is not counted as an active read at all. These paths violate the requirement that key lifetime end at read completion or the drain deadline, whichever comes first, and that readers losing the race fail closed with `vaultLocked`.

Suggested fix: do not create independent DEK copies for leases; use a revocable shared allocation/read permit, or register and force-zero every leased allocation at the deadline. Track a lock generation and reject successful results whose permit was force-revoked. Hold the read permit across validation and the public scoped plaintext callback (and register its secure buffer for deadline zeroing), then add tests that deliberately hold both a read and a lease beyond a very short drain deadline.

## 4. Concurrent unlocks bypass backoff

Evidence: every `unlock` constructs an independent `UnlockRateLimiter`, calls `checkAllowed`, runs the KDF, and only then records failure (`Sources/VaultCore/SealedVault.swift:172-183`). `checkAllowed`, `load`, and `recordFailure` have no shared synchronization, and `recordFailure` implements a read-modify-write of the sidecar (`Sources/VaultCore/RateLimiter.swift:37-58`, `69-85`).

Why it matters: a batch of concurrent wrong-password attempts can all observe the same allowed state and run expensive guesses. They can then all read the same old count and overwrite the sidecar with the same incremented value; concurrent truncating writes can also produce a sidecar that `load` treats as absent. An attacker can therefore sustain guesses without the documented cooldown even within the stated single-process model.

Suggested fix: serialize the whole check-attempt-record transition per canonical gallery in the same shared coordinator used for writer ownership, or use an interlocked/file-locked state machine that accounts for attempts before releasing them to the KDF. Add a task-group test that launches more than `freeAttempts` simultaneous failures and asserts later attempts are rejected and the persisted count includes every admitted attempt.

## 5. Post-commit errors leave the actor stale

Evidence: the atomic HEAD replacement is the declared commit point (`Sources/VaultCore/Store.swift:222-229`), but `commit` can still throw when syncing the gallery directory afterward (`Sources/VaultCore/Store.swift:230-232`). `Gallery.commitAppending` updates its in-memory `inventory` only after `commit` returns successfully (`Sources/VaultCore/Gallery.swift:263-267`), while the generic import error path merely aborts staging and leaves the actor usable (`Sources/VaultCore/Gallery.swift:239-245`).

Why it matters: if the HEAD rename succeeds and the following directory fsync fails, the caller sees a failed import while disk already points to the new inventory. The actor still holds the old generation. A subsequent import through that same actor builds from the old entries and swaps HEAD again, silently removing the first, already-visible commit.

Suggested fix: make `CommitTx.commit` report whether the commit point was crossed even when a later durability step fails. Once crossed, update/reload the actor's inventory before returning an error, or poison the actor and require reopening; never permit another mutation from known-stale state. Fault-inject an ordinary I/O failure after `headSwapped` without simulating process death and verify subsequent use cannot lose the committed entry.

## 6. The Swift toolchain is not exactly pinned or CI-enforced

Evidence: `.swift-version` contains only `6.2`, and `Package.swift:1` uses `swift-tools-version:6.2`. The latter selects the manifest language/minimum tools compatibility, not the claimed `swiftlang-6.2.0.19.9` compiler build. No committed CI workflow selects or verifies that exact toolchain; `Package.swift:2-3` only comments that CI must do so.

Why it matters: the goal explicitly requires an exact pin because the move-only API and compile-fail diagnostic assertions are toolchain-sensitive. A later 6.2 patch can change ownership diagnostics or behavior while still satisfying both current selectors, and there is no automated gate to reveal the drift.

Suggested fix: use the repository's toolchain manager to pin the full supported identifier/version and add a macOS CI job that selects it, asserts `swift --version`, and runs `swift test` (including the compile-fail harness).

## 7. Format v0 accepts nonzero epochs

Evidence: `GalleryMeta.parse` enforces exactly one keyring entry but never checks the parsed `epoch` value (`Sources/VaultCore/GalleryMeta.swift:76-94`). The goal and `docs/formats.md` require the sole v0 entry to be epoch 0.

Why it matters: accepting an undocumented single-entry epoch silently expands v0 and undermines the stated forward-compatibility boundary: rotation is supposed to raise the format's accepted keyring/epoch rules deliberately. Independent implementations following the normative document will reject vaults this parser accepts.

Suggested fix: reject `epoch != 0` in the v0 parser (and assert it in serialization), with a conformance test for a correctly wrapped but nonzero sole entry.

## 8. Best-effort `mlock` degradation is never logged

Evidence: `SodiumRuntime.ensure` only checks `sodium_init` (`Sources/VaultCore/SecureBytes.swift:7-16`), and `SecureBytes.init` calls `sodium_malloc`, zeroes the allocation, and returns without checking or emitting any page-lock diagnostic (`Sources/VaultCore/SecureBytes.swift:32-40`). There is no logger or `sodium_mlock` result handling in VaultCore.

Why it matters: the goal explicitly chooses a proceed-with-warning policy for common iOS `mlock` failures. The implementation proceeds silently, so callers and diagnostics cannot distinguish the intended degraded-security mode from successfully page-locked key memory.

Suggested fix: expose an injectable, non-secret diagnostic hook and explicitly probe/check page locking for each secure allocation (without turning failure into an unlock error), emitting the required warning once per process. Add a seam that forces the failure result in a unit test and verifies allocation still succeeds and one warning is produced.

REVIEW COMPLETE
