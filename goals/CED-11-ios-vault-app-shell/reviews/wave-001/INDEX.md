# Review wave-001

Blind multi-tool review wave for `CED-11-ios-vault-app-shell` (2026-07-19T23:42:02.202Z).
Each reviewer ran as a labeled tab in the executing session's own herdr
workspace. Model/effort/args columns record per-reviewer provenance;
`(default)` means nothing was passed and the harness kept its own default.

All reviewers completed.


| Tool | Outcome | Findings | Model | Effort | Args | Detail |
|---|---|---|---|---|---|---|
| claude-code | completed | [FINDINGS.md](claude-code/FINDINGS.md) | opus | high |  |  |
| codex | completed | [FINDINGS.md](codex/FINDINGS.md) | (default) | (default) |  |  |
| sonarqube | completed | [FINDINGS.md](sonarqube/FINDINGS.md) | (default) | (default) |  |  |
| coderabbit | completed | [FINDINGS.md](coderabbit/FINDINGS.md) | (default) | (default) |  |  |

## Merged findings

Reconciled by the executing session, 2026-07-19. All four reviewers
completed on the first wave. Sonarqube: 0 open. claude-code (13
findings) and codex (8) and coderabbit (8) converged independently on
three defects — the purge-on-lock reentrancy race, the unwired
thumbnail-recovery rule, and the grace-return shield gap — which is
the blind-wave mechanism working as intended. Fixes landed in commit
`b05bcfb`; the full simulator gate suite (42→43 unit tests, e2e,
perf) was re-run green after the fixes, and gate 3's perf numbers
were re-measured with the corrected instrumentation.

### Fixed

1. **Purge-on-lock reentrancy race** (cc #1, coderabbit; also cc #8's
   cost double-count) — `ThumbnailPipeline.image(for:)` could insert
   decoded plaintext into the cache after `purge()` ran during its
   `await`. Insert now guards on the reader (generation token)
   surviving; re-insert subtracts the replaced entry's cost. New
   regression test races 20 purge/decode bursts and asserts emptiness.
2. **Thumbnail recovery never wired** (cc #2, codex #5) —
   `regenerateMissingThumbnails()` was dead code; the store now
   triggers it from `itemsChanged` when the index reports missing
   thumbnails, idempotent via an attempted-set. The recovery test now
   drives the STORE (the wiring), not the coordinator. Orphan/
   undecodable counts additionally surface in a gallery banner
   (codex #5's reporting half).
3. **Grace-return shield gap** (cc #5, codex #1, coderabbit —
   three-way convergence) — returning past the grace window dropped
   the shield before the async lock landed, flashing the unlocked
   grid. The shield now stays up while a lock is pending and drops in
   `phaseChanged` when `.locked` lands. Gate-5 test extended to the
   lock-after-window branch (which also resolves cc #11: the branch
   was untested because the window was a `static let`; it is now an
   instance preference).
4. **Gate-3 metrics summed cumulative counters** (cc #3) — per-scroll
   counter reset in `scrollViewWillBeginDragging`; the display link
   also now tears down on a non-decelerating drag end (cc #12). Perf
   gate re-measured with honest per-scroll numbers.
5. **No background-task assertion around lock** (cc #4) —
   `store.lock()` now takes `beginBackgroundTask` so iOS lets the
   consuming drain finish before suspension.
6. **Calibration ignored its scratch dir** (cc #6) — `realMedianOf5`
   now builds its throwaway vault inside the caller's
   Data-Protection-classed scratch directory.
7. **UI-test seams reachable in Release** (cc #7) —
   `UITestSupport.isUITestMode` is compile-time false outside DEBUG
   (no seeding path, no KDF-downgrade seam in a shipping binary).
   The fixture images still ride the app bundle — recorded as a
   follow-up, not fixed (moving them to test-injected resources
   perturbs the e2e harness late in the leg).
8. **Unparented thumbnails silently dropped** (cc #9) — a derived
   entry with a missing/unparseable parent now classifies as an
   orphan in `IndexReport`.
9. **Dedup raced the index build** (cc #10) — `startImport` now
   synchronously catches the index up with the gallery's CURRENT
   snapshot before capturing the duplicate hash set.
10. **NSLog breadcrumbs on production paths** (cc #13) — replaced
    with `Logger` `.debug` privacy-annotated events.
11. **Shield was translucent + animated** (codex #2) — opaque
    system-background fill, inserted with animation explicitly
    disabled.
12. **Lock left import-summary plaintext + detached detail decode**
    (codex #3) — `lastImportSummary`/`importProgress` clear
    synchronously in `lock()`; summaries arriving during/after a
    pending lock are dropped; the detail decode is a cancellable
    task cancelled on view disappearance. Trade recorded: the
    interrupted-batch resume prompt no longer survives a LOCK (it
    survives in-foreground cancellation); custody beats convenience
    per WS D.3.
13. **Detail viewer unbounded for huge sources** (codex #4, partial)
    — explicit total-operation ceiling: sources over 256 MiB are
    refused with honest copy. The streaming/chunked decode that
    would remove the whole-file materialization is the Playback
    leg's deferred seam (GOAL WS B.1 defers streaming sources);
    recorded as residual + follow-up.
14. **Cell reuse didn't cancel the underlying decode** (codex #6) —
    `prepareForReuse` now routes cancellation to the pipeline task,
    not just the cell's waiting task.
15. **Low-disk check ran only after staging** (codex #7, partial) —
    once any item has been observed, a pre-stage projection (mean ×
    remaining × 2) refuses before copying; the exact post-stage
    check remains. The FIRST item necessarily has no estimate —
    residual recorded (a provider-side size capability is a
    follow-up).
16. **Calibration lacked peak memory** (codex #8) — a 25 ms
    `task_vm_info.phys_footprint` sampler records
    `peakFootprintMiB` across the timed unlocks; shown in Settings,
    destined for RESULT.md's device gate.
17. **Damage badge fired on transient failures** (coderabbit #1) —
    only `missingChunk`/`authenticationFailed` mark an item damaged;
    `vaultLocked` no longer mislabels intact media.
18. **Backup-exclusion / staging-wipe failures swallowed**
    (coderabbit #3, #4) — both now log `.fault` and assert in debug;
    the custody contract fails loud.
19. **ProRAW preview semantics misdocumented** (coderabbit #5) —
    `StillDecoder` now uses `FromImageIfAbsent` (reuses embedded
    previews — the behavior the goal describes for the detail
    viewer); `Thumbnailer` keeps `Always` deliberately (uniform
    stored thumbnails) with the doc corrected.
20. **Thermal fallback copy misattributed to headroom**
    (coderabbit #6) — reason text now says "raise not attempted".

### Rejected / deferred, with reasons

- **`lock()` should await the in-flight import task** (coderabbit) —
  REJECTED. Fail-closed drain is the designed semantic (CED-10 gate
  5 / LockRaceTests): the custodian refuses post-lock reads and the
  commit path re-checks lock state, so a straggling import errors
  closed; awaiting an uncancellable mid-KDF import inside `lock()`
  would let an import defer the 500 ms drain budget indefinitely —
  inverting the custody priority. The post-lock `finishImport`
  writes only lock-safe state (and summaries are now dropped while
  a lock is pending, per fix 12).
- **Fixture images in the Release bundle** (cc #7's second half) —
  DEFERRED follow-up (see RESULT.md): ~1 MiB hygiene/size issue;
  the dangerous half (runtime seams) is closed by the DEBUG gate.
- **Streaming detail decode** (codex #4's full ask) — DEFERRED to
  the Streaming Playback leg, which owns the resident-plaintext
  budget and the VaultCore streaming-source seam by map design.
- **First-item low-disk estimate** (codex #7 residual) — DEFERRED:
  needs a provider-side estimated-size capability
  (`NSItemProvider` cannot cheaply provide one); recorded as
  follow-up.
