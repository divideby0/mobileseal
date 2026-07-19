---
status: draft
created: 2026-07-19T16:48:58-05:00
author: cedric
---

# Build iOS Vault App Shell and Photo Grid

## Problem

VaultCore shipped in CED-10 (merged `dc680f6`) but nothing uses it —
there is no app. This leg makes the vault _visible_: an iOS app target
that imports photos from the system library into an encrypted gallery,
renders a Photos-style grid from app-generated encrypted thumbnails,
and wires VaultCore's lock/drain semantics to the app lifecycle. It is
the second leg of the wayfinder map (`wayfinder/MAP.md`, recrafted
from CED-10's locked snapshot) and unblocks the Streaming Playback and
Multiple Galleries legs.

## Scope

Derived from the map ticket and CED-10 RESULT.md follow-ups (verbatim
intake at `references/intake.md`); sized L. Provisional workstreams —
grilling will sharpen import fidelity and custody decisions:

### Workstream 0 — carried-forward first commit

1. `.coderabbit.yaml` with `goals/**` review path filters (CED-10
   follow-up; must land before this goal's review wave).

### Workstream A — Xcode app target

1. iOS app target (SwiftUI lifecycle) in the existing SwiftPM-rooted
   repo, linking VaultCore; signing via the paid Apple Developer
   account; bundle id/team TBD (grilling).
2. Runs on latest-OS simulator and Cedric's iPhone.

### Workstream B — import pipeline

1. Import from the system photo library (picker-based; exact scope —
   Live Photos, HEIC/ProRAW, bursts, EXIF handling — is a grilling
   question) through VaultCore's `Gallery` actor (WAL-staged commits,
   dedup, padding all come free).
2. App-generated **encrypted** thumbnails at import time; never
   QuickLook/Photos-subsystem previews (intake spec §6/§10).

### Workstream C — grid + detail UI

1. Photos-equivalent grid: `UICollectionView` with compositional
   layout wrapped for SwiftUI (spec §10 — plain SwiftUI won't hit the
   scroll/zoom bar), fed from inventory snapshots.
2. Detail view for stills (video/audio playback is the next leg).

### Workstream D — lock/unlock UX + device benchmark

1. Unlock screen (password entry → VaultCore unlock with its
   rate-limit surface); explicit lock; auto-lock and app-switcher
   snapshot redaction on scenePhase background/inactive (spec §11
   items that ride this leg).
2. Device Argon2id benchmark: assert the 0.5–1 s unlock envelope on
   the real iPhone; implement the research report's adaptive
   calibration (raise memlimit only with measured headroom).
3. Metadata custody decision (grilling): whether decrypted
   EXIF/names for the grid live in `SecureBytes` or stay
   access-revoked ordinary heap (CED-10's documented trade).

## Green gates

Provisional — to be sharpened during grilling:

1. End-to-end on simulator: create gallery → import N photos → grid
   renders from encrypted thumbnails → relaunch → unlock → grid
   restores; `swift test` (VaultCore suite) stays green.
2. Custody: no plaintext image bytes or thumbnails on disk outside
   VaultCore's audited claim (extend the canary approach to the app
   container).
3. Backgrounding: scenePhase → background locks the vault and redacts
   the app-switcher snapshot (verifiable in simulator).
4. Device benchmark recorded: unlock envelope on real hardware, with
   calibration behavior demonstrated.
5. Blind multi-tool review wave (all four reviewers) completed and
   reconciled per CED-10's gate-9 shape.

## References

- `references/intake.md` — verbatim intake (map ticket + CED-10
  follow-ups).
- `wayfinder/MAP.md` — the recrafted map (this goal is its second
  leg).
- `goals/CED-10-private-photo-vault/results/RESULT.md` (main) —
  VaultCore's execution record; its API surprises section is required
  reading for the executor.
- `docs/formats.md`, `CONTEXT.md`, `docs/adr/0001` (main) — the
  format contract and glossary this app builds on.
- `research/_default/argon2id-tuning-on-modern-iphones.md` —
  calibration guidance for Workstream D.2.

## Open questions (for grilling)

1. Import scope: PHPicker copy-in only, or full-library access
   (PHPhotoLibrary) with incremental import? Delete-originals flow?
2. Import fidelity: Live Photos (pair or still-only), HEIC/ProRAW
   (store original bytes vs transcode), bursts, EXIF privacy.
3. Thumbnail pipeline: sizes/format, stored as vault chunks vs a
   separate encrypted cache, regeneration story.
4. Metadata custody (Workstream D.3).
5. Bundle id / app name / team for signing.
6. Testing loop: what runs in CI-less `swift test` vs simulator UI
   tests vs manual device checks.

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- VaultCore API: read CED-10 RESULT.md "Spike outcome" and "Design
  decisions made during execution" before writing app code — the
  move-only session, drain-on-lock, and `aad_file_id` semantics are
  non-obvious.
- Xcode project generation in a SwiftPM repo: keep VaultCore a pure
  package; the app target references it — do not fold app code into
  the package (it must stay UIKit-free for the CLI leg).
- Simulator can exercise everything except the device benchmark and
  real signing; those need the physical iPhone (coordinate with
  Cedric for the device step — it cannot run unattended).
