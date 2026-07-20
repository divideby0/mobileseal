# Blind code review — CED-11 iOS Vault App Shell (claude-code, wave-001)

## Verdict

This is a strong, coherent leg. The architecture matches the goal
closely: `VaultCoordinator` really is the sole owner of the move-only
`UnlockSession` (actor-isolated storage plus `Optional.take()`, no task
closure captures it), the snapshot feed reads `Gallery.snapshotStream()`
with a fresh reader per generation as Codex B4 demanded, staging
lifecycle and the custody canary are genuinely tested, and the
error-mapping copy honors the "wrong password and tamper are
indistinguishable" requirement. I verified gate 1b independently:
`xcodebuild -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
build` → **BUILD SUCCEEDED**. The findings below are real defects rather
than architectural disagreement. Two of them undercut claims the goal's
green gates assert: a reentrancy race that can repopulate the decoded-image
cache *after* purge-on-lock (gate 5's custody claim), and gate 3's scroll
metrics being summed from cumulative counters, so the numbers destined for
RESULT.md are inflated. A third — the Codex B2 "missing thumbnail
regenerates on open" recovery rule — is implemented but never wired into
the running app. No blocker: nothing here corrupts a vault or leaks
plaintext to disk.

## Findings

| # | Severity | Location | Finding |
|---|----------|----------|---------|
| 1 | major | `App/MobileSeal/Grid/ThumbnailPipeline.swift:89` | Decoded plaintext can be inserted into the cache *after* `purge()`, defeating the purge-on-lock custody claim |
| 2 | major | `App/MobileSeal/VaultStore.swift:88` | `regenerateMissingThumbnails()` is never called — the B2 recovery rule is dead code in the app |
| 3 | major | `App/MobileSealUITests/GridScrollPerfUITests.swift:74` | Gate 3 sums cumulative counters, inflating `frames`/`hitches` — the recorded perf numbers are wrong |
| 4 | major | `App/MobileSeal/VaultStore.swift:120` | Lock-on-background takes no `beginBackgroundTask` assertion; iOS may suspend the process before the session is consumed |
| 5 | minor | `App/MobileSeal/VaultStore.swift:103` | Grace-period return drops the shield before the async lock lands — unlocked grid is briefly visible |
| 6 | minor | `App/MobileSeal/Support/KDFCalibrator.swift:132` | `realMedianOf5` ignores the caller's `scratchDir`; the throwaway vault lands in `tmp`, outside the prepared container |
| 7 | minor | `project.yml:38` | UI-test seams and 110 fixture images ship in the Release bundle |
| 8 | minor | `App/MobileSeal/Grid/ThumbnailPipeline.swift:114` | `insert` double-counts `cacheCost` on re-insert, drifting the LRU ceiling downward |
| 9 | minor | `App/MobileSeal/MediaIndex.swift:103` | Thumbnails with a missing/unparseable `parent` are silently dropped — neither shown nor reported |
| 10 | minor | `App/MobileSeal/VaultCoordinator.swift:291` | Dedup hash set is read from an index the snapshot feed fills asynchronously — duplicates slip through right after unlock |
| 11 | minor | `App/MobileSealTests/ScenePhaseLockTests.swift:103` | `gracePolicyLocksOnlyAfterWindowOnReturn` never exercises the lock-after-window branch it names |
| 12 | nit | `App/MobileSeal/Grid/PhotoGridView.swift:154` | Display link leaks when a drag ends without deceleration |
| 13 | nit | `App/MobileSeal/VaultStore.swift:75` | Debug `NSLog` tracing left on production lock/scene paths |

---

### 1. Decoded plaintext can re-enter the cache after purge-on-lock (major)

**Evidence** — `App/MobileSeal/Grid/ThumbnailPipeline.swift:88-94`:

```swift
inflight[key] = task
let image = await task.value      // ← suspension point
inflight[key] = nil
if let image {
    insert(image, for: key)
}
```

`ThumbnailPipeline` is an actor, so `await task.value` is a reentrancy
point. `purge()` (`:43`) can run during that suspension — it cancels
in-flight tasks, empties `cache`/`cacheOrder`/`cacheCost` and nils the
reader. When the suspended `image(for:)` resumes, it unconditionally
executes `insert(image, for: key)`, putting a decrypted `UIImage` back
into the just-emptied cache.

The cancellation inside the task body is not a defense: `Task.isCancelled`
is checked only between `decryptWhole` and `decode` (`:74`). A task that
had already produced its image before `purge()` returns that image
normally.

**Why it matters** — GOAL WS D.3 and gate 5 claim decoded caches are
"bounded and emptied on lock." The realistic trigger is exactly the case
the gate is meant to cover: the user backgrounds the app while the grid
is mid-scroll with decodes in flight. `ScenePhaseLockTests.backgroundImmediatePolicyLocksAndPurgesEverything`
(`ScenePhaseLockTests.swift:65`) does not catch it because `makeWarmStore`
awaits `image(for:)` to completion *before* locking, so nothing is ever
in flight at lock time.

**Suggested fix** — make the insert generation-aware. The reader already
serves as the generation token:

```swift
let image = await task.value
inflight[key] = nil
// A purge (lock) during the await dropped the reader — this decode
// belongs to a dead generation and must not repopulate the cache.
guard reader != nil, !Task.isCancelled else { return nil }
if let image { insert(image, for: key) }
return image
```

Add a regression test that starts a decode, locks while it is in flight,
and asserts `debugCacheIsEmpty`.

---

### 2. The missing-thumbnail recovery rule is never triggered (major)

**Evidence** — `App/MobileSeal/VaultStore.swift:88-94` defines
`regenerateMissingThumbnails()`, and `VaultCoordinator.regenerateThumbnail(for:)`
(`VaultCoordinator.swift:323`) implements the regeneration. Neither is
called from any non-test code:

```
$ grep -rn "regenerateMissingThumbnails" App/
App/MobileSeal/VaultStore.swift:88:    func regenerateMissingThumbnails() {
```

`ThumbnailRecoveryTests.swift:32` even carries the comment "Regenerate
(the store triggers this from the report)" immediately before calling
`vault.coordinator.regenerateThumbnail(...)` directly — the test asserts
a wiring that does not exist.

**Why it matters** — GOAL WS B.3 states "on open, a missing thumbnail
regenerates," and Codex B2 makes the crash-window-between-two-commits
case the motivating scenario. In the shipped app, an original committed
without its thumbnail keeps a permanent "no preview" badge
(`PhotoGridView.swift:229`); nothing ever heals it. The unit test passes
while the user-visible behavior the gate describes is absent.

**Suggested fix** — call it from the sink once the index reports missing
thumbnails, guarded against re-entry so a persistently undecodable
original does not retry every generation:

```swift
func itemsChanged(_ items: [MediaItem], report: IndexReport) {
    // …existing damage-flag merge…
    if report.missingThumbnails > 0 { regenerateMissingThumbnails() }
}
```

and track already-attempted IDs in the store so the pass is idempotent.
Then extend `ThumbnailRecoveryTests` to drive the store rather than the
coordinator, so the wiring itself is covered.

---

### 3. Gate 3's scroll metrics are summed from cumulative counters (major)

**Evidence** — `PhotoGridView.swift:135-178`: `frameCount`, `hitchCount`
and `maxGapMs` are `Coordinator` instance properties. `scrollViewWillBeginDragging`
(`:144`) resets only `lastFrameTimestamp`; the three counters are never
reset. `scrollViewDidEndDecelerating` (`:162`) publishes their running
totals into `accessibilityValue`.

`GridScrollPerfUITests.swift:74-83` then does:

```swift
for _ in 0..<6 {
    grid.swipeUp(velocity: .fast)
    Thread.sleep(forTimeInterval: 1.5)
    if let report = grid.value as? String {
        let metrics = Self.parse(report)
        totalFrames += metrics.frames      // ← already includes scrolls 1..n-1
        totalHitches += metrics.hitches
    }
}
```

Reading N is the cumulative total through scroll N, so the sum over six
scrolls is a sum of prefixes — roughly 3.5× the true frame count.

**Why it matters** — gate 3 requires "hitch/dropped-frame metrics
recorded and thresholds stated in the test," and the `PERF-REPORT` line
(`:96`) is explicitly the number transcribed into RESULT.md. `hitchRatio`
survives by luck (numerator and denominator inflate together), but
`totalFrames`, `totalHitches` and the recorded report are wrong, and
`worstGap` is a max-of-maxes that can only ever equal the first scroll's
running max onward. The gate reports a number it does not measure.

**Suggested fix** — reset the counters in `scrollViewWillBeginDragging`
alongside `lastFrameTimestamp`:

```swift
lastFrameTimestamp = 0
frameCount = 0
hitchCount = 0
maxGapMs = 0
```

so each published value describes exactly one scroll interval, which is
what the test's summation assumes.

---

### 4. Lock-on-background has no background-task assertion (major)

**Evidence** — `VaultStore.swift:120-130` → `lock()` (`:74`) → `Task { await lockAndPurge() }`.
`lockAndPurge` awaits `thumbnails.purge()` and then `coordinator.lock()`,
which itself consumes the session and may block up to 500 ms draining
readers. No `UIApplication.beginBackgroundTask` assertion is taken
anywhere in the target:

```
$ grep -rn "beginBackgroundTask\|BGTask" App/
NO BACKGROUND TASK ASSERTION
```

**Why it matters** — the strict default (GOAL WS D.2) is "immediate lock
on `.background`," and the whole point is that key material does not
survive in a backgrounded process. iOS may suspend the process shortly
after `scenePhase` reaches `.background`; a detached `Task` that has not
yet run — or that is mid-drain — is simply frozen, leaving the unlocked
`UnlockSession` and its DEK resident in the suspended process's memory
until it is resumed or jetsammed. The unit test cannot see this because
`ScenePhaseLockTests` never suspends anything.

**Suggested fix** — wrap the lock path in a background-task assertion so
the drain is allowed to finish:

```swift
func sceneEnteredBackground() {
    shielded = true
    backgroundedAt = Date()
    guard lockPreferences.backgroundPolicy == .immediate else { return }
    let id = UIApplication.shared.beginBackgroundTask(withName: "vault-lock")
    Task {
        await lockAndPurge()
        UIApplication.shared.endBackgroundTask(id)
    }
}
```

If that is deliberately deferred, the residual belongs in RESULT.md
alongside the other device-only gaps (Codex A7) rather than being left
implicit.

---

### 5. Grace-period return drops the shield before the lock lands (minor)

**Evidence** — `VaultStore.swift:103-118`:

```swift
if let away = backgroundedAt, lockPreferences.backgroundPolicy == .grace,
   Date().timeIntervalSince(away) > LockPreferences.gracePeriod {
    lock()            // async, fire-and-forget
}
backgroundedAt = nil
shielded = false      // ← shield down immediately
```

`lock()` enqueues a `Task`; `phase` stays `.unlocked` until the
coordinator processes it. `ContentView` (`MobileSealApp.swift:73-94`)
renders `GalleryView` for `.unlocked` and drops `ShieldView` as soon as
`shielded` is false.

**Why it matters** — on the exact path where the user's preference says
"this session is over, lock it," the decrypted grid is rendered
unshielded for the duration of at least one actor hop plus the drain.
It is a short window, but it is the one moment the policy exists to
prevent.

**Suggested fix** — keep the shield up when a lock is pending:

```swift
let locking = /* the grace-window condition */
backgroundedAt = nil
shielded = locking          // stays up until phase reaches .locked
if locking { lock() }
```

and lower it in `phaseChanged` when the phase settles.

---

### 6. Calibration ignores the scratch directory it is handed (minor)

**Evidence** — `VaultCoordinator.createGallery` (`VaultCoordinator.swift:159-163`)
builds `container.stagingDir/calibration-<uuid>` and passes it as
`scratchDir`. `KDFCalibrator.calibrate` accepts it and sets up
`defer { try? FileManager.default.removeItem(at: scratchDir) }` (`:68`) —
but `realMedianOf5` (`:132-135`) never uses it:

```swift
let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("kdf-cal-\(UUID().uuidString)", isDirectory: true)
```

So the passed path is never created, the `defer` removes nothing, and the
throwaway calibration vault is written to the app's `tmp` directory.

**Why it matters** — WS A.3 makes the container layout a contract, and
`AppContainer.applyProtection` deliberately classes the staging tree
`.completeUnlessOpen`. The calibration vault holds a real Argon2id
keyring (no user data, so this is not a plaintext leak), but it escapes
the Data-Protection-classed container and the launch-time
`wipeStaging()` sweep — a crash mid-calibration strands it in `tmp`
under whatever default class applies. The dead parameter also reads as
though the seam works when it does not.

**Suggested fix** — have `realMedianOf5` take and use the scratch
directory:

```swift
static func realMedianOf5(_ params: KDFParams, scratchDir: URL) throws -> TimeInterval {
    let dir = scratchDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    …
}
```

threading it through the `measure` seam (the injected test doubles
already ignore their argument, so they are unaffected).

---

### 7. UI-test seams and fixtures ship in Release (minor)

**Evidence** — `UITestSupport.isUITestMode` (`UITestSupport.swift:11`) is a
runtime launch-argument check with no `#if DEBUG` guard, and `project.yml:36-39`
adds `App/Fixtures` to the **app target's** resources unconditionally
(`configFiles` maps both Debug and Release to the same xcconfig). The
seams it gates are user-visible controls: `Import Fixtures` and
`Seed 500` toolbar buttons plus the raw item-count readout
(`GalleryView.swift:46-93`), and `VaultCoordinator.init` (`:118`) swaps in
1-op/16 MiB KDF params under the same flag.

**Why it matters** — ~1 MiB of test images ride every shipped build, and
a release binary launched with `-mobileseal-uitest` exposes a vault-seeding
path and a deliberately weakened KDF. Passing launch arguments to an
installed App Store app is not casually reachable, so this is a hygiene
and binary-size issue rather than an exploitable one — but the KDF
downgrade in particular is the kind of seam that should be impossible to
reach in a shipping build, not merely inconvenient.

**Suggested fix** — gate the whole enum on `#if DEBUG` (returning `false`
in release), and move the fixtures to the test targets only. The UI test
bundle can inject them into the app via a launch environment path, or the
app target can carry them under a Debug-only build phase.

---

### 8. `cacheCost` double-counts on re-insert (minor)

**Evidence** — `ThumbnailPipeline.swift:114-126`:

```swift
private func insert(_ image: UIImage, for key: FileID) {
    let cost = Self.cost(of: image)
    cache[key] = image          // may overwrite an existing entry
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
    cacheCost += cost           // old entry's cost never subtracted
```

**Why it matters** — `cacheOrder` is de-duplicated but `cacheCost` is
not, so any re-insert of a live key permanently inflates the accounted
cost. The eviction loop then evicts against a phantom total, shrinking
the effective 64 MiB ceiling over a long session and causing needless
re-decrypt/re-decode work during scrolling — the exact cost gate 3
measures. Reachable via the finding-1 race and via `prefetch` racing a
cell load.

**Suggested fix**:

```swift
if let existing = cache[key] { cacheCost -= Self.cost(of: existing) }
cache[key] = image
cacheCost += cost
```

---

### 9. Unparented thumbnails are silently dropped, not reported (minor)

**Evidence** — `MediaIndex.resolvedItems` (`MediaIndex.swift:101-104`):

```swift
for (id, meta) in records where live.contains(id) {
    guard let parent = meta.parentFileID else { continue }
```

A `.thumbnail` or `.livePhotoVideo` record whose `parent` is nil, or
whose stored string does not parse as a UUID (`MediaMetadata.parentFileID`,
`MediaMetadata.swift:70-73`), is skipped before the orphan classification
below it. It is not displayed (correct), not counted in
`orphanThumbnails`, and not counted in `undecodable` (the blob decoded
fine).

**Why it matters** — Codex B2's rule is "an orphaned thumbnail (parent
gone) is ignored **and reported**," and `IndexReport` is the reporting
surface. A link record with a corrupted or absent parent field is the
most orphaned an entry can be, yet it is the one case that vanishes from
every counter — the entry occupies vault space that nothing will ever
account for.

**Suggested fix** — classify the guard's failure branch instead of
`continue`-ing past it:

```swift
guard let parent = meta.parentFileID else {
    if meta.kind != .original { orphans.insert(id) }
    continue
}
```

---

### 10. Dedup reads an index the snapshot feed fills asynchronously (minor)

**Evidence** — `VaultCoordinator.startImport` (`:291`) captures
`index.originalContentHashes()` at batch start. `index` is populated by
`ingest` (`:260-285`), driven by the `snapshotStream()` task started in
`adoptUnlocked` (`:229`). Nothing sequences unlock-time index population
before the first import.

**Why it matters** — grill Q5 promises duplicates are skipped with a
notice. On a large gallery, an import started promptly after unlock — or
after a lock/unlock cycle, since `adoptUnlocked` resets `index = MediaIndex()`
(`:226`) — sees a partially built hash set and re-imports already-present
photos as fresh entries. VaultCore's own dedup is not consulted (by
design, per the comment at `ImportEngine.swift:180-184`), so nothing else
catches it. `duplicateImportSkipsWithNotice` does not surface this: it
awaits the first summary, by which point the feed has caught up.

**Suggested fix** — either gate `startImport` on the index having ingested
the current snapshot's originals (a `latestSnapshot`-vs-`records`
completeness check), or surface the state to the UI so the import can
report "duplicate detection unavailable — index still loading" rather
than silently degrading.

---

### 11. The grace-period test does not test the grace period (minor)

**Evidence** — `ScenePhaseLockTests.swift:103-119`. The test is named
`gracePolicyLocksOnlyAfterWindowOnReturn` but only drives the
short-absence path (`sceneEnteredBackground` → immediate
`sceneBecameActive`) and asserts no lock occurred. The
`Date().timeIntervalSince(away) > LockPreferences.gracePeriod` branch at
`VaultStore.swift:109-113` — the half that actually locks — is never
executed.

**Why it matters** — gate 5 covers lock behavior, and `.grace` is one of
three user-selectable policies. Its locking half is currently unverified;
finding 5 lives in exactly that untested branch.

**Suggested fix** — make the window injectable rather than a
`static let` (`LockPreferences.swift:26`) — e.g. an instance
`gracePeriod` on `LockPreferences` defaulting to 30 — so the test can set
it to 50 ms, background, wait, return, and assert `.locked`.

---

### 12. Display link leaks when a drag ends without deceleration (nit)

**Evidence** — `PhotoGridView.swift:144-165`. The link is created in
`scrollViewWillBeginDragging` and invalidated only in
`scrollViewDidEndDecelerating`. A drag released without velocity fires
`scrollViewDidEndDragging(_:willDecelerate: false)` instead, which is not
implemented — so the link keeps firing at display rate, and the
`displayLink == nil` guard blocks instrumentation from restarting on the
next scroll.

**Suggested fix** — implement
`scrollViewDidEndDragging(_:willDecelerate:)` and tear down when
`!decelerate`, sharing one `finishInstrumenting(scrollView)` helper with
`scrollViewDidEndDecelerating`. UI-test-mode-only, so the cost is
confined to gate 3 runs — but it makes those runs' later scrolls report
nothing.

---

### 13. Debug `NSLog` tracing on production paths (nit)

**Evidence** — `VaultStore.swift:75`, `:99`, `:121`, `:148`
(`MOBILESEAL-LOCK`, `MOBILESEAL-SCENE`). These log lock and scene-phase
transitions unconditionally, in release builds, to the system log.

**Why it matters** — no secrets are logged (the policy rawValue and the
idle timeout are the most sensitive fields), so this is hygiene rather
than a leak. Still, a privacy-focused vault app writing a
device-log-readable trace of when its vault locks and unlocks is a
behavioral fingerprint worth not shipping.

**Suggested fix** — move to `Logger(subsystem:category:)` with
`.debug`-level, privacy-annotated messages — the target already imports
`OSLog` in `PhotoGridView.swift` for signposts — or drop the calls now
that the tests they helped debug are green.

REVIEW COMPLETE
