---
status: promoted
created: 2026-07-20T17:40:07-05:00
author: cedric
promoted: 2026-07-20T18:02:54-05:00
issue_url: https://linear.app/cedric-personal/issue/CED-13/build-manifest-crdt-and-device-identity
linear_project: Mobileseal
linear_project_id: cccebfd8-6d19-474b-852f-c87bf528dcf6
---

# Build Manifest CRDT and Device Identity

## Problem

Every gallery's content list is still CED-10's local encrypted
inventory v0 — single-device, no authorship, no deletion, no merge.
The sync legs need signed, mergeable manifest entries authored by
per-device identities (spec §9/§5.4). This leg builds them in
VaultCore and migrates the app. Zero HITL gates (with one stated
custody residual). Verbatim intake: `references/intake.md`; map:
`wayfinder/MAP.md`; blind plan review (14 blockers folded):
`references/codex-plan-review-20260720.md`.

**Scope-honesty note (review B4/B5/B12, resolving to the TOFU
decision's own rationale):** formats are versioned and extensible,
but AUTHORITY semantics this leg are single-user/multi-device — every
device belongs to the vault owner; gallery-password possession IS
authorization; roles are recorded but multi-party authority (trust
genesis attestation, escalation resistance, owner recovery, member
purge rights) is explicitly deferred to the sharing legs, where the
account/membership anchor exists (spec §9's premise). A format
version bump there is acceptable and planned for.

## Scope

Sized L.

### Workstream A — device identity

1. Per-device **Ed25519 signing keypair only** (X25519 deferred to the
   sharing legs that consume it — review A5). Custody (review B11,
   honest version): libsodium-generated key stored as a Keychain
   generic-password item, `WhenUnlockedThisDeviceOnly` — device-bound
   Keychain, NOT Secure-Enclave-resident (SE cannot host libsodium
   Ed25519). Exactly ONE audited extraction point copies the Keychain
   `Data` into `SecureBytes` and zeroes the intermediary; the
   compile-fail raw-key gate applies everywhere else. Behind the
   pluggable `DeviceKeyStore` protocol (CLI leg adds
   passphrase-wrapped file).
2. Trust list, single-user semantics: a signed, versioned device
   registry (device pubkey, name, added-at, role recorded for future
   use). Genesis: created at gallery creation/migration, signed by
   the creating device (review Q1 — genesis attestation beyond this
   is a sharing-leg concern, documented). New devices self-register
   on first unlock (TOFU per session-001 Q8). Trust-list updates are
   an append-only device-set union this leg (no removal — revocation
   is sharing-leg; review B5's non-convergence is thereby out of
   scope and documented).
3. Device migration/restore behavior stated (review B12): a restored
   vault without its Keychain key enrolls as a NEW device via TOFU;
   old entries stay valid under the old pubkey; no recovery of the
   old identity is needed in single-user semantics.

### Workstream B — signed manifest (supersedes inventory v0)

1. **Canonical signed encoding** (reviews B1/A1/A2): every signed
   object (AddEntry, Tombstone, TrustList, HEAD descriptor) is a
   canonical byte encoding — fixed field order, declared bounds,
   duplicate/alternate-encoding rejection — whose signature covers a
   domain separator (object kind), format version, **gallery UUID**,
   epoch, and every semantic field. Signatures are computed over the
   canonical plaintext; objects are then sealed with the existing
   AEAD discipline (nonce/AAD documented); verification order
   (decrypt → parse → verify signature) is normative.
2. **AddEntry preserves the storage contract** (review B2): carries
   `file_id`, `aad_file_id`, dedup hash, chunk list + addresses,
   chunk size, unpadded length, encrypted metadata, author pubkey,
   epoch — a superset of inventory-v0's entry, so dedup-shared
   chunks, thumbnail/Live-Photo links, and readers keep working.
   **Entry identity = `file_id`** (review Q2), with a normative
   equivalence rule for migration duplicates (B.4).
3. **Tombstone targeting** (review B3): targets `file_id` (the
   durable identity), plus the gallery-bound canonical digest of the
   targeted AddEntry when known; tombstone-before-add is held inert
   until its target appears; malformed targets are inert and
   reported.
4. **Merge**: entry-set union keyed by identity; tombstone
   application under the validity rule (author-or-owner; in
   single-user semantics every trusted device passes — the rule's
   full force arrives with sharing). **Migration equivalence rule**
   (review B8): entries flagged `migrated_from_v0` with equal
   (`file_id`, content hash) are one logical entry regardless of
   signer — two devices independently migrating the same backed-up
   v0 vault converge. Property suite: commutativity, associativity,
   idempotence, tombstone convergence, duplicate-migration
   convergence (two-peer fixture histories — review B14).
5. **On-disk graph defined** (review B7): a manifest object is one
   COMPLETE encrypted operation-set snapshot (entries + tombstones +
   trust list reference), content-addressed like inventory v0; HEAD
   names exactly one; recovery keeps the
   highest-valid-local-generation rule. The **local generation
   counter survives as a LOCAL commit revision** (review Q5) feeding
   `snapshotStream`/readers — persisted, not part of the CRDT, not
   synced; documented as such in formats.md.
6. **Migration** (reviews B9/B8): idempotent state machine with
   defined order — device key ensured in Keychain → trust-list
   genesis staged → manifest staged → single WAL commit (manifest +
   HEAD) → high-water mark initialized; crash injection at every
   step; re-running any prefix is a no-op. v0 object superseded only
   at the commit point.
7. **Rollback detection, honestly scoped** (review B10/Q4): signed
   HEAD descriptor with per-device monotonic counter; the high-water
   mark lives DEVICE-LOCAL (outside the vault, beside the Keychain
   identity) so it neither rolls back with a restored vault nor
   blocks one. Detector fires only on a KNOWN signer presenting an
   older-than-observed counter; a fire surfaces a user-visible
   "restored from an older backup?" acceptance flow that
   re-baselines and RECORDS the acceptance. What it does NOT detect
   (element omission, cross-signer games) is documented; stronger
   detection is the sync leg's (peer attestation).

### Workstream C — app adoption + delete

1. App reads/writes the signed manifest; grid/import/dedup/playback
   unchanged; migration transparent (progress UI if a 500-item
   fixture migration exceeds 2 s on the simulator — review A4's
   measurable threshold).
2. **Two-tier delete over the media AGGREGATE** (reviews B13/Q6;
   grill Q2/Q3): delete targets the logical media item — original +
   linked thumbnail/Live-Photo/poster entries — never a bare entry.
   _Delete-for-myself_ = soft state, **device-local this leg**
   (review B6/Q3 resolved by scoping: the per-user merge algebra is
   designed at the sync leg — map fog); Recently Deleted section
   lists soft-deleted aggregates (poster/thumbnail still renderable
   from the soft state), restore clears it, 30-day expiry or manual
   purge emits hard Tombstones for the whole aggregate.
   _Delete-for-everyone_ = those Tombstones (single-user: always
   authorized; the Signal-style two-button UI arrives with sharing).
   iPhone-parity UI: pager single delete + grid multi-select bulk
   delete + confirmation; copy says "removed" (space reclaimed at
   the GC leg).
3. CONTEXT.md gains identity/manifest/delete-tier vocabulary.

## Green gates

1. `swift test`: canonical-encoding KATs (accept exactly one
   representation; reject duplicates/alternates/bounds violations);
   signature suite with SEPARATE probes (review A3) — wrong gallery,
   wrong domain, wrong version, tampered field each fail at the
   signature layer, distinguishable from AEAD failure; merge
   property suite incl. two-peer histories and duplicate-migration
   convergence; tombstone matrix (author/owner/inert/late-target,
   aggregate tombstoning); migration state machine crash-injected at
   every step, idempotent re-run proven; rollback detector fires on
   stale counter and re-baselines through the recorded acceptance
   path.
2. App suites + `xcodebuild` (simulator + generic device) green.
   Scripted e2e (review B14): migrate pre-migration fixture → grid
   identical → pager single delete → grid multi-select bulk delete →
   Recently Deleted shows aggregates → restore one → purge one →
   relaunch → states durable; playback of a restored item works.
3. `docs/formats.md` covers all new formats incl. canonical signing
   encoding + verification order; conformance test decodes the KAT
   fixture (now incl. a migrated vault and a tombstoned aggregate)
   with documented constants only.
4. Key custody: the single audited Keychain extraction point;
   compile-fail fixture for raw key bytes elsewhere; **stated
   residual** (review A6): simulator asserts Keychain attributes and
   API behavior — device-bound/protection-class enforcement is
   hardware behavior, listed on the map's HITL validation checklist,
   not counted green here.
5. Blind multi-tool review wave (all four reviewers) completed and
   reconciled.

## References

- `references/intake.md`; `wayfinder/MAP.md`;
  `references/codex-plan-review-20260720.md` (dispositions inline by
  finding number).
- Ground truth to read first: `Sources/VaultCore/Inventory.swift`,
  `Wire.swift`, `FormatConstants.swift`, `Gallery.swift`
  (generation/snapshotStream), `KeyCustodian.swift`,
  `SecureBytes.swift`; `App/MobileSeal/MediaIndex.swift` +
  `MediaMetadata.swift` (the aggregate link model);
  `docs/formats.md` (§Inventory object, §Commit protocol/Recovery).
- Spec §5.4/§9: `goals/CED-10-private-photo-vault/references/intake.md`.
- CED-10 RESULT.md (`aad_file_id`, crash protocol); CED-12 RESULT.md
  (reader paths).
- `research/_default/e2ee-photo-vault-market-landscape.md`
  (append-only ownership differentiator).

## Decisions (grilling session 001 + review dispositions)

Grill: Keychain device-key custody (SE-resident dropped as
unrealizable — review B11); iPhone-parity delete UI; Signal-style
two-tier semantics (soft per-user / hard author-gated tombstone).
Review-driven scope decisions: single-user authority semantics with
versioned formats (multi-party at sharing legs); X25519 deferred;
soft-delete device-local this leg (sync algebra at sync leg);
append-only trust list (revocation at sharing legs).

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- Formatter runs scope to THIS goal folder only — never `goals/**`.
- VaultCore stays UIKit-free; the Keychain-backed `DeviceKeyStore`
  implementation lives in the app layer; core sees only the
  protocol + SecureBytes.
- Read CED-10's `aad_file_id` note before touching entry formats;
  AddEntry must carry it forward verbatim.
- High-water mark + device identity live OUTSIDE the vault root
  (they must not ride iCloud backup with the vault — that's the
  point); document the exact locations in formats.md's security
  notes.
- xcodegen regeneration after adding files; `Scripts/run-gates.sh`
  is the gate-suite shape.
