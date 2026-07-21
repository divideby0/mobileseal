# CED-13 Result: Build Manifest CRDT and Device Identity

## What changed

Format v1: the signed manifest superseded CED-10's local encrypted
inventory across VaultCore and the app, with per-device Ed25519
identity, TOFU trust, set-union merge, transparent v0→v1 migration,
device-local rollback detection, and iPhone-parity two-tier delete.
Commits, in order:

- `d25bcd7` feat: signed manifest CRDT core + device identity (WS
  A/B) — `DeviceIdentity` (libsodium Ed25519, no secret accessor) +
  pluggable `DeviceKeyStore`; canonical signed
  AddEntry/Tombstone/TrustList/HEAD-descriptor codecs with per-kind
  domain separators, sig-version + gallery-UUID binding, and
  strict-canonical parsing (sorted orders, duplicate/alternate/bounds
  rejection); sealed `ManifestObject` carrying the LOCAL commit
  revision; `HeadV1` (plaintext address + sealed signed descriptor,
  splice cross-check); set-union merge with the
  migration-equivalence collapse (smallest canonical digest —
  min is associative, so convergence is free); idempotent migration
  state machine with failpoints; `RollbackStateStore` protocol +
  file impl; TOFU registration folded into commits; `Gallery` /
  `UnlockSession` / `SealedVault` rewired. All 75 pre-existing v0
  suites green over the new world unchanged.
- `a7082a0` test: gate-1 suites — canonical-encoding KATs, signature
  probes separated from AEAD failure, merge property suite incl.
  two-peer histories through real vault APIs, migration crash
  injection at every migration AND commit step, tombstone matrix,
  TOFU, rollback detector + recorded acceptance, `devicekey-raw-escape`
  compile-fail fixture.
- `42d95e7` feat: app adoption + two-tier delete (WS C) —
  `KeychainDeviceKeyStore` (`WhenUnlockedThisDeviceOnly`, the single
  audited raw-key transfer point), backup-excluded `DeviceLocal/`
  dir (rollback state + soft-delete ledger), transparent migration at
  unlock, rollback acceptance alert, pager single delete + grid
  multi-select bulk delete (soft → Recently Deleted), Recently
  Deleted screen (restore / permanent purge), 30-day expiry.
- `f81e957` docs+test: formats.md §Format v1 (normative), kat-vault-v1
  fixture (migrated vault + tombstoned aggregate) + third-party
  conformance decoder from documented constants only, committed v0
  app-vault fixture + seeding seam + migration/delete e2e, CONTEXT.md
  vocabulary.
- `94f476a` test: e2e green + gate-runner entry (toolbar overflow fix
  — see surprises).
- `2fe93e0` fix: wave-001 findings (9 fixed, 3 rejected with recorded
  reasons — see Gate 5).

### Design decisions made during execution (not in the spec)

- **Trust list EMBEDDED in the manifest object** (GOAL B.5 said
  "trust list reference"): embedding makes the object genuinely
  COMPLETE, covers the trust list under the same WAL-commit
  atomicity, and eliminates a dangling-reference recovery rule — the
  exact gap class review B7 flagged. Documented normatively in
  formats.md; coderabbit's wording flag is reconciled in the wave
  INDEX (#13).
- **Sealing epoch is NOT in the signing preamble** (GOAL B.1 lists
  epoch among signature-covered fields): binding signatures to the
  sealing epoch would break DEK rotation — signed CRDT elements must
  survive re-sealing verbatim (a tombstone's author cannot re-sign
  after rotation). Epoch is signed where it is a SEMANTIC field
  (AddEntry's chunk epoch); the AEAD AAD binds the container epoch.
  Rationale is normative in formats.md; codex's finding is
  reconciled in the wave INDEX (#11).
- **HEAD v1 keeps the manifest address plaintext** (sealed plane must
  resolve HEAD without the DEK, as in v0) and seals only the signed
  descriptor — device public keys and counters never sit cleartext
  on disk. The descriptor's inner address is signed and cross-checked
  against the plaintext pointer (splice detection).
- **Merge representative = smallest canonical digest** for
  same-`file_id` entries: deterministic, commutative, associative —
  covers both the migration-equivalence class and the
  cannot-happen non-equivalent collision.
- **TOFU registration at the write boundary, folded into commits**:
  reading needs only the password; authorship needs trust
  membership. `ensureDeviceRegistered()` runs eagerly at unlock in
  the app, and any first mutation folds registration in
  automatically, so a device's own tombstones can never go inert.
- **`local_revision` rides inside the sealed manifest body** but is
  documented non-CRDT/local-only; migration sets it to
  `v0 generation + 1` so v0/v1 recovery shares one axis (ties prefer
  v1).
- **App delete is soft by default** (iPhone parity): pager/grid
  delete → device-local Recently Deleted; only purge/expiry emit the
  hard aggregate tombstones. The soft ledger is deliberately
  fail-open on read (fail-SAFE direction: items reappear; nothing
  lost) — unlike the rollback store, whose unreadable-file case
  throws (fail-open there would silently disarm the detector).
- **Keychain custody has two bounded raw-byte moments** (load AND
  create direction), both inside the one audited file, both zeroing
  intermediaries (create-path wipe made CoW-proof in the wave fix);
  Security-framework internal copies are the stated residual.

### Surprises worth recording for later legs

- ~Copyable types cannot ride in tuples — multi-value returns
  involving `SecureBytes` need closure shapes (`createShell`).
- iOS collapses a >2-item trailing toolbar into a system overflow
  "More" button, silently burying a SwiftUI `Menu` one level deeper —
  the UI-test seams now live INSIDE the More menu and tests match
  menu items by LABEL (SwiftUI does not propagate accessibility
  identifiers onto menu items; row identifiers in Lists propagate
  onto every CHILD element).
- Ed25519 keygen is fast enough (~50 µs) that per-test fresh
  identities cost nothing; the whole 119-test core suite runs in ~5 s.

## What did NOT need changing

- `gallery.meta`, chunk objects, chunking/padding, the WAL commit
  protocol, and the CAS layout: v1 rides them unchanged — the commit
  generalization is one `headBytes` closure parameter.
- `ChunkReader`/`StreamingReader`/playback/import pipelines: they
  consume effective entries through the same interfaces; zero changes.
- The v0 KAT fixture: committed bytes untouched — it became the
  migration-input fixture (`FormatConformanceTests` still green
  against it).

## Gate 1 — swift test (canonical KATs, signature probes, merge, tombstones, migration, rollback)

**119 tests / 26 suites green** (`swift test`, final tree). New
suites: `SignedFormatTests` (byte-identical round-trip; trailing
bytes / unsorted / duplicate / hostile-bounds / bad-enum rejection;
wrong-gallery, wrong-domain, wrong-sig-version, per-field tamper,
author substitution, migration-flag flip each fail at the SIGNATURE
layer, typed distinctly from AEAD failure; HEAD splice; trust signer
self-listing), `MergePropertyTests` (commutativity, associativity,
idempotence, tombstone convergence across delivery orders,
duplicate-migration convergence, two-peer histories through real
vault APIs), `MigrationTests` (contract preservation over the
committed v0 KAT fixture; crash injection at every `MigrationStep`
AND every `CommitStep` with idempotent re-runs proven; completed
migration re-run is a no-op; recovery scan spans both formats),
`TombstoneAndTrustTests` (author/cross-device/untrusted/digest
matrix, aggregate delete durability, dedup-twin safety, TOFU
enrollment incl. restored-vault-as-new-device),
`RollbackDetectorTests` (fires on stale counter from a known signer,
acceptance re-baselines and RECORDS, unknown signers never fire, own
commits never fire), `FormatConformanceV1Tests`,
`Wave001RegressionTests`.

## Gate 2 — app suites + xcodebuild + scripted e2e

`Scripts/run-gates.sh` full pass: VaultCore macOS suite, generic
unsigned device build, simulator unit tests (**64 tests / 14 suites**
incl. the new `DeleteTierTests` and `KeychainDeviceKeyStoreTests`),
`E2EFlowUITests`, **`MigrationDeleteUITests`** (the CED-13 leg:
seeded committed v0 vault → unlock migrates transparently → grid
identical, 3 items → import 114 → pager single delete of a playable
video → grid multi-select bulk delete → Recently Deleted shows 3
aggregates → restore the video → purge one still → relaunch → counts
and ledger durable → the RESTORED video plays, scrubber advancing),
`GridScrollPerfUITests`, `PlaybackPagerUITests`. Re-verified green
after the wave-fix commit.

## Gate 3 — docs/formats.md + conformance

formats.md gained the normative §Format v1: signed-object common
form + domain table + verification order, AddEntry/Tombstone/
TrustList/Manifest/HEAD layouts with all constants, merge semantics,
migration state machine, recovery, honestly-scoped rollback
detection (incl. its stated non-detections), device restore, and the
custody/device-local security notes. The committed `kat-vault-v1`
fixture (the v0 KAT vault migrated by a real identity, plus an
imported two-entry aggregate hard-tombstoned) is decoded by
`FormatConformanceV1Tests.thirdPartyDecodeOfMigratedTombstonedVault`
using ONLY documented constants — including Ed25519 preamble
construction and the tombstone application rule — and cross-checked
by a reference-implementation read.

## Gate 4 — key custody

`KeychainDeviceKeyStore` is the single audited raw-key transfer
point (both directions documented and wave-hardened);
`DeviceIdentity` has no secret accessor — `devicekey-raw-escape`
compile-fail fixture + control pin it; simulator tests assert the
Keychain item's `WhenUnlockedThisDeviceOnly` attribute and
create/load idempotence. **Stated residual** (review A6): device-
bound/protection-class ENFORCEMENT is hardware behavior — recorded
on the map's HITL validation checklist (verify on-device enforcement

- restored-backup TOFU re-enrollment), not counted green here.

## Gate 5 — blind multi-tool review wave

`reviews/results-001/`: all four reviewers completed first attempt
(claude-code 2 findings — it independently ran the suites green;
codex 6 by inspection; sonarqube 0 open; coderabbit 6). Reconciled
in INDEX.md: **9 fixed** (converged recovery-HEAD/trust gap, inert
tombstones blocking valid deletes, writer-side trust bounds,
Keychain CoW wipe, purge ordering, rollback-store fail-open, recovery
tie-break, loud fixture seeding, dead code) with regression pins in
`Wave001RegressionTests`; **3 rejected with recorded reasoning**
(sealing-epoch signature binding breaks rotation survival;
package-sealing the key seam kills pluggable custody; GOAL
"reference" wording is a documented deviation); 2
already-satisfied/accepted-as-documented. Fix commit `2fe93e0`;
post-fix gates re-verified.

## Follow-ups

- GC leg (existing map ticket, now sharper): tombstoned entries'
  chunks, superseded v0 objects, and orphaned crashed-migration
  manifests all await reclamation; copy says "removed", space
  reclaim is deferred there.
- Sync leg: soft-delete per-user merge algebra; peer attestation for
  the rollback detector's stated non-detections (element omission,
  cross-signer replay); op exchange vs sealed-object exchange.
- Sharing legs: multi-party authority (genesis attestation,
  revocation, escalation resistance, owner recovery), X25519
  keypairs, the Signal-style two-button delete UI — format version
  bump planned.
- HITL checklist (map): on-device Keychain enforcement + restored-
  backup TOFU smoke.
- Minor: `.untrustedSigner`/`signatureInvalid` unlock failures
  currently surface through the generic `.other` copy in the app; a
  dedicated "vault integrity" message would be friendlier.
