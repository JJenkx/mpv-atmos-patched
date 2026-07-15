# mpv-patched for Windows x86_64

Cross-compiled on Arch Linux with mingw-w64 from the same patched sources as the
Linux build: FFmpeg master with the **TrueHD/Atmos MAT padding fix**
(`patches/spdifenc.c`, upstream FFmpeg PR #23542) and the
[JJenkx/mpv fork](https://github.com/JJenkx/mpv/commits/custom) (branch
`custom`) with all streaming features as commits (segmented parallel HTTP,
segmented speed telemetry, unselected-track demux caching, in-process
thumbnail cache, immediate playlist prefetch, Windows heap-trim).

Fully self-contained: every codec/support DLL sits beside `mpv.exe`, and the
config lives in `portable_config/` (mpv's native portable mode — detected
automatically, no launcher script, no environment variables). Neither install
mode reads or writes anything from a system FFmpeg/codec installation.

## Files

| Path | What |
|---|---|
| `dist-win/` | the complete runnable payload (4 exes + 45 DLLs + `portable_config/`) |
| `installer/Output/mpv-patched-setup.exe` | the installer (System **or** Portable mode) |
| `build_mpv_windows.sh` | rebuilds everything from source (resumable; `FORCE_REBUILD=1` for clean) |
| `collect_dlls.sh` | re-assembles `dist-win/` from the `mpv-win/` prefix + audits DLL closure |
| `build_installer.sh` | recompiles the installer under Wine |
| `windows_config/portable_config/` | the Windows config source of truth (edit here, then re-run `collect_dlls.sh`) |

## Install modes

- **System install**: Program Files, Start menu, appears in Windows *Default apps*
  for common media extensions (without stealing existing defaults), uninstaller.
  `portable_config/` (and only it) is made user-writable so watch-later/shader
  cache work for non-admin users.
- **Portable install**: pure extraction to any folder; zero registry writes, no
  uninstaller. `dist-win/` itself is also directly runnable/copyable — the
  installer's portable mode produces the same thing.

Silent flags: `/VERYSILENT /PORTABLE=1 /DIR="D:\apps\mpv"`.

## Config notes (what changed vs. the Linux tree)

- `ao=wasapi` + `audio-exclusive=yes` — exclusive mode is required for untouched
  spdif/TrueHD-MAT bitstreaming. Pick your HDMI device via
  `.\mpv.com --audio-device=help` (from PowerShell/cmd in the install folder — use
  `mpv.com`, not `mpv.exe`, or you get no console output) and set `audio-device=`
  in `mpv.conf`.
- IPC: named pipe `\\.\pipe\mpv-socket` (was a Unix socket).
- Launcher flags migrated into `mpv.conf`.
- Shader hotkeys (F1–F4, `\`, `]`) fixed to portable `~~/shaders/` paths
  (they pointed at `~/.config/mpv/...` before and were broken even on Linux).
- **Activated**: `autoload.lua`, `playlistmanager.lua` (were inert at config root).
- **Dropped**: `sponsorblock` (needed Python), `audio_reset.lua` (ALSA-only),
  `Mac_Integration.lua` (macOS-only).
- `autosave.lua` computes watch-later hashes via Windows' built-in `certutil`.
- thumbfast keeps `cache_backend=yes` (your in-process thumbnail-cache patch);
  `direct_io=yes` enabled for the Windows pipe fast path.
- No `hwdec` is set (16-thread software decode, same as Linux). If you want
  hardware decode: `hwdec=auto-copy` is the safe choice under `gpu-api=vulkan`
  (D3D11VA, DXVA2 and NVDEC are all compiled in).
- Renderer: `vo=gpu-next` + `gpu-api=vulkan` (excellent on AMD and Nvidia).
  If a machine has broken Vulkan drivers, set `gpu-api=d3d11` — the D3D11
  backend is compiled in as a fallback.
- **HTTPS**: Windows has no OpenSSL CA store, so Mozilla's CA bundle ships as
  `portable_config/cacert.pem` and `mpv.conf` sets `tls-ca-file=~~/cacert.pem`
  (covers normal streams and the segmented downloader). For standalone
  `ffmpeg.exe`/`ffprobe.exe` HTTPS use, set
  `$env:SSL_CERT_FILE="...\portable_config\cacert.pem"` or pass
  `-ca_file`.

## Verify on real Windows hardware (can't be tested under Wine)

1. **Vulkan rendering**: play any HDR file; check `i` stats show `vulkan` and
   gpu-next; tone-mapping bt.2446a applies.
2. **TrueHD/Atmos passthrough** (the point of the spdifenc patch): WASAPI
   exclusive to your AVR over HDMI; play a TrueHD Atmos track; the receiver
   should light up "Atmos". `audio-spdif=ac3,dts,eac3,dts-hd,truehd` is already set.
3. **Thumbnails**: hover the uosc seekbar — thumbfast must produce thumbs with
   no child mpv process (Task Manager: only one mpv.exe).
4. **Segmented HTTP**: play a large HTTP file; uosc's speed readout should show
   the per-worker download rate (8 chunks configured).
5. **Watch-later in Program Files** (system install, non-admin): quit mid-file,
   reopen, position restores; files appear in `portable_config\watch_later\`.
6. **File associations** (system install): Settings → Default apps → mpv-patched.
7. **IPC**: `Get-ChildItem \\.\pipe\ | findstr mpv` in PowerShell while playing.
8. Shader hotkeys F1–F4 switch chains; `]` cycles the quality presets.

## Rebuilding

```bash
./build_mpv_windows.sh   # resumable; only rebuilds what's missing + FFmpeg/mpv
./collect_dlls.sh        # re-assemble dist-win/ (fails loudly on any missing DLL)
./build_installer.sh     # recompile setup.exe under Wine
```

Upstream drift: the enhanced mpv comes from the fork's `custom` branch, which
only moves when upstream is deliberately merged in (TOOLS/fork-sync-upstream.sh
in the fork). Pin known-good revisions with `MPV_ENHANCED_REF=<commit>
FFMPEG_REF=<commit>` if needed.

Known quirks handled in the scripts (don't "clean up" without reading them):
libiconv ≥1.18 for GCC 15+/C23; explicit `--build` triplet because wine's
binfmt handler makes autoconf think it isn't cross-compiling; vorbis built with
autotools (its cmake passes a `.def` mingw's ld rejects); x265 needs an
unshallowed clone for `git describe`; libarchive keeps CMake modules in
`build/cmake` (never `rm -rf build` there) plus a CMake-4 `CheckHeaderDirent`
shim; rubberband JNI off (host JDK leak); `shaderc.pc` carries `-lstdc++` for
mpv's C-driver link; cmake's libogg is shipped as `ogg.dll` (import-lib name).

`libmpv-2.dll` is built too (in `mpv-win/bin/`) if you ever want to embed the
player; it's not shipped in `dist-win/` because nothing there uses it.
