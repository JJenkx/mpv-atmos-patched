# mpv-atmos-patched

> ### 🤖 Heads up: this is 100% vibe coded with Claude
> The patches, build scripts, packaging and CI in this repo were all written with
> AI assistance. It works and the binaries are tested, but I'm one person with a
> receiver and a lot of enthusiasm — not a team of maintainers.
>
> **If you hit an issue, or have a suggestion, please tell me** — open an
> [issue](https://github.com/JJenkx/mpv-atmos-patched/issues). Bug reports,
> "this broke on my distro", config improvements, code review of the patches:
> all genuinely welcome.

Portable, self-contained builds of [mpv](https://mpv.io) with **TrueHD / Dolby
Atmos (MAT) bitstream passthrough** compiled in — for **Linux** and **Windows**,
built entirely in the open on GitHub Actions from the source in this repository.

Every build bundles its own patched FFmpeg and all codec libraries, so it depends
on nothing already installed on your system and can't be broken by a system
update. Nothing here reads or writes a system FFmpeg/codec install.

---

## Which build should I download?

There are **two variants**, each available for Linux and Windows. Both include the
Atmos/TrueHD patch — that's the whole point of the project. They differ only in
whether the extra streaming features are compiled in.

| | **Stock + Atmos** | **Enhanced + Atmos** |
|---|---|---|
| Base | Stock mpv + stock FFmpeg | Stock mpv + FFmpeg + custom patches |
| TrueHD/Atmos (MAT) passthrough | ✅ | ✅ |
| Segmented parallel HTTP downloading | — | ✅ |
| Live download-speed telemetry (uosc) | — | ✅ |
| Unselected sub/audio track demux-caching | — | ✅ |
| In-process (fork-free) seekbar thumbnails | — | ✅ |
| Next-file prefetch | — | ✅ |
| Flat-RAM tuning for long playlists | — | ✅ |
| Closest to upstream mpv | ✅ | |

- **Pick "Stock + Atmos"** if you just want a normal, upstream-faithful mpv that
  can bitstream TrueHD/Atmos to your AVR, with the smallest possible deviation
  from official mpv.
- **Pick "Enhanced + Atmos"** if you also want the network-streaming
  improvements (parallel segmented downloading, prefetch, in-buffer thumbnails,
  flat memory use over long playlists).

> 📖 **Using the Enhanced build? Read [TUNING.md](TUNING.md).** It explains what each
> custom flag does, how **more segmented workers fill your buffer faster** (and how to
> find your ceiling using the live download-rate readout), and — importantly — **how to
> raise the cache sizes incrementally and measure RAM** instead of setting them huge and
> freezing your machine.

> The **Atmos/TrueHD passthrough** comes from a patch to FFmpeg's `spdifenc` and is
> present in **both** variants. It is independent of AAC — no nonfree codecs are
> involved. See below for what it actually does.

---

## What the Atmos fix actually is (the Kodi MAT packer)

**Short version: this is Kodi's MAT packer implementation, ported into FFmpeg.**

To send Dolby TrueHD / Atmos to a receiver untouched, the bitstream has to be wrapped
in **MAT** (Metadata-enhanced Audio Transmission) frames and then in IEC 61937 framing
— that's the container HDMI uses to carry TrueHD to an AVR. FFmpeg does this in
`libavformat/spdifenc.c`.

**The problem with upstream FFmpeg:** its TrueHD path packs each frame into a
fixed-size MAT container using a **small ring of output buffers**. A single call can
emit *several* MAT frames, which can clobber a buffer that hasn't been sent yet. The
result is the flaky TrueHD/Atmos passthrough people run into — dropouts, receivers
that won't lock on, or audio that falls apart under timing pressure.

**Kodi solved this years ago.** Its `CPackerMAT` uses a **FIFO output model** instead:
one working buffer is assembled, each completed MAT frame is pushed onto a queue, and
exactly one frame is drained per output call — so nothing is ever overwritten in
flight. It also **pads through timing gaps** rather than resetting the packer on them,
which is what keeps a receiver locked during discontinuities.

This build ports that model into FFmpeg's `spdifenc.c`: the TrueHD path is rebuilt
around an `AVFifo` of completed MAT frames, following Kodi's `CPackerMAT`. The MAT
padding math is preserved. Everything else in `spdifenc.c` (AC3, DTS, E-AC3, DTS-HD…)
is untouched upstream code.

The patch is [`patches/spdifenc.c`](patches/spdifenc.c) — a drop-in replacement for
FFmpeg's file, applied to **both** the stock and enhanced builds. It's the whole
reason this project exists.

> **Attribution / licensing:** the MAT FIFO model is derived from
> [Kodi](https://github.com/xbmc/xbmc)'s `CPackerMAT` (GPL-2.0-or-later). FFmpeg's
> `spdifenc.c` is LGPL-2.1-or-later. These builds are distributed as **GPLv3**, which
> is compatible with both. Credit for the approach belongs to the Kodi project.

---

## Downloads (always-current latest release)

> Links point at the newest published release and update automatically. If a link
> 404s, the first release hasn't finished building yet — see
> [Releases](https://github.com/JJenkx/mpv-atmos-patched/releases) and
> [Actions](https://github.com/JJenkx/mpv-atmos-patched/actions).

### Linux (x86_64)

| Variant | AppImage (single file) | Tarball (extract & run) |
|---|---|---|
| **Enhanced + Atmos** | [`mpv-atmos-enhanced-linux-x86_64.AppImage`](https://github.com/JJenkx/mpv-atmos-patched/releases/latest/download/mpv-atmos-enhanced-linux-x86_64.AppImage) | [`mpv-atmos-enhanced-linux-x86_64.tar.xz`](https://github.com/JJenkx/mpv-atmos-patched/releases/latest/download/mpv-atmos-enhanced-linux-x86_64.tar.xz) |
| **Stock + Atmos** | [`mpv-atmos-stock-linux-x86_64.AppImage`](https://github.com/JJenkx/mpv-atmos-patched/releases/latest/download/mpv-atmos-stock-linux-x86_64.AppImage) | [`mpv-atmos-stock-linux-x86_64.tar.xz`](https://github.com/JJenkx/mpv-atmos-patched/releases/latest/download/mpv-atmos-stock-linux-x86_64.tar.xz) |

**AppImage:** `chmod +x mpv-atmos-*.AppImage && ./mpv-atmos-*.AppImage <file>`
**Tarball:** `tar xf mpv-atmos-*.tar.xz && ./mpv/bin/mpv <file>`

### Windows (x86_64)

| Variant | Portable ZIP |
|---|---|
| **Enhanced + Atmos** | [`mpv-atmos-enhanced-windows-x86_64.zip`](https://github.com/JJenkx/mpv-atmos-patched/releases/latest/download/mpv-atmos-enhanced-windows-x86_64.zip) |
| **Stock + Atmos** | [`mpv-atmos-stock-windows-x86_64.zip`](https://github.com/JJenkx/mpv-atmos-patched/releases/latest/download/mpv-atmos-stock-windows-x86_64.zip) |

**Windows:** unzip anywhere and run **`mpv.exe`** (or drag a video onto it). Fully
portable — config lives in `portable_config\` next to the exe; no installer, no
registry writes.

> 💡 **For anything on the command line, use `mpv.com`, not `mpv.exe`.**
> `mpv.exe` is the windowed player and prints **nothing** to the console. `mpv.com`
> is the identical player *with* console output. Open PowerShell in the folder
> (Shift + Right-click → *Open in Terminal*) and run e.g.:
> ```powershell
> .\mpv.com --audio-device=help     # list audio devices
> .\mpv.com --version               # version / build info
> .\mpv.com "C:\path\to\movie.mkv"  # play, with log output visible
> ```

---

## Why you can trust these binaries

- **The source is right here.** Every patch is a readable file in
  [`patches/`](patches/); the entire build is
  [`build_mpv.sh`](build_mpv.sh) (Linux) and
  [`build_mpv_windows.sh`](build_mpv_windows.sh) (Windows).
- **The binaries are built in the open.** They are compiled by GitHub Actions,
  not uploaded from anyone's laptop. Every release's build log is public under
  [Actions](https://github.com/JJenkx/mpv-atmos-patched/actions) — you can read
  every command that produced the file you downloaded.
- **Cryptographic provenance.** Each release asset carries a signed
  [build-provenance attestation](https://github.com/JJenkx/mpv-atmos-patched/attestations)
  linking it to the exact commit and workflow run that built it. Verify a
  download with:
  ```bash
  gh attestation verify mpv-atmos-enhanced-linux-x86_64.AppImage \
     --repo JJenkx/mpv-atmos-patched
  ```
- **Pinned upstream.** Each release records the exact mpv and FFmpeg commits it
  was built from in the release notes.

---

## Configuration

Each build ships a small, curated `portable_config/mpv.conf` with sensible
streaming defaults (the **enhanced** build additionally enables its patched
options — segmented downloading, next-file prefetch, unselected-track caching).

> ### 🔊 Turning on TrueHD/Atmos passthrough (2-minute setup)
> Bitstreaming HD audio to a receiver is the point of this build, but it **ships
> off**, because passthrough only works when it's aimed at *your* HDMI/AVR device —
> and your AVR is almost never the system's default audio device. Enabling it
> blindly doesn't just fail silently; on Linux, exclusive-mode spdif sent to the
> wrong device **can hang your machine hard enough that it won't even reboot.**
>
> So it's one deliberate step — see below. **No receiver?** Change nothing; you get
> normal PCM audio out of the box.

### Requirements

**Windows:** none. Unzip and run — everything is in the folder.

**Linux:** on a normal desktop, **nothing to install.** The build bundles its own
FFmpeg, codecs, libass, OpenSSL, wayland, etc.

It deliberately does *not* bundle libraries that must come from **your** system —
your GPU driver links the same ones, and a bundled copy would shadow it and break
your driver. Every desktop already has these, but for the record mpv needs:

| Library | Provided by |
|---|---|
| `libvulkan.so.1` | your GPU driver / Vulkan loader |
| `libGL`, `libEGL`, `libdrm`, `libgbm` | your GPU driver / Mesa |
| `libpulse`, `libasound` | your sound server (PulseAudio/PipeWire, ALSA) |
| X11 / XCB / `libxkbcommon` | your desktop |
| glibc, `libstdc++` | your system |

If mpv exits with something like `libvulkan.so.1: cannot open shared object file`
(only likely on a *minimal* or headless install), install the missing bits:

```bash
# Debian / Ubuntu
sudo apt install libvulkan1 libpulse0 libasound2 libgl1 libegl1

# Fedora
sudo dnf install vulkan-loader pulseaudio-libs alsa-lib mesa-libGL mesa-libEGL

# Arch
sudo pacman -S vulkan-icd-loader libpulse alsa-lib libglvnd
```

### Enabling passthrough — Windows

1. **Open PowerShell** (or Command Prompt) **in the folder you unzipped.**
   Easiest way: in Explorer, **Shift + Right-click** the folder →
   *"Open PowerShell window here"* / *"Open in Terminal"*. Or type it:
   ```powershell
   cd "C:\path\to\mpv-atmos-enhanced-windows-x86_64"
   ```
2. **List your audio devices:**
   ```powershell
   .\mpv.com --audio-device=help
   ```
   > ⚠️ Use **`mpv.com`**, not `mpv.exe`. `mpv.exe` is the windowed player and prints
   > **nothing** to the console — `mpv.com` is the same player *with* console output,
   > so it's the one that will actually show you the list. The same applies to any
   > command-line use (`.\mpv.com --version`, `.\mpv.com "C:\movie.mkv"`, etc.).

   You'll see lines like `'wasapi/{0.0.1.00000000}.{9a8b…}' (Denon-AVR …)`. Copy the
   whole `wasapi/{…}` part for your receiver.
3. **Edit `portable_config\mpv.conf`** (Notepad is fine): paste your device into the
   `audio-device=` line, then **remove the leading `#`** from that line *and* from
   `ao=`, `audio-channels=`, `audio-exclusive=`, `audio-spdif=`, `audio-buffer=`.
4. **Test:** `.\mpv.com "C:\path\to\movie.mkv"` — your receiver should display
   *Atmos / TrueHD / DTS-HD*. Press **`i`** in mpv for the stats overlay.

### Enabling passthrough — Linux

1. Open a terminal in the extracted folder:
   ```bash
   cd ~/Downloads/mpv-atmos-enhanced-linux-x86_64
   ```
2. List your audio devices:
   ```bash
   ./mpv --audio-device=help
   ```
   (Or `aplay -L`, `aplay -l`, `pactl list sinks short`.) Look for your HDMI/AVR
   output, e.g. `alsa/hdmi:CARD=HDMI,DEV=0`.
3. Edit `portable_config/mpv.conf`: paste it into `audio-device=`, then uncomment
   that line *and* `ao=`, `audio-channels=`, `audio-exclusive=`, `audio-spdif=`,
   `audio-buffer=`.
4. Test: `./mpv /path/to/movie.mkv` — your receiver should display the format.

The `mpv.conf` in your download walks you through all of this too, with the exact
lines to uncomment.

The maintainer's full personal `mpv.conf` and `input.conf` ride along as
`mpv.conf.example` / `input.conf.example` for reference — copy what you like.
uosc, thumbnails, and a curated set of upscaling shaders are bundled and active.

## Licensing

These public builds are **GPLv3** and are freely redistributable. They are
configured **without** `--enable-nonfree` / `libfdk-aac` (FFmpeg's native AAC
decoder is used instead — lossless for playback), so there are no
non-redistributable components. The corresponding source is this repository plus
the pinned upstream mpv/FFmpeg commits.

They contain GPL components (x264, x265). H.264/H.265 and other codecs may be
covered by patents in some jurisdictions; you are responsible for your own use.

---

## Building it yourself

```bash
# Linux, enhanced variant, redistributable config:
VARIANT=enhanced DISTRIBUTABLE=1 ./build_mpv.sh

# Linux, stock variant:
VARIANT=stock    DISTRIBUTABLE=1 ./build_mpv.sh

# Windows cross-build (mingw-w64), enhanced:
VARIANT=enhanced DISTRIBUTABLE=1 ./build_mpv_windows.sh && ./collect_dlls.sh
```

- `VARIANT` = `enhanced` (default) or `stock`.
- `DISTRIBUTABLE=1` produces the redistributable GPLv3 config used for releases.
  Omit it (default `0`) for a personal build that additionally enables
  `nonfree`/`libfdk-aac` — **do not redistribute that binary.**

See [`README-WINDOWS.md`](README-WINDOWS.md) for Windows build details and
config notes.

---

*mpv is licensed GPLv2+/LGPL; FFmpeg LGPL/GPL. This project distributes patched
builds of both under GPLv3. It is not affiliated with the upstream mpv or FFmpeg
projects, or with Dolby.*
