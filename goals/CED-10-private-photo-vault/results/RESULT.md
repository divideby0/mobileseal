# CED-10 Result: Build VaultCore Encryption and Chunk Store

## What changed

The repo went from zero Swift code to a complete, tested VaultCore
package. Commits, in order:

- `72c3113` feat: scaffold VaultCore SwiftPM package — root-level
  Package.swift, Swift-Sodium 0.9.1 pinned exact (sole crypto
  dependency, exposing both the `Sodium` wrapper and the `Clibsodium`
  C module), toolchain pinned to Apple Swift 6.2 via `.swift-version`.
- `0814324` test: prove ~Copyable + sodium_malloc feasibility spike —
  WS A.2 ran FIRST as mandated (details under Gate outcomes; the
  fallback design was not needed).
- `e72b5ff` feat: VaultCore two-plane crypto core and chunk store —
  the whole of workstreams B and C (~15 source files; see below).
- `3e9690f` test: green-gate suites (gates 1–6).
- `78780f0` test: compile-fail misuse harness with paired controls.
- `767d406` docs: normative format contract + committed KAT fixture.
- `025f9ca` docs: glossary, ADR 0001, Argon2id benchmark target.

### Spike outcome (WS A.2, Codex B7) — native move-only, no fallback

On the pinned toolchain (Apple Swift 6.2, swiftlang-6.2.0.19.9) all
required shapes compile and run: `~Copyable` structs with `consuming
func lock()`, borrowing scoped closures, actor interop with a
reference-typed custodian, and Clibsodium decrypting AEAD ciphertext
**directly into `sodium_malloc` memory** with no intermediate
`Data`/array plaintext copy. The class-based-custody fallback was NOT
needed. Kept as `FeasibilitySpikeTests` in the suite.

Surprises worth recording for later legs:

- `sodium_init()` must run before any `sodium_malloc` — the guard
  canary otherwise aborts the process (hit under parallel tests).
  `SodiumRuntime.ensure()` now gates every allocation.
- The Swift 6.2 region-based isolation checker rejects borrowing a
  move-only buffer inside a closure formed in actor-isolated code
  ("sending 'buffer' risks causing data races"). Fix: the custodian
  grew `keyCopy()` (scoped secure copy under read custody) so the
  actor's import path avoids closure-captured `SecureBytes`.
- `-typecheck` does NOT run the move-only ownership diagnostics; the
  compile-fail harness must use `-emit-sil` (SIL-pass diagnostics) or
  every negative fixture passes vacuously.
- Top-level (main-actor global) move-only bindings are borrowed and
  cannot be consumed — executable targets must wrap session lifecycle
  in a function.

### Design decisions made during execution (not in the spec)

- **`aad_file_id` inventory field**: chunk AAD binds the sealing file
  ID (Codex B3), but dedup re-imports share chunks sealed under the
  ORIGINAL importer's ID. Each entry therefore records the AAD context
  its chunks decrypt under (`aad_file_id` = own ID for first import,
  original's for dedup). Documented in formats.md; exercised by the
  KAT fixture's dedup pair.
- **Tamper vs. wrong password**: keyring-entry tamper and wrong
  password are cryptographically indistinguishable; both surface one
  typed error (`dekUnwrapFailed`), documented as deliberate.
- **HEAD damage recovers; inventory tamper errors**: corrupt/missing/
  dangling HEAD falls back to the highest-generation valid inventory
  and repairs HEAD (spec'd behavior), but a present HEAD target that
  fails AEAD surfaces `authenticationFailed(.inventory)` — deliberate
  tampering is not silently rolled back to older data.
- **Read-path error tiers**: the hot read path relies on AEAD (tag +
  positional AAD) rather than re-hashing addresses, so tampered chunk
  bytes surface as `authenticationFailed(.chunk)`; address mismatches
  are the sealed audit's tier (`auditAddresses`/`copyChunk`). This
  keeps the two verification tiers named and distinct (Codex A1).

## What did NOT need changing

- No CI config existed or was added — the repo has no CI yet; the
  pinned-toolchain requirement is carried by `.swift-version` plus the
  manifest comment, and the wave/benchmark ran locally.
- Decoy-chunk bucketing, DEK rotation mechanics, tombstones, signed
  entries, and streaming custody budgets: all explicitly deferred by
  the spec to later legs; nothing was pre-built.

## Gate 1 — round-trip, dedup, wrong password, corruption matrix

`swift test` green: **40 tests, 11 suites** (run 3× for stability).
Round-trips are byte-identical across 0-byte, 1 B, sub-chunk,
exact-boundary, exact-2-chunk, and multi-chunk-ragged-tail sizes;
zero-byte files store as exactly one padded chunk. Dedup re-import
creates a new entry sharing the original's chunk addresses with the
chunk-file count unchanged (identity = media bytes; different metadata
per entry). Wrong password throws `dekUnwrapFailed` cleanly.
Corruption matrix (`CorruptionMatrixTests`): chunk ciphertext, header
magic, header nonce, version field, truncation, missing chunk, orphan
chunk, keyring-entry tamper, meta magic/version, oversized KDF params
(pre-allocation), inventory-object tamper, corrupt/missing/dangling
HEAD, all-inventories-invalid, plus parser-level hostile declared
lengths (entry count, metadata length, misaligned chunk size,
inconsistent chunk count, trailing bytes) — each with its documented
typed error or documented recovery, never plaintext.

## Gate 2 — random access

`midFileRangeReadTouchesOnlyNeededChunks`: a range spanning exactly
chunks 2–3 of a 5-chunk file performs exactly **2** chunk decrypts
(instrumented counter), a single-chunk range performs 1, and
out-of-bounds ranges are refused typed.

## Gate 3 — plaintext custody

`CustodyCanaryTests`: canary bytes planted at chunk start, mid-chunk,
boundary straddle, and tail; exercised through create, file + bytes
import, range/chunk reads, error paths (wrong password, out-of-bounds,
tampered-chunk read), and a simulated crash at `stagedInventoryWritten`
plus recovery. The audited path set is stated in the test per Codex
B12: recursive scan of the vault root and the process temporary
directory; swap/core-dumps/other-process caches are explicitly outside
the claim. Zero hits.

## Gate 4 — crash-consistency fault injection

`CrashConsistencyTests` aborts after **each of the 9 commit steps**
(parameterized over `CommitStep.allCases`): recovery yields full
pre-state for every step before the HEAD swap and full post-state at/
after it; the WAL is empty after startup recovery; surviving entries
decrypt end-to-end; deep verification passes; a retry import (fresh
txid) succeeds afterwards.

## Gate 5 — lock-vs-read race

`LockRaceTests`: 8 detached readers hammer range reads until the lock
lands; every read either returned correct bytes or failed closed with
`vaultLocked` (nothing else observed); the custodian's key allocation
is **provably zeroed** after drain (`debugKeyIsZeroed` inspects the
live allocation); post-lock reads and imports are refused immediately;
`lock()` returns within the 500 ms drain deadline.

## Gate 6 — unlock rate limit

`RateLimitTests` against an injected clock: 5 free failures, then
cooldowns 2 s → 4 s → … capped at 300 s, exact schedule asserted;
attempts during cooldown throw `rateLimited` WITHOUT running the KDF;
success resets the counter and removes the sidecar; a corrupt sidecar
degrades to absent (documented local-only mechanism).

## Gate 7 — format conformance

`FormatConformanceTests.thirdPartyDecryptRoundTrip` decodes the
committed fixture vault (`Tests/VaultCoreTests/Fixtures/kat-vault/`,
three entries incl. an empty file and a dedup pair) using ONLY
constants transcribed from `docs/formats.md` — independent parsing
code, no VaultCore imports for the decode path — deriving the KEK,
unwrapping the DEK, walking HEAD → inventory → chunks, validating
padding and dedup-hash domain separation, and matching the committed
plaintexts and pinned addresses in `expected.json`. The reference
implementation also reads the same fixture (mutual check). Regenerate
with `VAULTCORE_REGEN_FIXTURE=1 swift test --filter KATFixtureGenerator`.

## Gate 8 — Argon2id benchmark

`swift run -c release argon2-bench` on this macOS machine (Apple M4
Pro, macOS 15.7.2), median of 5 after warmup:

| parameters                              | median      |
| --------------------------------------- | ----------- |
| INTERACTIVE (2 ops, 64 MiB)             | 0.051 s     |
| 3 ops, 128 MiB                          | 0.160 s     |
| **MODERATE — default (3 ops, 256 MiB)** | **0.331 s** |
| 3 ops, 384 MiB                          | 0.515 s     |
| 3 ops, 512 MiB                          | 0.691 s     |
| full `SealedVault.unlock` (defaults)    | 0.324 s     |

Params follow `research/_default/argon2id-tuning-on-modern-iphones.md`
(opslimit 3 / memlimit 256 MiB, libsodium MODERATE), stored per
gallery with hard bounds [1..12] × [16 MiB..1 GiB] validated before
allocation. These are **honest macOS numbers only**: an M4 Pro is
faster than any target iPhone; the 0.5–1 s device envelope is
asserted at the App Shell leg per Codex B13. The research report's
prediction that 256 MiB lands well inside the envelope on Apple
silicon is consistent with these numbers.

## Gate 9 — blind review wave

Two waves, both fully reconciled:

- **wave-001** (`reviews/wave-001/INDEX.md`): claude-code (opus/high)
  13 findings — three majors, two of them repro-confirmed (readRange
  overflow trap; two-Gallery silent import loss); coderabbit 34
  findings (two real code fixes, one real contract gap — inventory
  epoch discoverability — the rest against immutable provenance
  artifacts, rejected with reasons); sonarqube 0 open. Codex FAILED
  on its recurring spawn race (`agent_not_found` after the automatic
  retry) — recorded as a wave failure per the never-absorbed rule.
  Every accepted finding was fixed and regression-locked in commit
  `27bf0e7` (see the INDEX's 16-item fixed list + 5 reasoned
  rejections).
- **wave-002** (`reviews/wave-002/INDEX.md`): rerun of all four
  reviewers, blind, against the fixed tree — so codex's review
  actually happened and the fixes themselves got re-reviewed.
  {WAVE-002 OUTCOME RECORDED AFTER COMPLETION}

## Follow-ups

- **Wayfinder**: next leg (iOS Vault App Shell or Manifest CRDT)
  recrafts `wayfinder/MAP.md` forward from this locked snapshot.
- **Device benchmark** rides the App Shell leg (first device target):
  assert the 0.5–1 s envelope, and add the adaptive calibration step
  the research report recommends (raise memlimit only when measured
  headroom allows).
- **Orphan-chunk GC** — deep verify reports orphans; reclaiming them
  is a future tombstone/GC leg.
- **Multi-process semantics** (Codex A2) — single-process assumption
  documented; the CLI leg owns cross-process locking.
- **swift-sodium staleness**: 0.9.1 (2021) ships a prebuilt
  libsodium xcframework. Fine for this leg; the CLI leg should
  revisit (Linux uses the system libsodium via pkg-config, so version
  skew between platforms is possible and worth pinning there).
- **`.coderabbit.yaml` missing**: the EVA-9 convention excludes
  `goals/**/reviews/**` (and session provenance like `goals/**/adhd/**`)
  via `reviews.path_filters` so CodeRabbit stops re-litigating
  immutable records — wave-001's noise against adhd artifacts was
  exactly this. Could not be added mid-goal without perturbing a
  running blind wave; first commit of the next goal should add it.
- **Metadata custody upgrade**: if the App Shell leg puts plaintext
  EXIF/names in the metadata blob, revisit holding blobs in
  `SecureBytes` (today: opaque bytes in ordinary heap, access-revoked
  on lock — the documented wave-001 trade).
