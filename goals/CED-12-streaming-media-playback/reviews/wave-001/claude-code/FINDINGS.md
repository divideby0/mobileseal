# Blind review — CED-12 streaming media playback (claude-code)

## Verdict

This is a strong, unusually well-specified change: the VaultCore seam
(`SealedChunkProvider` / `StreamingReader` / `ResidentChunkCache`) is
carefully reasoned about custody, the address check genuinely sits at
the seam, AEAD/padding verification stayed on the plaintext plane, the
loader-delegate request registry implements the exactly-once discipline
it claims, and the lock ordering (fail requests → release players →
purge cache → custodian drain) is real code with real assertions
behind it. I verified `swift test` green (73 tests, 17 suites) and a
clean simulator build of the app target; `DetailView` is removed with
no dangling references. No blockers. What I do find are four `major`
issues, all in the app/playback and gate layers rather than in the
crypto core: the capture-shield truth table is not applied to Live
Photo motion pages at all (the cover view is never installed on those
pages); the damaged-vs-unsupported classification reads the wrong
delegate when a failure probe resolves after a swipe, which can stamp a
false damaged badge on a healthy item; the benchmark records its 30 s
timeout as a legitimate sample, so gate 5's decision-grade numbers can
silently encode "no frame ever presented"; and prefetch generation
tokens are only checked *before* a warm read, so no stale work is
actually cancelled — while gate 4's UI assertion that would catch it is
tautological by construction. None of these threaten vault
confidentiality at rest; they are correctness and gate-integrity
issues.

## Findings

| # | Severity | Location | Finding |
|---|----------|----------|---------|
| 1 | major | `App/MobileSeal/Detail/MediaPageViewController.swift:107` | Capture-shield cover is never installed on Live Photo pages, so motion video plays unblanked during screen recording |
| 2 | major | `App/MobileSeal/Playback/PlaybackController.swift:99` | `activeItemSawIntegrityFailure` reads `delegates.last`, not the failing page's delegate — misclassifies damaged vs unsupported and can falsely mark a healthy item damaged |
| 3 | major | `App/MobileSealTests/ChunkProfileBenchmarkTests.swift:183` | Cold-seek measurement returns the 30 s timeout as a sample instead of failing — the predeclared decision rule can run on non-measurements |
| 4 | major | `App/MobileSeal/Playback/PlaybackController.swift:124` | `warmNeighbor` checks the generation token only before the read; stale prefetch is never cancelled, contradicting the comment and gate 4's stated observable |
| 5 | minor | `App/MobileSealUITests/PlaybackPagerUITests.swift:103` | Gate 4's `players <= 1` and `cacheBytes <= budget` assertions cannot fail by construction |
| 6 | minor | `App/MobileSeal/Playback/VaultResourceLoaderDelegate.swift:174` | Narrow race: `respond(with:)` can land on a request `failAllRequests` already finished |
| 7 | minor | `App/MobileSeal/MediaIndex.swift:285` | Codex Q7's lazy duration backfill for pre-CED-12 paired Live-Photo videos is documented but not implemented |
| 8 | minor | `App/MobileSeal/Playback/PlaybackController.swift:133` | Neighbor warming materialises 4 MiB of plaintext `Data` outside the residency budget only to discard it |
| 9 | nit | `App/MobileSeal/VaultCoordinator.swift:551` | On-disk chunk-tamper primitive is compiled into Release builds (unreachable, but present) |
| 10 | nit | `App/MobileSeal/Detail/MediaPageViewController.swift:261` | `item` shadowing in `attach(player:muted:looping:)` makes the later `item.isVideo` check hard to read |

---

### 1 — Live Photo motion plays unshielded under screen recording (major)

**Evidence.** `MediaPageViewController.viewDidLoad` installs the video
chrome only for ordinary videos:

- `App/MobileSeal/Detail/MediaPageViewController.swift:107` —
  `if item.isVideo { installVideoChrome() }`
- `captureCover` is configured and added to the hierarchy *only* inside
  `installVideoChrome()` (`:176`–`:187`).
- `applyCaptureTruthTable()` (`:398`) explicitly admits Live Photo
  pages: `guard item.isVideo || item.livePhotoVideoID != nil`, then
  sets `captureCover.isHidden = false` — on a view that has no
  superview, no background colour and no frame constraints.
- `playLivePhotoMotionOnce()` (`:235`) creates a real `AVPlayer` +
  `AVPlayerLayer` for the paired video on exactly those pages.
- I grepped the whole app target: `sceneCaptureState` / `captureCover`
  appear nowhere else, so there is no global shield to fall back on.

**Why it matters.** The truth table is a stated deliverable (GOAL WS
C.4, and the CONTEXT.md "external-playback exemption" entry): scene
capture active + no external playback must blank the *player surface*.
Live Photo motion is a player surface streaming decrypted vault
plaintext. Today, recording or mirroring the screen captures it with no
cover and no fallback. The gap is invisible in tests because no test
exercises the Live Photo page under capture.

**Suggested fix.** Split the chrome installation: install
`captureCover` (and register the trait observer) for any page that can
ever attach a player — `item.isVideo || item.livePhotoVideoID != nil` —
and keep only the mute button and scrubber behind `item.isVideo`. Add a
regression test that calls `applyCaptureTruthTable()` on a Live-Photo
page and asserts `captureCover.superview != nil` and
`isHidden == false`.

### 2 — Integrity classification reads the wrong delegate (major)

**Evidence.**

- `PlaybackController.swift:99` —
  `var activeItemSawIntegrityFailure: Bool { delegates.last?.sawIntegrityFailure ?? false }`
- `MediaPageViewController.showPlaybackFailure()` (`:374`) is the sole
  consumer and branches on it to choose between the damaged-item state
  (plus `store.markDamaged(item.id)`) and "can't play this format".
- The two triggers for `showPlaybackFailure` are both asynchronous and
  unbounded in time: the `\.status` KVO observation (`:262`) and the
  `asset.load(.isPlayable)` probe (`:274`), the latter itself an
  `await` on a streamed asset.
- Meanwhile `MediaPagerViewController.landed(on:)` (`:139`) →
  `activatePlayer` (`PlaybackController.swift:73`) appends the new
  delegate and calls `pruneInactiveDelegates(keeping:)`, so
  `delegates.last` becomes the *newly landed* item's delegate.

**Failure scenario.** Page A holds the unsupported-codec fixture; page
B holds the tampered video. The user opens A, swipes to B before A's
`isPlayable` probe resolves. `delegates` is now `[B]`. A's probe
resolves, `showPlaybackFailure()` reads B's `sawIntegrityFailure ==
true`, and the app calls `store.markDamaged(A.id)` — a permanent
damaged badge on an undamaged item, and A never shows its
"can't play this format" state. The mirror case (A tampered, B clean)
loses the damaged badge entirely, which is the exact distinction gate 2
exists to prove.

**Suggested fix.** Key the query by file: give `PlaybackController` a
`func sawIntegrityFailure(for fileID: FileID) -> Bool` backed by a
`[FileID: VaultResourceLoaderDelegate]` (or have the page hold a weak
reference to the delegate it was activated with) and have
`showPlaybackFailure` pass `item.id`. Bonus: gate the whole handler on
`store.playback.activeItemID == item.id` so a page that is no longer
landed cannot mutate shared item state at all.

### 3 — The benchmark records timeouts as measurements (major)

**Evidence.** `ChunkProfileBenchmarkTests.coldSeekToFirstFrame`
(`App/MobileSealTests/ChunkProfileBenchmarkTests.swift:164`–`:200`):

```swift
let deadline = start.advanced(by: .seconds(30))
while ContinuousClock.now < deadline {
    let t = output.itemTime(forHostTime: CACurrentMediaTime())
    if output.hasNewPixelBuffer(forItemTime: t) { break }
    try await Task.sleep(for: .milliseconds(2))
}
let elapsed = start.duration(to: ContinuousClock.now)
```

The loop exits identically whether a pixel buffer arrived or the
deadline expired; the caller appends `ms` unconditionally
(`:121`), and the only assertions at the end (`:157`–`:160`) count
samples, not validity.

**Why it matters.** This is the leg's decision-grade instrument: WS D.2
predeclares a rule keyed on p90 seek-to-first-frame, and gate 5 records
its output in RESULT.md. If any repetition fails to present a frame —
an unsupported profile, a loader bug, a simulator hiccup — it enters
the distribution as a ~30000 ms sample. Ten reps per video means a
single timeout can move p90 for that video's whole set, and because the
rule is `p90_4MiB > 400 && improvement > 25%`, a timeout in the 4 MiB
arm can flip the decision toward adopting 2 MiB for reasons that have
nothing to do with chunk size. A benchmark that cannot distinguish
"slow" from "never" is not decision-grade.

**Suggested fix.** Return an optional / throw on deadline expiry, and
have the caller fail the test (or at minimum record and print a
per-profile timeout count and exclude those samples, asserting the
count is zero before applying the rule).

### 4 — Prefetch generation tokens never cancel anything (major)

**Evidence.** `PlaybackController.warmNeighbor` (`:124`):

```swift
Task { [weak self] in
    // Stale-token check before AND after the read: a fast
    // swipe invalidates warm work rather than letting it
    // fight the landed item for budget.
    guard let self, await self.prefetchGeneration == token else { return }
    _ = try? await reader.readRange(fileID: fileID, offset: 0, length: length)
}
```

The comment describes a check before *and* after; the code has only the
before check. The `Task` handle is discarded, so nothing can cancel it,
and `readRange`'s internal `Task.checkCancellation()`
(`Sources/VaultCore/StreamingReader.swift:83`) is therefore never
reachable for warm work. A fast swipe through five videos launches five
warm reads that all run to completion, each pulling up to 4 MiB through
the provider and decrypting it into the shared cache, competing for
budget with the landed item's loader requests.

**Why it matters.** GOAL WS C.2 and green gate 4 both name generation
tokens *cancelling stale work* as the observable. As written, the token
only prevents work that has not started yet within the same turn of the
main actor — in practice almost never, since `warmNeighbor` bumps
nothing and `landed()` bumps the generation only via
`releasePlayer`/`activatePlayer`. Combined with finding 5, the gate
cannot detect this.

**Suggested fix.** Retain the warm tasks (`var warmTasks: [Task<Void,
Never>]` or keyed by `FileID`), cancel them in `releasePlayer()` and at
the top of `activatePlayer`/`prepareForLock`, and re-check
`prefetchGeneration == token` after the read before treating the result
as useful. Then assert in the UI gate that a stale warm read is
observably abandoned (e.g. a `warmCancelled` counter surfaced in the
debug overlay).

### 5 — Gate 4's core assertions are tautologies (minor)

**Evidence.** The overlay derives its player count from a single
optional (`MediaPagerViewController.swift:102`):

```swift
let players = self.store.playback.player == nil ? 0 : 1
```

`PlaybackController.player` is one `AVPlayer?`, so `players` is 0 or 1
by construction and
`XCTAssertLessThanOrEqual(worstPlayers, 1, "one-active-player violated")`
(`PlaybackPagerUITests.swift:103`) can never fail. Likewise
`cacheBytes > budget` (`:98`) is prevented internally by
`ResidentChunkCache.makeRoom`/`evictToBudget`, so
`XCTAssertFalse(worstOverBudget, …)` restates a cache invariant that
already has direct unit coverage rather than testing pager behaviour.

**Why it matters.** Gate 4 is the only automated check on prefetch
discipline, and as written it would stay green under exactly the bug in
finding 4. The `activated` and `drained` assertions later in the same
test are meaningful; these two are not.

**Suggested fix.** Instrument what can actually vary: count *player
items created* (a monotonic counter bumped in `activatePlayer`) and
assert it does not exceed the number of settled landings across the
swipe burst; count in-flight warm tasks and assert they drop to zero
after the burst; report peak `residentBytes` and assert it stays below
a threshold well under the budget rather than at it.

### 6 — `respond(with:)` can race the lock sweep (minor)

**Evidence.** `VaultResourceLoaderDelegate.serve` (`:161`–`:186`)
checks `Task.isCancelled` immediately after the read (`:174`) and then
calls `dataRequest.respond(with: data)` (`:175`). `failAllRequests`
(`:238`) removes the entry, cancels the task, and then calls
`entry.request.finishLoading(with:)` from another thread. If the sweep
lands in the window between the post-await cancellation check and
`respond`, the delegate responds to a request that has already been
finished — documented AVFoundation misuse.

**Why it matters.** Lock-during-playback is a first-class scenario here
(gate 3 exercises it), so the window is reachable in exactly the
situation the code cares most about. The blast radius is an
AVFoundation-side assertion rather than a custody leak — the data has
already left the cache — which is why this is minor rather than major.

**Suggested fix.** Hold the registry lock across the "is this request
still ours?" check and the `respond` call, e.g. a
`func respondIfLive(_ req:, _ data:) -> Bool` that takes `lock`,
verifies `registry[key] != nil`, responds, and returns whether it did;
`serve` bails out when it returns false. `finishLoading` in
`failAllRequests` already happens after registry removal, so the two
become mutually exclusive.

### 7 — Q7 duration backfill is documented but absent (minor)

**Evidence.** `MediaMetadata.swift:415`–`:423` and
`MediaIndex.swift:283`–`:285` both describe the Codex Q7 disposition —
"already-imported Live-Photo paired videos backfill duration LAZILY in
memory on first open" — and GOAL WS B.3 lists it as the defined
recovery for the v1→v2 schema evolution. Grepping the app target,
`durationSeconds` is only ever *written* at import
(`ImportEngine.swift:353`) and *read* for the grid badge
(`PhotoGridView.swift:318`). There is no open-time derivation path.

**Why it matters.** It is a spec/implementation mismatch in a place
where the comments assert the behaviour exists, which is worse than an
acknowledged gap — a future reader will trust the comment. Practical
impact is small today, since paired Live-Photo videos are not top-level
grid items and so never show the badge.

**Suggested fix.** Either implement it (derive duration from the
streamed asset when a Live Photo page first attaches its player, and
cache it in the in-memory `MediaItem`) or downgrade both comments to
state plainly that pre-CED-12 paired videos carry no duration and that
nothing consumes it yet.

### 8 — Warm reads leak plaintext into the residual class (minor)

**Evidence.** `PlaybackController.warmNeighbor` (`:133`) calls
`reader.readRange(fileID:offset:length:)` and discards the result with
`_ =`. `StreamingReader.readRange`
(`Sources/VaultCore/StreamingReader.swift:68`–`:99`) assembles the
range into an ordinary-heap `Data` — explicitly the "documented
residual" class the design tries to keep small.

**Why it matters.** The only *wanted* effect of warming is populating
the budgeted `ResidentChunkCache`; the 4 MiB `Data` copy is pure
collateral. It is unzeroized heap, outside the budget, allocated per
neighbour per landing, for bytes the caller never looks at. It does not
break the honest-boundary claim (the boundary is documented), but it
enlarges the residual for no benefit.

**Suggested fix.** Add a cache-warming entry point on `StreamingReader`
— e.g. `func warm(fileID:offset:length:) async throws` that walks the
same chunk loop but passes an empty body to
`cache.withChunk(address:cost:fetchAndDecrypt:_:)` — and call that from
`warmNeighbor` instead of `readRange`.

### 9 — Tamper primitive ships in Release (nit)

`VaultCoordinator.debugTamperFirstChunk(of:)`
(`App/MobileSeal/VaultCoordinator.swift:551`) and
`VaultStore.debugTamperNewestPlayableVideo()` (`VaultStore.swift:290`)
are not behind `#if DEBUG`. The only call site is gated by
`UITestSupport.isUITestMode` (`GalleryView.swift:107`), which is
compile-time `false` in Release, so nothing reachable calls them — and
`debugGallery()` sets the same precedent. Still, this one *writes
corrupted bytes into the user's CAS*, which is a different class of
primitive from a read-only debug accessor. Wrapping both in `#if DEBUG`
costs nothing and keeps the shipping binary free of a
vault-damaging code path.

### 10 — Shadowed `item` in `attach` (nit)

`MediaPageViewController.attach(player:muted:looping:)` binds
`if let item = player.currentItem` at `:261`, shadowing the
view controller's `item: MediaItem` for the next ~20 lines; then `:304`
(`if item.isVideo { installTimeObserver(player) }`) refers to the
outer `MediaItem` again. The behaviour is correct, but the reader has
to track a scope boundary to confirm it. Rename the inner binding to
`playerItem`.

REVIEW COMPLETE
