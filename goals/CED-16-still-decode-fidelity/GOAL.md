---
status: completed
created: 2026-07-20T23:02:25-05:00
author: cedric
stacked_on: CED-15-media-export-share-import
promoted: 2026-07-20T23:02:57-05:00
issue_url: https://linear.app/cedric-personal/issue/CED-16/fix-still-decode-serving-embedded-previews
linear_project: Mobileseal
linear_project_id: cccebfd8-6d19-474b-852f-c87bf528dcf6
started: 2026-07-21T01:33:00-05:00
completed: 2026-07-21T02:05:30-05:00
---

# Fix Still Decode Serving Embedded Previews

## Problem

Full-screen stills render visibly soft (cedric's report, 2026-07-20,
validated same night): `StillDecoder.decode` passes ImageIO
`kCGImageSourceCreateThumbnailFromImageIfAbsent`, which serves the
container's EMBEDDED preview whenever one exists. iPhone-camera HEICs
always carry one — so a 6000×4000 source decodes to **432×288** (the
embedded thumbnail) instead of the intended 4096-long-edge bound.
Empirical repro: `references/validation-repro.swift` (shipped options
→ 432×288; `Always` → 4096×2730 — a ~90× pixel deficit). Introduced
in CED-11 (WS C.3's bounded viewer), inherited by CED-12's pager;
storage-fidelity gates couldn't catch a display-path bug. New goal per
the no-reopen rule, stacked on CED-15 (chain order; no functional
dependency).

Ceremony note: no grill (zero open decisions — root cause validated),
no pre-execution plan review (XS validated fix; the four-reviewer wave
still gates the code).

## Scope

Sized XS.

1. `StillDecoder`: normal images decode with
   `kCGImageSourceCreateThumbnailFromImageAlways` at the existing
   4096 ceiling; RAW/DNG keeps the embedded-preview path (detect via
   source UTI/`kCGImageSourcePropertyRawDictionary` presence) — the
   distinction the shipped comment intended but the option didn't
   deliver.
2. Purge any cached decoded stills on upgrade so previously-viewed
   items re-decode sharp (decoded caches are session-scoped already —
   verify, don't assume).

## Green gates

1. Regression test from the validated repro: generated
   6000×4000 embedded-thumbnail HEIC fixture → decoded long edge
   ≥ 4096; a small (<4096) image decodes at native size; a DNG-style
   fixture still uses its preview path. `swift test` + app suites +
   xcodebuild green.
2. Blind multi-tool review wave (stacked base: CED-15's locked head)
   completed and reconciled.

## References

- `references/validation-repro.swift` — the empirical proof + fixture
  recipe (run on macOS: `swift validation-repro.swift`).
- `App/MobileSeal/Detail/StillDecoder.swift` (the option flip),
  `MediaPageViewController.swift` (consumer).
- CED-11 RESULT.md (viewer ceiling rationale), CED-12 wave-001
  coderabbit #5 (the RAW/normal distinction the comment cites).

## Executor notes

- Stacked: diff base = CED-15's LOCKED head —
  `90ec3fe22a84a704bd0041b510fb7b573842909c` (locked 2026-07-21
  01:30); never main.
- Formatter scoped to THIS goal folder only.
- Zero HITL. Keep the fix surgical — no tiling/progressive-zoom work
  (that's the streaming-still-decode fog item, not this goal).
