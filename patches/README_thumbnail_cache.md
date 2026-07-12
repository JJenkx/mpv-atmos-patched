# In-process, from-buffer thumbnailer (`thumbnail-cache`)

**"Patch B".** Makes mpv generate seekbar thumbnails *itself*, decoding frames
straight out of the demuxer's in-memory seekable cache — no second mpv process,
no `fork()`, and no extra network I/O. This is what thumbfast does, but done
in-process so it does not trip the spdif-underrun wedge (any `fork()` of the
~9 GB mpv duplicates page tables and stalls spdif; a worker *thread* shares the
address space and does not).

## What it adds

A new command:

```
thumbnail-cache <time> <width> <height> <filename>
```

It decodes the **keyframe at/before `<time>`** with a private libavcodec context
on a worker thread, scales the frame to exactly `<width>×<height>` BGRA, and
writes the raw pixels (`width*height*4` bytes, tightly packed) to `<filename>`
via a temp-file + `rename` (atomic for the overlay reader). Where the keyframe
comes from depends on the source:

- **Network / non-seekable** → from the **already-buffered demuxer cache** only
  (no extra I/O, no disturbance to playback). Coverage is the buffered window.
- **Local seekable file** → the file is opened **directly** (a private
  libavformat context, kept open and reused across hovers, rebuilt when the
  played file changes) and seeked anywhere. **Full-timeline coverage**, still no
  subprocess fork. Reads file data off disk, independent of the player's cache.

The source is chosen automatically from `demuxer->is_network`/`->seekable`, so
one command serves both and the Lua side needs no branching.

**Keyframe-accurate, on purpose.** It returns the keyframe frame, not the exact
frame at `<time>` — the same thing a keyframe seek lands on, which is what stock
thumbfast shows for long media (`allow_fast_seek`, duration ≥ 30 s). Decoding
the exact inter-frame instead made thumbnails jitter frame-to-frame as the hover
time wobbled, and walk forward as a GOP filled during buffering. Snapping to the
keyframe makes the thumbnail deterministic for a given time and cheap (one packet
decoded, not a GOP). Granularity is therefore the GOP length; dragging steps at
keyframe boundaries.

`cmd->success` is true only when a file was written, i.e. the frame was in the
cache. If `<time>` is not buffered, it writes nothing and reports failure — the
caller just keeps the previous thumbnail.

## Files

| File | Role |
|------|------|
| `thumbnail_cache/demux_thumb_cache.c` | `demux_get_cached_video_packets()` — read-only extraction from the cache. `#include`d at the end of `demux/demux.c` because it needs the private `demux_internal`/`demux_cached_range`/`demux_queue` structs and the static helpers `find_cache_seek_range()` / `find_seek_target()`. |
| `thumbnail_cache/thumbnail.c` | `cmd_thumbnail_cache()` — decode + scale + write. New `player/thumbnail.c`. |
| `thumbnail_cache/thumbnail.h` | prototype. New `player/thumbnail.h`. |
| `apply_thumbnail_cache.sh` | copies the three files and makes four anchored, idempotent edits: `demux/demux.c` (`#include`), `demux/demux.h` (prototype), `player/command.c` (`#include` + `mp_cmds[]` row), `meson.build` (source). |

Applied automatically by `build_mpv.sh` (after the segmented-http and
sub-cache patches). Idempotent; fails loudly if an upstream anchor moved.

## How it stays correct / safe

- **Read-only w.r.t. playback.** It never touches any `ds->reader_head`, never
  issues a low-level or network seek. It only walks the cache linked list under
  `in->lock` and deep-copies (`demux_copy_packet`) the packets it needs.
- **No lock inversion.** Lock order is core-lock → `in->lock`, the same order
  every command that calls a demuxer function already uses.
- **Separate decoder.** A private `AVCodecContext` on deep-copied packets — no
  shared state with the main decode path; the two run concurrently and safely.
- **Worker thread.** The command uses `mp_cmd_def.spawn_thread`, so the decode
  runs off the core lock (which it drops for the heavy work and re-takes before
  returning). No fork → no spdif wedge.

## Fundamental limitation (physics, not fixable by this patch)

The cache is a **sliding window** around the play head (this build:
`demuxer-max-bytes=1024MiB` forward / `2GiB` back). Seekbar thumbnails inherently
want frames across the *whole* timeline. So you get thumbnails only for
positions currently buffered — a band around the current time — and nothing for
far-away hover points that were never downloaded. That is the deliberate
"only thumbnail what's in the buffer" behaviour; it is not a bug.

## Known gaps (v1, could be added later)

- No rotation handling (`video-rotate`) — rotated video thumbnails come out
  unrotated. The `real_res()` path in thumbfast still works because output is
  exactly `w*h*4`.
- No HDR tone-mapping — bt.2020 frames convert with plain sws and may look
  washed out. (`tone_mapping` is already `no` in this setup.)
- Software decode only (no hwdec) — intentional; cheap and avoids GPU download.
- On-disk demuxer cache (`--cache-on-disk`) is not supported: if a packet is
  `is_cached`, extraction bails (this build uses the in-RAM cache only).

## Client side

`mpv.config/scripts/thumbfast.lua` gains a `cache_backend` option (on in
`script-opts/thumbfast.conf`). When enabled it feature-detects the command and,
instead of spawning a subprocess, calls `thumbnail-cache` from `seek()`,
writing into the same overlay file the existing `check_new_thumb()`/`draw()`
pipeline already consumes — so uosc needs no changes. On a stock mpv without the
command it logs a warning and falls back to the normal subprocess thumbnailer.

## Rebuild / test

```
./build_mpv.sh          # re-applies the patch and rebuilds mpv
```

Then play a network item, let a region buffer, and hover the seekbar within the
buffered band — thumbnails appear with no second mpv process (`pgrep -a mpv`
shows only the player) and no spdif interruption.
