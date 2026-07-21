# Wayfinder map — Private Photo Vault

Recrafted forward from the locked CED-12 snapshot
(`../../../CED-12-streaming-media-playback/wayfinder/MAP.md`, merged),
folding in CED-12's execution results
(`../../../CED-12-streaming-media-playback/results/RESULT.md`).

## Destination

A daily-driver private photo vault on Cedric's own current-generation
Apple devices: spec phases 1–5 (encrypted core ✅, app shell ✅, media
playback ✅, multiple galleries, manifest/CRDT + device identity,
local peer sync) — on the portable UIKit-free **VaultCore** whose
formats are the contract for a later macOS/Linux CLI peer. Cloud,
sharing, iPad, visionOS: beyond this map.

## Notes

- **This map carries execution** (wayfinder "Plan, don't do" override).
- Skills: `goals`, `grill-me`, `domain-modeling` (CONTEXT.md gained
  playback vocabulary in CED-12; extend for identity/manifest terms).
- Estimates: fixed t-shirt scale (XS=1…XXL=13), never calendar time.
- Spec §11 hardening items ride the leg whose surface they touch.
- Device floor: latest current OS. Device steps are HITL (executor
  shells cannot reach the login keychain).
- **Standing principle**: background execution transfers SEALED bytes
  only — crypto runs only in the open, unlocked app.
- **Deferred HITL validation checklist** (CED-12 RESULT, cedric away
  from machine): AirPlay truth table, on-device benchmark
  confirmation, real-picker video/Live-Photo smoke — run before the
  daily-driver milestone, no leg blocks on them. CED-13 adds: verify
  on a REAL device that the device-key Keychain item is enforced as
  `WhenUnlockedThisDeviceOnly` (device-bound, absent from backups —
  simulator asserts attributes/API behavior only; stated residual,
  review A6), and that a restored backup re-enrolls as a new device
  via TOFU.
- Format changes land in `docs/formats.md` with KAT vectors (CED-10
  discipline); formatter runs scope to the ACTIVE goal folder only —
  never a bare `goals/**` glob (locked records are byte-stable).

## Tickets

- **Manifest CRDT & Device Identity** (task, L) — the triggering goal
  (this folder): per-device Ed25519 keypair (X25519 deferred to
  sharing legs), Keychain custody behind pluggable DeviceKeyStore;
  canonical gallery-bound signed formats (AddEntry preserving
  file_id/aad_file_id, Tombstone, TrustList, HEAD) + KAT vectors;
  set-union merge with duplicate-migration convergence; append-only
  TOFU trust list; idempotent v0 migration; device-local rollback
  high-water mark with a backup-restore re-baseline flow; iPhone-
  parity delete over media aggregates with Recently Deleted.
  Authority semantics single-user this leg (post-review scope
  honesty; multi-party at sharing legs).
- **Multiple Galleries** (task, M) — per-gallery DEK/password,
  switcher, per-gallery lock state. **Unblocked.**
- **Local Peer Sync** (task, XL) — Multipeer/Bonjour hash-diff
  reconciliation; two-in-process-peer tests; real two-device
  verification (HITL). (blocked by: Manifest CRDT & Device Identity,
  Multiple Galleries)
- **CLI Sync Peer UX Grilling** (grilling, M) — headless sync DEVICE
  with its own device key; owns cross-process flock + swift-sodium
  pinning + the portable passphrase-wrapped device-key custody
  variant. (blocked by: Local Peer Sync)

## Decisions so far

- [Streaming Media Playback — shipped](../../../CED-12-streaming-media-playback/results/RESULT.md)
  — SealedChunkProvider + residency budget, loader-delegate request
  state machine (both moov placements), video import + posters +
  schema v2, autoplay pager with Live Photo motion, AirPlay-exempt
  capture shield. **Chunk-profile verdict: keep 4 MiB** (simulator
  p90 15× under the predeclared threshold; device confirmation
  queued, cannot change the verdict for new imports). Wave-001 all
  four reviewers, first attempt.
- [iOS Vault App Shell — shipped](../../../CED-11-ios-vault-app-shell/results/RESULT.md)
  — MobileSeal app (`494c57f`); on-device calibration chose 3 ops /
  512 MiB (0.632 s); VaultCore needed zero changes.
- [Vault Core Crypto & CAS — shipped](../../../CED-10-private-photo-vault/results/RESULT.md)
  — two-plane API, epoch keyring, random-nonce chunks, WAL, formats
  contract + KAT fixture.
- [E2EE photo vault market landscape](../../../../research/_default/e2ee-photo-vault-market-landscape.md)
  — empty competitive intersection; Ente/Stingle/Proton patterns for
  the sharing legs; Cure53 audits as design-against checklist.
- [App-shell grilling (9 decisions)](../../../CED-11-ios-vault-app-shell/grilling/session-001-20260719-171500.md)
  and [playback grilling (5 + trim)](../../../CED-12-streaming-media-playback/grilling/session-001-20260720-012500.md)
  — PHPicker copy-in; backup inclusion; Face ID deferred; auto-lock
  preference; byte-exact originals; Photos-lite pager; muted
  autoplay; external playback allowed; video-only; filmstrip
  deferred.
- Prior decisions (CED-10 record): portable core/formats-as-contract
  (ADR 0001); ciphertext-hash + manifest dedup; epoch keyring; TOFU;
  tail padding; random nonces.

- [Manifest-CRDT grilling, session 001](../grilling/session-001-20260720-174500.md)
  — Keychain/Secure-Enclave device-key custody (portable variant at
  CLI leg); two-tier Signal-style delete: delete-for-myself = soft
  per-user restorable state, delete-for-everyone = CRDT tombstone
  under the author-or-owner rule; single-user UI = iPhone-parity
  Recently Deleted; two-button UI at the sharing legs.

## Not yet specified

- Soft-delete ("delete for myself") multi-device merge algebra —
  device-local this leg; designed at the sync leg.
- Multi-party authority: trust genesis attestation, role escalation
  resistance, revocation/removal, owner recovery, member purge
  rights — sharing legs, with a planned format-version bump.
- `rewrapKeyring` core API — KDF recalibration + password change
  (Ente-audit lesson).
- Biometric unlock token API (Face ID).
- Delete-originals "move into vault" flow — at the sync milestone.
- GC/repair leg — orphan chunks, entry rewrite, snapshot pinning;
  sharpens once tombstones exist (THIS leg creates them).
- CI leg — macOS + iOS-simulator lanes.
- CLI non-LAN role (always-on hub).
- Pager polish candidates (zoom carryover, pinch-to-grid, filmstrip);
  streaming still decode; remote-source availability semantics (sync
  leg).
- Smaller residuals indexed in CED-11/CED-12 RESULT Follow-ups.

## Out of scope

- Supabase backend, cloud sync, sharing, invites (phases 6–7).
- iPad adaptation and visionOS port (phases 8–9) — incl. spatial
  stereo display.
- Dedicated hardening pass (phase 10).
- DEK rotation implementation, storage-backend choice, decoy
  bucketing, hosted-vs-self-hosted Supabase.
