# Segmented download-speed exposure

Surfaces the **true** download rate of the segmented HTTP downloader's worker
threads to mpv scripts, so the uosc seek bar can show a live combined MiB/s
readout and the stats overlay can show a per-thread breakdown.

## Why not just use `cache-speed` / `raw-input-rate`?

mpv already exposes an aggregate rate via the `cache-speed` property and
`demuxer-cache-state/raw-input-rate` (both = `demux_reader_state.bytes_per_second`).
But that figure is measured from `stream->total_unbuffered_read_bytes`, which for
the segmented stream is incremented by `stream_read_unbuffered()` based on what
`seg_fill_buffer()` returns — i.e. the rate at which the **demuxer drains
already-downloaded slot buffers** (a `memcpy`), *not* what the N worker sockets
pull off the network.

Because the workers download *ahead* into slot buffers, the two diverge:
`raw-input-rate` reads ~0 while the readahead window is full (even though the
connections are saturating the link) and spikes far above the real network rate
when the demuxer reads a burst of buffered data. So the honest download rate has
to be measured inside the segmented module itself.

## What the patch adds

Split across two pieces:

- **`stream_segmented_http.c`** (copied in wholesale by `apply_segmented_http.sh`):
  - `struct worker.dl_total` — monotonic bytes each connection has downloaded,
    incremented in the read loop under the existing lock.
  - `struct priv` EMA sampling state (`speed_last_ns`, `worker_prev_total[]`,
    `worker_bps[]`).
  - `STREAM_CTRL_GET_SEGMENTED_SPEED` handler in `seg_control()`: rolls a 50/50
    EMA (matching demux.c's `bytes_per_second` smoothing) at ~1s cadence and
    returns combined + per-connection bytes/sec in a `struct stream_segmented_speed`.
    Idle workers contribute 0, so the rate decays toward 0 when the window is
    fully buffered and the threads park — which is the honest state.

- **`apply_segmented_speed.sh`** (anchored `insert_after` hooks, run after
  `apply_segmented_http.sh` from `build_mpv.sh`):
  - `stream/stream.h`: the `STREAM_CTRL_GET_SEGMENTED_SPEED` enum value and the
    `struct stream_segmented_speed` result struct.
  - `demux/demux.h`: `segmented_active` / `segmented_total_bps` /
    `segmented_num_workers` / `segmented_worker_bps[16]` on `demux_reader_state`.
  - `demux/demux.c`: `update_cache()` queries the stream (right where it already
    queries `STREAM_CTRL_GET_METADATA`, on the demux thread, ~1s tick), stashes the
    result in `demux_internal`, and publishes it via `demux_get_reader_state()`.
  - `player/command.c`: adds `segmented-input-rate` (int64 bytes/sec) and
    `segmented-worker-rates` (int64 array) to the `demuxer-cache-state` property
    node — but only when the stream is segmented (emitted even at rate 0 so the
    readout stays visible).

## Consumers (in this repo)

- `mpv.config/scripts/uosc/main.lua` — observes `demuxer-cache-state`, stashes
  `segmented-input-rate` → `state.download_speed` and `segmented-worker-rates` →
  `state.worker_speeds`.
- `mpv.config/scripts/uosc/elements/Timeline.lua` — the seek-bar readout that used
  to show buffered seconds (`42s`, capped at `buffered_time_threshold`) now shows
  `state.download_speed` as `X.X MiB/s` (via `format_speed()`), always visible for
  segmented streams, hidden for local/non-segmented ones.
- `mpv.config/scripts/stats.lua` — the `i` overlay's Cache section gains a
  `Segmented DL:` line (combined) and a `Workers:` line (per-connection).

## Keeping the value live (no freeze at EOF)

Once a file is fully buffered to EOF the demuxer stops reading from the stream, so
mpv stops calling `update_cache()` — which is what queries our speed. Without care
the last value freezes on screen. Three pieces keep it honest:

- **Staleness hard-zero** (`stream_segmented_http.c`): `struct priv.last_dl_ns` is
  bumped whenever any worker receives bytes; the `STREAM_CTRL_GET_SEGMENTED_SPEED`
  handler zeroes all rates once no bytes have arrived for 1.5s.
- **Live re-query** (`demux/demux.c`, `apply_segmented_speed.sh` step 3g):
  `demux_get_reader_state()` re-queries the segmented stream on every read (gated
  on `segmented_active`; `seg_control` is non-blocking), so a property read always
  reflects the current rate instead of the frozen `in->` snapshot.
- **1s poll** (uosc `main.lua`): `mp.add_periodic_timer(1, …)` re-reads
  `demuxer-cache-state` and re-renders when the value changes, since the property
  stops change-notifying once caching goes idle.

## Next-file prefetch speeds

When the next playlist entry is prefetching in parallel (see
[next-file prefetch](README_next_file_prefetch.md)), its download is a separate
demuxer reachable at `mpctx->open_res_demuxer`. `mp_property_demuxer_cache_state`
calls `demux_get_reader_state()` on it (gated on `atomic_load(open_done)` and
`!= mpctx->demuxer`) and adds `segmented-prefetch-input-rate` /
`segmented-prefetch-worker-rates`. uosc stacks them under the current file's
readout, separated by a `– – –` divider.

## Rebuild

Run `./build_mpv.sh`. The apply step fails loudly if an upstream anchor moved.

Verify on a segmented stream (`mpv_patched.sh --segmented-chunks=8 <http-url>`):
`demuxer-cache-state` should carry `segmented-input-rate` /
`segmented-worker-rates` that rise during buffering and fall to 0 once the window
is full, while `cache-speed` behaves erratically for the same stream.
