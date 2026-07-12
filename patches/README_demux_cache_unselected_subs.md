# demux cache-unselected-tracks patch (subs + audio)

**Problem:** on network streams, enabling or switching a subtitle or audio
track destroys the whole forward demuxer cache. mpv's cache only stores
packets of *selected* tracks, so a newly selected track has no packets in
the cache; mpv issues a "refresh seek" that clears every queue and re-reads
the stream from the current position — with HTTP streams the entire
readahead is re-downloaded. Upstream issue:
https://github.com/mpv-player/mpv/issues/8422 (closed, never fixed;
demux.c even carries a comment reserving `demux_stream_is_selected()` for
exactly this future use).

**Fix:** two new options, both default **yes**, active only when the
seekable demuxer cache is on (network streams); local files unaffected:

- `--demuxer-cache-unselected-subs` — subtitle packets are cached while
  the track is deselected. Selecting a sub track delivers the whole cached
  queue (decoders filter by timestamp, so ASS events overlapping the
  current position are never missed). Memory cost negligible.
- `--demuxer-cache-unselected-audio` — same for audio tracks. On select,
  the reader is positioned at the current timestamp via `find_seek_target`
  (delivering history would burst-decode it). The audio data of all tracks
  is downloaded anyway (interleaved in the stream); this keeps it in
  memory, counted against `demuxer-max-back-bytes` (16GiB here).

## Files

- `demux_cache_unselected_subs.patch` — git diff against mpv master
  (g102e693f4, 2026-07): `demux/demux.c`, `demux/demux.h`,
  `DOCS/man/options.rst`.
- `apply_demux_cache_unselected_subs.sh <mpv-src-dir>` — idempotent apply;
  called automatically by `build_mpv.sh` after its git reset.

## What the patch touches (demux.c)

1. `stream_cached_anyway()` — helper: sub/audio stream + seekable cache +
   option.
2. `add_packet_locked()` — don't drop packets of deselected cached-anyway
   streams; only attach the reader to new packets when selected.
3. `update_stream_selection_state()` — keep the queue on deselect.
4. `refresh_track()` — fast path on select: subs start at queue head
   (empty queue is fine if `queue->incomplete` is false — means the range
   simply has no sub packets yet); audio starts at `find_seek_target(ref_pts)`.
   Falls back to the normal refresh seek if the queue can't serve.
5. `queue->incomplete` flag — set when a queue starts while its range
   already has data (stream added mid-demuxing, or cleared by a refresh
   seek); fresh ranges are complete. Distinguishes "no packets exist" from
   "packets missing" for the empty-queue sub case.
6. `initiate_refresh_seek()` (other track switches) — preserve
   cached-anyway queues; mark them `refreshing` so re-read duplicates get
   dropped by the existing dedup (needs queue pos/dts correctness, else
   falls back to clearing = old behavior).
7. `attempt_range_joining()` / `execute_cache_seek()` — same `refreshing`
   dedup when the demuxer resumes past a cached range. A cached-anyway
   audio queue with no join point is dropped (gap/overlap protection);
   `execute_cache_seek` no longer sets `reader_head` on deselected streams
   (a stuck reader would count as forward bytes forever).
8. `read_packet()` — don't EOF-mark deselected streams (would toggle per
   packet now); `is_bof` after seek-to-start includes cached-anyway queues.
9. `demux_stream_is_selected()` — report cached-anyway streams as selected
   so the actual demuxers (demux_lavf `AVDISCARD_ALL`, demux_mkv block
   skip) deliver their packets.

## Known limitations

- Video track switches still drop the cache (nobody switches video tracks
  mid-play; caching all video is too big).
- Under back-buffer memory pressure, deselected sub queues are pruned
  first; audio queues prune normally. Effect: selecting afterwards falls
  back to today's behavior.
- A track that genuinely appears mid-stream (MPEG-TS PMT updates etc.;
  mkv tracks are all known upfront) has `queue->incomplete` set and falls
  back to the normal refresh seek on first select.
- `--stream-record` now also records deselected cached-anyway tracks.

## Verification (2026-07-03, throttled local HTTP server, 10-min mkv,
2 audio + 3 srt tracks, one srt with first cue at 35s)

- Options **no** (= stock): cache 62.8s → **0.0s** on every sub
  enable/switch and audio switch.
- Options **yes**: cache never dips (65.1s min, keeps growing to 250s+)
  across: audio 1→2→1 (audio-pts kept advancing, A/V in sync), enabling
  the no-cues-yet sub track (cue then appeared on time at 35s), sub
  switches, audio off/on, uncached seek + enable, seek back into cached
  range. Local-file playback unchanged. Zero warnings/errors in logs.
