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
Codex plan review (`references/codex-plan-review-20260719.md`) and all
nine grilling decisions (session 001) are folded in below.

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
   UIKit-free — CLI leg depends on it). Display name **MobileSeal**,
   bundle id `com.gmail.cedric.hurst.mobileseal` (grill Q9).
   Checked-in Xcode project; shared scheme; personal team/signing in
   a gitignored local xcconfig.
3. **App-container contract** (Codex B8): vault root under
   `Application Support/Vault/` with iOS Data Protection
   `.completeUnlessOpen` (files must be writable during background
   import completion — grill may tighten), picker/staging material in
   a separate `staging/` dir cleaned on every launch and import end;
   **vault files participate in iCloud/device backup** (grill Q7 —
   ciphertext is safe to back up and survives device migration
   pre-sync); gate 4 verifies nothing under the vault root is flagged
   `isExcludedFromBackup`.

### Workstream B — import pipeline

1. Import via **PHPicker copy-in only** (grill Q1 — out-of-process,
   zero photo-library entitlement; full-library access and the
   delete-originals "move" flow are deferred to the sync milestone,
   when the vault has redundancy) through VaultCore's `Gallery`
   actor. **Staging policy** (Codex B1):
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
4. Import fidelity (grill Q4): **byte-exact originals always** (HEIC
   stays HEIC, ProRAW stays ProRAW; thumbnails are the only derived
   artifacts); Live Photos import BOTH parts — the paired video as a
   linked entry (`kind: livePhotoVideo`, same link pattern as
   thumbnails), UI shows the still until the Playback leg; full EXIF
   incl. location kept inside encrypted metadata (encryption is the
   privacy layer); spatial photos/videos survive automatically as
   originals (stereo display belongs to a future visionOS effort).
5. Duplicate imports (grill Q5): **skip with notice** — VaultCore's
   plaintext-hash dedup detects the match; the app declines to create
   a second entry and the import summary reports skips.
6. Batch import semantics (grill Q8 confirmed the executor default):
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
   rate-limit errors); explicit lock control; **password-only this
   leg** (grill Q3 — Face ID convenience unlock deferred: it requires
   a custody-respecting biometric-token API in VaultCore, noted on
   the map). **Redaction ≠ lock** (Codex A2): the privacy shield
   appears on `.inactive` (before snapshot capture); transient
   `.inactive` never locks.
2. **Auto-lock is a user preference** (grill Q2): a Settings surface
   with lock-on-background (immediate / grace period / off) and idle
   timeout; strict defaults = immediate lock on `.background`,
   5-minute foreground idle backstop. Preferences are policy, stored
   in UserDefaults. Backgrounding mid-import: cancel-and-cleanup +
   resume prompt (grill Q8; Workstream B.6).
3. **Purge-on-lock for app-side plaintext** (Codex B5; grill Q6
   chose ordinary heap + purge-on-lock over SecureBytes for the
   metadata index — same documented residual class as decoded
   pixels): decoded
   UIImage/CGImage caches, metadata index, and prefetch queues are
   bounded and emptied on lock; this leg owns still/thumbnail
   residency (Playback owns streaming residency).
4. Device Argon2id benchmark, **calibrate-at-creation** (Codex B6):
   VaultCore has no rewrap API, so calibration runs before gallery
   creation — release build, median-of-5 protocol, peak-memory and
   thermal-state recorded, fallback to MODERATE when headroom is
   absent. A `rewrapKeyring` core API is noted as a future-leg
   candidate, not built here.
5. Integrity-failure UX (Codex Q8, executor default stands):
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

## Decisions (grilling session 001 — all nine questions resolved)

See `grilling/session-001-20260719-171500.md` for full provenance.
Q1 PHPicker copy-in only, delete-originals at the sync milestone ·
Q2 auto-lock as a Settings preference, strict defaults · Q3 Face ID
deferred pending a custody-respecting core token API · Q4 byte-exact
originals, Live Photo pairs, EXIF kept encrypted, spatial media
survives as originals · Q5 duplicates skip-with-notice · Q6 metadata
heap + purge-on-lock · Q7 vault included in backup · Q8
cancel-and-cleanup confirmed · Q9 MobileSeal /
`com.gmail.cedric.hurst.mobileseal`. **Standing principle (map-level,
for sync legs): background execution moves SEALED bytes only —
encrypt/decrypt runs only while the app is open and unlocked; the
two-plane API is the enforcement seam.**

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
