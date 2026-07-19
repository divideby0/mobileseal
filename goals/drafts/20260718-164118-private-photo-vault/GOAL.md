---
status: draft
created: 2026-07-18T16:41:18-05:00
author: cedric
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
Fibonacci t-shirt scale).

## Scope

Create **VaultCore**, a UIKit/SwiftData-free Swift package (the
portable core; its on-disk formats are the cross-platform contract),
plus the repo's Swift scaffolding to host it. Per intake spec §5–§6
and session-001 decisions:

### Workstream A — package scaffolding

1. SwiftPM package `VaultCore` with Swift-Sodium (libsodium) as the
   sole crypto dependency; builds and tests on macOS via `swift test`
   (iOS app targets arrive in the next map leg).
2. Seed `CONTEXT.md` glossary (gallery, DEK/KEK, chunk, entry,
   tombstone, epoch) and `docs/adr/0001` recording the portable-core /
   formats-as-contract decision.

### Workstream B — envelope encryption

1. Per-gallery 256-bit DEK; KEK = Argon2id(password, per-gallery
   salt); `gallery.meta` blob stores wrapped_dek, salt, argon2
   params, and a reserved `epoch` integer (always 0 — rotation is
   deliberately deferred, spec §5.6).
2. Argon2id defaults from the delivered research report
   (`research/_default/argon2id-tuning-on-modern-iphones.md`), stored
   per gallery so later tuning never breaks existing vaults; include a
   benchmark executable target (runnable on device later) asserting
   the 0.5–1s unlock envelope.

### Workstream C — chunked content-addressed store

1. Fixed-size chunking (default 4 MiB pending the chunk-size research
   report), each chunk independently encrypted with
   XChaCha20-Poly1305, nonce derived from (fileID, chunkIndex) — never
   secretstream, never OpenPGP (spec §5.1).
2. Chunk address = BLAKE2b(ciphertext); manifest-level dedup via a
   plaintext BLAKE2b carried inside encrypted per-file metadata
   (session-001 Q6 — storage stays fully opaque, import-time dedup).
3. On-disk layout per spec §6 (`galleries/{id}/gallery.meta`,
   `chunks/{hash}`, …); random-access decrypt of an arbitrary chunk
   range; AEAD tag verified on every read.
4. A short `docs/formats.md` describing gallery.meta and the chunk/CAS
   layout — the first cut of the cross-platform contract.

## Green gates

1. `swift test` (macOS) green, covering: encrypt→decrypt round-trip is
   byte-identical across files spanning 0 bytes, sub-chunk, exact
   chunk-boundary, and multi-chunk sizes; tampered ciphertext (any
   chunk, any byte) fails AEAD verification and is reported, never
   returned; wrong password fails cleanly; import-dedup detects an
   identical re-import without re-storing chunks.
2. Random-access proof: decrypting an arbitrary mid-file chunk range
   touches only those chunks (no whole-file decrypt), demonstrated by
   test.
3. No plaintext ever written to disk by any VaultCore API (audited by
   test using a temp-dir sentinel).
4. Benchmark target runs on macOS and reports Argon2id unlock time for
   the chosen params; params + rationale recorded in RESULT.md against
   the research report.
5. Blind multi-tool review wave completed and reconciled.

## References

- `references/intake.md` — full v0.1 spec (§5 crypto, §6 layout are
  this goal's sections).
- `wayfinder/MAP.md` — the map this goal is the first leg of;
  recrafted forward when this goal locks.
- `grilling/session-001-20260718-165000.md` — decision provenance
  (Q4 portable core, Q6 addressing, Q7 epochs, Q9–Q10 research, Q11
  testing).
- `research/_default/argon2id-tuning-on-modern-iphones.md` and
  `research/_default/chunk-size-for-encrypted-media-cas.md` (repo
  root `research/`, main branch once delivered) — dispatched
  2026-07-19; fold their recommendations in before executing
  Workstreams B/C constants.

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- The repo has no Swift code yet — this goal creates the first
  package; there is no Xcode project until the App Shell leg.
- Swift-Sodium via SPM (github.com/jedisct1/swift-sodium). Do not add
  CryptoKit, OpenPGP, or secretstream-based designs (spec §5.1
  explicitly rejects them).
- macOS toolchain only for this goal; iOS/device benchmarking happens
  in later legs (the benchmark target just needs to be portable).
- Research reports land under `research/_default/` on main via a
  detached delivery worker; if absent at execution start, check
  `evie-agent research status --slug <slug>` (env: source
  `.envrc.local`) and proceed with libsodium MODERATE / 4 MiB defaults
  if runs are still pending, noting that in RESULT.md.
- Wayfinder rule: this goal locks → next draft (iOS Vault App Shell or
  Manifest CRDT leg) recrafts `wayfinder/MAP.md` forward from this
  folder's locked snapshot.
