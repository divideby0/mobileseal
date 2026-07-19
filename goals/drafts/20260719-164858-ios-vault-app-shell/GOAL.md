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
the second leg of the wayfinder map (`wayfinder/MAP.md`) and unblocks
the Streaming Playback and Multiple Galleries legs. A pre-grill blind
Codex plan review (`references/codex-plan-review-20260719.md`) is
folded in below; grill decisions pending in Open Questions.

## Scope

Sized L. Per the map ticket, CED-10 RESULT.md follow-ups, and the
Codex-review fixes:

### Workstream 0 — carried-forward first commit

1. `.coderabbit.yaml` with `goals/**` review path filters (CED-10
   follow-up; must land before this goal's review wave).

### Workstream A — app target + session coordinator

1. **Coordinator spike first** (Codex B3): a `VaultCoordinator` state
   machine that solely owns the move-only `UnlockSession` and its
   `Gallery`/reader/snapshot-task children — explicit transitions for
   create, unlock, importing, inactive, locking (consuming `lock()`
   off the main actor; it can block up to 500 ms), locked, unlock
   failure, teardown. The compile-fail harness already rejects
   capturing the session in a `Task`; the spike proves the coordinator
   shape compiles before UI work begins. Single-scene policy for this
   leg: additional scenes get read-nothing UI; `galleryAlreadyOpen`
   surfaces as "vault is open elsewhere," never a crash.
2. iOS app target (SwiftUI lifecycle) in the SwiftPM-rooted repo,
   linking VaultCore as a package dependency (VaultCore stays
   UIKit-free — CLI leg depends on it). Checked-in Xcode project;
   shared scheme; personal team/signing in a gitignored local
   xcconfig.
3. **App-container contract** (Codex B8): vault root under
   `Application Support/Vault/` with iOS Data Protection
   `.completeUnlessOpen` (files must be writable during background
   import completion — grill may tighten), picker/staging material in
   a separate `staging/` dir cleaned on every launch and import end;
   backup participation is a grill decision (Open Q7) and its answer
   is recorded here and tested.

### Workstream B — import pipeline

1. Import via the system picker (exact source scope: Open Q1) through
   VaultCore's `Gallery` actor. **Staging policy** (Codex B1):
   `NSItemProvider.loadFileRepresentation` produces plaintext temp
   files and `Gallery.importFile` needs a seekable, twice-readable
   source — copy provider output into the protected `staging/` dir,
   import from there, then securely remove; the custody gate's
   audited-path claim includes `staging/` lifecycle (created →
   imported → removed, verified also on the crash path). Extending
   VaultCore with a streaming rewindable source is explicitly out of
   scope this leg (deferred candidate for the Playback leg).
2. Deterministic import seam (Codex A6): a provider-abstraction layer
   with fixture-backed fakes so success, cancellation, provider
   error, iCloud-download delay, and cleanup are simulator-testable;
   the real picker gets one manual smoke test.
3. App-generated **encrypted** thumbnails at import: stored as vault
   entries whose app-level encrypted metadata blob carries
   `{kind: thumbnail, parent: <fileID>}` links (no VaultCore change
   needed — the blob is opaque to core). Original and thumbnail are
   two commits (Codex B2): on open, a missing thumbnail regenerates
   and an orphaned thumbnail (parent gone) is ignored and reported —
   the recovery rule is tested.
4. Batch import semantics (Codex Q5, executor default pending grill):
   per-item commits (VaultCore's WAL already gives per-item
   atomicity); a failed item stops the batch, reports which items
   landed, leaves committed items committed; low-disk surfaces
   pre-flight when free space < 2× batch estimate.

### Workstream C — grid + detail UI

1. Photos-equivalent grid: `UICollectionView` + compositional layout
   wrapped for SwiftUI, **fed from `Gallery.snapshotStream()`** —
   never the unlock-frozen `UnlockSession.snapshot()` — with a fresh
   `Gallery.makeReader()` per committed generation and snapshot-task
   cancellation on lock (Codex B4). Diffable data source keyed by
   fileID; cancelable prefetch/decrypt scheduling with cell-reuse
   cancellation and a bounded decoded-image cache (Codex A3).
2. **Date-sorted order** (Codex B10): the app's encrypted metadata
   blob carries date-taken (EXIF-derived) + import date; the grid
   sorts from an in-memory index built at unlock from decrypted
   metadata. This deliberately supersedes intake-spec §6's SwiftData
   index for this leg — at personal-library scale the in-memory index
   suffices; a persisted encrypted index is a future-leg optimization
   if unlock-time indexing measurably lags.
3. Detail view = bounded still viewer (Codex A4): full-res decode with
   an explicit memory ceiling, zoom, ProRAW treated as its embedded
   preview this leg; video/audio and anything streaming belongs to
   the Playback leg.

### Workstream D — lock/unlock UX + device benchmark

1. Unlock screen (password → VaultCore unlock, surfacing its
   rate-limit errors); explicit lock control. **Redaction ≠ lock**
   (Codex A2): the privacy shield appears on `.inactive` (before
   snapshot capture); the vault locks on `.background` (in-flight
   import handling: Open Q8) — transient-interruption lock policy is
   Open Q2.
2. **Purge-on-lock for app-side plaintext** (Codex B5): decoded
   UIImage/CGImage caches, metadata index, and prefetch queues are
   bounded and emptied on lock; this leg owns still/thumbnail
   residency (Playback owns streaming residency).
3. Device Argon2id benchmark, **calibrate-at-creation** (Codex B6):
   VaultCore has no rewrap API, so calibration runs before gallery
   creation — release build, median-of-5 protocol, peak-memory and
   thermal-state recorded, fallback to MODERATE when headroom is
   absent. A `rewrapKeyring` core API is noted as a future-leg
   candidate, not built here.
4. Integrity-failure UX (Codex Q8, executor default pending grill):
   `missingChunk`/`authenticationFailed` → per-item damaged badge +
   detail explanation, never silent; `noValidInventory` /
   `dekUnwrapFailed` → gallery-level error screen distinguishing
   wrong-password from damage (they are cryptographically
   indistinguishable at the keyring — copy must say so).

## Green gates

1. **iOS build gates** (Codex B9): `xcodebuild` succeeds for (a) the
   simulator destination including app unit tests and the import-seam
   fixture tests, (b) a generic unsigned device build; `swift test`
   (VaultCore macOS suite) stays green.
2. End-to-end on simulator, scripted (not manual): create gallery →
   import a committed fixture batch (≥100 mixed HEIC/JPEG incl. one
   forced failure) → grid renders from encrypted thumbnails → relaunch
   → unlock → grid restores → per-item failure visible.
3. Grid performance, measured: instrumented scroll over a 500-photo
   fixture gallery on the simulator with hitch/dropped-frame metrics
   recorded (os_signpost/MetricKit) and thresholds stated in the test;
   device spot-check recorded in RESULT.md.
4. Custody: canary audit extended to the app container — no plaintext
   image bytes outside `staging/` during its documented lifecycle;
   staging is empty after import completion, after cancellation, and
   after simulated-crash relaunch.
5. Lock behavior: scenePhase tests prove shield on `.inactive`, lock +
   app-plaintext purge on `.background` (caches empty, snapshot task
   cancelled, readers fail closed); process-registry claim released.
6. Device benchmark recorded: calibration protocol run on the real
   iPhone with envelope, peak memory, and chosen params in RESULT.md
   (device steps coordinated with Cedric — cannot run unattended;
   residual simulator/device gaps documented per Codex A7).
7. Blind multi-tool review wave (all four reviewers) completed and
   reconciled per CED-10's gate-9 shape.

## References

- `references/intake.md` — verbatim leg intake (map ticket + CED-10
  follow-ups). **The full v0.1 product spec is NOT here** — it lives
  at `goals/CED-10-private-photo-vault/references/intake.md` on main
  (Codex B10); §6/§10/§11 are this leg's sections.
- `references/codex-plan-review-20260719.md` — pre-grill blind plan
  review; blockers folded above, user decisions routed to Open
  Questions.
- `wayfinder/MAP.md` — the recrafted map (this goal is its second
  leg).
- `goals/CED-10-private-photo-vault/results/RESULT.md` (main) — the
  "Spike outcome" and "Design decisions" sections are required
  reading (move-only session, drain-on-lock, `aad_file_id`).
- `docs/formats.md`, `CONTEXT.md`, `docs/adr/0001` (main).
- `research/_default/argon2id-tuning-on-modern-iphones.md` —
  calibration guidance.

## Open questions (for grilling)

1. Import scope: PHPicker copy-in only (no library entitlement), or
   PHPhotoLibrary access with incremental import? Delete-originals
   flow in or out this leg?
2. Auto-lock semantics: inactivity timeout value, lock on device
   screen-lock?, transient `.inactive` (control center, Face ID
   prompt) — shield-only or full lock?
3. Face ID / Keychain convenience unlock: excluded, deferred, or
   required for daily use? (Password-only is the crypto posture;
   convenience unlock caches the DEK behind biometrics.)
4. Import fidelity: Live Photos (pair or still-only this leg),
   HEIC/ProRAW original-bytes vs transcode, bursts, EXIF privacy
   (strip location on import? keep encrypted?).
5. Duplicate imports: VaultCore creates a new entry sharing chunks —
   display separately, group, or suppress?
6. Metadata custody: decrypted names/dates/EXIF for the grid in
   SecureBytes or ordinary heap purged on lock (CED-10's documented
   trade)?
7. Backup/reinstall policy (pre-sync): vault files in iCloud/device
   backup (recoverable but a second ciphertext copy exists) or
   excluded (uninstall before the sync legs = data loss)?
8. Backgrounding during import: cancel-and-cleanup (simplest) or
   background-task continuation with deferred lock?
9. App name / bundle id / team.

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- Read CED-10 RESULT.md's API-surprises before writing app code; the
  session is `~Copyable` (no Task capture — the compile-fail harness
  is the law), `lock()` consumes and can block, writers are
  process-registry-exclusive per vault path.
- VaultCore stays a pure UIKit-free package; app code lives only in
  the app target.
- Simulator limits (Codex A7): no real Data Protection, jetsam,
  mlock, thermal, or iCloud-photo behavior — device-only checks are
  listed in gate 6 and coordinated with Cedric; everything else must
  be simulator-automatable.
- Executor defaults marked "pending grill" above (batch semantics,
  integrity UX, single-scene policy) stand unless the grill
  transcript overrides them.
