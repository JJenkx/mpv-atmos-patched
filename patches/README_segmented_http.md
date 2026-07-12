# Segmented parallel HTTP downloading for mpv

Files:
- `stream_segmented_http.c` — new mpv stream module (copied into `stream/`)
- `apply_segmented_http.sh` — applies the module + 4 hook lines to an mpv
  source tree (anchored, idempotent; fails loudly if upstream anchors move).
  Called automatically by `build_mpv.sh` in the mpv step.

## Usage

    mpv --segmented-chunks=6 --segment-size=10MiB <http(s) url>

- `--segmented-chunks=N` (0–16, default 0 = disabled). N parallel HTTP Range
  connections each fetch one chunk ahead of the playback position; chunks are
  stitched into one seamless, fully seekable byte stream.
- `--segment-size=SIZE` (default 10MiB). Byte-size suffixes: `KiB`, `MiB`, `GiB`.
- `--segment-auto-size=yes|no` (default yes). If `demuxer-max-bytes` leaves
  headroom, segment size is grown toward it (capped at 4× the requested size
  and a 1 GiB total window).

Interaction with `demuxer-max-bytes`:
- window total (chunks × size) > demuxer-max-bytes → demuxer-max-bytes is
  raised to fit and a log line is printed.
- window total < demuxer-max-bytes → auto-size grows chunks (see above); the
  demuxer additionally keeps filling its own packet buffer as usual, so the
  effective readahead is demuxer buffer + chunk window.

Fallbacks (transparent, logged):
- `--segmented-chunks` unset/0/1 → normal single-connection stream_lavf path.
- Server without Range support, or unknown file size → stream_lavf path.
- HLS/live streams have no usable byte length → stream_lavf path.

Seeking: seeks inside the downloaded window are served from RAM. Seeks
outside it re-anchor the window at the new position, keeping any already
downloaded chunks that still fall inside it — only chunks that can no longer
be used are dropped, so a seek costs at most the in-flight remainder instead
of the whole window.

Wasted-transfer safeguards (added 2026-07-03):
- Every chunk is requested as an exact `Range: bytes=A-B`, never open-ended.
  Open-ended ranges made the server keep pushing data past the chunk into
  TCP buffers, which was discarded on every chunk transition (measured up to
  tens of percent overhead). Exact ranges are fully consumed, which also lets
  ffmpeg reuse the keep-alive connection for the next chunk (no new TLS
  handshake per chunk).
- ffmpeg's `short_seek_size` is capped at 64 KiB per worker connection; its
  default (the TCP window size) made it "seek" forward by downloading and
  discarding multi-MB gaps.
- The open() probe request is bounded to 256 KiB.
- Downloading always stops once the window (chunks × size ahead of the read
  position) is full; workers idle until the demuxer consumes more. Measured
  steady-state overhead vs file size: ~0.15% (the probe).

**Important companion settings** (set in mpv.conf 2026-07-02): with a large
`demuxer-max-bytes` and fast parallel downloading, the demuxer will otherwise
churn RAM at full line rate for minutes on huge files, which can starve
audio/video (ALSA underruns, dropped frames). `demuxer-readahead-secs=240` +
`demuxer-hysteresis-secs=120` make it fill in short bursts and idle in
between. While the demuxer idles, the server may drop the parked worker
connections; the `[ffmpeg] https: Will reconnect` log lines on resume are
expected and harmless.

Verified 2026-07-02 against mpv master (102e693f): byte-exact stream dump
(md5 match), parallel ranges confirmed via instrumented HTTP server, seek +
fallback paths exercised.

Re-verified 2026-07-03 after the waste/seek rework: byte-exact md5, 0.14%
transfer overhead on a linear dump, zero duplicate ranges across forward and
backward seeks within the window, deadlock-free backward seeks into a full
window (throttled-server stress test), and 1.00x playback with 0 underruns
post-seek on the real 4K TrueHD file with the full user config.
