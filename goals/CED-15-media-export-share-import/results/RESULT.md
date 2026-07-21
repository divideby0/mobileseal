# CED-15 Result: Build Media Export and Share-Sheet Import

## What changed

Two commits — `4978246` (feat: media export + share-extension import)
and `f02fbeb` (fix: reconcile wave-001 blind-review findings) — give
the vault both doors: the one deliberate custody exit (full share
sheet) and entry from other apps (non-unlocking share extension +
staged inbox), stacked on CED-14's locked head `dc4e389`.

### Workstream A — export

- **`ExportController`** (`App/MobileSeal/Export/ExportController.swift`):
  an actor owning the export custody lifecycle, registered in the
  coordinator's ONE lock path via new `attachExport(controller:)`
  (Codex B2) exactly like PlaybackController. Staging decrypts
  slice-by-slice (4 MiB reads through `ChunkReader.readRange`) on a
  DETACHED task (wave-001 codex #1 — an actor-inherited task starved
  the lock path) into a per-batch directory under a NEW
  **`StagingExport/`** container root (Codex B3) — a SIBLING of
  `Staging/`, deliberately not under it, because import's
  `wipeStaging()` wipe-all runs at every import end and must never
  race a live share handoff. `prepareForLock()` bumps a teardown
  generation, cancels the in-flight staging task, AWAITS it (its
  defers close every open file handle first), then sweeps the root —
  no unlinked-but-open plaintext vnode can outlive the sweep, and a
  staging task that raced any teardown refuses to hand out its batch.
  The root is also swept at every launch (crash path) and at share
  completion/cancellation.
- **Item contract** (Codex B1/B5/Q1/A2): ALL exports stage to file
  first; the sheet gets file-URL items via `ExportActivityItem:
UIActivityItemSource` with the preserved original filename
  (dedup-suffixed "name (1).jpg" on collision), stored UTI as the
  declared type identifier, filename as subject. Live Photos export
  as TWO separate file items (still + paired video under the still's
  stem with a UTI-derived extension) — true re-pairing needs PhotoKit
  write authorization we don't hold (documented, deferred).
- **UI**: grid multi-select gains a bottom-bar Share (a third
  top-trailing item would trip the CED-13 overflow-collapse lesson);
  the pager gains a bottom-leading share button (guarded on
  `exportActive`, matching the grid). Both flow through the same
  generic pre-share custody warning (destination unknowable, iCloud
  transit named, delivered-bytes-are-gone stated — Codex B4/A5) →
  `ExportShareFlow.stageAndPresent`.
- **Lock interplay** (Codex B4): the sheet survives `.inactive`; on
  `.background` an active export cancels + sweeps REGARDLESS of the
  grace/off preference — under a `beginBackgroundTask` assertion so
  iOS cannot suspend the process mid-teardown (wave-001 codex #1) —
  and a mid-share lock sweeps via the participant and force-dismisses
  the sheet (`ExportShareFlow.dismissActive`, the pager-presenter
  pattern).
- **Custody boundary** (Codex A5): stated in code and tests — the
  canary claim ends at the provider handoff; bytes a chosen activity
  copies are the OS's.

### Workstream B — share extension + inbox

- **`App/ShareInbox/`** — the inbox protocol as a library compiled
  into BOTH targets (app + extension), unit-tested through the app
  target: `InboxManifest` (versioned schema v1: UTI, byte length,
  BLAKE2b-256, pairing, fractional-second dates; `sourceApp` OPTIONAL
  per Codex A1; decode validates the payload-name pattern so a
  manifest can never reference a foreign path), `InboxStore` (state
  machine incomplete → committed → claimed → imported/discarded,
  derived from what exists on disk; launch sweep removes ONLY stale
  incompletes + malformed manifests and releases orphaned claims —
  committed items persist, the app's wipe-all explicitly does not
  apply; quota 2 GiB / 50 items with oldest-committed-first expiry —
  total-ordered by (committedAt, itemID) — recorded as notices;
  all-or-nothing batch claims; a persisted prompted ledger; an
  injectable disk probe), `InboxWriter` (extension side: live-photo
  bundle representation FIRST mirroring PickerMediaProvider — Codex
  B10 — no still/video duplication; `loadFileRepresentation` ONLY
  with a REAL cancellation handle bridged through
  `withTaskCancellationHandler`, copy inside the callback — Codex B8;
  concurrency 1 by construction; typed disk-full/quota/cancel
  refusals with per-item cleanup and live-photo partial-move
  rollback; manifest written LAST atomically — the commit point,
  Codex B9 — with quota victims evicted only AFTER the commit).
- **VaultCore** grew one additive public surface: `MediaHashing`
  (streamed BLAKE2b-256 hex over Clibsodium's crypto_generichash) so
  the extension hashes manifests in the vault's own hash family with
  no new dependency; pinned to RFC 7693 test vectors in
  `Tests/VaultCoreTests/MediaHashingTests.swift`.
- **Extension target `MobileSealShare`** (xcodegen, Codex B7/B11):
  share-services extension, media-only activation rule (image+movie,
  max 50 each), bundle id `com.gmail.cedric.hurst.mobileseal.share`,
  embedded in the app; app group
  `group.com.gmail.cedric.hurst.mobileseal` entitlement on BOTH
  targets (generated `.entitlements` committed with project.yml +
  regenerated pbxproj). The extension never unlocks, never runs the
  KDF (120 MB limit; the argon2id research is why), touches no
  Keychain. Per-file `.completeUnlessOpen` + backup exclusion are
  applied EXPLICITLY to every inbox file (app-group containers
  inherit neither — Codex B7). Cancel disables the UI, cancels the
  writer, AWAITS its typed cleanup, and only then ends the request.
- **Main-app intake** (Codex A4): discovery on activation AND unlock
  AND gallery switch (`VaultStore.discoverInbox` — all three triggers
  funnel to one precondition-guarded entry); exactly-once prompt per
  batch, PERSISTED across relaunch in the inbox's `prompted.json`
  ledger (declined batches re-offer only alongside NEW arrivals);
  quota-expiry notices surface in the prompt. Accept claims the batch
  ATOMICALLY through the CED-14 switch authority — new
  `GallerySwitchboard.claimBoundToLiveGallery` runs claim +
  import-start as ONE serialized FIFO transaction bound to the live
  gallery's UUID, so no switch/lock/create can interleave (the
  parent's shipped switchboard API matched the plan; no deviation to
  report). Validation before import: `InboxMediaProvider` re-derives
  byte length + BLAKE2b-256 against the manifest — on the SOURCE and
  again on the staged COPY (wave-001 coderabbit #1) — and throws the
  new typed `MediaProviderError.integrityMismatch` →
  `ImportFailure.integrityMismatch`; corrupt items are DISCARDED at
  reconciliation (they can never import), everything else releases
  back to committed. Decline keeps committed items; per-item discard
  lives in Settings ("Staged Imports"). Import routes through the
  UNCHANGED CED-11 pipeline (ImportEngine staging discipline, dedup,
  thumbnails, low-disk checks).
- **Interruption rules**: a lock/switch mid-inbox-import follows the
  normal import-interruption path; because the coordinator drops the
  summary on teardown, the store releases ALL active claims at the
  phase change — imported members re-offer and dedup to
  `skippedDuplicate` next time (convergent), unimported ones simply
  re-offer. Orphaned claims from a crashed process release at the
  next launch sweep.
- **UI-test hermeticity**: UI-test launches get an ISOLATED inbox
  inside their per-test container — the shared app-group container
  persists across simulator launches, and a stray staged item would
  pop the import prompt mid-e2e. App-hosted unit tests likewise get a
  per-test inbox (`TestSupport.makeStore`) because the TEST_HOST app
  now carries the real entitlement.

### Drive-by fix

- `VaultCoordinator.ingest` re-checks `phase.isUnlocked` after its
  internal awaits before publishing: a lock completing while an
  ingest was suspended (actor reentrancy) could paint a stale
  pre-lock item list over the cleared UI state. Pre-existing window;
  CED-15's extra lock participant shifted scheduling into it (caught
  by ScenePhaseLockTests flaking once in-suite, then pinned).

## What did NOT need changing

- **The import pipeline** (CED-11) — the inbox rides `MediaProvider`
  unchanged; per-item commits, dedup, thumbnails, low-disk checks all
  reused as-is.
- **The switchboard's transition set** (CED-14) — the claim
  transaction is a new METHOD on the existing FIFO chain (a
  value-returning `serializedResult` variant), not a new code path;
  teardown/unlock/switch bodies untouched. The parent's shipped
  switchboard shape matched the plan's assumption — nothing to
  report under the Executor-notes deviation clause.
- **VaultCore formats** — nothing about the on-disk vault changed;
  the one addition (`MediaHashing`) is a public wrapper over the
  existing internal BLAKE2b stream. `docs/formats.md` untouched (the
  inbox manifest is app-layer staging metadata, not a vault format).

## Gate 1 — build + suites (stacked diff base)

- `swift test` (macOS VaultCore): 121 tests, 27 suites — pass (+2
  tests/+1 suite over CED-14: the MediaHashing vectors).
- `xcodebuild` generic iOS device (unsigned, `CODE_SIGNING_ALLOWED=NO`),
  now including the embedded extension target: builds.
- Simulator app-hosted unit suite (`MobileSealTests`): 123 tests, 19
  suites — pass (three new CED-15 suites plus canary extensions; four
  tests added by the wave-001 reconciliation).
- All five UI suites (E2EFlow, MigrationDelete, MultiGallery,
  GridScrollPerf, PlaybackPager): pass — full `Scripts/run-gates.sh`
  green twice (pre-wave and post-reconciliation).
- Wave diff base: `CED-14-multiple-galleries` at its locked head
  `dc4e38943c22e150f7794f8e31b664099a56da61` (Codex A6) — the branch
  ref never moved during execution.

## Gate 2 — export e2e via the consumption seam

`ExportCustodyTests` (Codex B13/Q8): the exported items' load
handlers are invoked DIRECTLY (`UIActivityItemSource
itemForActivityType`/`dataTypeIdentifier`/`subject` — what
Photos/Files/AirDrop call) — byte-exact content, preserved filename,
correct UTI asserted per item type: still (jpeg), ordinary video
(mp4), Live Photo pair (two file items; paired .mov under the
still's stem). Collision dedup ("photo.jpg" / "photo (1).jpg")
asserted. Completion sweeps; cancellation sweeps (postcondition race
test PLUS the deterministic slice-hook test that parks staging
provably in flight and proves the lock's cancel preempts it);
mid-share lock sweeps via the participant with a locked-vault stage
refusing typed; simulated-crash relaunch sweeps StagingExport/; the
grace/off background override fires with the vault provably still
unlocked (off-policy variant). Custody boundary stated in the tests
(Codex A5).

## Gate 3 — share-in pipeline

`InboxProtocolTests` (writer/store as a library): atomic
manifest-last commit with hash/length attested from the inbox's own
bytes; truncated/foreign/garbage manifests classified malformed and
swept, never imported; unsupported schema version rejected typed;
states + sweep rules (fresh incompletes survive, stale sweep,
committed persist, claims release at launch); quota count + byte
expiry oldest-first with notices, single-oversize typed refusal,
victims claimed-since-planning skipped; disk-full typed with no
partials — including the live-photo bundle sized by CONTENTS;
live-photo bundle preferred over split representations (no
duplication); non-media skipped typed; load failure typed; mid-stage
cancellation typed with cleanup through the REAL cancel-handle
plumbing; concurrent writers collision-free.

`InboxImportIntegrationTests` (main-app flow over the real pipeline):
committed batch → discovery → exactly-once prompt → gallery-bound
claim (`claimBoundToLiveGallery` refuses a stale gallery and a locked
vault) → real import → items in the grid, inbox cleared; decline
keeps + re-prompts only with new arrivals — including across a
simulated relaunch; per-item discard; hash-mismatch rejected before
import and discarded; lock racing an accepted import leaves no
stranded claims and conserves every item (vault ∪ committed);
bootstrap releases orphaned claims.

Extension-process termination mid-copy is modeled by bare payloads
with no manifest (the writer's crash leaves exactly that): classified
incomplete, never committed, swept when stale. Real share-from-Photos
and the signed two-App-ID install join the map's HITL checklist.

## Gate 4 — custody canary

`AppCustodyCanaryTests` extended over both new roots: the canary
image is visible under `StagingExport/` ONLY inside the documented
staged→swept window, absent from the whole container after the
completion sweep AND after a mid-share lock; the claim's boundary is
stated in the test — it ends at the provider handoff (Codex A5).
Inbox files (payload + manifest) carry per-file backup exclusion,
protection class asserted where the filesystem reports it, and
nothing remains after removal. `StagingExport/` carries backup
exclusion + requested protection like `Staging/`. Device ENFORCEMENT
of protection classes remains the stated simulator residual (Codex
A7 lineage).

## Gate 5 — blind multi-tool review wave

Wave results-001: all four reviewers completed on the first attempt
(claude-code opus/high, codex, sonarqube — 0 open on the ephemeral
branch project, compute task `2b83a170…` — coderabbit). 13 findings →
12 deduplicated: **9 fixed** (including all three codex majors — the
actor-executor staging starvation, evict-before-commit quota, and the
extension's fire-and-forget cancel), **2 fixed as defense-in-depth**,
**1 rejected as filed with its mechanism adopted** (the teardown
generation counter). Full reconciliation:
`reviews/results-001/INDEX.md`. Fixes verified by the full unit suite
(123 tests) and a final full `run-gates.sh` sweep.

Folder-naming note: the wave writer emitted `reviews/results-001/`
(the upstream wave-NNN naming deviation CED-13/14 recorded); left as
generated.

## HITL checklist additions (map, not gates)

- Signed two-App-ID install with App Groups on the paid personal team
  (Codex B11/Q7): simulator proves functionality; App Groups on
  personal teams is supported on paper — risk documented, not assumed
  away.
- Real share-from-Photos smoke (extension activation, live-photo
  bundle from the real provider) and share-sheet export to
  Photos/Files/AirDrop on device.
- Device enforcement of `.completeUnlessOpen` + backup exclusion on
  the app-group inbox (simulator asserts attributes only).

## Follow-ups

- **Interprocess inbox transaction** — the recorded residual from
  wave-001 codex #2/claude-code #2: concurrent extension processes
  can transiently exceed the quota and a claim can still race an
  expiry inside the execute window (benign terminal state, but a
  SQLite/NSFileCoordinator transaction would close it properly).
  Candidate goal if share-in sees real multi-app use.
- Cross-gallery move orchestration remains a NON-GOAL (Codex A7) —
  export → reimport → delete is now manually possible; automation is
  its own future goal.
- "Save to Photos" for the two Live-Photo files saves separate
  assets; a PhotoKit-authorized re-pairing export is a candidate goal
  if that UX matters.
