---
status: started
created: 2026-07-18T16:41:18-05:00
author: cedric
promoted: 2026-07-19T13:38:51-05:00
issue_url: https://linear.app/cedric-personal/issue/CED-10/build-vaultcore-encryption-and-chunk-store
linear_project: Mobileseal
linear_project_id: cccebfd8-6d19-474b-852f-c87bf528dcf6
started: 2026-07-19T14:59:30-05:00
---

# Build VaultCore Encryption and Chunk Store

## Problem

The Private Photo Vault effort (full v0.1 spec preserved verbatim at
`references/intake.md`; wayfinder map at `wayfinder/MAP.md`) needs its
foundation: a portable cryptographic core. Everything downstream — the
iOS app shell, streaming playback, gallery management, CRDT sync, and
the eventual macOS/Linux CLI peer — layers over the primitives this
goal builds. Grilling session 001 re-scoped this draft from the
original XXL 10-phase idea down to this map-leg (L on the fixed
Fibonacci t-shirt scale). A pre-execution blind Codex plan review
(`references/codex-plan-review-20260719.md`) hardened this spec; its
dispositions are recorded in that file's appendix.

## Scope

Create **VaultCore**, a UIKit/SwiftData-free Swift package (the
portable core; its on-disk formats are the cross-platform contract),
plus the repo's Swift scaffolding to host it. Per intake spec §5–§6,
session-001 decisions, and the Codex-review amendments:

### Workstream A — package scaffolding

1. SwiftPM package `VaultCore` with Swift-Sodium (libsodium) as the
   sole crypto dependency; builds and tests on macOS via `swift test`
   (iOS app targets arrive in the next map leg).
2. **Feasibility spike first** (Codex B7): before building the full
   surface, prove on a pinned Swift toolchain that the move-only
   (`~Copyable`) `UnlockSession`/`SecureBytes` signatures compile in
   the shapes the API needs (scoped closures, actor boundaries), and
   that Swift-Sodium can decrypt into `sodium_malloc` memory without
   intermediate `Data` copies. Documented fallback if the toolchain
   can't: class-based custody with runtime lock checks, same public
   semantics.
3. Public API per `references/vaultcore-api-shape.md` **as amended by
   its "Post-review amendments" section**: `SealedVault` ciphertext
   plane (no-DEK operations: chunk enumeration/copy, address audit,
   meta parse) / move-only `UnlockSession` plaintext plane with
   `SecureBytes` scoped custody / `Gallery` actor owning WAL-staged
   atomic mutation, immutable snapshot reads, and generation-revocable
   off-actor `ChunkReader`s with **drain-on-lock semantics** (lock
   refuses new reads immediately, waits up to a short deadline
   (~500 ms) for in-flight reads, then force-zeroes; in-flight readers
   that lose the race fail closed with a typed error). Compile-fail
   misuse harness is part of the test suite, each negative fixture
   paired with a positive-compilation control (Codex A3).
4. Seed `CONTEXT.md` glossary (gallery, DEK/KEK, epoch keyring, chunk,
   entry, tombstone, sealed/unlocked plane, snapshot, inventory) and
   `docs/adr/0001` recording the portable-core / formats-as-contract
   decision.

### Workstream B — envelope encryption

1. Per-gallery 256-bit DEK. `gallery.meta` is a versioned, bounded
   format (magic + format version + explicit field lengths) holding a
   **keyring**: a list of wrapped-DEK entries keyed by epoch (today:
   exactly one, epoch 0) — not a lone integer beside a single
   `wrapped_dek` (Codex B4). DEK wrapping uses
   `crypto_aead_xchacha20poly1305_ietf` with a random 24-byte nonce
   stored in the entry and AAD binding (gallery UUID, epoch, format
   version); KEK = Argon2id(`crypto_pwhash`, alg ARGON2ID13) over the
   per-gallery salt (Codex B2 — exact primitives named, no
   "secretbox-equivalent" ambiguity).
2. Argon2id defaults per
   `research/_default/argon2id-tuning-on-modern-iphones.md`:
   `opslimit=3`, `memlimit=256 MiB` (libsodium MODERATE), stored per
   gallery. **Stored parameters are validated against hard bounds
   before any allocation** (opslimit and memlimit floors/ceilings), so
   tampered `gallery.meta` cannot DoS the device (Codex B13).
3. Password custody: unlock takes NFC-normalized UTF-8 bytes in a
   zeroed-after-use buffer, never a retained Swift `String` (Codex A5).
4. Local rate-limit/backoff on repeated failed unlock attempts,
   implemented in VaultCore (this goal creates the surface; intake §11
   requirement rides this leg — Codex B15).
5. Benchmark executable target reporting Argon2id unlock timing on
   macOS for the chosen params. The 0.5–1 s envelope is asserted on
   real devices at the App Shell leg where a device target first
   exists; this goal records honest macOS numbers only (Codex B13).

### Workstream C — chunked content-addressed store

1. Fixed-size 4 MiB chunking (confirmed by
   `research/_default/chunk-size-for-encrypted-media-cas.md`; chunk
   size is a per-file property recorded in the inventory, with a
   bounded allowed range and alignment rule so hostile metadata cannot
   request pathological allocations — Codex A8), each chunk
   independently encrypted with `crypto_aead_xchacha20poly1305_ietf`.
2. **Random 24-byte (192-bit) nonce per chunk, stored in a versioned
   chunk header** — this deliberately supersedes intake §5.3's
   deterministic `(fileID, chunkIndex)` derivation (Codex B1: fileID
   uniqueness is unprovable across re-imports/retries/multi-device;
   XChaCha's nonce size exists for exactly this). Chunk AAD binds
   (gallery UUID, file ID, chunk index, epoch, format version), so a
   validly-tagged chunk cannot be substituted at another position
   (Codex B3).
3. Chunk address = BLAKE2b-256 over the full stored object (header +
   ciphertext); dedup hash = BLAKE2b-256 over plaintext with a
   distinct domain-separation prefix, carried only inside encrypted
   metadata (Codex A4). CAS insertion is no-overwrite: an existing
   address is never rewritten.
4. Tail-chunk padding (grill Q12) with normative rules (Codex B10):
   the boundary value lives in the format doc; the unpadded length is
   recorded inside AEAD-protected metadata and validated against
   chunk contents on read; zero-byte files are representable without
   a unique fingerprint (empty file ⇒ one padded chunk, not zero
   chunks). Decoy-chunk bucketing stays deferred to the cloud leg.
5. **Local encrypted inventory, format-version 0** (Codex B9): a
   minimal encrypted index (file entries: file ID, chunk refs +
   per-chunk addresses, plaintext dedup hash, unpadded length,
   encrypted metadata blob) — explicitly a local artifact that the
   Manifest-CRDT leg supersedes with the durable signed-entry format;
   version field present so the migration is detectable. No signed
   entries, tombstones, or merge logic in this goal.
6. Crash-consistency protocol, specified not implied (Codex B8):
   mutations stage under `wal/{txid}/`; the commit point is a single
   atomic rename of the new inventory object followed by the HEAD
   pointer swap, with fsync ordering defined (object file, then its
   parent directory, then HEAD, then HEAD's parent); startup recovery
   deletes orphaned WAL dirs and defines behavior for corrupt/missing
   HEAD (fall back to last valid inventory reachable from the CAS);
   file IDs are random UUIDs minted once per logical import and never
   reused across retries (retry ⇒ new txid, same file ID only if the
   prior txid never committed).
7. On-disk layout per spec §6 (`galleries/{id}/gallery.meta`,
   `chunks/{hash}`, …); random-access decrypt of an arbitrary chunk
   range; AEAD tag verified on every read.
8. `docs/formats.md` — the cross-platform contract, with normative
   detail (Codex B14): canonical byte encodings, endianness, magic +
   version fields, field length bounds, hash lengths, algorithm
   identifiers, the padding boundary, and committed known-answer test
   vectors (fixture vault + expected addresses/plaintexts) that an
   independent implementation can verify against.

## Green gates

1. `swift test` (macOS) green, covering: encrypt→decrypt round-trip
   byte-identical across 0-byte, sub-chunk, exact-boundary, and
   multi-chunk files; import-dedup detects an identical re-import
   without re-storing chunks (identity = media bytes; a re-import
   creates a new inventory entry sharing chunks); wrong password fails
   cleanly; **corruption matrix** (Codex B11): tampering any byte of
   chunk ciphertext, chunk header, `gallery.meta` keyring entry,
   inventory object, or HEAD — plus truncation, missing chunk, extra
   orphan chunk, and oversized declared lengths — each fails with the
   right typed error and never returns plaintext.
2. Random-access proof: decrypting an arbitrary mid-file chunk range
   touches only those chunks (no whole-file decrypt), demonstrated by
   test.
3. Plaintext-custody gate, scoped to what the harness can observe
   (Codex B12): no VaultCore API writes plaintext under the vault
   root or the process temp directory, verified by sentinel canaries
   and filesystem observation across normal operation, error paths,
   and simulated-crash recovery; the claim and its audited path set
   are stated in the test.
4. Crash-consistency fault injection (Codex B8): tests kill/abort at
   each step of the commit sequence and assert recovery yields either
   the full pre-state or full post-state, never a corrupt vault.
5. Lock-vs-read race test (Codex B5): concurrent readers during
   lock() either complete within the drain deadline or fail closed
   with the typed lock error; the DEK allocation is provably zeroed
   after drain; no read ever observes a partially-zeroed key.
6. Unlock rate-limit test: repeated failures back off per the
   documented policy.
7. Format conformance: known-answer vectors round-trip; the committed
   fixture vault decodes to expected plaintexts; `docs/formats.md`
   covers every field a third-party decryptor needs (checked against
   the fixture by a test that parses using only documented constants).
8. Benchmark target runs on macOS and reports Argon2id timing for the
   chosen params; params + rationale recorded in RESULT.md against
   the research report (device-envelope assertion explicitly deferred
   to the App Shell leg).
9. Blind multi-tool review wave completed with all four configured
   reviewers (claude-code, codex, sonarqube, coderabbit) finishing or
   their failure recorded as a wave failure; merged findings
   reconciled in the wave INDEX.md with a recorded disposition
   (fixed / rejected-with-reason / deferred-to-new-goal) for every
   finding; no blocking finding left unresolved (Codex A7).

## References

- `references/intake.md` — full v0.1 spec (§5 crypto, §6 layout are
  this goal's sections; §5.3's deterministic nonce derivation is
  superseded by Workstream C.2).
- `references/vaultcore-api-shape.md` — ADHD session 001 synthesis
  plus post-review amendments (drain-on-lock, snapshot metadata
  custody, trimmed streaming scope, mlock-failure policy).
- `references/codex-plan-review-20260719.md` — blind pre-execution
  plan review; dispositions appendix maps every finding to the
  change above (or the recorded reason it wasn't taken).
- `wayfinder/MAP.md` — the map this goal is the first leg of;
  recrafted forward when this goal locks.
- `grilling/session-001-20260718-165000.md` — decision provenance
  (Q1–Q12).
- `research/_default/argon2id-tuning-on-modern-iphones.md` and
  `research/_default/chunk-size-for-encrypted-media-cas.md` (repo
  root `research/`, committed on main) — delivered 2026-07-19; folded
  into Workstreams B/C.

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- The repo has no Swift code yet — this goal creates the first
  package; there is no Xcode project until the App Shell leg.
- Swift-Sodium via SPM (github.com/jedisct1/swift-sodium). Do not add
  CryptoKit, OpenPGP, or secretstream-based designs (spec §5.1
  explicitly rejects them).
- Pin the Swift toolchain version in the package manifest and CI
  invocation; the `~Copyable` feasibility spike (Workstream A.2) runs
  before the full API is built, and its outcome (native move-only vs
  documented fallback) is recorded in RESULT.md.
- `sodium_malloc` failure aborts unlock with a typed error; `mlock`
  failure (common under iOS memory limits) logs a warning and
  proceeds — guarded allocation is still used, only page-locking is
  best-effort. Record this policy in `docs/formats.md`'s security
  notes (Codex Q7 disposition).
- macOS toolchain only for this goal; device benchmarking happens in
  later legs (the benchmark target just needs to be portable).
- Both research reports are delivered and committed on main under
  `research/_default/`; no pending inputs remain.
- Wayfinder rule: this goal locks → next draft (iOS Vault App Shell or
  Manifest CRDT leg) recrafts `wayfinder/MAP.md` forward from this
  folder's locked snapshot.
