#!/usr/bin/env bash
# mpv_patched.sh — portable MPV launcher for Arch KDE Wayland
# Forces Wayland app-id / X11 WM_CLASS to "mpv-patched"
# Forces mpv to use the portable config dir (MPV_HOME / --config-dir) so it’s fully relocatable.

set -euo pipefail

APPDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MPV_ROOT="$APPDIR/mpv"
MPV_BIN="$MPV_ROOT/bin/mpv"
MPV_CONFIG="$APPDIR/mpv.config"

# ── Sanity checks ─────────────────────────────────────────────────────
if [[ ! -x "$MPV_BIN" ]]; then
  printf '\033[1;31m[mpv]\033[0m Not found or not executable: %s\n' "$MPV_BIN" >&2
  exit 1
fi

# ── Portable env (critical for thumbfast child mpv + relocatability) ──
# Make sure 'mpv' resolves to our portable binary first
export PATH="${MPV_ROOT}/bin:${PATH-}"
# Portable shared libs for mpv/ffmpeg
export LD_LIBRARY_PATH="${MPV_ROOT}/lib:${LD_LIBRARY_PATH-}"

# Force mpv to use the portable config instead of ~/.config/mpv
export MPV_HOME="$MPV_ROOT"
export XDG_CONFIG_HOME="$MPV_CONFIG"

# Lua paths (portable)
export LUA_PATH="${MPV_ROOT}/share/lua/5.1/?.lua;${MPV_ROOT}/share/lua/5.1/?/init.lua;${MPV_ROOT}/share/lua/5.2/?.lua;${MPV_ROOT}/share/lua/5.2/?/init.lua;${LUA_PATH-}"
export LUA_CPATH="${MPV_ROOT}/lib/lua/5.1/?.so;${MPV_ROOT}/lib/lua/5.2/?.so;${LUA_CPATH-}"

EXTRA_FLAGS=()

# Allow a one-off forced title if desired
[[ -n "${MPV_FORCE_TITLE-}" ]] && EXTRA_FLAGS+=( --force-media-title="$MPV_FORCE_TITLE" )

# Playlist mode
if [[ "${MPV_PLAYLIST:-0}" = "1" && $# -ge 1 ]]; then
  set -- --playlist "$1" "${@:2}"
fi

LOCK_TITLE_LUA="$APPDIR/app_config/lock-title.lua"

# Hardcode IDs
APP_ID="mpv-patched"

# NOTE: --config=yes and --config-dir="$MPV_ROOT" ensure portable config is used.
exec "$MPV_BIN" \
  --config=yes \
  --config-dir="$MPV_CONFIG" \
  --watch-later-dir="$MPV_CONFIG/watch_later" \
  --gpu-shader-cache-dir="$MPV_CONFIG/shader_cache" \
  --icc-cache-dir="$MPV_CONFIG/icc_cache" \
  --reset-on-next-file=force-media-title \
  --wayland-app-id="$APP_ID" \
  --x11-name="$APP_ID" \
  ${LOCK_TITLE_LUA:+--script="$LOCK_TITLE_LUA"} \
  --input-ipc-server="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mpv.sock" \
  "${EXTRA_FLAGS[@]}" \
  "$@"
