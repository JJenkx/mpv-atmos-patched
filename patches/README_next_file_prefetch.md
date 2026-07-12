# Next-file prefetch for mpv

Prefetch the **next** playlist entry from the moment the current file starts
playing — held cheap while it prefetches, then ramped to full buffering the
instant it becomes the current file, reusing the already-buffered data (no
stream reopen). Built on mpv's own demuxer prefetch, so it honours
`demuxer-cache-unselected-audio/subs` retention automatically.

Files:
- `apply_next_file_prefetch.sh` — anchored, idempotent core patch (options,
  demux, stream, player). Called by `build_mpv.sh` after the segmented-http
  patch. Fails loudly if an upstream anchor moves.
- Consumes hooks added by the segmented-http patch — see
  `stream_segmented_http.c` (`STREAM_PREFETCH`, `STREAM_CTRL_SEGMENTED_ACTIVATE`).

## Options

    next-file-prefetch=yes|no                      # master switch (default no)
    next-file-demuxer-max-bytes-prefetch=SIZE      # cache cap while prefetching
                                                   #   (default/0 = 256MiB)
    next-file-segmented-chunks=N                    # segmented-http workers while
                                                   #   prefetching (default 1)

During playback the next entry's demuxer is opened early and fills only up to
`next-file-demuxer-max-bytes-prefetch` (back-buffer disabled), and its
segmented-http stream downloads with just `next-file-segmented-chunks` parallel
connections. When the entry is promoted to the current file the cache cap is
lifted to the normal `demuxer-max-bytes` / `demuxer-max-back-bytes` and download
parallelism ramps to the normal `segmented-chunks` — no reopen, buffered data
kept.

## Why this design

- **Immediate, not near-EOF.** mpv's stock `--prefetch-playlist` only opens the
  next file once the current file's cache reaches EOF. Here `prefetch_next()` is
  also triggered from `handle_update_cache()` as soon as the current file is
  playing without stalling for cache (`!paused_for_cache`), so a long episode's
  successor is buffered from the start.

- **Cheap during prefetch, full on promotion — the hard part.** mpv reuses the
  prefetched demuxer *and its stream* as-is when the entry becomes current, so
  per-phase settings can't come from reopening. Two mechanisms handle it:

  - *Demuxer cache cap* is a per-instance override in `demux_internal`
    (`in_prefetch_mode` / `prefetch_max_bytes`), applied on top of the option
    values in `update_opts()`. It is **not** done by toggling the global
    `demuxer-max-bytes`: a runtime write to that option is seen as a demuxer
    option change and makes mpv *drop the very prefetch being built*, and it
    would also shrink the currently-playing file's cache. On promotion the
    player calls `demux_end_prefetch()`, which (on the demux thread, the owner of
    the stream) lifts the cap and forwards the activation to the stream.

  - *Segmented parallelism* is scaled without reallocating anything: the
    readahead **window** (`num_slots`, buffers) is allocated at the full
    `segmented-chunks` size up front, but only `next-file-segmented-chunks`
    **workers** are allowed to run; the rest park. Workers and window are
    separate concepts — parking/waking workers needs no realloc, so the raw
    `struct slot *` pointers workers hold never dangle.
    `STREAM_CTRL_SEGMENTED_ACTIVATE` wakes the parked workers on promotion.

- **All stream access stays on the demux thread.** The player never touches the
  prefetched stream directly (it is owned by the demuxer thread once caching is
  on). `demux_end_prefetch()` only flags + wakes the demux thread, which does
  the cap-lift and `STREAM_CTRL_SEGMENTED_ACTIVATE` in `thread_work()`.

## Interactions

- `next-file-segmented-chunks` lives in `stream_segmented_http_conf` (registered
  by the segmented-http patch). If `segmented-chunks < 2` the module is disabled
  and the next file prefetches over a single plain connection (already minimal);
  the activation control is then a harmless no-op.
- While prefetching, the segmented module never raises the global
  `demuxer-max-bytes` (its `reconcile_demux_buffer` skip), for the same
  drop-the-prefetch reason as above; the per-instance cap governs volume.
- Only the top-level entry demuxer enters prefetch mode; sub-demuxers
  (timeline/EDL) are unaffected.

## Testing

Verify options are present and typed:

    mpv --list-options | grep next-file

With `--msg-level=stream=v,demux=v`, playing a playlist over http you should see
the next entry's `segmented: ... [prefetch: reduced parallelism]` line while the
current file plays, then `segmented: activated full parallelism` on switch.
