---
status: draft
created: 2026-07-20T22:17:11-05:00
author: cedric
---

# Build Multiple Galleries and Switcher

## Problem

VaultCore has been multi-gallery-capable since CED-10 (independent
keyring per directory; writer registry keyed by path), but the app
hardcodes one gallery: one container path, one coordinator, one
unlock flow, global settings. This leg delivers the product promise's
other half — multiple independently-password-keyed galleries — and is
the last frontier ticket before Local Peer Sync unblocks. Verbatim
intake: `references/intake.md`; map: `wayfinder/MAP.md`.

## Scope

Sized M. Grill decisions (session 001) folded.

### Workstream A — gallery registry + lifecycle

1. Gallery registry: enumerate gallery directories under the vault
   root; create flow (name optional, password, per-gallery KDF
   calibration at creation — the CED-11 calibrator, per gallery);
   delete-gallery deferred (a gallery with content is a GC/sharing
   question — fog).
2. **One-unlocked-at-a-time via a single switch authority** (grill
   Q2; Codex B1/B2/B3): a process-wide `GallerySwitchboard` actor
   owns ALL select/unlock/lock transitions as serialized
   transactions — scene events, idle timers, switch taps, and unlock
   tasks all route through it (the per-path VaultProcessRegistry
   cannot enforce a cross-path policy). Switching tears down through
   the FULL VaultStore path (plaintext-adjacent state + thumbnail
   pipeline purge, then coordinator lock/drain) — never a raw
   coordinator.lock(). The one-live-DEK proof (gate 3) is custody
   evidence, not claim counts: old key provably zeroed and escaped
   readers revoked BEFORE the target's KDF begins, under
   double-switch and background races. Switch-fail state (Codex
   Q15): a wrong target password leaves the app on the target's
   unlock screen with everything locked; Back returns to the list.
   Auto-lock policy handoff (Codex Q18): the OLD gallery's policy
   applies until its lock completes; the LIST screen holds no DEK
   and needs no policy; the target's policy arms at its unlock.
3. Per-gallery state, with an explicit ownership table (Codex B5/B6
   — NOT "already per-gallery"): LockPreferences' two global
   UserDefaults keys become per-gallery-ID keys (with one-time
   migration of the existing values to gallery #1); calibration.json
   becomes per-gallery records; RecentlyDeletedStore is already
   gallery-ID-scoped (keep); **rollback state stays ONE shared
   `FileRollbackStateStore` instance** injected everywhere (its
   internal per-gallery keying is correct; multiple instances over
   one file would race CED-13's fail-closed detector); trust lists
   are in-gallery (keep). UI-test reset paths clear per-gallery
   keys. The table (key → owner → migration) is written into the
   goal's results.

### Workstream B — switcher UI + device-local labels

1. Gallery list screen (app root when >1 gallery exists; a
   one-gallery user gets a "New Gallery" affordance in Settings —
   Codex Q16): per-gallery tile with lock state. **Registry
   identity = the authoritative `gallery.meta` gallery UUID** (Codex
   Q17/B7), with directory path as location only; duplicate UUIDs
   (copied dirs) surface as an error tile, not data loss. **Locked
   discovery never constructs SealedVault** (Codex B4 —
   `init` runs WAL recovery): a read-only meta/HEAD structural
   parser (or cached registry metadata) feeds the list, and the
   active gallery's path is never re-opened while claimed.
   Sealed-plane honesty (Codex A11): tiles show only what's real —
   registry-recorded created-date, lock state; no counts.
2. **Device-local labels** (grill Q1; Codex B8/B9/A12/Q19):
   optional name + cover photo per gallery, this device only.
   Storage: a NEW dedicated Keychain key (`label-store-key`,
   `WhenUnlockedThisDeviceOnly` — distinct from the device-identity
   key), AEAD with gallery-UUID AAD binding; label ciphertext lives
   in Application Support and MAY ride backup, and the DEFINED
   restore outcome is graceful loss (key doesn't restore → labels
   reset to generic tiles; recovery = relabel). Cover pipeline: no
   plaintext file ever (decrypt → downscale in memory → seal under
   the label key in one pass); decoded cover pixels pre-unlock are a
   DISCLOSED memory residual; covers purge with the global shield —
   the list stays behind the existing `.inactive` shield, so covers
   never appear in the app-switcher snapshot. Color/emoji is
   DROPPED (not part of the settled name+cover decision). Unlabeled
   tiles: index + registry created-date.
3. Migration: the existing single gallery becomes registry entry #1
   with its current settings; zero-friction relaunch (e2e-gated).

## Green gates

1. `swift test` + app suites + `xcodebuild` (simulator + generic
   device) green; VaultCore untouched or additive-only.
2. Scripted e2e: existing-vault relaunch lands in its gallery
   unchanged (migration to registry entry #1 atomic + idempotent,
   crash-injected, preserving settings/calibration — Codex B7) →
   create second gallery (distinct password, calibration runs) →
   import into it → switch back (full-store teardown; wrong password
   leaves target unlock screen, Back to list) → relaunch shows list
   → label + cover set while unlocked, visible on locked list,
   absent from every gallery-format file.
3. Custody + adversarial matrix (Codex B3/B9/B10): one-live-DEK
   proven as custody evidence (old key zeroed + readers revoked
   before target KDF; DEBUG-only probes, no production exposure of
   registry internals — Codex A13) under rapid A→B→C switching,
   backgrounding mid-target-KDF, and switching during
   import/playback/snapshot delivery; registry-creation crash
   points; corrupt/swapped label records and missing label key
   (graceful generic-tile fallback, typed, no crash); duplicate
   gallery UUIDs surface safely; cover plaintext never on disk
   (container scan incl. tmp) and purged with the shield.
4. Blind multi-tool review wave (all four reviewers) completed and
   reconciled.

## References

- `references/intake.md`; `wayfinder/MAP.md`;
  `grilling/session-001-20260720-222000.md`.
- Ground truth: `App/MobileSeal/AppContainer.swift`,
  `VaultCoordinator.swift`, `VaultStore.swift`,
  `Support/KeychainDeviceKeyStore.swift` (device-local-key pattern
  to mirror for labels), `Support/RecentlyDeletedStore.swift`,
  `UI/UnlockView.swift` + `GalleryView.swift`;
  `Sources/VaultCore/VaultProcessRegistry.swift` (per-path claims),
  `SealedVault.swift` (sealed-plane meta parse for the locked list).
- CED-11 RESULT.md (calibrator, coordinator custody), CED-13
  RESULT.md (per-gallery trust/rollback stores).

## Decisions (grilling session 001)

Q1 device-local optional name + cover photo (Keychain-key-encrypted,
pre-unlock visible, never synced/shared) · Q2 one-unlocked-at-a-time,
switch locks previous · Q3 cross-gallery move/copy deferred to map
fog (staged-reimport sketch recorded there).

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`. Formatter scoped to THIS goal folder.
- Zero HITL: all gates simulator/macOS.
- The registry's one-writer-per-path is per-VAULT-path — the
  one-live-DEK rule is an APP policy on top (enforce in the
  coordinator layer, gate-instrumented).
- Device-local label store mirrors KeychainDeviceKeyStore's pattern;
  labels live under Application Support OUTSIDE gallery dirs (they
  ride device backup, which is fine — they're device-scoped by
  design, not secret gallery material).
- xcodegen regeneration; `Scripts/run-gates.sh` shape.
