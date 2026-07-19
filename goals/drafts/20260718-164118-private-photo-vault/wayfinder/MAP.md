# Wayfinder map — Private Photo Vault

## Destination

A daily-driver private photo vault on Cedric's own current-generation
Apple devices: spec phases 1–5 (encrypted core, full media playback,
multiple galleries, manifest/CRDT + device identity, local peer sync) —
built on a portable, UIKit-free **VaultCore** whose on-disk/wire formats
are the contract that later powers a macOS/Linux CLI sync peer (on this
map at user request). Cloud backend, sharing, iPad, and visionOS are
beyond this map's destination.

## Notes

- **This map carries execution** (wayfinder "Plan, don't do" override):
  the spec (`../references/intake.md`, v0.1) already answers most
  design questions; tickets here are mostly executable goal-sized legs,
  resolved one at a time through the normal goal lifecycle.
- Skills each session should consult: `goals`, `grill-me` (for grilling
  tickets), `domain-modeling` (VaultCore vocabulary: gallery, DEK/KEK,
  chunk, entry, tombstone — a CONTEXT.md should crystallize in the
  first goal).
- Estimates are relative t-shirt sizes (XS=1…XXL=13), never calendar
  time.
- Spec §11 hardening items that touch a leg's surface ride that leg's
  green gates (e.g. no-plaintext-temp-files rides playback); the
  final dedicated hardening pass is beyond this map.
- Device floor: latest current OS on in-use devices (user deferred;
  revisit only if an older device joins the fleet).

## Tickets

- **Vault Core Crypto & CAS** (task, L) — the triggering goal (this
  folder): VaultCore Swift package with Argon2id envelope encryption
  (epoch field reserved), per-chunk XChaCha20-Poly1305, ciphertext-hash
  CAS with manifest-level plaintext-hash dedup, `swift test`
  round-trip/tamper suite, on-device Argon2id benchmark harness.
- **iOS Vault App Shell** (task, L) — Xcode app target: import from
  Photos, app-generated encrypted thumbnails, grid + detail
  UICollectionView-in-SwiftUI, lock/unlock UX with backgrounding
  redaction. (blocked by: Vault Core Crypto & CAS)
- **Streaming Media Playback** (task, L) — AVAssetResourceLoaderDelegate
  streaming decrypt for video/audio, swipe/zoom polish, scrub-latency
  benchmark that confirms or shrinks the chunk size. (blocked by: iOS
  Vault App Shell)
- **Multiple Galleries** (task, M) — per-gallery DEK/password, gallery
  switcher, per-gallery lock state. (blocked by: iOS Vault App Shell)
- **Manifest CRDT & Device Identity** (task, L) — Ed25519/X25519 device
  keys, signed AddEntry/Tombstone, set-union merge,
  trust-on-first-use, all in VaultCore with `swift test` merge suite.
  (blocked by: Vault Core Crypto & CAS)
- **Local Peer Sync** (task, XL) — Multipeer/Bonjour transport over the
  hash-diff reconciliation, two-in-process-peer tests in VaultCore,
  real two-device verification. (blocked by: Manifest CRDT & Device
  Identity, Multiple Galleries)
- **CLI Sync Peer UX Grilling** (grilling, M) — what is the
  macOS/Linux `vaultctl` actually like: rsync-style one-shot vs.
  daemon/hub, unlock model on a headless box, Linux libsodium/Swift
  toolchain reality check. (blocked by: Local Peer Sync)

## Decisions so far

- [Structure: wayfinder map](../grilling/session-001-20260718-165000.md) —
  10-phase XXL spec becomes a rolled-forward map; first goal is
  phase-1-sized.
- [Destination: phases 1–5](../grilling/session-001-20260718-165000.md) —
  daily-driver = playback polish + a second synced local copy; cloud
  can wait.
- [Portable core, formats as contract](../grilling/session-001-20260718-165000.md)
  — UIKit-free VaultCore Swift package; macOS/Linux CLI later as a
  format-compatible client; no Rust/FFI seam.
- [Signing: paid Apple Developer account](../grilling/session-001-20260718-165000.md)
  — 1-year profiles; no 7-day re-sign ritual for a daily-driver vault.
- [Chunk addressing: ciphertext-hash + manifest dedup](../grilling/session-001-20260718-165000.md)
  — storage stays fully opaque; import-time dedup via plaintext BLAKE2b
  inside encrypted metadata.
- [DEK epochs: defer, reserve field](../grilling/session-001-20260718-165000.md)
  — epoch integer in formats from day one, rotation logic only with a
  future sharing leg.
- [Device trust: TOFU](../grilling/session-001-20260718-165000.md) —
  spec's pick confirmed; approval ceremonies deferred to sharing.
- [Testing: swift test core, device for UX](../grilling/session-001-20260718-165000.md)
  — crypto/manifest/sync logic tested on macOS in the package;
  simulator/device only for UI, playback, benchmarks, transport.
- [Argon2id Tuning on Modern iPhones](../../../../research/_default/argon2id-tuning-on-modern-iphones.md)
  — delivered 2026-07-19: opslimit=3 / 256 MiB (libsodium MODERATE)
  default, params stored per gallery, adaptive calibration toward
  384–512 MiB later; never SENSITIVE for interactive unlock. Folded
  into the crypto goal (Workstream B).
- [Chunk Size for Encrypted Media CAS](../../../../research/_default/chunk-size-for-encrypted-media-cas.md)
  — delivered 2026-07-19: 4 MiB fixed confirmed as the storage-object
  default; keep chunk size a per-file manifest property so the
  playback leg can adopt a 1–2 MiB video profile if scrub latency
  demands. Folded into the crypto goal (Workstream C).

## Not yet specified

- Import fidelity details: Live Photos, HEIC/ProRAW, bursts, EXIF
  privacy handling — sharpens when the App Shell leg is drafted.
- CLI non-LAN role: does the CLI peer ever become an always-on hub
  (the "iCloud-like" ambition), and does that change the sync
  protocol? Hangs on CLI Sync Peer UX Grilling.
- Format spec document shape (the "contract" artifact): what exactly a
  third-party decryptor needs — firms up while the crypto goal writes
  the formats.

## Out of scope

- Supabase backend, cloud sync, sharing (password + sealed-box paths),
  invites (spec phases 6–7) — returns as a fresh effort/map once the
  destination here is reached.
- iPad adaptation and visionOS port (phases 8–9).
- Dedicated security-hardening pass (phase 10) — per-leg hardening
  items ride their legs (see Notes).
- DEK epoch rotation implementation, storage-backend choice
  (Supabase Storage vs BlobStore), self-hosted-vs-hosted Supabase —
  all cloud-leg questions.
