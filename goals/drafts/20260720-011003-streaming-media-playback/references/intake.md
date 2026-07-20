Streaming Media Playback — third executed leg of the private-photo-
vault wayfinder map, drafted after CED-11 (iOS Vault App Shell)
merged at 494c57f.

Map ticket (from CED-11's locked wayfinder/MAP.md): AVAssetResource-
LoaderDelegate streaming decrypt for video/audio, swipe/zoom polish,
scrub-latency benchmark that confirms or shrinks the per-file chunk
size; owns the resident-plaintext budget / streaming custody design
CED-10 deliberately trimmed. Blocked by: iOS Vault App Shell — now
resolved.

Carried in from CED-11 RESULT.md follow-ups:
- Streaming rewindable ChunkSource + streaming detail decode (remove
  the still viewer's whole-file materialization behind its 256 MiB
  ceiling).
- Live Photo motion playback (pairs are stored since CED-11; the
  still is shown today; picker Live-Photo path is fixture-tested
  only — device smoke test owed).
- Resident-plaintext budget with memory-pressure awareness (deferred
  from CED-10's api-shape trim).

Carried in from Cedric's mid-CED-11 questions (map-rollforward-queue):
- Design the reader seam with a PLUGGABLE chunk source (local store
  now, remote fetching source at the sync/cloud legs) — enables
  play-while-chunks-download (iCloud-like streaming) without
  redesign; explicitly NOT literal HLS (byte-exact originals stand).
- Pager gesture set is a grill question: Photos-style interactive
  transitions vs Instagram-style hard-snap paging ("instagram-style
  swiping" was Cedric's phrase; spec §10's bar is Photos-feel), with
  swipe-down-dismiss and neighbor-prefetch/decrypt scope.

Research on file: chunk-size report recommends keeping 4 MiB for
storage but allows a 1-2 MiB per-file video profile if scrub latency
demands (chunk size is already a per-file inventory property).
Spec §10: decrypt only the chunks needed for the current playback
position, never the whole file, never a plaintext temp file.
