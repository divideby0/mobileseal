# Wayfinder map — Private Photo Vault

Recrafted forward from the locked CED-11 snapshot
(`../../../CED-11-ios-vault-app-shell/wayfinder/MAP.md`, merged in
`494c57f`), folding in CED-11's execution results
(`../../../CED-11-ios-vault-app-shell/results/RESULT.md`) and the
mid-execution items Cedric queued (pluggable chunk source, pager
gesture question).

## Destination

A daily-driver private photo vault on Cedric's own current-generation
Apple devices: spec phases 1–5 (encrypted core ✅, app shell ✅, full
media playback, multiple galleries, manifest/CRDT + device identity,
local peer sync) — on the portable UIKit-free **VaultCore** whose
formats are the contract for a later macOS/Linux CLI peer. Cloud,
sharing, iPad, visionOS: beyond this map.

## Notes

- **This map carries execution** (wayfinder "Plan, don't do" override).
- Skills: `goals`, `grill-me`, `domain-modeling` (CONTEXT.md gained
  app-shell terms in CED-11; extend for playback vocabulary).
- Estimates: fixed t-shirt scale (XS=1…XXL=13), never calendar time.
- Spec §11 hardening items ride the leg whose surface they touch.
- Device floor: latest current OS. Signing: paid account; team in
  gitignored Local.xcconfig; device steps are HITL (executor shells
  cannot reach the login keychain — CED-11 friction note).
- **Standing principle** (app-shell grill): background execution
  transfers SEALED bytes only — crypto runs only in the open,
  unlocked app; the two-plane API is the enforcement seam.

## Tickets

- **Streaming Media Playback** (task, L) — the triggering goal (this
  folder): pluggable rewindable `ChunkSource` + resident-plaintext
  budget in VaultCore; AVAssetResourceLoaderDelegate streaming
  decrypt (no plaintext temp files); video import poster frames;
  swipe-to-advance pager with neighbor prefetch and zoom/dismiss
  transitions; Live Photo motion; streaming still decode (removes the
  detail viewer's whole-file materialization); scrub-latency
  benchmark deciding the per-file video chunk profile (4 MiB vs
  1–2 MiB — research on file).
- **Multiple Galleries** (task, M) — per-gallery DEK/password,
  switcher, per-gallery lock state (writer registry already keys by
  vault path). **Unblocked.**
- **Manifest CRDT & Device Identity** (task, L) — device keys, signed
  AddEntry/Tombstone, set-union merge, TOFU; supersedes inventory v0;
  owns rollback detection. **Unblocked.**
- **Local Peer Sync** (task, XL) — Multipeer/Bonjour hash-diff
  reconciliation; two-in-process-peer tests; real two-device
  verification. (blocked by: Manifest CRDT & Device Identity,
  Multiple Galleries)
- **CLI Sync Peer UX Grilling** (grilling, M) — headless sync DEVICE
  with its own device key (market-research conclusion); owns
  cross-process flock + swift-sodium pinning. (blocked by: Local
  Peer Sync)

## Decisions so far

- [iOS Vault App Shell — shipped](../../../CED-11-ios-vault-app-shell/results/RESULT.md)
  — MobileSeal app merged (`494c57f`): PHPicker import, encrypted
  thumbnails, snapshotStream-fed grid (0.11% hitch), full
  lock/purge/preference surface, on-device calibration chose
  **3 ops / 512 MiB (0.632 s)**. Execution revelations: VaultCore
  needed ZERO changes (metadata blob carried the app schema; the
  tempting dedup probe was avoided with an app-level hash); wave
  clean on the first attempt; ProMotion adaptive refresh broke
  interval-based hitch metrics (lateness-vs-target is the fix);
  xcodegen regeneration and Xcode first-launch packages are real
  operational gotchas.
- [Vault Core Crypto & CAS — shipped](../../../CED-10-private-photo-vault/results/RESULT.md)
  — VaultCore (`dc680f6`): two-plane API, epoch keyring, random-nonce
  chunks, WAL, formats contract + KAT fixture; three waves.
- [E2EE photo vault market landscape](../../../../research/_default/e2ee-photo-vault-market-landscape.md)
  — empty competitive intersection; adopt Ente/Stingle/Proton
  patterns at the sharing legs; Ente's Cure53 audits as
  design-against checklist.
- [App-shell grilling (9 decisions)](../../../CED-11-ios-vault-app-shell/grilling/session-001-20260719-171500.md)
  — PHPicker copy-in; backup inclusion; Face ID deferred behind a
  core token API; auto-lock as preference; byte-exact originals incl.
  Live Photo pairs + spatial; duplicates skip-with-notice; metadata
  heap+purge; MobileSeal identity; background-sealed-transfer-only
  principle.
- Prior decisions (CED-10 record): portable core/formats-as-contract
  (ADR 0001); ciphertext-hash + manifest dedup; epoch keyring; TOFU;
  tail padding; random nonces; Argon2id MODERATE default with
  calibrate-at-creation (device chose 512 MiB).

## Not yet specified

- `rewrapKeyring` core API — recalibrate KDF params after creation
  (matters now that the real gallery sits at 512 MiB; also the
  password-change path Ente's audit flagged).
- Biometric unlock token API (Face ID) — deferred from app-shell
  grill.
- Delete-originals "move into vault" flow — unblocks at the sync
  milestone.
- GC/repair leg — orphan chunks, entry rewrite, snapshot pinning;
  sharpens once tombstones exist.
- CI leg — macOS + iOS-simulator lanes (`Scripts/run-gates.sh` is the
  shape), pinned-toolchain assertion, compile-fail harness.
- CLI non-LAN role (always-on hub) — hangs on CLI grilling.
- Smaller CED-11 residuals (fixtures out of Release bundle, provider
  size estimates, persisted metadata index, resume-prompt across
  locks) — indexed in its RESULT.md Follow-ups; promote to tickets
  only if they bite.

## Out of scope

- Supabase backend, cloud sync, sharing, invites (phases 6–7) — a
  fresh effort/map after this destination.
- iPad adaptation and visionOS port (phases 8–9) — incl. spatial
  stereo display (spatial originals already survive).
- Dedicated hardening pass (phase 10).
- DEK rotation implementation, storage-backend choice, decoy
  bucketing, hosted-vs-self-hosted Supabase — cloud-leg questions.
