---
status: promoted
created: 2026-07-20T01:10:03-05:00
author: cedric
promoted: 2026-07-20T07:37:48-05:00
issue_url: https://linear.app/cedric-personal/issue/CED-12/build-streaming-encrypted-media-playback
linear_project: Mobileseal
linear_project_id: cccebfd8-6d19-474b-852f-c87bf528dcf6
---

# Build Streaming Encrypted Media Playback

## Problem

MobileSeal browses photos but cannot play a video: the vault stores
any media byte-exact (CED-10), the app shell renders stills (CED-11),
but there is no decrypt-on-demand playback path — and the app cannot
even import an ordinary video yet (the picker filter excludes them).
This leg delivers spec §10's media engine: video import, streaming
decrypt through `AVAssetResourceLoaderDelegate`, and the
autoplay-on-swipe pager. Verbatim intake: `references/intake.md`;
map: `wayfinder/MAP.md`; blind plan review (all blockers folded
below): `references/codex-plan-review-20260720.md`. Scope trimmed per
its A1 with cedric's approval: streaming still decode deferred to map
fog; the remote-source seam ships as interface + contract test only.

## Scope

Sized L. Grill decisions (session 001) and review fixes folded.

### Workstream A — VaultCore read-path seam (first core change since CED-10)

1. **`SealedChunkProvider`** (NOT `ChunkSource` — that name is taken
   by the existing move-only import source; Codex B1): a public
   protocol on the sealed plane fetching stored chunk objects by
   `ChunkAddress`, with CAS-address verification at the seam; AEAD
   verification stays where it lives today (the plaintext-plane
   reader). The local store is the only real implementation this
   leg; a fake provider proves the seam with defined minimal
   semantics — a missing chunk throws a typed
   `chunkUnavailable(address:, retryable:)`, no suspension/retry
   machinery (that design belongs to the sync leg that builds a real
   remote source; Codex A2, trim (b)).
2. **Custody-bound range reads over a residency budget**: the
   plaintext cache holds noncopyable `SecureBytes` chunk entries with
   defined semantics (Codex B4/A4): entries are pinned while
   borrowed; eviction zeroizes; concurrent misses coalesce;
   oversize/all-pinned-over-budget requests fail typed
   (`budgetExhausted`), never block; caps and shrink behavior
   (initial 64 MiB, floor 16 MiB, halve on pressure, restore on
   recovery) are constants injected via a test-controllable pressure
   provider — deterministic tests, no reliance on live OS
   notifications. The budget counts ONLY cache-owned decrypted chunk
   bytes; response `Data`, decoded frames, and AVFoundation-internal
   buffers are documented residuals outside it (Codex Q3 — honest
   boundary, stated in docs and the gate).
3. `swift test`: padding-aware range→chunk math, budget
   accounting/eviction/pinning under concurrency, provider contract
   incl. unavailable + address-mismatch, all UIKit-free.

### Workstream B — playback engine

1. **Loader-delegate request state machine** (Codex B2), specified
   not improvised: custom `vault://` scheme (AVPlayer never sees a
   file URL to plaintext — none exists);
   `contentInformationRequest` filled with contentType (UTI from
   stored metadata), contentLength (unpadded length),
   `isByteRangeAccessSupported = true`; every accepted
   `dataRequest` tracked in a request registry and satisfied
   incrementally from `currentOffset` (bounded slices, ≤ one chunk
   per respond) or failed exactly once;
   `requestsAllDataToEndOfResource` fed incrementally to EOF,
   cancellation, or error; `didCancel` unwinds registry entries. The
   delegate serves the byte ranges AVPlayer ACTUALLY requests —
   overlapping, out-of-order, tail-first — never a time→chunk
   mapping of its own (Codex B3).
2. Fixture matrix commits BOTH `moov`-placement variants (Codex B3):
   fast-start (leading moov) and tail-moov MP4/MOV, plus a valid
   unsupported-codec case so loader failure is distinguishable from
   AEAD damage (Codex A6): unsupported-but-authentic renders a
   "can't play this format" state, never the damaged badge; tampered
   chunks surface the damaged-item UX.
3. **Video import, enumerated** (Codex B6): picker filter admits
   videos; a `StagedPart` ordinary-video role; `ImportEngine` accepts
   video-primary items; poster-frame thumbnail + duration via
   `AVAssetImageGenerator`/`AVAsset` at import; `MediaMetadata`
   evolves by backward-compatible optional fields (kind: video,
   durationSeconds) with a schema-version bump and defined recovery:
   already-imported Live-Photo paired videos backfill duration
   lazily on first open (Codex Q7).

### Workstream C — pager + playback UX

1. **Photos-lite pager** (grill Q1): hard-snap paging, tile↔detail
   zoom morph on open/close, interactive swipe-down dismiss;
   zoom-carryover and pinch-to-grid stay deferred (map fog).
2. **Autoplay** (grill Q3): landing on a video autoplays MUTED and
   looping, tap toggles sound; Live Photos auto-play motion once.
   One-active-player rule: neighbors get at most poster + leading
   ranges warmed through the provider; player-item creation happens
   only for the landed item; generation-token cancellation (the
   thumbnail-purge discipline) invalidates prefetch work on
   fast swipes (Codex A3).
3. **PlaybackController owns playback custody** (Codex B5/Q2): one
   object retains player, delegate, request registry, cache, and
   readers, and registers with the coordinator's lock path. Lock
   ordering: fail all outstanding loader requests → stop/release
   players → release readers/cache (zeroize) → then the custodian
   drain proceeds. The gate's observable is concrete: active-request
   count == 0 and cache bytes == 0 post-lock (no "buffers purge"
   hand-waving — AVFoundation internals are a documented residual).
4. **External playback truth table** (grill Q2 + Codex B7): AirPlay
   external playback ALLOWED — `allowsExternalPlayback = true`, and
   while `AVPlayer.isExternalPlaybackActive` the capture shield is
   EXEMPT for the player surface; screen recording and mirroring
   (current scene capture API, not the deprecated
   `UIScreen.isCaptured`) blank the local player when external
   playback is not active. AirPlay behavior verified as a HITL
   device check with Cedric.
5. Video-only this leg (grill Q4 — picker can't import audio);
   filmstrip deferred (grill Q5); CONTEXT.md gains playback
   vocabulary (provider, residency budget, request registry,
   external-playback exemption) as a work item (Codex A7).

### Workstream D — chunk-profile benchmark (decision-grade; Codex B8)

1. Committed fixture generator producing the SAME source videos
   (two codecs H.264/HEVC, 30 s, defined GOP, both moov placements)
   imported into SEPARATE vaults per chunk profile (4 / 2 / 1 MiB —
   dedup in one gallery would silently reuse the first profile),
   cold-cache controlled.
2. Instrumentation: seek-to-first-PRESENTED-frame (first pixel
   buffer timestamp via player-item output), 10 repetitions across
   5 positions, report p50/p90. **Predeclared decision rule**: keep
   4 MiB unless p90 cold seek-to-first-frame exceeds 400 ms on the
   simulator AND the difference to 2 MiB exceeds 25% — then adopt
   the 2 MiB video profile for new imports (per-file property;
   formats.md already permits it). The decision must hold on the
   physical iPhone (HITL device run) before RESULT.md records it.
3. Budget degradation test via the injected pressure provider:
   under simulated pressure, playback continues with shrunken cache
   (assert continued frame delivery + shrunken cache bytes), never
   a crash.

## Green gates

1. `swift test` green incl. provider/budget suites; app suites
   green; `xcodebuild` simulator + generic device builds succeed.
2. Scripted e2e (XCUITest): import fixture videos (both moov
   variants) → grid shows poster + duration → autoplay muted on
   pager landing → tap unmutes → scrub to 3 positions (frames
   presented: first-pixel-buffer observable) → unsupported-codec
   item shows its distinct state → tampered item shows damaged
   state.
3. Playback custody: request-registry/decrypt/cache counters
   exposed in test builds; lock mid-playback yields
   active-requests==0, cache-bytes==0, readers failed closed;
   custody canary over the app container clean during and after
   playback (no plaintext temp files); documented residual boundary
   (AVFoundation internals) stated in the test.
4. Prefetch discipline: fast-swipe UITest across mixed batch —
   one-active-player invariant holds, generation tokens cancel
   stale work, cache bytes stay ≤ budget (instrumented).
5. Chunk-profile benchmark: fixture matrix run per D.2's
   predeclared rule, simulator numbers + device confirmation
   (HITL), decision + p50/p90 table in RESULT.md.
6. Blind multi-tool review wave (all four reviewers) completed and
   reconciled.

## References

- `references/intake.md`; `wayfinder/MAP.md`;
  `references/codex-plan-review-20260720.md` (dispositions inline
  above by finding number).
- Local ground truth the executor MUST read first:
  `Sources/VaultCore/Gallery.swift` (existing move-only
  `ChunkSource` — do not collide), `ChunkReader.swift`,
  `KeyCustodian.swift` (drain), `SecureBytes.swift`,
  `App/MobileSeal/VaultCoordinator.swift` (lock path),
  `App/MobileSeal/Import/*` (picker filter, StagedPart roles,
  ImportEngine still-requirement), `App/MobileSeal/MediaMetadata.swift`
  - `MediaIndex.swift` (schema to evolve), `docs/formats.md`
    (chunk header/padding/per-file chunk size).
- Apple: AVAssetResourceLoadingContentInformationRequest /
  DataRequest (incl. `requestsAllDataToEndOfResource`) contracts;
  external-playback + scene capture state APIs.
- `goals/CED-11-ios-vault-app-shell/results/RESULT.md` (coordinator
  custody, xcodegen regeneration, lateness-vs-target perf pattern,
  device-step logistics); CED-10 RESULT.md.
- `research/_default/chunk-size-for-encrypted-media-cas.md`.

## Decisions (grilling session 001)

`grilling/session-001-20260720-012500.md`: Photos-lite pager ·
external playback ALLOWED (owner override; recording/mirroring still
blank) · muted autoplay + tap-for-sound, Live Photo auto-motion,
looping · video-only · filmstrip deferred. Post-review scope trim
(cedric-approved): streaming still decode → map fog; remote-source
seam minimal.

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- VaultCore changes stay UIKit-free; formats are FROZEN — the
  provider is read-path only; the chunk-profile decision changes
  only what import writes for NEW files.
- xcodegen: regenerate after adding files (CED-11 gotcha);
  `Scripts/run-gates.sh` is the gate-suite shape.
- Device steps (AirPlay check, benchmark confirmation, Live-Photo
  picker smoke) are HITL with Cedric — executor shells cannot sign
  to device.
- The existing import `ChunkSource` and its two-pass read are load-
  bearing for dedup — read CED-10 RESULT.md's `aad_file_id` note
  before touching anything near import.
