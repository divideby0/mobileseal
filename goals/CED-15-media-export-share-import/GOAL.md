---
status: promoted
created: 2026-07-20T22:46:50-05:00
author: cedric
stacked_on: CED-14-multiple-galleries
promoted: 2026-07-20T22:56:59-05:00
issue_url: https://linear.app/cedric-personal/issue/CED-15/build-media-export-and-share-sheet-import
linear_project: Mobileseal
linear_project_id: cccebfd8-6d19-474b-852f-c87bf528dcf6
---

# Build Media Export and Share-Sheet Import

## Problem

The vault has import but no exit: nothing can leave (a trap, and the
missing enabler for manual cross-gallery moves), and nothing can
enter from other apps. This stacked leg (parent:
`CED-14-multiple-galleries` — shares grid/pager selection surfaces)
adds both doors. Verbatim intake: `references/intake.md`. NOTE: this
draft carries no wayfinder/ — the map recrafts forward from CED-14's
locked snapshot at this goal's launch (orchestrator step).

## Scope

Sized M (grew from S with the share extension).

### Workstream A — export (the one deliberate custody exit)

1. Share action on pager (single) and grid multi-select (bulk):
   generic pre-share custody warning → UIActivityViewController.
   **Item contract, defined** (Codex B1/B5/Q1/A2): ALL exports stage
   to file first — a dedicated `staging/export/` root (Codex B3 —
   isolated from import's wipe-all) — and are handed to the sheet as
   file-URL items via UIActivityItemSource with preserved original
   filename (dedup-suffixed on collision) and correct UTI; no
   in-memory streaming claim. Live Photos export as TWO separate
   file items (still + video; true re-pairing needs PhotoKit write
   auth we don't hold — documented, deferred). Custody boundary
   (Codex A5): the canary claim ends at provider handoff — bytes a
   chosen activity copies are the OS's.
2. **ExportController owns the export lifecycle** (Codex B2):
   registered in the coordinator lock path like PlaybackController —
   lock cancels in-flight decrypt/writes, awaits open file handles,
   then sweeps `staging/export/`. Lock interplay (Codex B4, replacing
   the blanket claim): the share sheet survives `.inactive`; on
   `.background`, REGARDLESS of the user's grace/off auto-lock
   preference, an active export cancels and sweeps (export-specific
   override — an open plaintext handoff never rides a grace window);
   bytes already delivered to an activity are gone and the warning
   copy says so.

### Workstream B — share extension (import from other apps)

1. Share Extension target accepting images/videos (media UTIs
   only). No unlock, no KDF (120 MB limit). **Inbox protocol,
   defined** (Codex B6/B8/B9/B10/A1/A3): items copy inside the
   `loadFileRepresentation` callback (file representations ONLY —
   no data-loading fallback; concurrency 1; disk-full and
   cancellation produce typed cleanup), preferring the live-photo
   bundle representation first (mirror PickerMediaProvider's
   order — no still/video duplication). Atomic commit: media file
   fully written → hash+length computed → manifest (versioned
   schema: UTI, byte length, BLAKE2 hash, pairing info, date;
   source-app OPTIONAL) written LAST under a collision-resistant
   name. Inbox states: incomplete → committed → claimed → imported /
   discarded; the launch sweep removes ONLY incomplete/stale (the
   app's wipe-all staging behavior explicitly does not apply);
   quota: 2 GiB or 50 items — oldest committed items expire with a
   notice; low-disk refuses new copies typed.
2. Main app: inbox discovery on activation AND unlock AND gallery
   switch, exactly-once prompt per batch (Codex A4): "Import N
   staged items into <unlocked gallery>?" — accept claims the batch
   atomically through the CED-14 switch authority (single
   gallery-bound claim; a switch/lock during import follows the
   normal import-interruption rules), validates manifest hash/length
   before import, routes through the existing pipeline; decline
   keeps committed items (within quota); per-item discard exists.
3. Entitlements + app-group custody (Codex B7/B11): app group
   `group.com.gmail.cedric.hurst.mobileseal` on BOTH targets;
   per-file `.completeUnlessOpen` + backup exclusion applied
   explicitly to inbox files (app-group containers inherit
   neither); extension touches no Keychain. xcodegen grows the
   extension product with its plist activation rule (media-only),
   embedding, and bundle id
   `com.gmail.cedric.hurst.mobileseal.share`. **Signing
   feasibility is a stated residual** (Codex B11/Q7): simulator
   proves functionality; the signed two-App-ID install with App
   Groups joins the map's HITL checklist (paid personal teams
   support App Groups; risk documented, not assumed away).

## Green gates

1. `swift test` + app suites + `xcodebuild` (simulator incl.
   extension target; generic device build for the APP —
   extension-signed installs are the HITL residual) green; stacked
   wave diffs the parent's LOCKED head...HEAD only (base SHA
   recorded at launch — Codex A6).
2. Export e2e with a **provider-consumption seam** (Codex B13/Q8):
   tests invoke the exported items' load handlers directly
   (simulating Photos/Files/AirDrop consumption) — correct bytes,
   filename, UTI per item type (still / video / Live Photo pair);
   completion, cancellation, and mid-share lock each cancel + sweep
   `staging/export/` (verified incl. simulated-crash relaunch); the
   grace/off-preference background override fires.
3. Share-in pipeline: inbox protocol unit/integration tested via the
   extension's writer as a library (atomic manifest-last commit;
   truncated/mismatched/malformed manifests rejected before import;
   states + sweep rules + quota/expiry + disk-full; live-photo
   preference order; concurrent-invocation names) → main-app prompt
   → real pipeline import → inbox cleared; decline/discard;
   extension-process termination mid-copy leaves only
   incomplete-state files, swept. Real share-from-Photos +
   signed-install checks join the HITL checklist.
4. Custody: canary scan extended over `staging/export/` and the
   app-group inbox (protection attributes + backup-exclusion flags
   asserted; device enforcement = stated residual); no plaintext
   outside documented windows; the canary claim's provider-handoff
   boundary stated in the test.
5. Blind multi-tool review wave (all four reviewers, stacked base)
   completed and reconciled.

## References

- `references/intake.md` (cedric's two-way design, 2026-07-20).
- Parent branch ground truth: CED-14's GallerySwitchboard/registry
  (import-prompt targets the unlocked gallery), CED-11 staging
  discipline (`App/MobileSeal/Import/*`), CED-13 delete-selection UI
  (reuse the multi-select affordances), custody canary
  (`TestSupport`), `research/_default/argon2id-tuning-on-modern-iphones.md`
  (extension memory — why no KDF in extension).

## Decisions (grill, in-chat 2026-07-20)

Full share sheet for export (generic warning; parity) + MobileSeal as
share-sheet destination via non-unlocking staged-inbox extension —
both cedric's explicit design. Media types only; files-types fog.

## Executor notes (self-sufficiency)

- **Stacked goal**: diff base is the parent's LOCKED head (the
  orchestrator re-runs the rebase onto the locked
  `CED-14-multiple-galleries` before launch and records the base
  SHA here) — never main, never a moving parent (Codex A6/B12). The
  import-prompt/switch integration binds to the parent's ACTUAL
  shipped switchboard API as found in the rebased tree, not the
  parent GOAL.md's wording; if the shipped shape differs materially,
  say so in RESULT.md rather than forcing the plan's wording.
- Cross-gallery move orchestration is a NON-GOAL (Codex A7): no
  automated delete-after-export, no destination selection.
- Formatter scoped to THIS goal folder only.
- Extension targets in xcodegen need explicit product/entitlement
  stanzas; regenerate after adding files.
- Zero-HITL gates; share-from-Photos device smoke is on the map's
  HITL checklist, not a gate.
