# CED-12 Result: Build Streaming Encrypted Media Playback

## What changed

MobileSeal went from stills-only to streaming encrypted video
playback: video import, decrypt-on-demand through
`AVAssetResourceLoaderDelegate`, and the autoplay-on-swipe pager —
with the first VaultCore change since CED-10. Commits, in order:

- `91994b6` feat: VaultCore streaming read seam (WS A) —
  `SealedChunkProvider` (sealed-plane fetch by `ChunkAddress`,
  CAS-verified at the seam; deliberately NOT `ChunkSource`),
  `ResidentChunkCache` (budgeted noncopyable `SecureBytes` entries:
  pinned while borrowed, eviction zeroizes, misses coalesce,
  over-budget requests fail typed, injected pressure halves the
  budget to a floor and recovery restores it), `StreamingReader`
  (padding-aware range reads; AEAD/padding verification stays on the
  plaintext plane), typed `chunkUnavailable(retryable:)` and
  `budgetExhausted`. 18 new UIKit-free tests.
- `1f98ea7` feat: video import, streaming loader, playback custody,
  pager (WS B/C) — picker admits videos; `StagedPart.video` role;
  ImportEngine video tail (poster + duration in one `AVAsset` pass;
  metadata v2 by backward-compatible optional fields); the `vault://`
  loader-delegate request state machine (content info from stored
  metadata, request registry, ≤ one-chunk slices from
  `currentOffset`, `requestsAllDataToEndOfResource` fed to EOF,
  exactly-once completion, `didCancel` unwind — serving the ranges
  AVPlayer actually requests, never a time→chunk mapping);
  `PlaybackController` owning playback custody, registered with the
  coordinator's one lock path (fail requests → release players →
  purge cache → custodian drain); Photos-lite pager (hard-snap
  paging, tile↔detail zoom morph, interactive swipe-down dismiss);
  muted looping autoplay + tap-for-sound; Live Photo motion-once
  through the same streaming path (no plaintext file ever exists);
  one-active-player with generation-token neighbor warming; external
  playback allowed with scene-capture blanking
  (`UITraitCollection.sceneCaptureState`, never the deprecated
  `UIScreen.isCaptured`). Committed fixture generator +
  fixtures: fast-start MP4, tail-moov MOV, unsupported-codec MP4
  (stsd FourCC patched to `zzzz`), paired MOV.
- `5f029a6` test: 8-test playback custody suite; the isPlayable
  probe (an unsupported codec never fails `AVPlayerItem.status` — it
  reports unplayable, so the page probes explicitly).
- `b9b3705` test: e2e video legs, prefetch-discipline gate, the
  chunk-profile benchmark harness.
- `9b8fd4d` fix: a blanket SwiftUI `simultaneousGesture(TapGesture())`
  over the UIViewRepresentable grid swallowed `didSelectItemAt` —
  latent since CED-11 (no test had ever tapped a cell).
- `024420b` test: semantic cell selection (XCUITest cell enumeration
  order is not the grid's sort order).
- `fef3423` fix: `coordinator.start()`/`bootstrap()` one-shot — a
  full-screen UIKit presentation re-runs the root SwiftUI `.task`,
  and the second `start()` re-routed an UNLOCKED vault to `.locked`
  mid-pager (diagnosed via a host-visible breadcrumb file showing a
  second `coordinator.start()` on the same pid).
- `3742e04` chore: benchmark opt-in marker file + recorded simulator
  numbers.
- `dfa448a` fix: wave-001 findings (see gate 6) — Live Photo capture
  shield, real warm-task cancellation + `StreamingReader.warm`,
  benchmark timeout honesty, Q7 backfill implemented, per-file
  integrity classification, video low-disk guard, still-viewer
  integrity UX restored, respond-vs-sweep lock, Release-stripped
  tamper seams, non-tautological gate-4 observables.

### Design decisions made during execution (not in the spec)

- **Cache keyed by `ChunkAddress`**: dedup-shared chunks resolve to
  one entry — identical address ⇒ identical sealed bytes ⇒ identical
  AAD context and plaintext.
- **Seam verification in the reader's miss path**: fetched bytes
  re-hash against the requested address once per miss, so ANY
  provider (local, fake, future remote) is held to the CAS contract.
- **Damage taxonomy through the streaming path**: on-disk tamper
  surfaces as `addressMismatch` AT THE SEAM; a consistently-renamed
  tampered object as `chunkUnavailable`; live AEAD failure is
  reachable only via the drain race (remapped `vaultLocked`). The
  app maps all integrity cases to the damaged UX; an unsupported
  codec is loader-clean + `isPlayable == false` — never confused
  with damage (Codex A6).
- **Unsupported-but-authentic imports as SUCCESS**: duration parses
  from moov → the item lands with duration and no poster; only an
  unreadable container fails the item.
- **Admission control fails typed under concurrent distinct misses**
  (never blocks); the loader serializes per-request serving in
  one-chunk slices so real playback does not contend.
- **Metadata v2**: all new blobs encode v2; decode accepts v1–v2;
  pre-CED-12 paired Live-Photo videos derive duration lazily at
  first open into `VaultStore.derivedDurations` (session-scoped —
  inventory blobs are immutable, nothing is rewritten).

### Environment friction worth recording

- The `simultaneousGesture` cell-selection kill and the SwiftUI
  `.task` re-run on full-screen presentation (above) are the two
  gotchas most likely to bite again.
- XCUITest: plain UIKit container identifiers do not surface (anchor
  on buttons/labels); cell order ≠ sort order (select by semantic
  `accessibilityValue`); a custom fullScreen dismissal animator must
  reinstall the presenter's view or the window is left empty.
- `TEST_RUNNER_` env vars do not reach app-hosted unit tests; the
  benchmark arms via `/tmp/mobileseal-bench` (the simulator shares
  the host filesystem — also the trick behind the breadcrumb-file
  diagnostics).
- Debugging UITest failures from ffmpeg-extracted frames of the
  xcresult screen recording was decisively faster than element-tree
  guesswork.

## What did NOT need changing

- **Formats: frozen, untouched** — the provider is read-path only;
  `docs/formats.md` and the KAT fixture are byte-identical, and the
  chunk-profile decision (keep 4 MiB) changes nothing import writes.
- **`ChunkReader` and the import `ChunkSource`** — untouched; the
  streaming reader decrypts under `e.aadFileID` exactly as
  `ChunkReader` does, so dedup-shared chunks needed no special
  handling (CED-10's `aad_file_id` note held).

## Gate 1 — build + unit suites

`swift test` (VaultCore, macOS): **75 tests / 17 suites green**
(20 new: provider contract incl. unavailable + address-mismatch,
range→chunk math, budget accounting/eviction/pinning under
concurrency, pressure shrink/restore, warm + warm-cancellation,
purge/lock). App unit suites: **57 tests / 12 suites green** (10-test
playback custody suite incl. the failure-taxonomy classifier).
`xcodebuild` simulator build and `generic/platform=iOS
CODE_SIGNING_ALLOWED=NO` build: **SUCCEEDED**.

## Gate 2 — scripted e2e (simulator)

`E2EFlowUITests.testCreateImportRelaunchUnlockRestore`: create →
import the 114-provider fixture batch (110 images, the first carrying
the Live-Photo paired MOV; fast-start MP4; tail-moov MOV;
unsupported-codec MP4; corrupt image LAST) → summary `imported=113
skipped=0 failed=1 interrupted=false` → grid shows posters + duration
badges → unsupported item renders "Can't play this video's format"
(its OWN state, never the damaged badge) → tail-moov video autoplays
MUTED (advancing scrubber is the observable), tap unmutes, three
scrubs keep presenting → the tamper seam flips a chunk byte + purges
the cache → reopening streams the damaged bytes cold and shows the
damaged state → relaunch → unlock → grid restores. **PASSED** (~56 s).
Frames-presented (first-pixel-buffer) per seek position is pinned at
unit level for BOTH moov placements
(`framesPresentAtStartAndAfterScrubs`).

## Gate 3 — playback custody

`PlaybackCustodyTests`: lock mid-playback yields **active-request
count == 0 and cache bytes == 0** (concrete counters), readers fail
closed (`vaultLocked`), coordinator children torn down; a
canary-marked video (valid trailing `free` box) is streamed — frames
presented — while a recursive byte-scan of the app container finds
ZERO plaintext during and after playback, and after lock. Residual
boundary stated in the test and docs: AVFoundation-internal buffers,
response `Data`, and decoded frames are ordinary process memory
outside the audited set (the honest boundary the goal required).

## Gate 4 — prefetch discipline

`PlaybackPagerUITests.testFastSwipesKeepOnePlayerAndBudget`: eight
rapid swipes across the mixed batch — players ≤ 1 in every sample,
cache bytes ≤ budget throughout, **player activations bounded by
landings** (non-tautological counter), warming ran, in-flight warms
drain to zero, the landed video activates exactly one player, loader
requests drain. Warm-task CANCELLATION is pinned deterministically at
unit level (`warmAbandonsWhenCancelled`,
`warmTasksAreTrackedAndSweptByLock`) since 20 KB fixtures warm too
fast for the UI race to be reliable. **PASSED**.

## Gate 5 — chunk-profile benchmark

Simulator, fixture matrix H.264+HEVC × fast-start + tail-moov (30 s,
720p, GOP 60), SEPARATE vaults per profile (dedup would silently
reuse the first profile's chunks), cold per repetition (fresh cache +
fresh player/asset; OS page cache of encrypted files is a shared,
documented residual). 10 reps across 5 positions per video;
seek-to-first-PRESENTED-frame; timeouts throw rather than sample:

| profile | p90 (aggregate) | p50 range per video |
| ------- | --------------- | ------------------- |
| 4 MiB   | 27.0 ms         | 19.3–24.4 ms        |
| 2 MiB   | 24.9 ms         | 19.9–22.9 ms        |
| 1 MiB   | 28.5 ms         | 20.4–25.9 ms        |

Predeclared rule (adopt 2 MiB only if p90(4 MiB) > 400 ms AND the
2 MiB improvement > 25%): neither branch triggers — p90 is ~15× under
the threshold and the improvement is 7.8%. **Decision:
keep-4MiB-default** (no format-affecting change). Full JSON in the
test log (`CHUNK-PROFILE-BENCH`). Device confirmation is a HITL run
with Cedric (below); since the decision keeps the status quo, no
new-import behavior hangs on it. Budget degradation:
`playbackContinuesUnderMemoryPressure` — the budget halves to the
floor under injected pressure, eviction obeys it, frames keep
presenting, recovery restores the cap.

## Gate 6 — blind review wave

`reviews/wave-001/INDEX.md`: **all four reviewers completed on the
first wave.** claude-code (opus/high) 10 findings; codex 6 (5
overlapping by convergence); sonarqube 0 open; coderabbit 0. Three
independent convergences — the unshielded Live Photo motion, the
non-cancelling generation tokens, and the benchmark's
timeout-as-sample — plus every distinct finding were judged real and
fixed in `dfa448a`; one gate assertion was adjusted with recorded
reasoning (UI-level warm-cancellation is timing-dependent; the
mechanism is unit-pinned). Full dispositions in the INDEX. All
suites re-run green post-fix.

## HITL device steps (queued for Cedric — executor shells cannot sign)

1. **AirPlay truth table**: play a vault video, AirPlay to the TV —
   external playback should work while the LOCAL surface stays
   usable; start a screen recording without AirPlay — the local
   player must blank behind the cover.
2. **Benchmark device confirmation** (gate 5's device half):
   `touch /tmp/mobileseal-bench` then run
   `MobileSealTests/ChunkProfileBenchmarkTests` against the iPhone;
   the keep-4MiB decision must hold (expected trivially — simulator
   p90 is 15× under threshold).
3. **Picker smoke**: import a real video and a Live Photo through the
   real PHPicker; verify grid badge, autoplay, and motion-once.

## Follow-ups

- **Capture cover for Live Photo motion is now installed**, but the
  cover text mentions recording/mirroring only — if a filmstrip or
  richer video chrome lands later, revisit the cover as a shared
  component.
- **Pager polish candidates** stay map fog: zoom carryover,
  pinch-to-grid, scrub-preview filmstrip (grill Q1/Q5).
- **Streaming still decode** stays map fog (plan-review trim A1);
  remote-source retry/suspension semantics belong to the sync leg
  (trim b) — the fake provider deliberately proves only
  fetch/unavailable/address-verify.
- **Sonar ephemeral project** `mobileseal-CED-12-streaming-media-playback`
  exists on the server; merge cleanup deletes it
  (`deleteSonarBranchProject`).
