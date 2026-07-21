# CED-14 Result: Build Multiple Galleries and Switcher

## What changed

Two commits — `40c9e8e` (feat: multiple galleries with switchboard,
registry, labels) and `19faa18` (fix: reconcile wave-001 blind-review
findings) — turn the app layer from one hardcoded gallery into N
independently-password-keyed galleries, on an
unchanged-except-additive VaultCore.

### Workstream A — registry + lifecycle

- **`GallerySwitchboard`** (`App/MobileSeal/GallerySwitchboard.swift`)
  is the process-wide switch authority (plan review B1): every
  select/unlock/lock/create transition — scene events, the idle
  backstop, switch taps, unlock tasks — routes through it. The
  decisive design lesson: **actor isolation alone was not enough** —
  Swift actors are reentrant at suspension points, and the gate-3
  adversarial suite caught two transactions interleaving at their
  internal awaits (duplicate teardown events over stale ledger state).
  The switchboard therefore chains every transition through an
  explicit FIFO transaction tail (`serialized`), making each atomic
  with respect to the others.
- **Full-store teardown** (plan review B2) is structural: the
  thumbnail pipeline is now a registered `VaultLockParticipant`
  (alongside CED-12's playback controller), and the store clears
  plaintext-adjacent UI state on the `.locking` phase — so EVERY
  teardown path (user lock, scene policy, idle, switch, create) runs
  the one coordinator lock path with nothing skippable.
- **Coordinator changes**: discovery/selection moved out of `start()`
  into switchboard-driven `select`/`deselect`; `createGallery` returns
  the authoritative gallery UUID and persists the calibration record
  per gallery; ONE shared `FileRollbackStateStore` lives on the
  coordinator for its whole life (plan review B5/B6 — a second
  instance over the same file would race the CED-13 fail-closed
  detector's ground truth).
- **Two custody races found by writing the gate-3 tests, fixed in the
  coordinator**: (1) a CANCELLED import's late `finishImport`/progress
  callbacks could surface the OLD gallery's summary and progress —
  with provider filenames — after a DIFFERENT gallery unlocked; both
  now hop through the actor and drop when `importTask` was cleared by
  a teardown. (2) a scene lock racing an in-flight unlock could land
  first on the switchboard (a no-op — nothing live yet) and the
  unlock would then settle an unlocked vault in the background; the
  store's pending-lock backstop re-issues the lock when an unlock
  settles under `lockPending`, so the lock always wins and the shield
  never drops.

### Workstream B — switcher UI + device-local labels

- **`GalleryRegistry`** (`Support/GalleryRegistry.swift`): discovery
  is a filesystem scan keyed by the AUTHORITATIVE `gallery.meta` UUID
  (plan review Q17/B7); the `registry.json` sidecar records
  created-dates ONLY and is self-healing (a creation crash before the
  sidecar write backfills a best-effort date from file metadata,
  disclosed as unstable — plan review A11). Duplicate UUIDs (copied
  directories) and unreadable metas surface as ERROR TILES and are
  never openable (UUID-keyed device state would cross-apply).
- **Locked discovery never constructs `SealedVault`** (plan review
  B4): new additive VaultCore API `SealedVault.readStructuralMeta
(directory:)` reads and parses `gallery.meta` bytes only — no WAL
  recovery, no directory mutation; the ACTIVE gallery's path is never
  re-read while claimed (cached record stands in; proven by a test
  that garbages the active meta and scans).
- **Device-local labels** (`Support/GalleryLabelStore.swift`, plan
  review B8/B9): a NEW dedicated Keychain generic-password item
  (`…mobileseal.label-store-key`, `WhenUnlockedThisDeviceOnly`,
  distinct from the device-identity key) holds a 32-byte AEAD key;
  records are ChaChaPoly-sealed with the gallery UUID as AAD and live
  under `Application Support/Labels/` (NOT backup-excluded — the
  DEFINED restore outcome is graceful loss: ciphertext restores, the
  key does not, reads degrade to typed `keyUnavailable` → generic
  tiles; recovery = relabel). Reads never mint a key (that would
  collapse the typed restore state into `unreadable`). Cover pipeline:
  decrypt original → downscale in memory (`Thumbnailer`) → seal, one
  pass, no plaintext file; decoded pixels are the DISCLOSED memory
  residual; decoded covers purge with the global shield and the list
  stays behind it (plan review Q19). Color/emoji dropped (A12).
- **UI**: `GalleryListView` (root when >1 gallery or any discovery
  failure; tiles show name-or-positional-fallback, registry
  created-date, lock glyph, cover — no counts, per A11),
  `CreateGalleryView` (optional device-local name + password;
  per-gallery calibration runs at creation), Back-to-list on the
  unlock screen, "Switch Gallery" + selection-mode "Set Cover" in the
  gallery, Settings gains the gallery-name field and the one-gallery
  "New Gallery" affordance (plan review Q16).
- **Migration** (WS B.3): the existing gallery becomes registry entry
  #1 — legacy global lock-preference keys copy to its per-gallery
  keys then are removed; `calibration.json` becomes
  `calibration-<uuid>.json`; every step converges after a crash at
  any injected failpoint (unit-gated), and the UI-test reset sweeps
  the whole `lock.` prefix.

### Per-gallery state ownership table (WS A.3, plan review B5)

| State                            | Pre-CED-14                                                                        | Now owned by                                                                                                                     | Keyed by                                 | Migration                                                                                    |
| -------------------------------- | --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- | -------------------------------------------------------------------------------------------- |
| Background/idle lock policy      | 2 GLOBAL `UserDefaults` keys (`lock.backgroundPolicy`, `lock.idleTimeoutSeconds`) | `LockPreferences` per-gallery keys `lock.*.<gallery-uuid>`; loaded at selection, saved on edit                                   | gallery UUID                             | one-time copy to gallery #1, legacy keys removed; idempotent (copy only while target absent) |
| KDF calibration record           | single `Vault/calibration.json`                                                   | `Vault/calibration-<gallery-uuid>.json`, written at creation                                                                     | gallery UUID                             | copy → verify → remove legacy; idempotent                                                    |
| Recently Deleted ledger          | `DeviceLocal/recently-deleted-<uuid>.json`                                        | unchanged — was already gallery-ID-scoped (CED-13)                                                                               | gallery UUID                             | none                                                                                         |
| Rollback high-water marks        | `DeviceLocal/rollback-state.json`, a NEW `FileRollbackStateStore` per unlock      | ONE shared instance held by the coordinator for its lifetime, injected into every unlock                                         | gallery UUID + signer (internal)         | none — instance discipline, not data movement                                                |
| Trust list                       | inside each gallery's signed manifest                                             | unchanged (in-format)                                                                                                            | in-gallery                               | none                                                                                         |
| Registry created-dates           | — (new)                                                                           | `Vault/registry.json` sidecar (dates only; never names/covers; never authoritative for existence)                                | gallery UUID                             | backfill from meta file creation date (best-effort, disclosed)                               |
| Device-local labels (name/cover) | — (new)                                                                           | `Labels/label-<uuid>.sealed` + Keychain `label-store-key`                                                                        | gallery UUID (also the AEAD AAD binding) | n/a; restore without key = graceful generic tiles                                            |
| Auto-lock policy handoff         | n/a                                                                               | OLD gallery's policy until its lock completes; LIST holds no DEK, no policy; target's policy arms at selection (plan review Q18) | —                                        | —                                                                                            |

## What did NOT need changing

- **VaultCore multi-gallery capability** — as the intake stated:
  independent keyring/DEK per directory and the per-path writer
  registry needed zero changes. The one VaultCore addition is the
  additive read-only meta reader; `swift test` (119 tests) green
  unchanged otherwise.
- **RecentlyDeletedStore** — already gallery-ID-scoped (CED-13);
  verified rather than reworked.
- **Trust lists** — in-gallery by format; nothing to scope.

## Gate 1 — build + unit suites

- `swift test` (macOS VaultCore): 119 tests, 26 suites — pass.
- `xcodebuild` generic iOS device (unsigned): builds.
- Simulator app-hosted unit suite (`MobileSealTests`): 89 tests,
  16 suites — pass (includes the two new CED-14 suites below; four
  tests added by the wave-001 reconciliation).
- VaultCore untouched except the additive `readStructuralMeta`.

## Gate 2 — scripted e2e

`MobileSealUITests/MultiGalleryUITests` (committed; wired into
`Scripts/run-gates.sh`): existing-vault relaunch lands straight in its
gallery (no list, content intact — zero-friction) → second gallery
created from Settings with a distinct password (its own calibration
record visible in Settings) → import into it → cover set from
selection while unlocked → Switch Gallery → locked list shows the
device-local name AND the rendered cover (tile accessibility value,
wave-001 coderabbit #2) → wrong password on gallery 1 stays on ITS unlock
screen, Back returns to the list → correct password restores gallery
1's own 24 items → relaunch lands on the LIST with the label visible
pre-unlock and no unlock field. Migration atomicity/idempotence under
crash injection is unit-gated (`MultiGalleryStateTests.
migrationConvergesAfterCrashAtEveryStep`, parameterized over every
failpoint); the pre-registry-vault relaunch flow is additionally
exercised by the existing `MigrationDeleteUITests` (v0 fixture seed,
now passing through registry bootstrap + migration on the same run).
Full `Scripts/run-gates.sh`: pass (see gate log).

## Gate 3 — custody + adversarial matrix

`GallerySwitchboardTests` (custody half): one-live-DEK proven as
CUSTODY EVIDENCE, not claim counts —

- **Switch**: an escaped reader from the old gallery fails CLOSED
  (`vaultLocked`) after teardown, `debugChildrenAreTornDown` holds at
  the boundary, and the DEBUG-only event trail (plan review A13 —
  compiled out of Release, no registry internals exposed) shows the
  old teardown strictly preceding the target's `kdfWillStart`.
- **Rapid A→B→A bursts**: overlapping transactions in arbitrary
  arrival order never violate the replay invariant "a KDF may only
  start while no DEK is live"; terminal state is at most one live DEK
  with coordinator state consistent. (This test CAUGHT the actor
  reentrancy hole and forced the FIFO transaction chain.)
- **Backgrounding mid-target-KDF**: converges to locked with children
  torn down and the shield held, in both arrival orders (this test
  caught the lock-loses-the-race bug; the pending-lock backstop is
  the fix).
- **Switch during import** (also covers snapshot-feed delivery, which
  the import drives): import cancelled inside the one lock path, the
  torn-down session's summary/progress dropped (the coordinator-level
  fix), target unlocks with only its own content.
- Switch-fail state (Q15) pinned: wrong target password → target's
  unlock screen, everything locked, Back → list.

`MultiGalleryStateTests` (state half): registry creation crash point
(self-healing sidecar), duplicate-UUID copies → two error tiles and
no openable record, unreadable meta → typed error tile,
active-gallery-never-re-read (garbage the claimed meta; cached record
stands in), migration crash-injection at every failpoint, per-gallery
preference isolation + reset sweep, and the label failure matrix:
swapped record (AAD mismatch) → typed `unreadable`, corrupt record →
`unreadable`, missing key after "restore" → typed `keyUnavailable` —
all graceful generic-tile fallbacks, no crash.

Cover/name custody canaries
(`GallerySwitchboardTests.labelAndCoverNeverTouchGalleryFormatFiles…`):
the label name and a distinctive slice of the cover's compressed
bytes appear NOWHERE under the container (gallery dirs, Labels/
ciphertext included) nor the process temporary directory; covers
render on the locked list and purge from memory when the shield
rises.

Playback/snapshot teardown during a switch rides the SAME single lock
path CED-12's `PlaybackCustodyTests` already gate (participants sweep
before the custodian drain) — the switch path adds no second lock
code path to test.

## Gate 4 — blind multi-tool review wave

Wave results-001: all four reviewers completed on the first attempt
(claude-code opus/high, codex, sonarqube — 0 open on the ephemeral
branch project, coderabbit). 13 findings → 12 deduplicated: **9
fixed** (both codex majors — discovery hiding a meta-less gallery,
and the calibration migration trusting an unvalidated destination —
plus the coderabbit creation-failure stranding, cover-residency
tightening from claude-code, and four robustness minors), **2
documentation fixes**, **2 rejected with recorded reasons** (the
GOAL.md gate-wording edit — a UI-test process cannot scan the app
container, so the absence claim is deliberately unit-canary-gated;
and the pbxproj folder reference, which is xcodegen's rendering of
the local package at `path: .`, not a goal-folder reference). Full
reconciliation: `reviews/results-001/INDEX.md`. Fixes verified by
the full unit suite (89 tests), the extended e2e (locked-list cover
render now asserted), and a final full `run-gates.sh` sweep.

Folder-naming note: the wave writer emitted `reviews/results-001/`
(the same upstream naming deviation CED-13 recorded for evie-agent —
wave-NNN is the documented shape); left as generated.

## Follow-ups

- Delete-gallery flow remains map fog (GC/sharing question), as
  scoped.
- Cross-gallery move stays covered by the Media Export ticket
  (export → reimport → delete).
- The label key is created lazily on first label write; a
  Face-ID-era hardening pass could pre-create it at first launch to
  make the restore semantics observable earlier.
- Interrupted-import summary after an explicit lock is now dropped at
  the coordinator (it was already unreachable in-app; the CED-11-era
  test pinning it was updated). If a resume-prompt-after-relock UX is
  ever wanted, it needs a per-session summary ledger, not the sink
  path.
