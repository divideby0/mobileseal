# Review wave-003

Blind multi-tool review wave for `CED-10-private-photo-vault` (2026-07-19T21:14:18.749Z).
Each reviewer ran as a labeled tab in the executing session's own herdr
workspace. Model/effort/args columns record per-reviewer provenance;
`(default)` means nothing was passed and the harness kept its own default.

All reviewers completed.

| Tool        | Outcome   | Findings                               | Model     | Effort    | Args | Detail |
| ----------- | --------- | -------------------------------------- | --------- | --------- | ---- | ------ |
| claude-code | completed | [FINDINGS.md](claude-code/FINDINGS.md) | opus      | high      |      |        |
| codex       | completed | [FINDINGS.md](codex/FINDINGS.md)       | (default) | (default) |      |        |
| sonarqube   | completed | [FINDINGS.md](sonarqube/FINDINGS.md)   | (default) | (default) |      |        |
| coderabbit  | completed | [FINDINGS.md](coderabbit/FINDINGS.md)  | (default) | (default) |      |        |

## Merged findings

Reconciled by the executing session, 2026-07-19. First fully clean
wave (all four reviewers completed — codex's two prior failures traced
to an untrusted-repo TUI prompt, fixed before this wave). Sonarqube: 0
open. Note: codex could not run `swift test` in its sandbox (host
denied SwiftPM's nested sandbox-exec — recorded in its FINDINGS); its
findings are static-analysis; claude-code independently verified the
suite green. Fixes below landed in commit `378b026` (55 tests green,
4 consecutive runs).

### Fixed

1. **BLOCKER — writer exclusivity was per-session, not per-vault**
   (claude-code #1 AND codex #1, independently converging;
   claude-code reproduced the silent lost import) — the claim moved
   to a process-wide registry keyed by canonical vault path
   (`VaultProcessRegistry`), claimed at `openGallery()`, released at
   lock or custodian deinit. A second `unlock()` can no longer mint a
   second writer. Regression: `secondUnlockCannotMintSecondWriter`
   (two sessions, second `openGallery` throws, claim releases with
   the owner's lock, no import lost).
2. **Session teardown did not revoke escaped capabilities** (codex
   #2) — `UnlockSession` now has a `deinit` that locks the custodian
   (immediate deadline), honoring the api-shape "deinit self-zeroes"
   contract; an escaped reader fails closed once its session is gone.
   Regression: `droppedSessionRevokesEscapedReader`.
3. **Concurrent unlock attempts bypassed backoff** (codex #4) — the
   check→KDF→record sequence now runs under a per-vault mutex
   (`VaultProcessRegistry.unlockLock`). Regression:
   `concurrentGuessesRespectBackoff` (9 concurrent guesses: ≤6 reach
   the KDF, the rest are `rateLimited`, the persisted count matches).
4. **Post-commit-point durability failure left the actor stale**
   (codex #5) — `commitAppending` now detects a crossed commit point
   (HEAD names the new inventory) on error, adopts the post-state and
   publishes the snapshot before rethrowing; a later mutation can no
   longer silently erase a visible commit.
5. **Regression test for the wave-002 #6 mutation guard did not
   exercise the guard** (claude-code #2, major) — the `ChunkSource`
   seam is now internal and `importSourceMutationGuardsFire` injects
   a shape-shifting source: same-length-different-content and
   shrinking sources both surface `sourceChangedDuringImport`, with
   the vault unchanged and WAL clean. The old test remains, renamed
   to what it actually asserts (`distinctContentDoesNotFalselyDedup`).
6. **Dedup-path commit failure leaked WAL staging** (claude-code #3)
   — `commitAppending` aborts a self-created transaction on
   non-simulated failure (SimulatedCrash carve-out preserved for the
   recovery tests).
7. **Dedup re-import could mint a second unreadable entry**
   (claude-code #4) — the shortcut now requires every shared chunk to
   exist in the CAS; otherwise the import falls through and re-seals.
   Scope honesty (`dedupReimportSelfHealsMissingChunk`): the NEW
   entry is fully readable; the ORIGINAL broken entry cannot be
   healed in place because random nonces give re-sealed chunks new
   addresses — entry repair is recorded as a follow-up for the
   GC/repair leg.
8. **v0 accepted nonzero keyring epochs** (codex #7) — parser now
   rejects `epoch != 0` (`nonzeroEpochRejectedInV0`).
9. **mlock degradation was silent** (codex #8) — first secure
   allocation probes `sodium_mlock`; refusal sets the public
   `SecureMemoryStatus.pageLockingDegraded` flag and logs one
   warning. (A forced-failure unit test is not portably writable;
   the observable flag is the deliverable.)
10. **Unused `Sodium` product dependency** (claude-code #5, nit) —
    dropped; `Clibsodium` is the sole product, matching the
    deliberate raw-C-API custody design.
11. **`inout [UInt8]` wipe over-promised under COW aliasing**
    (coderabbit) — doc reworded to best-effort with the
    uniquely-referenced requirement stated.

### Rejected / deferred, with reasons

- **Toolchain pin not exact + no CI** (codex #6) — deferred to a new
  goal: the repo has no CI infrastructure yet (recorded in RESULT.md
  from the start); `.swift-version` + the manifest pin the 6.2 line,
  and the exact-build assertion belongs to the CI leg that owns
  workflow files. Not a code defect this leg can close.
- **Bounded drain leaves lease copies + post-AEAD straggler success**
  (codex #3) — partially by-design, already documented: leases exist
  ONLY on sealing paths (encryption; no plaintext revocation at
  stake, commits refused post-lock) and are drain-AWAITED; the
  bounded force-zero race and its plaintext-callback scope are
  written decisions in docs/formats.md §Security notes (wave-002
  reconciliation). The read path decrypts against the custodian's
  allocation, which is what the drain guarantee covers.
- **Apple-only syscalls in the portable core** (claude-code #6, nit)
  — explicitly in-scope for this leg ("macOS toolchain only"); the
  portability contract is the FORMATS (ADR 0001). `#if canImport`
  shims are noted for the CLI leg.
- **adhd prompt absolute paths** (coderabbit, third repeat) —
  immutable session provenance; same disposition as waves 001/002.
- **wave-002 sonarqube run.sh "fixed project key"** (coderabbit) —
  misread: `mobileseal-CED-10-private-photo-vault` IS the per-branch
  ephemeral key (`<baseKey>-<branch>`, EVA-11 isolation); committed
  run.sh files are self-locating RECORDS of a wave, not replayable
  scripts (their own header says so).

### Wave verdict

All four reviewers completed; the blocker and every accepted finding
fixed and regression-locked in `378b026`; remaining items are
reasoned rejections or recorded deferrals. `swift test`: 55 tests in
13 suites, green across 4 consecutive runs. Gate 9's acceptance
criteria are met on this wave.
