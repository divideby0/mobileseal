# Verdict

The change establishes a substantial app shell and exercises much of the intended flow, but it is not ready to accept as implemented: the privacy shield and grace-lock transition can expose gallery content, app-owned plaintext is not completely purged on lock, the detail viewer's claimed memory bound does not bound the dominant allocations, and the required thumbnail-recovery path is never wired into normal unlock. The low-disk check also happens too late to be a preflight, while cell-reuse cancellation and benchmark recording fall short of their stated gates. I could not complete `swift test` or the unsigned Xcode build because this review environment rejects SwiftPM's nested `sandbox-exec` even after caches were redirected to `/tmp`; those were environmental failures and are not counted as findings.

| # | Severity | Location | Finding |
|---|---|---|---|
| 1 | major | `App/MobileSeal/VaultStore.swift:109` | Returning after an expired grace period removes the shield before the asynchronous lock starts, briefly exposing an unlocked gallery. |
| 2 | major | `App/MobileSeal/UI/SettingsView.swift:101`, `App/MobileSeal/MobileSealApp.swift:95` | The privacy shield is translucent and animated, so it does not guarantee redaction before the system snapshot. |
| 3 | major | `App/MobileSeal/VaultStore.swift:79`, `App/MobileSeal/Detail/DetailView.swift:56` | Lock does not purge all app-owned plaintext: import filenames remain retained and detached detail decoding can outlive lock. |
| 4 | major | `App/MobileSeal/VaultCoordinator.swift:349`, `App/MobileSeal/Detail/StillDecoder.swift:14` | The detail viewer's 64 MiB claim only bounds the decoded bitmap; it reads and copies the entire original first, leaving total memory unbounded. |
| 5 | major | `App/MobileSeal/VaultStore.swift:88`, `App/MobileSeal/VaultCoordinator.swift:275` | Missing-thumbnail regeneration and orphan reporting exist only as disconnected internals, so the required on-open recovery behavior never happens in the app. |
| 6 | minor | `App/MobileSeal/Grid/PhotoGridView.swift:215`, `App/MobileSeal/Grid/ThumbnailPipeline.swift:70` | Cell reuse cancels only the waiting UI task, not the underlying decrypt/decode task. |
| 7 | major | `App/MobileSeal/Import/ImportEngine.swift:161` | The low-disk "preflight" runs only after provider bytes have already been copied into staging. |
| 8 | minor | `App/MobileSeal/Support/KDFCalibrator.swift:35` | The calibration record omits the required peak-memory measurement. |

## 1. Grace return unshields before locking

Evidence: `VaultStore.sceneBecameActive()` detects an expired grace interval at `App/MobileSeal/VaultStore.swift:109-114`, but `lock()` merely launches an unstructured `Task` at `App/MobileSeal/VaultStore.swift:74-81`. The same method then immediately sets `shielded = false` at line 116. Until that task reaches `VaultCoordinator.lock()` and publishes `.locking` at `App/MobileSeal/VaultCoordinator.swift:405-406`, the store is still `.unlocked`, so `ContentView` renders `GalleryView` without a shield. The same race is possible after a quick immediate-policy background/foreground transition if suspension delays the scheduled lock task.

This matters because the grace policy promises that an app returning after the grace window is locked. Instead, sensitive thumbnails can be displayed during the exact foreground transition the policy is intended to protect.

Suggested fix: keep the shield raised while a required lock is in progress. Make the transition async (or track a synchronous `lockRequested` state), await cache purge and coordinator lock, and only lower the shield for a return that does not require locking. Do not call `noteInteraction()` on a return that is being locked.

## 2. The snapshot shield remains visually revealing

Evidence: `ShieldView` fills its screen with `.ultraThinMaterial` at `App/MobileSeal/UI/SettingsView.swift:101-104`; that material is intentionally translucent and preserves colors and shapes from the photos underneath. `ContentView` also applies `.animation(.default, value: store.shielded)` at `App/MobileSeal/MobileSealApp.swift:95`, so insertion of the conditional shield can fade rather than cover synchronously when `.inactive` arrives.

This matters because the goal requires a privacy shield before snapshot capture. A translucent, animated overlay can leave recognizable gallery content in the app-switcher snapshot even when the shield callback was invoked in time.

Suggested fix: use a fully opaque fill for the redaction surface and disable animation when raising it. If desired, animate only removal after the scene becomes active; insertion on `.inactive` should be immediate.

## 3. Purge-on-lock does not cover all app plaintext

Evidence: `VaultStore.lockAndPurge()` at `App/MobileSeal/VaultStore.swift:79-82` purges only `ThumbnailPipeline` before delegating to the coordinator. `lastImportSummary`, declared at line 24, is not cleared, even though every `ImportOutcome` retains the provider filename in `ImportOutcome.name` (`App/MobileSeal/Import/ImportEngine.swift:20-22`). Separately, detail loading starts a `Task.detached` at `App/MobileSeal/Detail/DetailView.swift:56-66`. Cancellation of the SwiftUI `.task` does not propagate to a detached task, and there is no cancellation handler or lock-owned registry for it. If decryption finishes just before the core drain, ImageIO decoding and the resulting `UIImage` can remain alive after the session reports locked.

This matters because Workstream D.3 requires purge-on-lock for app-side plaintext, including metadata and decoded images. A summary can retain private filenames across lock (and re-present after unlock), while a detached detail decode is explicitly outside the only purge mechanism.

Suggested fix: clear `lastImportSummary` and every other plaintext-bearing UI state as part of the synchronous lock request. Move detail work under a store/coordinator-owned task registry, cancel it on lock, and do not complete the locked transition until non-cancellable decoding work has finished and its results have been dropped. Also clear the detail image on cancellation/disappearance and reject results if the session generation changed.

## 4. Detail decoding is not memory-bounded

Evidence: `VaultCoordinator.decryptWhole()` at `App/MobileSeal/VaultCoordinator.swift:349-353` requests `Int(unpaddedLength)` from `ChunkReader.readRange` and then copies that secure buffer into a new `Data`. The reader itself allocates an output buffer of the full requested length (`Sources/VaultCore/ChunkReader.swift:96`). Only after those whole-file allocations does `StillDecoder` apply a 4096-pixel ImageIO bound at `App/MobileSeal/Detail/StillDecoder.swift:14-24`.

This matters because a large ProRAW/DNG or other original consumes roughly two full compressed-file buffers concurrently, plus ImageIO state and up to about 64 MiB of decoded pixels. The maximum source size is not bounded, so a large valid photo can cause memory pressure or jetsam despite the UI claiming an explicit ceiling.

Suggested fix: feed ImageIO from a bounded random-access/sequential data provider backed by chunk-sized `ChunkReader` reads, or add a genuinely enforced total-operation byte ceiling and fail gracefully above it. The ProRAW path should extract its embedded preview without first materializing the entire original in ordinary heap memory.

## 5. Recovery behavior is not connected to normal unlock

Evidence: snapshot ingestion computes and publishes `missingThumbnails` at `App/MobileSeal/VaultCoordinator.swift:275-284`, and `VaultStore.regenerateMissingThumbnails()` exists at `App/MobileSeal/VaultStore.swift:88-93`, but no production call site invokes that method. The recovery test manually calls `coordinator.regenerateThumbnail` (`App/MobileSealTests/ThumbnailRecoveryTests.swift:32-33`), so it does not test the goal's "on open" behavior. Likewise, `indexReport` is assigned at `App/MobileSeal/VaultStore.swift:166-175` but no view reads it, leaving orphan/undecodable counts invisible to the user.

This matters because a crash between the original and thumbnail commits permanently leaves a blank/no-preview item unless some external caller invokes dead API. Orphaned thumbnails are technically counted but not actually "reported" by the app.

Suggested fix: after the initial unlock snapshot is fully indexed, schedule one regeneration attempt per missing original and surface orphan/undecodable recovery status in the gallery. Avoid firing during the normal brief original-before-thumbnail import generation, for example by limiting automatic recovery to the initial snapshot or by debouncing until the writer is idle. Update the test to lock/relaunch/unlock and verify healing without manually calling the coordinator.

## 6. Cell-reuse cancellation does not reach decryption

Evidence: `PhotoCell.prepareForReuse()` at `App/MobileSeal/Grid/PhotoGridView.swift:215-220` cancels only its local `loadTask`. `ThumbnailPipeline.image(for:)` creates a separate unstructured task at `App/MobileSeal/Grid/ThumbnailPipeline.swift:70-87` and stores it in `inflight`; canceling a task awaiting `running.value` does not cancel `running`. The pipeline's `cancel(_:)` is called for collection-view prefetch cancellation, but never from cell reuse.

This matters because rapid scrolling leaves decrypt/decode jobs for reused off-screen cells running, populating the cache with images the user has already scrolled past and competing with visible-cell work. That misses the explicitly required cell-reuse cancellation seam and can distort the scroll-performance gate.

Suggested fix: have each cell retain its requested `FileID` and notify the pipeline on reuse, or redesign coalescing around cancellation-aware waiter counts so the underlying operation is canceled when its final consumer disappears. Add a test that blocks a decode, reuses the cell, and verifies the underlying operation is canceled rather than merely suppressing assignment.

## 7. Low-disk handling happens after staging

Evidence: `ImportEngine.importOne()` calls `provider.stageParts(into:)` at `App/MobileSeal/Import/ImportEngine.swift:161-174`. Only after the provider has copied the complete still and Live Photo video does it calculate sizes and query free capacity at lines 195-207.

This matters because the check cannot prevent the staging copy itself from exhausting storage. When space runs out during `copyItem`, the user receives a generic `.providerFailed` error instead of the required low-disk preflight, and large batches begin plaintext custody work that should have been refused up front.

Suggested fix: add an estimated-byte-count capability to the provider seam and perform the 2x batch-capacity check before `stageParts`. Retain an exact post-stage recheck to handle stale estimates and capacity races, mapping ENOSPC during staging to `.lowDiskSpace` rather than a photo-provider failure.

## 8. Calibration records free headroom, not peak memory

Evidence: `KDFCalibrator.Record` at `App/MobileSeal/Support/KDFCalibrator.swift:35-45` records medians, chosen parameters, thermal state, and `availableMemoryMiB`. The only memory probe is `os_proc_available_memory()` at lines 183-190, which captures available headroom before calibration; no field or measurement records peak resident memory during the median-of-five runs. Settings labels the value "Free memory at run" at `App/MobileSeal/UI/SettingsView.swift:69-71`.

This matters because Workstream D.4 explicitly requires peak memory to be recorded alongside the device calibration. Available system memory is useful for candidate gating but is not evidence of the KDF's actual peak footprint, so the device benchmark record is incomplete.

Suggested fix: measure and persist peak process footprint (or attach a repeatable Instruments/MetricKit measurement artifact keyed to the calibration run), add it to `Record` and Settings, and assert the field is present for release/device calibration while allowing an explicit simulator-unavailable value.

REVIEW COMPLETE
