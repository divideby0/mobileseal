# Codex blind plan review — iOS Vault App Shell

## Blocking concerns

1. **The picker import path contradicts the plaintext-disk gate.** `GOAL.md §Workstream B.1` assumes picker output can flow directly through `Gallery`, but `Gallery.importFile` opens a seekable file and reads it twice, while `NSItemProvider.loadFileRepresentation` creates a plaintext temporary file; `importBytes` instead materializes the entire asset in ordinary memory. The plan must either extend VaultCore with a suitable public streaming/rewindable source, explicitly permit and securely clean staging files, or revise Green Gate 2. [Apple documents that file representations are copied to temporary files.](https://developer.apple.com/documentation/foundation/nsitemprovider)

2. **Thumbnail and metadata storage are not mapped onto the actual API.** `GOAL.md §Workstreams B.2/D.3` treats a separate encrypted cache and `SecureBytes` metadata as selectable app designs, but VaultCore exposes neither its DEK nor a cache-sealing API, and its metadata accessor returns `[UInt8]` backed by ordinary-heap inventory storage. If thumbnails become VaultCore entries, the plan also needs an entry-kind/link/version schema and recovery for the two independent original/thumbnail commits; WAL atomicity covers one import, not the pair.

3. **The lifecycle plan lacks a feasible owner for the move-only session.** `UnlockSession` is `~Copyable`, `lock()` consumes it and can block for 500 ms, and the compile-fail harness explicitly rejects capturing it in a concurrent `Task`; `GOAL.md §Workstream D.1` merely says to wire it to `scenePhase`. The plan needs an early feasibility spike defining the coordinator that owns and consumes the session, discards stale `Gallery`/reader handles, and prevents repeated SwiftUI construction from colliding with the process-wide writer claim.

4. **“Fed from inventory snapshots” is insufficient and risks stale reads.** `UnlockSession.snapshot()` and `UnlockSession.makeReader()` are frozen at unlock; only `Gallery.snapshotStream()` observes later commits, and a fresh `Gallery.makeReader()` is needed to read newly imported entries. `GOAL.md §Workstream C.1` must prescribe that flow, including snapshot-task cancellation on lock and reader replacement after every committed generation.

5. **Vault locking does not revoke app-owned plaintext.** `GOAL.md §Green gate 3` verifies only key lock and visual redaction, but decoded `UIImage`/`CGImage` pixels, copied `Data`, metadata arrays, prefetch operations, and UIKit caches can survive `UnlockSession.lock()`. `MAP.md §Tickets` also assigns the entire resident-plaintext budget to Streaming Playback even though this leg already needs bounded thumbnail/still caches and purge-on-lock behavior.

6. **Adaptive KDF calibration is not implementable as described.** `SealedVault.create` accepts KDF parameters, but VaultCore exposes no operation to rewrap an existing gallery at a higher memlimit; “raise memlimit” therefore only works before gallery creation unless this goal adds a new core API and transactional metadata update. `GOAL.md §Workstream D.2` also lacks a release-build protocol, peak-memory threshold, thermal-state rule, safe fallback, and definition of “measured headroom.”

7. **Background locking and import completion have no coherent policy.** A foreground import may still be downloading from iCloud, producing a temporary representation, running VaultCore’s two passes, or sitting between the original and thumbnail commits when the scene changes; `Gallery.importFile` itself is synchronous and not cancellation-aware. The plan must choose foreground-only cancellation and cleanup, or an explicit background-execution design that reconciles continued work with immediate DEK revocation and expiration handling. [Apple states background time is limited and expirable.](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app)

8. **The app-container contract is missing.** `CONTEXT.md §Gallery` says the app-shell leg introduces `galleries/{id}`, but `GOAL.md` never fixes the base directory, file-protection class, backup policy, or separation of vault data from transient picker material. A private vault should explicitly set and test the strongest compatible iOS Data Protection class rather than relying on the default “until first authentication” behavior. [Apple’s file-protection guidance](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)

9. **The green gates do not prove that an iOS app was built or that the UI target is usable.** `swift test` exercises the macOS package, not an iOS simulator/device build, Swift-Sodium XCFramework linkage, app unit tests, or UI tests; gates need explicit `xcodebuild` destinations for simulator and unsigned generic device builds. “N photos” and “Photos-equivalent” also have no dataset, memory ceiling, responsiveness target, scroll benchmark, or reproducible acceptance procedure.

10. **The executor references are incomplete and conceal a data-model requirement.** `GOAL.md` cites “spec §6/§10/§11,” but its local `references/intake.md` contains only a 30-line summary; the full referenced material is actually under `goals/CED-10-private-photo-vault/references/intake.md`. That upstream section requires an encrypted SwiftData index for date-sorted queries, while the plan proposes inventory snapshots that contain no dates or metadata and never resolves the discrepancy.

## Advisories

1. **Picker-only and PhotoKit modes need separate capability matrices.** PHPicker runs out of process and does not require direct Photo Library authorization, while PHPhotoLibrary requires purpose strings, authorization-state handling, and limited-library behavior; deletion and incremental observation cannot be treated as minor picker options. [PHPicker privacy model](https://developer.apple.com/videos/play/wwdc2020/10652/), [Photo Library usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription)

2. **Redaction and locking should not be conflated at `.inactive`.** A scene can become inactive for interruptions or system UI, whereas backgrounding precedes possible termination; the visual shield should appear immediately before snapshot capture, while the lock policy needs an explicit decision and test for transient inactivity. [Apple’s scene-phase semantics](https://developer.apple.com/documentation/swiftui/scenephase), [background snapshot sequence](https://developer.apple.com/documentation/uikit/about-the-background-execution-sequence)

3. **A compositional layout alone does not establish Photos-grade behavior.** `GOAL.md §Workstream C.1` should name diffable identifiers, prefetch/decrypt scheduling, cancellation on cell reuse, cache bounds, pinch-driven layout changes, and transition ownership across the SwiftUI/UIKit boundary. Apple’s collection-view guidance specifically requires cancelable prefetching for expensive image preparation. [UICollectionView prefetching](https://developer.apple.com/documentation/uikit/uicollectionviewdatasourceprefetching)

4. **The still-detail boundary needs tightening.** Full-resolution decoding, zooming, and large ProRAW memory behavior can silently absorb work that `MAP.md` assigns to Streaming Playback. Define this leg as a bounded still decoder/viewer with representative size and memory gates, leaving video/audio and playback-specific resident budgets to the next ticket.

5. **Any delete-original flow needs a post-commit safety protocol.** Deletion should occur only after the original entry and required thumbnail state are durable and authenticated through a fresh reader, with explicit user confirmation and partial-failure behavior. A successful `importFile` return alone does not prove the complete app-level asset transaction requested by this plan.

6. **System picker UI should not be the only automated import seam.** Simulator tests need a fixture-backed provider abstraction so success, cancellation, provider error, iCloud delay, and cleanup can be deterministic; a small manual picker smoke test can remain separate. Otherwise Green Gate 1 is a manual happy path disguised as an end-to-end test.

7. **The simulator limitation note is materially overstated.** `GOAL.md §Executor notes` says the simulator can exercise everything except signing and the benchmark, but it does not reproduce device Data Protection, jetsam headroom, `mlock` behavior, thermal throttling, real iCloud-backed Photos assets, or reliable app-switcher privacy behavior. Those need explicit device-only gates or documented residual risk.

8. **The Xcode project strategy is underspecified.** The plan should choose a checked-in project versus a generator, define schemes and test plans, and keep personal team/signing values outside shared project settings where practical. “Existing SwiftPM-rooted repo” is not enough for reproducible regeneration or command-line validation.

## Questions the plan leaves unanswered

1. **What exact runtime state machine owns `UnlockSession`, `Gallery`, the snapshot task, and readers?** It must define transitions for create, unlock, importing, inactive, locking, locked, unlock failure, and teardown without copying or asynchronously capturing the session.

2. **What does “auto-lock” mean beyond backgrounding?** The plan gives no inactivity duration, screen-lock behavior, transient-interruption policy, or rule for whether returning active requires a password every time.

3. **How should duplicate imports appear?** VaultCore deliberately creates a new logical entry while sharing chunks, so the app must decide whether duplicates are displayed separately, grouped, suppressed, or annotated.

4. **What happens when a second scene or stale coordinator receives `galleryAlreadyOpen`?** The plan does not say whether the app forbids multiple scenes, reuses a central writer, or falls back to a read-only UI.

5. **What are the batch-import semantics under partial failure?** There is no maximum batch size, ordering rule, retry model, low-disk response, or definition of whether successful items remain committed when a later provider item fails.

6. **Will password unlock be the only re-entry path?** The plan omits whether Face ID/Keychain-wrapped convenience unlock is intentionally excluded, deferred, or required for a daily-use shell.

7. **What is the backup and reinstall recovery policy?** The plan does not decide whether encrypted galleries participate in device/iCloud backup, are excluded as reproducible cache, or are irrecoverably lost on uninstall before the sync legs exist.

8. **How should integrity failures surface in the UI?** `missingChunk`, `authenticationFailed`, `noValidInventory`, and `dekUnwrapFailed` have materially different recovery implications, but the plan defines no user-facing states, retry policy, or preservation rule.
