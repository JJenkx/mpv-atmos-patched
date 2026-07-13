# mpv-atmos-patched

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

> The **Atmos/TrueHD passthrough** comes from a patch to FFmpeg's `spdifenc`
> (the MAT FIFO packer) and is present in **both** variants. It is independent of
> AAC — no nonfree codecs are involved.

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

**Windows:** unzip anywhere and run `mpv.exe`. It's fully portable — config lives
in `portable_config\` next to the exe; no installer, no registry writes.

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

> ### ⚠️ TrueHD/Atmos passthrough is ON by default
> These builds bitstream HD audio (TrueHD/Atmos MAT, DTS-HD, E-AC3, AC3, DTS)
> straight to an **AVR/receiver or soundbar over HDMI**, using exclusive-mode audio
> (WASAPI on Windows, ALSA on Linux). That's the point of this project.
>
> **If you do NOT have a receiver** — plain speakers, headphones, laptop or TV
> audio — passthrough won't work and **you may get no sound**. Open
> `portable_config/mpv.conf` and comment out (put `#` in front of) these four
> lines to get normal PCM audio:
> `ao=`, `audio-exclusive=`, `audio-spdif=`, `audio-buffer=`
>
> **If you DO have a receiver:** you'll likely also want to point mpv at the right
> output. Run `mpv --audio-device=help`, find your HDMI/AVR device, and set
> `audio-device=` in `mpv.conf` (it's commented out by default since it differs
> per machine).

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
