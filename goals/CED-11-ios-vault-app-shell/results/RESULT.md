# CED-11 Result: Build iOS Vault App Shell and Photo Grid

## What changed

The repo went from a headless VaultCore package to a working iOS app.
Commits, in order:

- `84bcf79` chore: .coderabbit.yaml goal-record path filters (WS0 —
  the CED-10 follow-up, landed first as mandated).
- `f45d8b3` feat: VaultCoordinator spike — session custody + import
  core (WS A.1/A.3/B-core/D.4). The spike ran FIRST as mandated and
  was verified with `swiftc -emit-sil` against the iOS simulator SDK —
  the SIL pass runs the move-only ownership diagnostics — before any
  UI work.
- `7f5eb50` feat: MobileSeal iOS app target, grid UI, and lock UX
  shell (WS A.2/C/D + xcodegen project + 111 committed fixtures).
- `755e170` test: app suites for gates 2/4/5 + scripted e2e and perf
  UI tests.
- `f51fe48` chore: green-gate runner (Scripts/run-gates.sh).
- `0718f64` feat: calibration record in Settings (gate 6 data source).
- `bb8e2d7` test: rate-limit test needs 7 attempts (limiter semantics:
  failure 6 starts the first cooldown).
- `7238609` fix: isolate lock-preference persistence from app-hosted
  tests (gate-2 flake root cause).
- `77e3919` fix: perf-test seed signal + idle-timeout launch override.
- `b05bcfb` fix: wave-001 findings — custody races, recovery wiring,
  honest gates (20 findings; see gate 7).
- `8ab2104` docs(goals): reconcile review wave-001.
- `99f1c11` + `7dbba0a` test/chore: gate-6 device benchmark as a
  single on-device test + project regeneration.
- `9014ddb` fix: measure scroll hitches as lateness past
  targetTimestamp (the device spot-check exposed the interval
  heuristic misreading ProMotion's adaptive refresh as hitching).

### Design decisions made during execution (not in the spec)

- **Session custody shape**: actor `VaultCoordinator` holds
  `UnlockSession?` (noncopyable Optional in actor storage); extraction
  via an `Optional.take()` extension (`consume self` + reinit).
  Pattern-matching a noncopyable optional in reference storage is
  itself a consume — a separate `sessionLive` bool mirrors liveness
  for probes. The consuming `lock()` runs on the coordinator's
  executor, off the main actor, under a `beginBackgroundTask`
  assertion.
- **App-level dedup hash**: VaultCore's dedup hash is domain-separated
  and internal, and `importFile` has no "would this dedup" probe — the
  app keeps its own SHA-256 of the plaintext in the encrypted metadata
  blob and skips before importing (same identity — media bytes — same
  user-visible skip-with-notice as grill Q5).
- **Undecodable original policy**: a corrupt image imports byte-exact
  (the archive never discards bytes) but the ITEM reports failed and
  stops the batch (WS B.6); it renders with a no-preview badge.
- **Provider-cancel vs batch-cancel**: a user cancelling one item's
  load skips that item; backgrounding cancels the batch and marks the
  summary interrupted for the resume prompt. Post-wave: a summary is
  DROPPED if a lock intervenes (custody beats convenience — outcomes
  carry filenames), so the resume prompt survives only in-foreground
  interruption.
- **Single-scene policy is structural**:
  `UIApplicationSupportsMultipleScenes=false`; `galleryAlreadyOpen`
  maps to "vault is open elsewhere" as defense in depth.
- **Grace-period lock is lock-on-return** (timers do not run
  suspended); the shield stays raised until the lock lands.
- **Calibration measures whole unlocks** on a throwaway vault (create
  once, unlock 5×, median) — the user-visible cost, not just the raw
  KDF; measure → extrapolate (linear in memlimit) → verify, with
  thermal and 2× free-memory gates, MODERATE floor, and a 25 ms
  `task_vm_info.phys_footprint` sampler for peak memory.
- **Perf instrumentation**: CADisplayLink lateness-vs-`targetTimestamp`
  tracking (UI-test mode only) + os_signpost intervals; thresholds
  stated in the test (hitch = frame > 8.4 ms past its promise, ratio
  ≤ 10%, no frame ≥ 250 ms late). The lateness formulation exists
  because the interval-vs-interval heuristic misread ProMotion's
  adaptive refresh (120→80→40 Hz during deceleration) as a 45% hitch
  ratio on real hardware.

### Environment friction worth recording

- Xcode 26.0.1's first-launch packages were absent on this machine —
  EVERY `xcodebuild` invocation died (CoreSimulator plugin load), even
  generic-destination builds. Cedric ran `sudo xcodebuild
-runFirstLaunch` mid-goal; the iOS 26.0.1 simulator runtime then
  needed `xcodebuild -downloadPlatform iOS` (8 GB) — the first,
  interrupted download left a corrupt runtime image
  (`simctl runtime verify` −67068) that had to be deleted and
  re-downloaded. Until then, development proceeded via SwiftPM
  cross-compile (`--triple arm64-apple-ios17.0-simulator`) plus direct
  `swiftc -emit-sil`/`-typecheck` (Testing macros need
  `-plugin-path <toolchain>/usr/lib/swift/host/plugins/testing`).
- App-hosted unit tests share the app's UserDefaults domain on a
  simulator: ScenePhase tests persisting a 0.2 s idle timeout poisoned
  later e2e launches (the vault locked itself mid-import). Fixed by
  injecting UserDefaults; a UI-test reset path also clears lock-pref
  keys.
- Device signing: the executor's shell session sees only the System
  keychain (no login keychain in its search list), so all
  device-signed runs went through Xcode GUI in Cedric's session; the
  team ID (from the GUI's one-time Signing & Capabilities selection)
  lives in gitignored `Configs/Local.xcconfig`.
- xcodegen (user-owned brew) generates the committed project; adding a
  source file requires regeneration or no target compiles it (bit the
  gate-6 test once).

## What did NOT need changing

- VaultCore: zero changes. The two-plane API held for every need —
  the metadata blob carried the app's kind/link schema opaquely,
  `snapshotStream()` + per-generation readers fed the grid, and the
  process-wide writer registry surfaced "open elsewhere" for free.
  The one tempting addition (a public dedup probe) was avoided with
  the app-level hash.
- No CI was added (still the CI leg's work; the pinned-toolchain
  assertion remains `.swift-version` + manifest comment).

## Gate 1 — iOS build gates

(a) `xcodebuild test` (iPhone 17 simulator, iOS 26.0.1): **43 app
unit tests in 9 suites green** — including the import-seam fixture
tests. (b) `xcodebuild -destination 'generic/platform=iOS'
CODE_SIGNING_ALLOWED=NO build`: **BUILD SUCCEEDED** (also verified
independently by the claude-code reviewer). (c) `swift test`
(VaultCore macOS): **55 tests, 13 suites green** — unchanged.

## Gate 2 — scripted end-to-end on simulator

`E2EFlowUITests.testCreateImportRelaunchUnlockRestore` (XCUITest, not
manual): create gallery → import the committed fixture batch (110
mixed HEIC/JPEG + 1 corrupt, forced-failure last) through the fixture
provider seam → summary line asserts `imported=110 skipped=0 failed=1
interrupted=false` → grid renders from encrypted thumbnails →
terminate → relaunch → unlock → grid restores → no-preview badge
visible on the corrupt item. A second test asserts the wrong-password
copy states tamper-ambiguity. Both green (~25 s + ~15 s).

## Gate 3 — grid scroll performance

`GridScrollPerfUITests`: seeds a 500-photo gallery through the Gallery
actor, then six instrumented fling-scrolls with CADisplayLink
lateness-vs-target tracking (os_signpost "grid-scroll" intervals
bracketing each). Thresholds stated in the test: hitch ratio ≤ 10%,
no frame ≥ 250 ms late. Simulator: **912 frames, 1 hitch (0.11%),
37.2 ms worst lateness**. Device spot-check (iPhone 17 Pro Max,
iOS 26.6): **passed within the stated thresholds** (1 m 12 s run via
Xcode; the per-scroll console line was not captured before the device
disconnected — the in-test assertions carried the bounds). The first
device run is what exposed the ProMotion instrumentation flaw fixed
in `9014ddb`.

## Gate 4 — custody canary over the app container

`AppCustodyCanaryTests`: a canary-marked JPEG imported through the
real pipeline; a recursive byte-scan of the app container (vault root

- galleries + staging) finds ZERO plaintext outside staging's
  documented lifecycle — after import completion, after cancellation
  (lock mid-batch), and after a simulated-crash relaunch (stranded
  staging plaintext wiped by the launch sweep). The canary round-trips
  byte-exact through the session plane. Backup policy: nothing under
  the vault root is `isExcludedFromBackup`; staging IS excluded.
  Audited-path claim and simulator Data-Protection gap documented in
  the test (Codex A7/B12 pattern).

## Gate 5 — lock behavior

`ScenePhaseLockTests` + `CoordinatorLifecycleTests`: shield on
`.inactive` without locking (redaction ≠ lock); `.background` under
the strict default locks and purges — decoded-image cache provably
empty, coordinator children torn down (session consumed, gallery
dropped, snapshot + import tasks cancelled, index purged), an
escaped pre-lock reader fails closed with `vaultLocked`; the
process-registry claim releases (a second coordinator can unlock
after the first locks); grace policy locks on return past the window
with the shield held up; idle backstop fires; the wave-001 regression
test races 20 purge/decode bursts against the cache and asserts
emptiness.

## Gate 6 — device Argon2id benchmark

Run as `DeviceBenchmarkTests/deviceCalibration` on **Cedric's iPhone
17 Pro Max (iPhone18,2), iOS 26.6 (23G5057c)** — the full
calibrate-at-creation protocol on real hardware, 2026-07-20:

| measure                                           | value                                                   |
| ------------------------------------------------- | ------------------------------------------------------- |
| Chosen parameters                                 | **3 ops / 512 MiB** (calibration raised above MODERATE) |
| Median unlock, 3 ops / 256 MiB (MODERATE)         | 0.301 s                                                 |
| Median unlock, 3 ops / 512 MiB (chosen, verified) | **0.632 s** — inside the 0.5–1.0 s envelope             |
| Thermal state                                     | nominal                                                 |
| Free memory before run                            | 3353 MiB (≥ 2× the 512 MiB pick)                        |
| Peak process footprint during run                 | 535 MiB                                                 |
| Build                                             | debug test host                                         |

Honesty note on the release-build protocol: the test host ran in
Xcode's default Debug configuration (`releaseBuild:false` in the
record). The Argon2id timings are still representative because the
crypto is Swift-Sodium's PREBUILT optimized libsodium binary — app
compilation mode does not change its speed, and the Swift wrapper
overhead is noise against a 0.3–0.6 s KDF. The ladder behaved as
designed: predicted 512 MiB ≈ 0.60 s from the MODERATE base,
verified 0.632 s.

Manual device smoke test (WS B.2): the installed app on the same
iPhone — vault created (real calibration), photos imported from the
real photo library through the real out-of-process PHPicker, and
rendered in the grid. The Live-Photo-pair variant of the picker path
remains fixture-tested only (follow-up below).

Residual simulator/device gaps (Codex A7), documented: the simulator
enforces no real Data Protection classes (the attribute is requested
and asserted, enforcement is device-only), no jetsam/mlock/thermal
behavior, no real iCloud Photos assets (the iCloud-delay path is
fixture-simulated), and app-switcher snapshot redaction is asserted
at the scenePhase/shield level, not by inspecting actual snapshot
images.

## Gate 7 — blind review wave

`reviews/wave-001/INDEX.md`: all four reviewers completed on the
FIRST wave (CED-10 needed three). claude-code (opus/high) 13
findings; codex 8; coderabbit 8; sonarqube 0 open. Three independent
convergences — the purge-on-lock reentrancy race, the unwired
thumbnail-recovery rule, the grace-return shield gap — all fixed in
`b05bcfb` along with 17 more; 4 reasoned rejections/deferrals
(fail-closed lock vs awaiting imports; fixtures in Release bundle;
streaming detail decode → Playback leg; first-item disk estimate).
Full gate suite re-run green post-fix.

## Follow-ups

- **Face ID convenience unlock** — needs a custody-respecting
  biometric-token API in VaultCore (map, deferred at grill Q3).
- **Streaming rewindable ChunkSource + streaming detail decode** —
  Playback leg (owns resident-plaintext budget); removes the detail
  viewer's whole-file materialization behind its 256 MiB ceiling.
- **`rewrapKeyring` core API** — recalibrate KDF params after
  creation (calibrate-at-creation is the only shot today; the device
  actually chose 512 MiB, so rewrap matters when hardware changes).
- **Move fixture images out of the Release app bundle** (wave-001
  cc #7 residual): Debug-only resources or test-injected files.
- **Provider-side size estimates** for a true first-item low-disk
  preflight (wave-001 codex #7 residual).
- **Persisted encrypted metadata index** if unlock-time indexing
  measurably lags at scale (deliberate supersession of intake §6's
  SwiftData index stands for personal-library scale).
- **Live Photo picker path device smoke test** — still-photo picker
  import verified on device; the Live Photo bundle
  (`UTType.livePhoto` file representation → .pvt contents) is
  fixture-tested only.
- **Import summary resume-prompt across locks** — dropped for
  custody in wave-001; a persistent (encrypted) pending-batch note
  could restore it.
- **CI leg** — unchanged from CED-10's follow-up; now also wants the
  iOS simulator lane (`Scripts/run-gates.sh` is the shape).
