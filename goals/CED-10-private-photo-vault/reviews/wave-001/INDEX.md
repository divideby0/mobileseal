# Review wave-001

Blind multi-tool review wave for `CED-10-private-photo-vault` (2026-07-19T20:41:59.315Z).
Each reviewer ran as a labeled tab in the executing session's own herdr
workspace. Model/effort/args columns record per-reviewer provenance;
`(default)` means nothing was passed and the harness kept its own default.

WAVE FAILED: codex (failed) — failures are reported, never silently absorbed; rerun or reconcile explicitly.

| Tool        | Outcome   | Findings                               | Model     | Effort    | Args | Detail                                        |
| ----------- | --------- | -------------------------------------- | --------- | --------- | ---- | --------------------------------------------- |
| claude-code | completed | [FINDINGS.md](claude-code/FINDINGS.md) | opus      | high      |      |                                               |
| codex       | failed    | none produced (failed at launch)       | (default) | (default) |      | agent_not_found: agent target w1:p5 not found |
| sonarqube   | completed | [FINDINGS.md](sonarqube/FINDINGS.md)   | (default) | (default) |      |                                               |
| coderabbit  | completed | [FINDINGS.md](coderabbit/FINDINGS.md)  | (default) | (default) |      |                                               |

## Merged findings

Reconciled by the executing session, 2026-07-19. The codex failure is
a recorded wave failure (its recurring spawn race, `agent_not_found`
after the automatic launch retry); wave-002 reruns all four reviewers
on the fixed tree so codex reviews it for real. Sonarqube: 0 open
issues — nothing to reconcile. Dispositions below; "fixed" items
carry regression tests where testable (ReviewRegressionTests, the new
LockRaceTests, tightened conformance assertions).

### Fixed

1. **readRange offset overflow traps the process** (claude-code #1
   major + coderabbit) — overflow-safe bounds check; regression test
   `readRangeRefusesOverflowingOffset` covers `UInt64.max`-adjacent
   offsets. `ChunkReader.swift`.
2. **Two `Gallery` instances silently drop a committed import**
   (claude-code #2 major, repro-confirmed) — single-writer claim is
   now structural: `openGallery()` throws typed `.galleryAlreadyOpen`
   on the second call (`KeyCustodian.claimWriter`). Regression test
   `secondGalleryIsRefused`.
3. **`FS.read` bounds enforced only after full materialization**
   (claude-code #3 major) — rewritten to fstat-then-capped-read on one
   descriptor (no TOCTOU); `copyChunk`/`auditAddresses` now pass real
   bounds (`maxStoredChunkBytes`, `maxInventoryObjectBytes`).
   Regression test `oversizedObjectRefusedBeforeAllocation`
   (sparse-extended chunk object refused by stat).
4. **`keyCopy()` escaped drain custody** (claude-code #5) — replaced
   by `KeyLease`: a lease counts as an active read until deinit, so
   `lockAndDrain` waits for the actor's sealing operations too. Test
   `lockWaitsForOutstandingLease`.
5. **Injectable `VaultClock` neutralized the rate limiter**
   (claude-code #7) — clock removed from the public API; internal
   seam reached via `@testable` only.
6. **Drain-wait untested** (claude-code #8) — real test parks a reader
   inside key custody and asserts `lock()` blocks for the hold
   (`lockWaitsForParkedInFlightRead`); the vacuous `allSatisfy`
   pattern coderabbit flagged is gone with it.
7. **Throttle sidecar unsynced + trusts future timestamps**
   (claude-code #10) — writes fsync; future-dated `lastFailureAt`
   clamps to now.
8. **`fsyncDir` swallowed errors despite normative ordering**
   (claude-code #11) — now throws `ioFailure` on failure.
9. **Empty password / single-NUL KEK collision** (claude-code #13) —
   empty password refused with typed `.emptyPassword`; regression
   test.
10. **Metadata blobs outlive lock in ordinary heap** (claude-code #4)
    — partially fixed, partially documented: the transient decrypted
    inventory body is now zeroed after parse; the retained per-entry
    blobs are recorded as a deliberate custody trade in
    `docs/formats.md` §Security notes (apps should pre-encrypt
    sensitive metadata — the field is opaque by design) and the
    misleading code comment corrected. Full `SecureBytes` custody for
    metadata would ripple the whole snapshot/accessor API for bytes
    VaultCore treats as ciphertext; revisit if the App Shell leg
    stores plaintext EXIF there.
11. **NFC normalization leaves an unwiped intermediate `String`**
    (claude-code #9) — documented honestly in the initializer doc and
    `docs/formats.md` §Security notes; callers can pass pre-normalized
    bytes via `init(consumingAndZeroing:)`. A byte-level NFC
    implementation is not worth the risk this leg.
12. **Force-zero races in-flight decrypts** (claude-code #6) — the
    bounded race is now a WRITTEN decision (`docs/formats.md`
    §Security notes + `KeyCustodian` doc): AEAD guarantees a
    partially-zeroed key never yields plaintext; bounded blocking was
    chosen over unbounded waiting per the GOAL's drain-on-lock spec.
13. **Inventory epoch not discoverable by independent readers**
    (coderabbit major, the one real contract gap it found) —
    `docs/formats.md` now specifies normative authenticated
    trial-decryption across keyring epochs (AAD binds the epoch, so a
    successful open authenticates it; ≤8 entries bounds the work).
    No format-byte change; fixture unchanged.
14. **Compile-fail harness pipe deadlock** (coderabbit) — pipe drained
    before `waitUntilExit()`.
15. **Conformance test accepted over-padded tails** (coderabbit) —
    now asserts the EXACT padded length per the format rule.
16. **Stale references** (coderabbit minors) — ADR now says "intake
    spec §5.1" explicitly; CONTEXT.md's gallery term no longer implies
    a `galleries/{id}/` layout this leg ships; MAP.md's benchmark line
    matches the macOS-only scope and its format-contract fog item is
    marked resolved.

### Rejected, with reasons

- **"Commit the fixture assets this test requires"** (coderabbit
  major) — false positive: the full fixture vault IS committed
  (`git ls-files Tests/VaultCoreTests/Fixtures/kat-vault` lists
  gallery.meta, HEAD, chunks, manifest, file-a.bin, expected.json);
  the reviewer saw a truncated file listing.
- **"Narrow the HEAD-corruption gate / rollback"** (coderabbit, on
  GOAL.md) — the corruption matrix already tests malformed/missing/
  dangling HEAD, which is what the recovery spec covers; rollback
  detection is explicitly out of scope for a lone local vault (Codex
  Q6 disposition, recorded in GOAL.md and formats.md). Green-gate text
  is not edited mid-execution.
- **All findings against `adhd/session-001-*/…` prompts and outputs**
  (coderabbit: stale absolute paths, five-of-six ideas, AEAD-claims
  inside brainstorm sketches, audit-ledger critique, etc.) — these
  files are immutable session provenance, not living design docs; the
  ideas coderabbit critiques were already superseded by the composed
  API shape and its post-review amendments. Re-running those prompts
  is not a supported operation.
- **PostgreSQL schema and secretbox wording in `intake.md`**
  (coderabbit) — intake.md is the verbatim v0.1 capture, immutable by
  design; GOAL.md's References section already records that §5.3's
  nonce scheme is superseded, and the Supabase schema belongs to a
  far-future leg that will draft its own spec.
- **`Manifest`/`FileEntry` naming in `vaultcore-api-shape.md`**
  (coderabbit) — historical synthesis document; the shipped code uses
  `Inventory`/`InventoryEntry`/`InventorySnapshot` per the CED-10
  boundary (Codex B9), which is the binding surface.

### Wave verdict

All blocking findings fixed and regression-locked; `swift test` green
(45 tests, 12 suites) after the fixes. Codex's failure is recorded
above and remediated by wave-002 (see `../wave-002/INDEX.md`).
