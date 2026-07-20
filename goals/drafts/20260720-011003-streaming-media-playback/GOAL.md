---
status: draft
created: 2026-07-20T01:10:03-05:00
author: cedric
---

# Build Streaming Encrypted Media Playback

## Problem

MobileSeal browses photos but cannot play a video: the vault stores
any media byte-exact (CED-10), and the app shell renders stills
(CED-11), but there is no decrypt-on-demand playback path — and the
detail viewer still materializes whole files under a memory ceiling.
This leg delivers spec §10's media engine: streaming decrypt through
`AVAssetResourceLoaderDelegate`, the Photos-style pager, and the
custody machinery (pluggable chunk source + resident-plaintext
budget) that CED-10 deliberately trimmed and the sync legs will
reuse. Verbatim intake: `references/intake.md`; map:
`wayfinder/MAP.md`.

## Scope

Sized L. Grilling sharpens the gesture/policy questions below.

### Workstream A — VaultCore streaming seam (first core change since CED-10)

1. Public rewindable **`ChunkSource`** abstraction: byte-range →
   chunk-range resolution over a PLUGGABLE source — the local store
   now; a fetching (remote) source at the sync/cloud legs plugs in
   without redesign (Cedric's play-while-downloading requirement;
   never literal HLS — originals stay byte-exact).
2. **Resident-plaintext budget**: caller-declared decrypted-chunk
   residency cap with LRU eviction and memory-pressure shrink
   (`os_proc_available_memory` / memory-pressure notifications on
   iOS, fixed cap for CLI). Deferred from CED-10's api-shape trim;
   stays UIKit-free.
3. `swift test` coverage: range→chunk math (padding-aware), budget
   accounting under concurrent readers, eviction correctness, and a
   fake remote source proving the seam (slow/partial availability).

### Workstream B — playback engine

1. `AVAssetResourceLoaderDelegate` serving decrypted bytes on demand:
   byte-range requests → ChunkSource → AEAD-verified chunks →
   response data; `isByteRangeAccessSupported`; **no plaintext temp
   files anywhere** (spec §10/§11) — custody canary extends over the
   playback path.
2. Scrubbing: seek maps to chunk range; only those chunks decrypt.
   Tampered chunk mid-playback surfaces the damaged-item UX (CED-11
   gate-1 pattern), never silent corruption.
3. Video import completes: poster-frame thumbnails generated at
   import for movie files (the grid currently has no video story);
   duration badge on grid tiles.
4. Streaming still decode: the detail viewer's whole-file
   materialization is replaced by ChunkSource-fed incremental decode
   (CED-11 follow-up).

### Workstream C — pager + motion

1. **Photos-lite pager** (grill Q1): hard-snap horizontal paging,
   tile↔detail zoom morph on open/close, interactive
   swipe-down-to-dismiss; zoom-carryover-between-items and
   pinch-out-to-grid are deliberately skipped (later polish
   candidate, on the map). Neighbor-prefetch/decrypt inside the
   residency budget, prioritizing the next item's leading chunks
   (autoplay depends on it).
2. **Autoplay** (grill Q3/Q3b): landing on a video starts MUTED
   looping playback immediately (Instagram model), tap toggles
   sound; Live Photos auto-play their motion once on landing.
   Device smoke test of the Live-Photo picker path (CED-11
   follow-up).
3. Inline video player UI: play/pause/scrub/mute, AVPlayer wired to
   the loader delegate; lock mid-playback tears down cleanly (player
   stops, buffers purge — gate-tested). **External playback ALLOWED**
   (grill Q2 — "it's my TV"): `allowsExternalPlayback = true`;
   screen RECORDING still blanks the player (`UIScreen.isCaptured`
   shield). Video-only this leg (grill Q4 — PHPicker cannot import
   audio; the loader is format-agnostic for a future Files-import
   leg). Scrub-preview filmstrip deferred (grill Q5).

### Workstream D — benchmarks + chunk profile

1. Scrub-latency benchmark on fixture videos (committed): measure
   seek-to-first-frame across positions at 4 MiB vs a 1–2 MiB
   re-chunked variant; **decide the per-file video chunk profile**
   (chunk size is already a per-file inventory property) and record
   the decision + numbers in RESULT.md (research report on file
   allows either).
2. Budget behavior under pressure: instrumented test proving
   playback degrades cache depth (not crashes) when memory shrinks.

## Green gates

1. `swift test` green incl. new ChunkSource/budget suites; app suites
   green; `xcodebuild` simulator + generic device builds succeed.
2. Scripted e2e (XCUITest): import fixture video → grid shows poster
   - duration → play → scrub to three positions → frames render (no
     plaintext temp file created — custody canary across the playback
     session, incl. lock-mid-playback teardown).
3. Pager: UITest swipes across a mixed batch (stills, video, Live
   Photo, damaged item) — neighbor prefetch stays within the stated
   residency budget (asserted via instrumentation).
4. Scrub benchmark recorded with the chunk-profile decision and
   thresholds stated in-test; device spot-check on the iPhone
   (HITL, coordinated with Cedric).
5. Blind multi-tool review wave (all four reviewers) completed and
   reconciled.

## References

- `references/intake.md` — verbatim intake (map ticket + CED-11
  follow-ups + Cedric's queued items).
- `wayfinder/MAP.md` — recrafted map (third executed leg).
- `goals/CED-11-ios-vault-app-shell/results/RESULT.md` (main) —
  coordinator custody shape, xcodegen regeneration gotcha, perf
  instrumentation (lateness-vs-target), device-step logistics.
- `goals/CED-10-private-photo-vault/results/RESULT.md` +
  `docs/formats.md` — chunk/padding format the range math must honor.
- `research/_default/chunk-size-for-encrypted-media-cas.md` — video
  profile guidance (1–2 MiB permitted if scrub demands).
- Full v0.1 spec: `goals/CED-10-private-photo-vault/references/intake.md`
  (§10 playback engine, §11 checklist).

## Decisions (grilling session 001 — all five questions resolved)

See `grilling/session-001-20260720-012500.md`. Q1 Photos-lite pager
(snap + morph + interactive dismiss; full-Photos transitions =
later polish) · Q2 external playback ALLOWED, screen-recording
blanks · Q3 videos autoplay muted + tap-for-sound, loop; Live
Photos auto-motion once · Q4 video-only (audio waits for a Files
import) · Q5 filmstrip deferred.

## Executor notes (self-sufficiency)

- Review-wave diff base: `main`.
- VaultCore changes (WS A) are the first since CED-10: keep the
  package UIKit-free (budget uses platform-neutral hooks with iOS
  wiring in the app layer); formats are FROZEN — ChunkSource is
  read-path only; a per-file chunk-size profile changes only what
  IMPORT writes for new files (docs/formats.md already permits it).
- xcodegen: adding files requires project regeneration (CED-11
  gotcha); run `Scripts/run-gates.sh` for the gate suite shape.
- Device steps (gate 4 spot-check, Live-Photo smoke) are HITL with
  Cedric — executor shells cannot sign to device (login keychain).
- AVAssetResourceLoader only engages for custom URL schemes (e.g.
  `vault://`); AVPlayer must never see a file URL to plaintext —
  there is none.
