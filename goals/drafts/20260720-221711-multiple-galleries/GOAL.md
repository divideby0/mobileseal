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
2. **One-unlocked-at-a-time** (grill Q2): switching galleries prompts
   the target's password and consumes the previous coordinator's
   lock() first (drain semantics unchanged); scenePhase lock applies
   to whichever gallery is open. Exactly one live DEK ever.
3. Per-gallery Settings scope: auto-lock prefs, and per-gallery
   Recently Deleted stores + rollback high-water marks + trust
   enrollment (all already per-gallery in core since CED-13 — the
   app stops hardcoding path assumptions).

### Workstream B — switcher UI + device-local labels

1. Gallery list screen (the new app root when >1 gallery exists, and
   the pre-unlock surface): per-gallery tile with lock state.
2. **Device-local labels** (grill Q1): optional user-assigned name +
   cover photo per gallery, stored ONLY on this device — encrypted
   under a device-local Keychain key (NOT any gallery DEK) so they
   display pre-unlock while staying protected at rest; never synced,
   never written into gallery formats (other devices label their
   own). Unlabeled galleries show generic tiles (index,
   created-date, optional color/emoji). Choosing a cover is an
   explicit, per-device opt-in leak; the picker for it runs while
   the gallery is UNLOCKED (it decrypts one thumbnail into the
   device-local store).
3. Migration: the existing single gallery becomes registry entry #1
   with its current settings; zero-friction relaunch (e2e-gated).

## Green gates

1. `swift test` + app suites + `xcodebuild` (simulator + generic
   device) green; VaultCore untouched or additive-only.
2. Scripted e2e: existing-vault relaunch lands in its gallery
   unchanged → create second gallery (distinct password, calibration
   runs) → import into it → switch back (password prompt; previous
   locks — registry claim released) → wrong-password on switch fails
   clean → relaunch shows the gallery list → device-local label +
   cover set while unlocked, visible on the locked list, absent from
   every gallery-format file (canary-style scan for label plaintext
   under gallery dirs).
3. Custody: one-live-DEK invariant instrumented (registry shows ≤1
   claim; switch = old zeroed before new unlock completes); cover
   thumbnails encrypted at rest under the device-local key
   (container scan finds no plaintext covers).
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
