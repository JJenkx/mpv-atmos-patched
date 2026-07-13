#!/usr/bin/env bash
# build_info.sh <prefix-dir> <linux|windows> <stock|enhanced> [recipe-commit]
#
# Prints the exact upstream versions this build was compiled from, read straight
# out of the source trees that were actually built (not from a remote lookup), so
# the record can't drift from the binary. Shipped inside every artifact as
# BUILD-INFO.txt and used to compose the GitHub Release notes.
set -Eeuo pipefail

PFX="${1:?usage: build_info.sh <prefix> <platform> <variant> [recipe-commit]}"
PLATFORM="${2:?platform}"
VARIANT="${3:?variant}"
RECIPE="${4:-unknown}"

# describe a git checkout: prefer a human tag/describe, always include the sha
gitver() {
  local d="$1"
  [ -d "$d/.git" ] || { echo "unknown"; return 0; }
  # -c safe.directory: the build may run as a different user than the caller
  # (e.g. root inside the container), which would otherwise trip git's
  # "dubious ownership" check and silently report "unknown".
  local g=(git -c "safe.directory=$d" -C "$d")
  # shallow clones have no tags; try to pull them so describe can work (best-effort)
  "${g[@]}" fetch --tags --depth=1 origin >/dev/null 2>&1 || true
  local sha desc
  sha="$("${g[@]}" rev-parse HEAD 2>/dev/null || echo unknown)"
  desc="$("${g[@]}" describe --tags --always 2>/dev/null || true)"
  if [ -n "$desc" ] && [ "$desc" != "${sha:0:7}" ]; then
    echo "$desc  ($sha)"
  else
    echo "$sha"
  fi
}

MPV_V="$(gitver "$PFX/src/mpv")"
FF_V="$(gitver "$PFX/src/ffmpeg")"
PL_V="$(gitver "$PFX/src/libplacebo")"

# Fail loudly rather than shipping a release that claims "unknown" upstream
# versions — the whole point of this file is that it is verifiable.
if [ "$MPV_V" = unknown ] || [ "$FF_V" = unknown ]; then
  echo "!! build_info: could not read upstream versions from '$PFX/src'" >&2
  echo "!!   mpv=$MPV_V ffmpeg=$FF_V (is the prefix correct, and run after the build?)" >&2
  exit 1
fi

# FFmpeg's configure bakes a readable version string into ffbuild/config.h;
# prefer it, falling back to the raw commit.
FF_PRETTY="$(sed -n 's/^#define FFMPEG_VERSION "\(.*\)"$/\1/p' \
  "$PFX/src/ffmpeg/ffbuild/config.h" 2>/dev/null | head -1 || true)"
FF_LINE="$FF_V"
[ -n "$FF_PRETTY" ] && FF_LINE="$FF_PRETTY  ($FF_V)"

cat <<EOF
mpv-atmos-patched — ${VARIANT} / ${PLATFORM}
built:        $(date -u '+%Y-%m-%d %H:%M UTC')
build recipe: ${RECIPE}

Upstream sources this binary was compiled from:
  mpv:        ${MPV_V}
  FFmpeg:     ${FF_LINE}
  libplacebo: ${PL_V}
EOF
