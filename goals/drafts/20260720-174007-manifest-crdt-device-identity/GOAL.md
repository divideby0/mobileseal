---
status: draft
created: 2026-07-20T17:40:07-05:00
author: cedric
---

# Build Manifest CRDT and Device Identity

## Problem

Every gallery's content list is still CED-10's local encrypted
inventory v0 — a single-device artifact with no authorship, no
deletion semantics, and no way to merge two devices' histories. The
sync legs (Local Peer Sync, then cloud) need the durable form the
spec designed in §9: signed, mergeable manifest entries authored by
per-device cryptographic identities. This leg builds both halves in
VaultCore and migrates the app onto them. Zero HITL steps — pure
`swift test` plus simulator-testable app adoption. Verbatim intake:
`references/intake.md`; map: `wayfinder/MAP.md` (fourth executed
leg).

## Scope

Sized L. Per spec §5.4/§9, standing decisions (TOFU — session-001
Q8; epoch keyring; formats-as-contract), and CED-10's Codex-review
deferral of rollback detection to this leg.

### Workstream A — device identity

1. Per-device Ed25519 (signing) + X25519 (future sealed-box) keypairs,
   generated on first vault use; **pluggable at-rest custody** behind
   a `DeviceKeyStore` protocol — iOS implementation per grill Q1;
   the CLI leg later adds a portable passphrase-wrapped file variant
   (spec §5.4's original shape). Private keys expose signing through
   scoped custody (SecureBytes discipline), never raw key bytes.
2. Trust-on-first-use list per gallery (`trustlist` format): a
   device that can unlock the gallery registers its pubkeys and
   role; the list itself is signed and versioned (spec §6's
   `trustlist.enc`). Roles: owner / member (owner = gallery creator
   this leg; membership machinery beyond one user is the sharing
   legs').

### Workstream B — signed manifest (supersedes inventory v0)

1. Wire formats in `docs/formats.md` + KAT vectors (CED-10
   discipline): `AddEntry {content_hash, chunk_list + per-chunk
addresses, chunk_size, unpadded_length, encrypted_metadata,
author_device_pubkey, epoch, signature}` and `Tombstone
{target_entry_hash, author_device_pubkey, signature}` — signature
   over a canonical byte encoding (defined endianness/lengths, no
   JSON ambiguity).
2. **Validity rule** (spec §9, client-side): a tombstone is honored
   only if its author matches the target entry's author OR an
   owner-role device in the trust list; invalid tombstones are
   retained but inert (they may become valid if the trust list
   later reveals authority), surfaced in deep-verify reporting.
3. **Set-union merge**: manifests merge as entry-set union with
   tombstone application; no clocks — display order stays
   EXIF/date-taken (already in encrypted metadata). Merge is a pure
   function with a `swift test` property suite (commutativity,
   associativity, idempotence, tombstone convergence).
4. **Migration**: version detection on open; inventory-v0 entries
   are re-authored as AddEntries signed by THIS device (honest:
   provenance begins at migration; documented in formats.md),
   single WAL-atomic commit, v0 object retained until the commit
   point then superseded. KAT fixture gains a migrated-vault case.
5. **Rollback detection** (CED-10 Codex Q6 disposition lands here):
   signed HEAD descriptor carrying a per-device monotonic counter;
   a HEAD older than the device's own recorded high-water mark
   fails loud (`rolledBackManifest`) instead of silently serving an
   old view. Cross-device rollback beyond that is documented as a
   sync-leg concern (needs peer attestation).

### Workstream C — app adoption

1. The app reads/writes the signed manifest through the existing
   coordinator paths; grid, import, dedup, and playback behavior
   unchanged from the user's view; migration runs transparently on
   first unlock (progress UI only if it measurably lags at
   personal-library scale).
2. Tombstone creation UI per grill Q2 (delete button this leg or
   core-only).
3. CONTEXT.md gains identity/manifest vocabulary (device identity,
   trust list, entry authorship, tombstone, rollback high-water
   mark).

## Green gates

1. `swift test` green: signature round-trip + tamper (flip any byte
   of entry/tombstone/trustlist → typed failure); merge property
   suite; validity-rule matrix (author-delete, owner-delete,
   stranger-delete-inert, late-authority activation); migration
   (v0 fixture → signed manifest, byte-identical media, WAL-atomic,
   crash-injected); rollback detection (stale HEAD fails loud);
   KAT vectors for all new formats decode with documented constants
   only.
2. App suites + `xcodebuild` simulator/generic-device builds green;
   scripted e2e: pre-migration fixture vault opens, migrates,
   grid/playback identical before/after, relaunch stable.
3. `docs/formats.md` covers entry/tombstone/trustlist/HEAD formats
   incl. canonical signing encoding; the third-party-decode
   conformance test extends over them.
4. No plaintext/key-material custody regressions: device private
   keys never appear in the canary scan or as raw `Data`
   (compile-fail fixture added for key-byte extraction).
5. Blind multi-tool review wave (all four reviewers) completed and
   reconciled.

## References

- `references/intake.md`; `wayfinder/MAP.md`.
- Full v0.1 spec §5.4 (device identity), §9 (manifest/CRDT model),
  §6 (trustlist.enc layout):
  `goals/CED-10-private-photo-vault/references/intake.md` (main).
- `docs/formats.md` + `Tests/VaultCoreTests/Fixtures/kat-vault/` —
  the contract this leg extends.
- `goals/CED-10-private-photo-vault/results/RESULT.md`
  (`aad_file_id` semantics — entry re-authoring must preserve
  dedup-shared chunk AAD context) and
  `goals/CED-12-streaming-media-playback/results/RESULT.md`
  (StreamingReader/provider paths the new manifest must keep
  feeding).
- `research/_default/e2ee-photo-vault-market-landscape.md` —
  append-only ownership + signed logs as the differentiator vs
  Proton's editor model.

## Open questions (for grilling)

1. iOS device-key custody: Keychain/Secure-Enclave-protected
   (no new passphrase UX; keys device-bound; spec's
   low-stakes-by-design rationale) vs passphrase-wrapped file (spec
   §5.4 literal; portable but demands a second passphrase UX).
2. Delete UI this leg: a delete button creating tombstones (first
   real use of the machinery, simulator-testable) or core-only
   (UI waits for a later leg)?

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- Zero HITL: every gate runs on macOS or the simulator.
- Formatter runs scope to THIS goal folder only — never `goals/**`
  (locked records are byte-stable; see map note).
- VaultCore stays UIKit-free; `DeviceKeyStore`'s iOS implementation
  lives in the app layer if it touches Keychain APIs — check
  Security-framework availability on Linux before placing code.
- Read CED-10 RESULT.md's `aad_file_id` note before migration work:
  chunks sealed under the ORIGINAL importer's file ID must keep
  their AAD context through re-authoring.
- xcodegen regeneration after adding files; `Scripts/run-gates.sh`
  is the gate-suite shape.
