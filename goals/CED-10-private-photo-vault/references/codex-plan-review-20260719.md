# Codex blind plan review — CED-10

## Blocking concerns

1. **Nonce uniqueness is assumed, not designed.** `GOAL.md` Workstream C.1 and `intake.md` §5.3 derive each nonce from `(fileID, chunkIndex)`, but never define file-ID generation, encoding, uniqueness, immutability, or behavior when an ID is reused. Reusing a pair with different plaintext under the same DEK catastrophically reuses an XChaCha20-Poly1305 nonce; the format must mandate and test uniqueness or store random 192-bit nonces.

2. **The DEK-wrapping primitive and envelope are ambiguous.** `intake.md` §5.1 calls XChaCha20-Poly1305 a “crypto_secretbox equivalent,” although libsodium `crypto_secretbox` uses XSalsa20-Poly1305 and has no associated data. `GOAL.md` Workstream B must select the exact API and specify nonce generation, salt size, tag placement, AAD, versioning, parameter encoding, and parser bounds before this becomes a format contract.

3. **Chunk and metadata authentication are underspecified.** `GOAL.md` Workstream C and `intake.md` §§5.3/6 never define the bytes covered by chunk AEAD, how encrypted per-file metadata is sealed, or how a manifest binds file ID, chunk index, plaintext length, padding, and chunk references. Without a normative authenticated structure, implementation choices can permit substitution, ambiguity, or incompatible decryptors despite every individual Poly1305 tag verifying.

4. **A single reserved epoch integer does not make later rotation migration-free.** `GOAL.md` Workstream B.1, `intake.md` §5.6, and `MAP.md` “DEK epochs” reserve one `epoch` beside one `wrapped_dek`, while rotation requires old objects to identify their epoch and current readers to retain the applicable old DEKs. The plan must either define an extensible keyring/object-epoch format now or stop claiming that the integer alone avoids migration.

5. **Move-only ownership contradicts shared revocable readers.** `vaultcore-api-shape.md` §§2 and 4 say `UnlockSession` uniquely owns and frees the DEK, while off-actor `ChunkReader`s share that DEK behind a generation counter. A generation check does not prevent `lock()` from zeroing or freeing the allocation after a read checks the generation but while libsodium is consuming the key; synchronization, lease lifetime, and lock/read race semantics must be designed and stress-tested.

6. **Immutable snapshots may defeat revocation.** `vaultcore-api-shape.md` §§3–4 makes `Manifest` freely copyable and `Sendable` but never states whether it contains plaintext filenames, dates, hashes, or other decrypted metadata. Any plaintext placed in such a snapshot can survive lock indefinitely and cannot be revoked by a reader generation counter.

7. **The `~Copyable` and secure-memory design lacks a feasibility gate.** `vaultcore-api-shape.md` names Swift non-copyable maturity as load-bearing, yet `GOAL.md` commits the entire public API to it without pinning a Swift language version, proving the proposed closure/actor signatures compile, or defining a fallback. It also does not establish that the chosen Swift-Sodium surface can decrypt directly into `sodium_malloc` memory without intermediate `[UInt8]`/`Data` copies, nor what happens when `mlock` fails.

8. **The claimed atomic commit is not a complete crash-consistency protocol.** `vaultcore-api-shape.md` §3 describes staging, fsync, “one atomic rename + HEAD swap,” but rename and HEAD replacement are separate visibility points and merging staged CAS objects into existing directories is not one atomic rename. The plan needs an explicit commit point, file and parent-directory fsync ordering, collision behavior, startup recovery rules, and fault-injection gates after every filesystem operation.

9. **Manifest work contradicts the roadmap boundary.** `GOAL.md` Workstream A requires `Manifest`, `FileEntry`, snapshots, WAL mutation, and encrypted per-file metadata, while `MAP.md` assigns the Manifest CRDT, signed entries, tombstones, and merge behavior to a later goal. The plan never distinguishes a temporary local manifest from the future durable manifest, creating either throwaway format work or premature implementation of the next leg.

10. **Tail-padding rules are insufficient for a permanent format.** `GOAL.md` Workstream C.3 does not define the boundary, full-boundary behavior, zero-byte representation, validation of the recorded unpadded length, or whether the length is authenticated. In particular, zero-byte files may remain uniquely identifiable if represented by zero chunks, despite the stated size-hiding property.

11. **The crypto-negative gates cover too little of the authenticated state.** `GOAL.md` Green gate 1 mutates chunk ciphertext but does not require corruption tests for `gallery.meta`, wrapped-DEK nonce/tag, encrypted metadata, manifests, HEAD, truncation, duplicate fields, oversized lengths, or missing/extra chunks. It also omits the runtime lock-versus-read race that is the API design’s most serious named risk.

12. **The “no plaintext ever written to disk” gate is not measurable as written.** `GOAL.md` Green gate 3 proposes a temp-directory sentinel, which can detect a known canary in selected paths but cannot establish the universal claim across alternate directories, error paths, mapped files, framework-created caches, or crash recovery. The gate must define the audited paths and fault cases and narrow its claim to what the harness can actually observe.

13. **The Argon2 requirement is internally inconsistent and accepts attacker-controlled resource parameters without bounds.** `GOAL.md` Workstream B says the benchmark target asserts a 0.5–1 second envelope, while Green gate 4 merely reports macOS timing and executor notes defer meaningful device measurement. Stored parameters also require validated upper and lower limits before allocation, or a modified `gallery.meta` can cause trivial CPU/memory denial of service.

14. **“Formats as contract” has no conformance gate.** `GOAL.md` Workstreams A/C promise a macOS/Linux-facing contract but require only a short prose document and macOS round trips produced and consumed by the same implementation. Canonical byte encoding, magic/version fields, integer endianness, length bounds, hash size, algorithm identifiers, deterministic fixtures, and independent known-answer vectors are required to catch self-consistent but incompatible formats.

15. **A stated hardening requirement is silently dropped at the layer that owns it.** `intake.md` §11 requires local rate-limit/backoff for repeated password failures, and `MAP.md` says hardening items ride the leg whose surface they touch. CED-10 creates the password-unlock surface but includes neither behavior nor a green gate for that requirement.

## Advisories

1. **Sealed-plane “integrity” needs stricter threat-model language.** `vaultcore-api-shape.md` correctly distinguishes address audit from AEAD authenticity, but `GOAL.md` still uses “integrity audit” broadly. A BLAKE2b address check detects corruption or inconsistent naming, not malicious replacement by an actor able to replace both blob and filename.

2. **Concurrent filesystem access is unaddressed.** `vaultcore-api-shape.md` allows a `SealedVault` constructed from a directory URL to enumerate and copy while `Gallery` mutates the same directory, but actor isolation protects only callers using that actor instance. The plan should define snapshot semantics and handling of external processes, multiple instances, symlinks, and files changed during audit/copy.

3. **Compile-fail tests can pass for the wrong reason.** `GOAL.md` Workstream A.2 and `vaultcore-api-shape.md` require negative compilation, but merely observing nonzero `swiftc` status would accept syntax errors, missing imports, or unrelated compiler failures. Fixtures should assert stable diagnostic identifiers or pair each misuse with a nearby positive-compilation control under a pinned toolchain.

4. **BLAKE2b parameters and CAS naming are not specified.** `GOAL.md` Workstream C uses BLAKE2b for both ciphertext addresses and plaintext dedup without selecting digest lengths or domain separation. The format also needs canonical filename encoding and safe no-overwrite insertion semantics.

5. **Password custody receives less treatment than the DEK.** `vaultcore-api-shape.md` exposes `unlock(password:)` without defining whether the password is a Swift `String`, raw UTF-8, normalized Unicode, or a scoped secure buffer. A `String` may create uncontrolled copies, and unspecified normalization can make cross-platform unlock behavior inconsistent.

6. **The resident-plaintext budget and `StreamingSessionActor` are premature scope.** `vaultcore-api-shape.md` introduces playback-specific custody machinery even though `MAP.md` assigns streaming integration and memory-pressure behavior to later legs. CED-10 only needs a minimal reader seam plus tests proving it can safely support that later work.

7. **The multi-tool review gate is a process statement, not an acceptance criterion.** `GOAL.md` Green gate 5 does not define required reviewers, severity policy, reconciliation evidence, or what happens to unresolved findings. It cannot independently determine whether the implementation is green.

8. **“Fixed 4 MiB” and “per-file property” need a bounded compatibility rule.** `GOAL.md` Workstream C.1 fixes 4 MiB while preserving per-file variability for later playback profiles. Readers need a specified allowed range, alignment, and rejection behavior now so hostile metadata cannot request pathological allocations.

## Questions the plan leaves unanswered

1. **What is the exact ownership graph among `SealedVault`, `Gallery`, `UnlockSession`, `ChunkReader`, and the shared key allocation?** `GOAL.md` and `vaultcore-api-shape.md` do not say which object keeps the allocation alive, who may initiate lock, or whether lock waits for in-flight reads.

2. **What durable manifest exists in CED-10?** The documents do not establish whether it is an encrypted local inventory, the first version of the later CRDT manifest, or an intentionally disposable implementation detail.

3. **How are file IDs created and handled on duplicate import, replacement, retry, and recovery?** This answer is required to justify deterministic nonce safety and to define whether duplicate imports create new logical entries while sharing existing chunks.

4. **What exactly does “identical re-import” mean?** `GOAL.md` Green gate 1 does not say whether equality covers only media bytes or also filename, EXIF, sidecars, Live Photo pairing, and import metadata, nor whether dedup skips chunks while still creating another gallery entry.

5. **What is the recovery result for a crash at every commit step?** The plan does not state whether orphan chunks are retained, when WAL directories are deleted, how a corrupt/missing HEAD is recovered, or how the previous manifest is located.

6. **What is the rollback threat model?** An authenticated old manifest and old HEAD can remain cryptographically valid, but the documents do not say whether rollback detection is required, deferred to signed CRDT history, or explicitly out of scope.

7. **What happens when secure-memory guarantees cannot be obtained?** The API shape does not decide whether `sodium_malloc` or `mlock` failure aborts unlock, falls back to ordinary memory with a surfaced warning, or makes the platform unsupported.
