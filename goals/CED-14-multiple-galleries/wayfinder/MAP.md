# Wayfinder map — Private Photo Vault

Recrafted forward from the locked CED-13 snapshot
(`../../../CED-13-manifest-crdt-device-identity/wayfinder/MAP.md`,
merged), folding in CED-13's execution results
(`../../../CED-13-manifest-crdt-device-identity/results/RESULT.md`).

## Destination

A daily-driver private photo vault on Cedric's own current-generation
Apple devices: spec phases 1–5 (encrypted core ✅, app shell ✅, media
playback ✅, manifest/CRDT + device identity ✅, multiple galleries,
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

- **Multiple Galleries** (task, M) — the triggering goal (this
  folder): gallery registry + create flow with per-gallery KDF
  calibration; one-unlocked-at-a-time switching; device-local
  optional name/cover labels (Keychain-key-encrypted, never synced);
  per-gallery settings/Recently-Deleted/trust scopes; single-gallery
  migration to registry entry #1.
- **Media Export / Save-Out** (task, S) — share-sheet export of
  selected items (decrypted originals) to Files or Photos: the
  vault's only deliberate custody exit, explicit confirmation, with
  an iCloud-Photos-sync warning and Files/"On My iPhone" offered as
  the non-cloud path. Also the manual cross-gallery move enabler
  (export → reimport → delete; cedric's design, 2026-07-20).
  Runs after Multiple Galleries (one loop at a time).
- **Local Peer Sync** (task, XL) — Multipeer/Bonjour hash-diff
  reconciliation over the signed manifest; two-in-process-peer
  tests; real two-device verification (HITL). (blocked by: Multiple
  Galleries — Manifest CRDT resolved)
- **CLI Sync Peer UX Grilling** (grilling, M) — headless sync DEVICE
  with its own device key; owns cross-process flock + swift-sodium
  pinning + the portable passphrase-wrapped device-key custody
  variant. (blocked by: Local Peer Sync)

## Decisions so far

- [Manifest CRDT & Device Identity — shipped](../../../CED-13-manifest-crdt-device-identity/results/RESULT.md)
  — first fully-autonomous leg (zero HITL, draft→lock→merge):
  canonical gallery-bound signed formats + KAT v1 fixture, Keychain
  Ed25519 identity, idempotent v0 migration, rollback re-baseline,
  iPhone-parity two-tier delete with Recently Deleted. Wave: 4/4
  reviewers, 9 fixed / 3 reasoned rejections. Review-folder naming
  deviation (results-001 vs wave-001) noted for upstream evie-agent.
- [Multiple-galleries grilling, session 001](../grilling/session-001-20260720-222000.md)
  — device-local optional name/cover labels (pre-unlock visible,
  Keychain-key-encrypted, never synced); one-unlocked-at-a-time
  (switch locks previous, one live DEK); cross-gallery move deferred.
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

- Cross-gallery move/copy: covered manually once Media Export
  ships (export → reimport → delete); the in-app staged two-unlock
  flow stays fog, promoted only if the manual path proves too
  annoying.
- TestFlight distribution (wireless installs to own devices) —
  convenience ticket if cable-to-Xcode gets old.
- Delete-gallery flow (a populated gallery's deletion is a
  GC/sharing-adjacent question).
- Vault-integrity unlock copy (CED-13 residual:
  .untrustedSigner/.signatureInvalid surface via generic error).
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
  tombstones exist since CED-13.
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
