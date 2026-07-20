# Blind review — wave-003 — claude-code

## Verdict

This is a strong, unusually disciplined implementation of the CED-10 spec.
The format contract in `docs/formats.md` is genuinely normative and the
conformance test decodes the committed KAT fixture using only transcribed
constants — the third-party-decryptor property the goal asks for actually
holds. Crypto primitive selection, AAD position-binding, KDF bounds
validation, bounded reads before allocation, drain-on-lock via raw-key
decryption, the WAL/HEAD commit protocol and its per-step fault injection
all match the spec and are backed by real tests. `swift test` is green (49
tests, 12 suites, exit 0) on the pinned toolchain, and every documented
green gate has a corresponding test. My findings are one confirmed
data-loss defect plus a small number of narrower issues.

The blocker is that the single-writer invariant — which the code, the
docs, and a wave-001 regression test all describe as "structural" — is
enforced on the `KeyCustodian`, which is created fresh per `unlock()`.
Two `unlock()` calls on the same `SealedVault` therefore yield two
`Gallery` actors that race the inventory and silently drop a committed
import. I reproduced this: one of two successfully-returned imports
vanishes, with no error on any call. That is precisely the failure mode
wave-001 finding #2 was raised against; the fix closed the
second-`openGallery()` door but left the second-`unlock()` door open.

## Findings

| #   | Severity | Location                                                              | Finding                                                                                                                                                         |
| --- | -------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | blocker  | `Sources/VaultCore/KeyCustodian.swift:111` / `UnlockSession.swift:37` | Single-writer claim is per-session, not per-vault: a second `unlock()` produces a second writable `Gallery` that silently loses a committed import (reproduced) |
| 2   | major    | `Tests/VaultCoreTests/ReviewRegressionTests.swift:171`                | The wave-002 #6 regression lock does not exercise the path it locks; `VaultError.sourceChangedDuringImport` has zero test coverage                              |
| 3   | minor    | `Sources/VaultCore/Gallery.swift:194,263`                             | Dedup-path commit failure leaks a WAL staging directory — the self-created `CommitTx` is never aborted                                                          |
| 4   | minor    | `Sources/VaultCore/Gallery.swift:186`                                 | Dedup reuses an existing entry's chunk addresses without checking those chunk objects still exist, so a re-import can "succeed" into an unreadable entry        |
| 5   | nit      | `Package.swift:25`                                                    | Declared dependency on the `Sodium` product is unused — only `Clibsodium` is imported                                                                           |
| 6   | nit      | `Sources/VaultCore/Store.swift:45,108`                                | `Darwin.read` / `F_FULLFSYNC` hardcode Apple platforms in the package the ADR designates as the portable core                                                   |

---

### 1. blocker — single-writer invariant is per-session, so a second `unlock()` silently loses a committed import

**Evidence.** The writer claim lives on `KeyCustodian`:

- `Sources/VaultCore/KeyCustodian.swift:111` — `claimWriter()` guards the
  per-instance `writerClaimed` flag.
- `Sources/VaultCore/UnlockSession.swift:37` — `openGallery()` is the only
  caller.
- `Sources/VaultCore/SealedVault.swift:186` — every `unlock()` constructs a
  **new** `KeyCustodian`, hence a fresh, unclaimed flag.

`SealedVault` is a public `Sendable` struct and `unlock(password:)` is
public with no documented "one session at a time" constraint. The
`docs/formats.md` §Security notes "single-process assumption" (line 309)
covers multi-_process_ access, not two sessions inside one process.

I reproduced the loss with a scratch test against the current tree (since
removed; working tree left clean):

```swift
let s1 = try vault.unlock(); let g1 = try s1.openGallery()
let s2 = try vault.unlock(); let g2 = try s2.openGallery()   // succeeds
let idA = try await g1.importBytes(...)   // returns success
let idB = try await g2.importBytes(...)   // returns success
// reopen:
PROBE survivors=1 hasA=false hasB=true gen=2
```

Both imports returned a `FileID` and neither threw. On reopen only file B
exists. `generation` is 2, not 3 — both galleries started from the same
in-memory `inventory` at generation 1, each computed `generation + 1`, and
the second HEAD swap overwrote the first. File A's chunks remain in the CAS
as unreferenced orphans, so the bytes are on disk but the photo is gone
from the gallery.

**Why it matters.** This is silent, unreported data loss on a
public-API path with no misuse required — exactly the class of bug the
wave-001 #2 fix, the `galleryAlreadyOpen` error, and
`ReviewRegressionTests.secondGalleryIsRefused` exist to prevent. The
existing regression test passes because it only probes the second
`openGallery()` on one session. For a photo vault, "import returned
success and the photo is gone" is the worst available failure mode, and
nothing in the current design surfaces it: no error, no log, and the
sealed-plane `auditAddresses()` reports the vault as clean (the orphan
chunks are only visible via the DEK-tier `verifyAuthenticity()`, which
classifies them as "harmless").

The same missing vault-level exclusion has a second facet worth fixing
together: `SealedVault.init` (`SealedVault.swift:39`) unconditionally runs
`Recovery.recover`, which deletes **every** `wal/{txid}/` directory. A
second `SealedVault(directory:)` opened while an import is staging will
delete that import's live staging dir out from under it. That one fails
loudly (the subsequent `publishCAS` throws `ioFailure`) rather than
corrupting, but it is the same root cause.

**Suggested fix.** Move the writer claim from the per-unlock custodian up
to something with vault-directory identity, so it survives across
sessions. Options, cheapest first:

1. A process-wide registry keyed by the canonical (symlink-resolved)
   vault directory path — a `static let` actor or `NSLock`-guarded
   `Set<String>` in `SealedVault` — claimed by `openGallery()` and
   released when the session locks. Keeps the existing
   `.galleryAlreadyOpen` error and needs no format change.
2. Additionally (and independently useful for the documented CLI leg): an
   on-disk `flock(2)`/`O_EXLOCK` lockfile in the gallery root, which also
   upgrades the "single-process assumption" from a comment to an enforced
   invariant and makes the `Recovery.recover` facet safe too.

Either way, gate the recovery sweep in `SealedVault.init` on holding that
claim, and add a regression test that mirrors the probe above —
two `unlock()` calls, two `openGallery()` calls, assert the second throws
`.galleryAlreadyOpen`.

A defence-in-depth complement (worth doing regardless, since it also
covers the multi-process case the lockfile cannot fully close on all
filesystems): make the HEAD swap compare-and-swap rather than
last-writer-wins — have `CommitTx.commit` re-read HEAD immediately before
the swap and refuse if it no longer matches the generation the caller
started from. That converts silent loss into a typed conflict error.

---

### 2. major — the wave-002 #6 regression lock does not test the path it locks

**Evidence.** `Tests/VaultCoreTests/ReviewRegressionTests.swift:171`,
`importRefusesSourceMutatedBetweenPasses()`. Its own body comment
(lines 184–195) concedes the substitution:

> "…mutating the file DURING pass 2 via a FileHandle from another task is
> flaky; the deterministic seam is the MemorySource path, which cannot
> change. So this test pins the honest observable: a same-length rewrite
> between two SEPARATE imports yields distinct entries with distinct
> hashes…"

What it actually asserts is that two sequential imports of different
content produce different chunk addresses — true of any correct
implementation, and true even if the two-pass hash comparison were deleted
entirely. Confirmed by grep: `VaultError.sourceChangedDuringImport` appears
only at its declaration (`Errors.swift:81`) and its two throw sites
(`Gallery.swift:220`, `Gallery.swift:231`) — no test references it.

**Why it matters.** Both guards in `importSource` — the per-chunk
`got == want` short-read check and the pass-2 `sealedHasher.finalize() ==
dedupHash` comparison — are the only thing standing between a mutating
import source and chunks permanently committed under a dedup hash
describing bytes that were never stored. That mislabelling is durable and
poisons all future dedup matches against the entry. An untested guard in
that position is a guard that can be silently broken by a later refactor,
and the credit taken for it in the wave-002 disposition is not backed by
the test suite. The honesty of the in-test comment is commendable, but a
test that cannot fail for the reason it is named is worse than no test:
it suppresses the coverage gap.

**Suggested fix.** The path is deterministically testable — the flakiness
the comment worries about comes from trying to race a real file. Add a
test-only `ChunkSource` conformance whose `read` returns different bytes
after `rewind()` (the protocol is already `private`, so either make it
`internal` or add an `internal` seam on `Gallery` that accepts an
injected source). Two cases:

- same total length, different content → expect
  `VaultError.sourceChangedDuringImport` from the pass-2 hash comparison;
- a short read mid-chunk on pass 2 → expect the same error from the
  `got == want` guard.

Then assert the vault is unchanged afterwards (no new inventory entry, WAL
clean). Rename the current test to what it actually checks
(e.g. `distinctContentDoesNotFalselyDedup`) and keep it — it is a
reasonable test, just not this one.

---

### 3. minor — dedup-path commit failure leaks a WAL staging directory

**Evidence.** `Sources/VaultCore/Gallery.swift:194` — the dedup early
return calls `try commitAppending(entry, stagedIn: nil)`, and this call
sits _before_ the `do { … } catch { tx.abort() }` block that begins at
line 209. Inside `commitAppending`, line 263 creates its own transaction
when none was passed:

```swift
let commitTx = try tx ?? CommitTx(layout: layout)
_ = try commitTx.commit(inventoryObject: object, failpoint: failpoint)
```

If `commit` throws (any `ioFailure` — a full disk, a failed fsync), nobody
calls `commitTx.abort()`: the caller's `catch` at line 243 aborts `tx`,
which is `nil` on this path. The same applies to the initial-inventory
commit in `SealedVault.create` (`SealedVault.swift:94`).

**Why it matters.** Correctness is preserved — the WAL dir is
unreferenced, and `Recovery.recover` deletes it on the next open — so this
is disk-space and hygiene, not corruption. But it means a vault that
repeatedly fails to commit while staying open accumulates staging
directories full of fsync'd chunk objects with no bound, and the leak is
invisible until a restart. On a photo vault on a device that is already
near-full (a plausible cause of the originating `ioFailure`), that makes a
bad situation worse.

**Suggested fix.** Wrap the commit in `commitAppending` so the transaction
is cleaned up on any failure regardless of who created it:

```swift
let commitTx = try tx ?? CommitTx(layout: layout)
do {
    _ = try commitTx.commit(inventoryObject: object, failpoint: failpoint)
} catch is SimulatedCrash {
    throw ...   // preserve the existing "leave the WAL as a real crash would" behaviour
} catch {
    commitTx.abort()
    throw error
}
```

Note the `SimulatedCrash` carve-out is load-bearing: `CrashConsistencyTests`
asserts that recovery — not the abort path — is what cleans the WAL after
a simulated crash.

---

### 4. minor — dedup adopts an existing entry's chunk addresses without verifying the chunks exist

**Evidence.** `Sources/VaultCore/Gallery.swift:186`:

```swift
if let existing = inventory.entries.first(where: {
    $0.dedupHash == dedupHash && $0.unpaddedLength == unpaddedLength
}) {
    let entry = InventoryEntry(..., chunkAddresses: existing.chunkAddresses, ...)
    try commitAppending(entry, stagedIn: nil)
    return fileID
}
```

The match is made purely against in-memory inventory state; there is no
check that `existing.chunkAddresses` are still present in `chunks/`.

**Why it matters.** If a chunk object has been lost since the original
import — filesystem corruption, a partial restore from backup, an
interrupted sync, or the GC leg that `docs/formats.md:258` explicitly
plans — the original entry is already broken, and re-importing the same
media is the most natural user response ("let me just add it again"). Today
that re-import reports success and produces a _second_ entry that is
equally unreadable, while the source file may then be deleted by the user
in the belief it is safely vaulted. The failure only surfaces later, at
read time, as `missingChunk`. Re-importing the actual bytes is the one
moment when the vault could cheaply self-heal, and it currently declines
to.

**Suggested fix.** Before taking the dedup shortcut, confirm every address
in `existing.chunkAddresses` exists in the CAS
(`FileManager.fileExists` on `layout.chunkURL(_:)`, or reuse
`SealedVault.listCASDir` once and test set membership — the latter avoids
N stat calls per import). If any are missing, fall through to the normal
seal-and-stage path; the CAS is no-overwrite, so present chunks are simply
re-published as no-ops and the missing ones are restored. This turns a
silent double-failure into automatic repair. Worth a test: delete one
chunk of an imported file, re-import the same bytes, assert both entries
read back correctly.

---

### 5. nit — unused `Sodium` product dependency

**Evidence.** `Package.swift:25` lists
`.product(name: "Sodium", package: "swift-sodium")` in the `VaultCore`
target's dependencies. No file under `Sources/` or `Tests/` contains
`import Sodium`; every crypto call goes through `import Clibsodium`
directly (`CryptoCore.swift:1`, `SecureBytes.swift:1`, etc.), which is the
right choice given the raw-pointer custody this design needs.

**Why it matters.** Minor, but the goal names Swift-Sodium as the _sole_
crypto dependency and this package is the security-critical core: linking
the Swift wrapper layer that nothing calls adds compile time and audit
surface for zero benefit, and it slightly obscures the real (deliberate,
well-reasoned) decision to use the C API directly.

**Suggested fix.** Drop the `Sodium` product from the `VaultCore` target,
keeping `Clibsodium`. Same for `Argon2Bench` if it does not import it
either. `swift build` will confirm immediately.

---

### 6. nit — Apple-only syscall usage in the designated portable core

**Evidence.** `Sources/VaultCore/Store.swift:45` uses
`fcntl(fd, F_FULLFSYNC)`, and `Store.swift:108` /
`Gallery.swift:30` call `Darwin.read` with an explicit module
qualifier. `Package.swift` declares only `.macOS`/`.iOS` platforms.

**Why it matters.** This is squarely within the goal's stated scope
("macOS toolchain only for this goal"), and the ADR's portability claim is
correctly about the _formats_ being the cross-platform contract, not the
code — so this is not a defect against the spec. Flagging it only because
`docs/formats.md:5` and `ADR 0001` both name a macOS/Linux CLI peer as the
consumer, and the `Darwin.` qualifier in particular is a hard compile
error rather than a graceful degradation the day someone tries a Linux
build. Cheap to neutralise now, annoying to unpick later.

**Suggested fix.** No action required this leg. When the CLI leg lands,
replace `Darwin.read` with the unqualified `read` (resolved via
`#if canImport(Darwin) import Darwin #else import Glibc #endif`) and gate
`F_FULLFSYNC` behind `#if canImport(Darwin)`, falling back to plain
`fsync` — the existing `guard fcntl(...) >= 0 || fsync(fd) == 0` already
has the right fallback shape, it just needs the compile-time guard.

---

## Verification performed

- `swift test` on the pinned toolchain: **49 tests in 12 suites passed**,
  exit code 0. No flakiness observed across the run.
- Reproduced finding #1 with a temporary test file, then deleted it;
  `git status --porcelain` confirms the working tree is clean.
- Confirmed finding #2's coverage gap by grepping every reference to
  `sourceChangedDuringImport` across `Sources/` and `Tests/`.
- Read `docs/formats.md` against the implementation constants: the
  `gallery.meta` offset table (`57 + 78·n`), the 42-byte HEAD, the AAD
  prefixes, the padding rules, and the KDF/chunk-size bounds all agree
  with `FormatConstants.swift` and with the committed KAT fixture sizes.
- No issues found in: AEAD primitive and nonce selection, AAD position
  binding, KDF bounds validation ordering, `readRange` overflow handling,
  the bounded `FS.read` stat-before-materialize path, the `WireReader`
  bounds checks, the commit-step fsync ordering, or the drain-on-lock
  raw-key mechanism.

REVIEW COMPLETE
