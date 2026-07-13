# Tuning guide — the custom flags in the Enhanced build

The **Enhanced + Atmos** build adds options that don't exist in upstream mpv.
They're what make network playback (Jellyfin/Plex/HTTP/SMB-over-HTTP, big remuxes)
behave like local playback. This page explains what each one does, and — more
importantly — **how to tune them without blowing up your RAM**.

> These options only exist in the **Enhanced** build. The Stock build will refuse
> to start if you put them in `mpv.conf`.

---

## The flags at a glance

| Option | Default (shipped) | What it does |
|---|---|---|
| `segmented-chunks=<0-16>` | `2` | Number of **parallel download workers**. `0` = off (normal single-connection HTTP). |
| `segment-size=<size>` | `5MiB` | Size of each chunk a worker fetches. Range 64KiB–1GiB. |
| `segment-auto-size=<yes\|no>` | `yes` | Lets chunks grow toward your demuxer budget (up to 4× `segment-size`, capped at a 1 GiB in-flight window). |
| `next-file-prefetch=<yes\|no>` | `yes` | Start downloading the **next playlist item** while the current one plays. |
| `next-file-demuxer-max-bytes-prefetch=<size>` | `256MiB` | How much of the next file to buffer ahead. |
| `next-file-segmented-chunks=<1-16>` | `2` | Workers used for that next-file prefetch. |
| `demuxer-cache-unselected-subs=<yes\|no>` | `yes` | Keep **subtitle** packets cached even for tracks you haven't selected. |
| `demuxer-cache-unselected-audio=<yes\|no>` | `yes` | Same, for **audio** tracks. |

Plus two standard mpv options that matter a lot here:

| Option | Default (shipped) | What it does |
|---|---|---|
| `demuxer-max-bytes` | `512MiB` | **Forward** buffer (how far ahead you're buffered). |
| `demuxer-max-back-bytes` | `512MiB` | **Back** buffer (instant backward seeking without re-downloading). |

---

## Why the unselected-track caching matters (and what it costs)

**The problem it fixes:** stock mpv only caches packets for the tracks you have
*selected*. Switch to a different audio track or turn on subtitles mid-playback and
mpv has nothing cached for it — so it does a "refresh seek" that **throws away your
entire forward buffer** and re-downloads from the current position. On a network
stream that's a multi-second stall every time you touch a track.

With `demuxer-cache-unselected-subs/-audio=yes`, those packets are kept, so
switching tracks is **instant and free**.

**The cost — and this is the part that bites people:** `demuxer-max-bytes` is a cap
on **bytes**, not on seconds. Caching every audio track and every subtitle track
means those bytes are now shared across *many* streams. A remux with 5 audio tracks
and 12 subtitle tracks fills the same 512 MiB budget with a lot of stuff that isn't
video — so you end up buffered **fewer seconds ahead** than you would be otherwise.

The natural reaction is "fine, I'll just raise `demuxer-max-bytes` a lot." That's
exactly how people end up with an mpv that eats all their RAM and freezes the
machine. Which brings us to:

---

## How to size your caches without OOM-ing yourself

### The memory actually adds up like this

```
peak RSS  ≈  demuxer-max-bytes                     (forward buffer, current file)
          +  demuxer-max-back-bytes                (back buffer, current file)
          +  next-file-demuxer-max-bytes-prefetch  (the NEXT file, buffered at the same time)
          +  segment buffers in flight             (segmented-chunks × chunk size, ≤ ~1 GiB)
          +  decoder / video-output / general overhead
```

Two things people miss:

1. **The back buffer is not free.** `demuxer-max-back-bytes=512MiB` is another
   512 MiB, on top of the forward buffer. Forward + back = 1 GiB before anything else.
2. **Next-file prefetch means two files are in memory at once.** The worst moment
   isn't mid-file — it's just before a playlist transition, when the current file is
   fully buffered *and* the next one is being prefetched.

With the shipped defaults that's `512 + 512 + 256` ≈ **1.25 GiB**, plus segments and
overhead. Now imagine someone sets `demuxer-max-bytes=8GiB` and
`demuxer-max-back-bytes=8GiB` "because I have 32 GB": that's 16 GiB of buffers plus
a prefetching next file — and when it goes over, Linux starts swapping and the whole
desktop locks up.

### The method: increment upward, measure, stop early

**Don't guess. Measure — and creep up on it.**

1. **Pick a worst-case test file.** The highest-bitrate thing you actually watch (a
   UHD remux at 80–100 Mbps), and specifically one with **many audio and subtitle
   tracks** — because unselected-track caching is what inflates memory per second
   buffered. Testing with a 5 Mbps single-track file tells you nothing.

2. **Start at the shipped defaults** (512 / 512 / 256). Don't start high and walk
   back — a bad value can hard-freeze the machine, and you learn nothing.

3. **Measure peak RSS at the two worst moments:**
   - mid-file, once the forward *and* back buffers are both full;
   - **across a playlist transition**, where current + prefetched next both sit in RAM.

   *Linux:* `watch -n1 'ps -o rss=,comm= -C mpv'` (RSS is in KiB), or just watch mpv
   in `htop`.
   *Windows:* Task Manager → Details tab → **Working set** / Memory column for
   `mpv.exe`.
   In mpv itself, press **`i`** for the stats overlay to see live demuxer cache
   usage (bytes buffered and seconds ahead).

4. **Double ONE value at a time**, then re-measure:
   `demuxer-max-bytes`: 512MiB → 1GiB → 2GiB → 4GiB …
   Changing several at once means you won't know which one hurt.

5. **Stop when peak RSS reaches ~50% of your physical RAM.** Leave real headroom —
   your OS, page cache, GPU driver, and browser all need memory too. Going over
   doesn't give a clean error; it pushes you into swap and can **freeze the whole
   machine**. Buffering 10 minutes ahead instead of 3 is not worth that.

6. **Verify it's stable over a long playlist.** Play 5–10 files back-to-back and
   confirm RSS **returns to baseline between files** instead of climbing.

> **On the RAM ratchet:** older builds had a real bug where memory climbed with every
> file played (glibc kept handing each new worker thread its own arena and never gave
> it back), which is how you'd wake up to a frozen machine after a night of playback.
> That's fixed in these builds (the tuning is compiled into the binary). So if you
> *do* see RSS ratcheting upward across files and never coming back down —
> that's a bug, please [open an issue](https://github.com/JJenkx/mpv-atmos-patched/issues).

### A sane starting point by RAM size

| System RAM | forward | back | next-file prefetch | rough peak |
|---|---|---|---|---|
| 8 GB | `512MiB` | `256MiB` | `128MiB` | ~1 GB |
| 16 GB | `1GiB` | `512MiB` | `256MiB` | ~2 GB |
| 32 GB | `2GiB` | `1GiB` | `512MiB` | ~4 GB |
| 64 GB+ | `4GiB` | `2GiB` | `1GiB` | ~8 GB |

These are deliberately conservative. Climb from here **only if you measured** and you
actually needed more.

---

## Segmented workers: how they make the buffer fill faster

### Why one connection is slow

Normal mpv opens **one** HTTP connection and reads the file sequentially. That single
stream's speed is limited by things that have nothing to do with your internet plan:

- **Latency (bandwidth-delay product).** A single TCP connection can only have so much
  data in flight before it must wait for acknowledgements. Over a 100 ms round-trip, one
  connection may only manage a fraction of your line rate no matter how fast your ISP is.
- **Per-connection throttling.** Lots of servers, CDNs, and seedbox/Jellyfin hosts cap
  the throughput of *each individual connection* — but not your total.

So you can be on a gigabit line and still watch a single-connection stream trickle in
at 8 MB/s, buffering slower than the movie plays.

### What the segmented downloader does

It splits the file into `segment-size` chunks and downloads **`segmented-chunks` of
them at the same time** on separate connections, reassembling them in order. When the
bottleneck is *per-connection* (latency or server throttle) rather than your actual
line, N workers gets you roughly **N× the throughput**.

**Why that matters for the buffer:** a big cache is useless if you can never fill it.

> A 4 GiB forward buffer at **8 MB/s** takes **~8.5 minutes** to fill.
> The same buffer at **40 MB/s** fills in **under 2 minutes**.

A buffer that fills fast means: it actually reaches full, so you can ride out network
dips; seeking recovers in seconds instead of stalling; and next-file prefetch finishes
before you get there.

### How to tune it (you can watch it live)

This build **exposes the real download rate** — the per-worker and combined throughput
of the segmented downloader — on the **uosc seek bar** and in the stats overlay
(`i`). That's not the same as mpv's usual `cache-speed`; it's the true network rate.
So you can tune this empirically instead of guessing:

1. Play a large network file and note the **combined rate** at `segmented-chunks=2`.
2. Raise it: **2 → 4 → 8**, watching the combined rate each time.
3. **Stop when the combined rate stops improving.** That plateau is your real ceiling
   (either your line, or the server's total cap). Then back off one step — extra
   workers past the plateau buy you nothing and cost RAM and sockets.

**Cautions:**
- More workers = more chunks in flight = **more RAM** (and more open sockets).
- Some servers **rate-limit or ban** aggressive parallel range requests. If throughput
  gets *worse* or connections start failing, back off.
- If a single connection **already saturates your line**, more workers gain you nothing.
  Segmentation helps when the *per-connection* limit is the bottleneck — not when your
  own bandwidth is.
- Maximum is **16**. Most people find the sweet spot at **4–8**.

### `segment-size` and `segment-auto-size`

- **`segment-size`** (default `5MiB`): bigger chunks = fewer requests and less
  per-request overhead, but coarser parallelism and more memory in flight. Smaller
  chunks = quicker to start and lighter on RAM, but more request overhead.
- **`segment-auto-size=yes`** (default): lets chunks grow toward your demuxer budget
  automatically — up to 4× your `segment-size`, and never past a ~1 GiB total in-flight
  window. Leave this on unless you're deliberately capping memory; it means a large
  cache gets filled with efficient large reads without you hand-tuning chunk size.

### `next-file-segmented-chunks`

Workers used to prefetch the **next** playlist item (default `2`). **Keep this low.**
The next file is a nice-to-have; the file you're *actually watching* should get the
bandwidth. If you set this as high as `segmented-chunks`, the prefetch will compete
with playback and can cause the current file to stall. `1`–`2` is right.

---

## Quick recipes

**"Playback stutters, buffer never fills"** → raise `segmented-chunks` (4, then 8) and
watch the combined rate on the seek bar. This is a *throughput* problem, not a cache
size problem — a bigger cache won't help if you can't fill it.

**"Switching audio/subtitle tracks stalls for seconds"** → that's stock mpv behaviour;
make sure `demuxer-cache-unselected-audio=yes` and `demuxer-cache-unselected-subs=yes`
(they're on by default in the Enhanced build).

**"Gaps between playlist items"** → `next-file-prefetch=yes` and raise
`next-file-demuxer-max-bytes-prefetch` (but remember it's added to your peak RAM).

**"mpv is using way too much RAM / froze my PC"** → you almost certainly stacked
`demuxer-max-bytes` + `demuxer-max-back-bytes` + prefetch. Go back to the defaults and
follow the increment-and-measure method above.
