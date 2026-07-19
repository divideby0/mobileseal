# Wayfinder map — Private Photo Vault

Recrafted forward from the locked CED-10 snapshot
(`../../../CED-10-private-photo-vault/wayfinder/MAP.md`, merged to main
in `dc680f6`), folding in CED-10's execution results
(`../../../CED-10-private-photo-vault/results/RESULT.md`).

## Destination

A daily-driver private photo vault on Cedric's own current-generation
Apple devices: spec phases 1–5 (encrypted core ✅, full media playback,
multiple galleries, manifest/CRDT + device identity, local peer sync) —
built on the portable, UIKit-free **VaultCore** (shipped in CED-10)
whose on-disk formats are the contract (`docs/formats.md` + KAT
fixture) that later powers a macOS/Linux CLI sync peer. Cloud backend,
sharing, iPad, and visionOS are beyond this map's destination.

## Notes

- **This map carries execution** (wayfinder "Plan, don't do" override).
- Skills each session should consult: `goals`, `grill-me`,
  `domain-modeling` (root `CONTEXT.md` glossary exists since CED-10 —
  extend it as UI-layer terms appear).
- Estimates are relative t-shirt sizes (XS=1…XXL=13), never calendar
  time.
- Spec §11 hardening items ride the leg whose surface they touch; the
  dedicated hardening pass is beyond this map.
- Device floor: latest current OS on in-use devices.
- First commit of the next goal adds `.coderabbit.yaml` with
  `goals/**` review path filters (CED-10 RESULT follow-up — wave-001
  noise against immutable provenance artifacts).

## Tickets

- **iOS Vault App Shell** (task, L) — the triggering goal (this
  folder): Xcode app target over VaultCore; Photos import; encrypted
  app-generated thumbnails; grid + detail UICollectionView-in-SwiftUI;
  lock/unlock UX with scenePhase redaction and auto-lock; device
  Argon2id benchmark + adaptive calibration (carried from CED-10).
- **Streaming Media Playback** (task, L) — AVAssetResourceLoaderDelegate
  streaming decrypt for video/audio, swipe/zoom polish, scrub-latency
  benchmark that confirms or shrinks the per-file chunk size; owns the
  resident-plaintext budget / streaming custody design CED-10
  deliberately trimmed. (blocked by: iOS Vault App Shell)
- **Multiple Galleries** (task, M) — per-gallery DEK/password, gallery
  switcher, per-gallery lock state (VaultCore's process-wide writer
  registry from wave-003 already keys by vault path). (blocked by:
  iOS Vault App Shell)
- **Manifest CRDT & Device Identity** (task, L) — Ed25519/X25519 device
  keys, signed AddEntry/Tombstone, set-union merge, trust-on-first-use;
  supersedes CED-10's inventory format-v0 with the durable signed-entry
  format (version field makes the migration detectable); owns rollback
  detection (deferred there from the Codex plan review). **Unblocked.**
- **Local Peer Sync** (task, XL) — Multipeer/Bonjour transport over
  hash-diff reconciliation, two-in-process-peer tests, real two-device
  verification. (blocked by: Manifest CRDT & Device Identity, Multiple
  Galleries)
- **CLI Sync Peer UX Grilling** (grilling, M) — macOS/Linux `vaultctl`:
  rsync-style one-shot vs. daemon/hub, headless unlock model, Linux
  libsodium/Swift toolchain reality; treat the peer as a headless sync
  DEVICE with its own device key, never a trusted server (market
  research conclusion); owns cross-process `flock` locking and the
  swift-sodium 0.9.1 staleness/pinning question (CED-10 follow-ups).
  (blocked by: Local Peer Sync)

## Decisions so far

- [Vault Core Crypto & CAS — shipped](../../../CED-10-private-photo-vault/results/RESULT.md)
  — VaultCore merged (`dc680f6`): two-plane API, epoch-keyring meta,
  random-nonce chunks with positional AAD, WAL crash consistency,
  normative `docs/formats.md` + KAT fixture; 55 tests green; three
  reconciled blind waves. Execution revelations: Swift 6.2 handles the
  full move-only design natively (no fallback); compile-fail harness
  requires `-emit-sil`; writer exclusivity needed a process-wide vault
  registry (wave-003 blocker, fixed).
- [E2EE photo vault market landscape](../../../../research/_default/e2ee-photo-vault-market-landscape.md)
  — no incumbent combines multi-vault + photos UX + serverless sync +
  provider-agnostic sharing; adopt Ente collection-key/link-fragment
  patterns, Stingle album-key rewrap, Proton role model (with our
  stricter add-only collaborator rule) at the sharing legs; Ente's
  Cure53 audits are a design-against checklist (password policy, key
  retention after password change, share revocation).
- Prior decisions (session-001 grilling + Codex plan review, all
  folded into CED-10's locked record): wayfinder structure; phases 1–5
  destination; portable core / formats-as-contract (ADR 0001 on main);
  ciphertext-hash + manifest dedup; epoch keyring, rotation deferred;
  TOFU; paid dev signing; swift-test-first strategy; Argon2id
  MODERATE (0.324 s measured on M4 Pro); 4 MiB chunks as per-file
  property; tail-chunk padding; random per-chunk nonces.

## Not yet specified

- Import fidelity: Live Photos, HEIC/ProRAW, bursts, EXIF privacy —
  being sharpened by this draft's grilling.
- CLI non-LAN role: always-on hub ambitions and whether they change
  the sync protocol — hangs on CLI Sync Peer UX Grilling.
- GC/repair leg: orphan-chunk reclamation, in-place entry repair
  (random nonces ⇒ new addresses), snapshot pinning as GC roots —
  sharpens once tombstones exist (Manifest CRDT leg).
- CI: a macOS workflow selecting the pinned toolchain, asserting
  `swift --version`, running the suite incl. the compile-fail harness
  (CED-10 follow-up; could ticket as a small task at any point).
- Metadata custody upgrade: SecureBytes for decrypted metadata blobs
  if plaintext EXIF/names enter them — this goal's grilling decides.

## Out of scope

- Supabase backend, cloud sync, sharing (password + sealed-box paths),
  invites (spec phases 6–7) — returns as a fresh effort/map once the
  destination here is reached.
- iPad adaptation and visionOS port (phases 8–9).
- Dedicated security-hardening pass (phase 10) — per-leg items ride
  their legs.
- DEK epoch rotation implementation, storage-backend choice, decoy-
  chunk bucketing, self-hosted-vs-hosted Supabase — cloud-leg
  questions.
