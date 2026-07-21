# Review results-001

Blind multi-tool review wave for `CED-14-multiple-galleries` (2026-07-21T04:30:56.777Z).
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

13 findings across the four reviewers (claude-code 4, codex 2,
sonarqube 0 open, coderabbit 7), deduplicated to 12 (no two tools hit
the same defect). Dispositions by the executing session's judgment;
fixes land in `19faa18` ("fix: reconcile wave-001 blind-review
findings"), verified by the full unit suite (89 tests / 16 suites),
the updated multi-gallery e2e, and a final full `run-gates.sh` sweep.

**Fixed — 9:**

1. **codex #1 (major)** — discovery pre-filtered directories on
   `gallery.meta`, so a gallery whose meta vanished disappeared
   silently and the app could route an existing user to setup.
   FIXED: `AppContainer.galleryDirectories()` returns every
   subdirectory and throws on enumeration failure; the registry turns
   a missing/unparsable meta into an `unreadableMeta` error tile, an
   enumeration failure into an explicit `scanFailed` tile, and skips
   only provably-empty creation husks (no meta, no HEAD, no objects —
   nothing to lose). New tests: missing-meta-with-content → error
   tile; empty husk → ignored.
2. **codex #2 (major)** — calibration migration trusted any existing
   destination and deleted the legacy source unverified: a partial
   target from a crash window would orphan the only valid record.
   FIXED: destination is trusted only if it DECODES as a
   `KDFCalibrator.Record`; a partial target is repaired from the
   intact legacy via atomic write; the source is removed only after
   read-back verification; an undecodable legacy is preserved in
   place. New tests: corrupt-pre-existing-target repair;
   undecodable-legacy preservation.
3. **coderabbit #7 (major)** — creation failure from the
   single-gallery Settings flow stranded the user on the list.
   FIXED: the previous selection is restored on creation failure.
4. **claude-code #1 (minor)** — the shield purged decoded covers but
   left the compressed cover plaintext cached in `galleryLabels`.
   FIXED: `purgeCoverImages()` strips both forms; unit-asserted.
5. **claude-code #2 (minor)** — cover material was retained (and
   re-decoded on every scene-active) for the whole foreground session
   regardless of surface. FIXED: covers are cached only while the
   route is `.list` and the shield is down; leaving the list purges
   both forms.
6. **coderabbit #4 (minor)** — clearing an empty label swallowed
   removal errors (`try?`), so a failed removal reported success over
   a stale sealed record. FIXED: only `.fileNoSuchFile` is benign;
   real failures throw.
7. **coderabbit #5 (minor)** — a typed gallery name was lost on
   swipe-to-dismiss of Settings. FIXED: dismiss persists the name,
   guarded to the gallery the sheet was editing (the guard matters:
   the New Gallery flow swaps the selection under the open sheet, and
   an unguarded save would have written gallery A's name onto B).
8. **coderabbit #6 (minor)** — tapping a stale list tile (directory
   vanished post-scan) was a silent no-op. FIXED: falls back to a
   rescan-and-republish of the list.
9. **coderabbit #2 (minor)** — the e2e never asserted the chosen
   cover actually renders on the locked list. FIXED: tiles expose a
   machine-readable cover state (`accessibilityValue` = generic |
   cover); the e2e asserts the flip.

**Fixed (documentation) — 2:**

10. **claude-code #4 (nit)** — stale "single gallery this leg
    manages" comment on `existingGalleryDirectory()`. FIXED: reworded
    as the UI-test/legacy helper it now is.
11. **claude-code #3 (nit)** — `switchTo(_:)` reads as a UI-wired
    transition but ships test-only. FIXED with a doc note (kept: it
    is the single-transaction switch the gate-3 double-switch race
    coverage exercises, and the natural hook for a future
    direct-switch affordance).

**Rejected with reason — 2:**

12. **coderabbit #1 (minor)** — "align the E2E gate claim (labels
    absent from every gallery-format file) with its actual coverage."
    REJECTED as a GOAL.md edit: a UI-test process cannot read the app
    container (sandbox), so a scripted-e2e byte-scan is impossible on
    this platform; the absence claim is deliberately gated by the
    unit-level custody canary
    (`labelAndCoverNeverTouchGalleryFormatFilesOrDiskPlaintext`),
    which scans the real container including tmp. The promoted GOAL.md
    gate text stays as authored (the goal spec is the promoted record;
    RESULT.md gate 2/3 documents exactly which half of the sentence
    each suite proves).
13. **coderabbit #3 (minor)** — pbxproj folder reference
    `CED-14-multiple-galleries` with `path = .` "should point at the
    goal directory". REJECTED: that reference is xcodegen's rendering
    of the local Swift package (`packages.VaultCore.path: .` in
    project.yml) — its display name derives from the checkout
    directory's basename, which in a goal worktree happens to equal
    the goal key. It is not a reference to `goals/…`, and the
    .xcodeproj is generated (`Scripts/generate-project.sh`) — a hand
    edit would be regenerated away. On the post-merge main checkout
    the same reference renders as the repo directory name.

Sonarqube: 0 open issues on the ephemeral branch project
(`mobileseal-CED-14-multiple-galleries`, compute task
`588c7692-5864-4244-aacf-013d3dfb3c25`) — nothing to reconcile.
