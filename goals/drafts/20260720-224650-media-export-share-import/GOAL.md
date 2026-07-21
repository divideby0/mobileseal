---
status: draft
created: 2026-07-20T22:46:50-05:00
author: cedric
stacked_on: CED-14-multiple-galleries
---

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
   generic pre-share custody warning (iCloud-transit named; share
   sheet cannot reveal destination) → UIActivityViewController with
   byte-exact originals; Live Photos provide both files; item
   providers stream from decrypted memory where the size allows, and
   large items stage a temp plaintext file ONLY for the handoff —
   created under the existing staging discipline, removed on
   completion/cancel/crash-sweep, its lifecycle inside the custody
   canary's audited claim.
2. Lock interplay: an in-flight share sheet survives `.inactive`
   (system UI exemption, like Face ID prompts); `.background` lock
   cancels the share and sweeps staging.

### Workstream B — share extension (import from other apps)

1. Share Extension target accepting images/videos (media UTIs only;
   arbitrary file types are map fog). The extension NEVER unlocks and
   runs no KDF (120 MB extension limit; extension-safe profiles per
   the Argon2id research are unnecessary because no crypto happens):
   it copies incoming items into an app-group container inbox
   (`group.com.gmail.cedric.hurst.mobileseal`), Data-Protected,
   with a manifest sidecar (source app, date, UTI).
2. Main app: on next unlock of any gallery, "Import N staged items
   into <this gallery>?" — accept routes through the existing
   staging→import pipeline (dedup, thumbnails, padding all apply);
   decline keeps them staged; a per-item discard exists. Inbox
   participates in the launch crash-sweep and the custody canary
   scope (it IS plaintext at rest until imported — documented as the
   share-in staging window, Data-Protected, bounded by user action).
3. Entitlements: app group + (if labels/keys need extension access —
   they should NOT; extension touches no Keychain) minimal set;
   xcodegen project updates.

## Green gates

1. `swift test` + app suites + `xcodebuild` (simulator + generic
   device incl. the extension target) green; stacked wave diffs
   `CED-14-multiple-galleries...HEAD` only.
2. Export e2e (simulator): select 2 photos + 1 video → share →
   custody warning → activity controller presents with correct item
   count/types (destination taps are OS UI — out of test scope);
   temp staging created only for the large-item path and swept on
   completion, cancel, and simulated-crash relaunch; lock mid-share
   cancels + sweeps.
3. Share-in pipeline: extension inbox logic unit-tested (fixture
   items → inbox manifest → main-app import prompt → import runs the
   real pipeline → inbox cleared; decline/discard paths; crash-sweep
   of stale inbox items); real share-from-Photos smoke joins the
   map's HITL checklist.
4. Custody: canary scan extended over the app-group inbox and export
   staging; no plaintext outside their documented windows.
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

- **Stacked goal**: review-wave diff base is `CED-14-multiple-galleries`
  (from `stacked_on` frontmatter), NEVER main — do not re-review the
  parent's diff. Parent is expected locked-but-unmerged at launch.
- Formatter scoped to THIS goal folder only.
- Extension targets in xcodegen need explicit product/entitlement
  stanzas; regenerate after adding files.
- Zero-HITL gates; share-from-Photos device smoke is on the map's
  HITL checklist, not a gate.
