The change establishes the main streaming-read and AVFoundation plumbing, but it is not ready to merge: Live Photo playback bypasses the capture shield, stale neighbor warming is not actually cancelled, the new video path skips the existing low-disk guard, still-image integrity failures are now swallowed, and the benchmark can silently treat a missing frame as a valid latency sample. The specified legacy Live Photo duration backfill is also absent. I could not execute the Swift or Xcode suites because the review sandbox rejected SwiftPM's own sandbox/cache access before compilation, so the findings below are based on direct code and test inspection plus fixture validation.

| # | Severity | Location | Finding |
|---|---|---|---|
| 1 | major | `App/MobileSeal/Detail/MediaPageViewController.swift:107-109,246-259,398-405` | Live Photo motion creates a player without installing the capture cover, so recording/mirroring leaves the local motion visible. |
| 2 | major | `App/MobileSeal/Playback/PlaybackController.swift:124-134` | The generation token only prevents not-yet-started neighbor warms; already-started decrypt/cache work is neither tracked nor cancelled. |
| 3 | major | `App/MobileSeal/Import/ImportEngine.swift:194-198,219-231` | Ordinary-video imports return into `importVideo` before the post-stage low-disk check and accounting, allowing large videos to bypass the import safety policy. |
| 4 | major | `App/MobileSeal/Detail/MediaPageViewController.swift:141-155` | The replacement still viewer suppresses all read/integrity errors, regressing the damaged-item UX for photos. |
| 5 | major | `App/MobileSealTests/ChunkProfileBenchmarkTests.swift:187-199` | A repetition that never produces a pixel buffer is recorded as an approximately 30-second latency sample instead of failing the benchmark. |
| 6 | minor | `App/MobileSeal/Import/ImportEngine.swift:275-281; App/MobileSeal/Detail/MediaPageViewController.swift:232-244` | The required lazy duration backfill for pre-existing Live Photo paired videos is not implemented. |

## 1. Live Photo playback is not capture-shielded

Evidence: `viewDidLoad` calls `installVideoChrome()` only when `item.isVideo` (`MediaPageViewController.swift:107-109`), and that method is the only place that adds `captureCover` to the view hierarchy. A still with `livePhotoVideoID` nevertheless enters `playLivePhotoMotionOnce()` and then `attach(player:muted:looping:)`; `attach` merely attempts to bring the never-added cover to the front (`MediaPageViewController.swift:246-259`). Although `applyCaptureTruthTable()` includes Live Photos (`MediaPageViewController.swift:398-405`), changing `isHidden` on a view that is not in the hierarchy cannot obscure the player layer.

Why it matters: the goal requires recording and non-external mirroring to blank the local player surface. A Live Photo's streamed motion is an `AVPlayer` surface too, and this path displays decrypted motion during capture despite the stated privacy truth table.

Suggested fix: split capture-cover installation from ordinary-video controls and install the cover for every page that can play either an ordinary video or Live Photo motion. Add a test that lands on a Live Photo, drives the capture-state seam active with external playback inactive, and verifies the cover is present and visible.

## 2. Generation changes do not cancel in-flight neighbor warming

Evidence: `warmNeighbor` snapshots `prefetchGeneration`, starts an untracked `Task`, and checks the token only before `reader.readRange` (`PlaybackController.swift:124-134`). There is no after-read check despite the comment claiming one, no retained task to cancel from `activatePlayer`, `releasePlayer`, or `prepareForLock`, and no generation-aware cache admission. Once the read starts, it may continue decrypting and populate/evict entries after a later page has landed.

Why it matters: this does not satisfy the specified generation-token cancellation discipline. Fast swipes can leave obsolete 4 MiB reads competing with the landed item for I/O, decrypt work, and residency budget; the added UI test only samples player count and total cache bytes, so it cannot detect stale work that remains within the cap.

Suggested fix: retain neighbor-warm tasks by generation, cancel them whenever landing/release/lock increments the generation, and make the reader/cache miss path prevent a cancelled warm with no live waiter from being admitted after its fetch completes. Instrument completed/cancelled generations and assert in the fast-swipe test that no stale generation commits cache work.

## 3. Video imports bypass low-disk enforcement

Evidence: immediately after staging, `importOne` detects `.video` and returns from `importVideo` (`ImportEngine.swift:194-198`). The exact staged-size calculation, update of `observedItemBytes`, and `available < estimate * 2` refusal occur later only on the still path (`ImportEngine.swift:219-231`). `importVideo` contains no equivalent check.

Why it matters: video is the newly admitted and typically largest media type. A first-item video has no pre-stage estimate at all, and videos in later positions neither receive the exact post-stage check nor inform estimates for subsequent items. This can consume the remaining volume during sealing and fail partway through an import instead of honoring the existing 2x-free-space safety policy.

Suggested fix: compute and record `itemBytes` and perform the post-stage capacity check before branching by media role, so still and video primary paths share the same guard. Add a capacity-provider seam and a test with a video as the first item plus a mixed batch where a large video affects the next item's estimate.

## 4. Still integrity failures are silently discarded

Evidence: `decodeFullStill` converts `decryptWhole` failures to `nil` with `try?` and simply returns when decoding fails (`MediaPageViewController.swift:141-155`). Unlike the deleted `DetailView`, it never distinguishes `missingChunk`/`authenticationFailed`, calls `store.markDamaged`, or presents an explanatory failure. Because the thumbnail is a separate entry, a damaged original can continue showing its intact poster indefinitely.

Why it matters: replacing the detail viewer regresses an existing integrity guarantee: opening a photo with a missing or tampered original gives no indication that the full media could not be read and never places the damaged badge on the grid.

Suggested fix: preserve the typed result from the detached read, map integrity errors to `markDamaged(item.id)` plus the damaged-item state, map `vaultLocked` separately, and show an honest decode/size state for non-integrity failures. Restore focused tests for missing and authenticated-but-corrupt still reads through the new pager.

## 5. The benchmark accepts “no frame” as a latency measurement

Evidence: `coldSeekToFirstFrame` polls until either `hasNewPixelBuffer` succeeds or the 30-second deadline passes (`ChunkProfileBenchmarkTests.swift:187-192`), but it does not retain whether a frame was observed. Both paths calculate and return elapsed milliseconds (`ChunkProfileBenchmarkTests.swift:193-199`), and the only harness assertions verify sample counts.

Why it matters: a decode/loader failure can become a 30,000 ms sample. If multiple profiles fail similarly, the mechanical rule can report `keep-4MiB-default` because the measured improvement is near zero, falsely presenting a broken matrix as decision-grade seek data.

Suggested fix: track `presented = true` only when a new pixel buffer is observed and throw a descriptive timeout otherwise; assert every matrix cell has ten presented-frame samples before calculating percentiles or a decision.

## 6. Legacy Live Photo duration backfill is absent

Evidence: new paired-video metadata is written with only `parent` and `uti` (`ImportEngine.swift:275-281`), and opening a Live Photo directly activates its player without loading or storing any derived duration (`MediaPageViewController.swift:232-244`). Repository-wide duration handling only populates `durationSeconds` for ordinary `.video` imports; there is no lazy backfill path for v1 `.livePhotoVideo` records despite the schema comment and goal explicitly promising one.

Why it matters: the defined recovery behavior for already-imported Live Photos is missing, leaving legacy and newly paired videos permanently without the evolved duration metadata in memory.

Suggested fix: carry paired-video duration in the resolved item model, derive it through the streaming asset on first open when absent, and cache that value for the unlocked session (or define and implement a safe metadata rewrite if persistence is desired). Add a v1-metadata fixture proving first-open backfill.

REVIEW COMPLETE
