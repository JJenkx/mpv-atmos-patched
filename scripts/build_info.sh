#!/usr/bin/env bash
# build_info.sh <prefix-dir> <linux|windows> <stock|enhanced> [recipe-commit]
#
# Prints the exact versions this build was compiled from, read straight out of the
# source trees and install prefix that were actually built — never from a remote
# lookup — so the record cannot drift from the binary. Shipped inside every
# artifact as BUILD-INFO.txt and used to compose the GitHub Release notes.
set -Eeuo pipefail

PFX="${1:?usage: build_info.sh <prefix> <platform> <variant> [recipe-commit]}"
PLATFORM="${2:?platform}"
VARIANT="${3:?variant}"
RECIPE="${4:-unknown}"

SRC="$PFX/src"
PC="$PFX/lib/pkgconfig"

# ── helpers ───────────────────────────────────────────────────────────────────

# short commit of a source tree (-c safe.directory: the build may run as root)
gitsha() {
  local d="$SRC/$1"
  [ -d "$d/.git" ] || { echo ""; return 0; }
  git -c "safe.directory=$d" -C "$d" rev-parse --short=12 HEAD 2>/dev/null || echo ""
}

# Version: field from a .pc file, but ONLY if it is a real dotted version.
# Several projects ship junk here (x264 "0.165.x", x265 "265", opus "0",
# luajit "${version}"), so those fall back to the git commit instead.
pcver() {
  local v
  v="$(sed -n 's/^Version:[[:space:]]*//p' "$PC/$1.pc" 2>/dev/null | head -1)"
  [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*$ ]] && echo "$v" || echo ""
}

# best-effort version for a dep: pkg-config version, else git commit
ver() { # <pc-name> <src-dir>
  local v; v="$(pcver "$1")"
  [ -n "$v" ] && { echo "$v"; return 0; }
  local s; s="$(gitsha "${2:-$1}")"
  [ -n "$s" ] && echo "git $s" || echo "unknown"
}

row() { printf '  %-16s %s\n' "$1" "$2"; }
# only print a row if we actually resolved a version (e.g. dav1d is Windows-only)
rowif() { [ "$2" = unknown ] || row "$1" "$2"; }

# ── core versions ─────────────────────────────────────────────────────────────

# mpv bakes its version string into a generated header during the build
MPV_V="$(grep -rhoE '"v[0-9][^"]*"' "$SRC"/mpv/build/*/version.h 2>/dev/null \
         | head -1 | tr -d '"')"
[ -n "$MPV_V" ] || MPV_V="git $(gitsha mpv)"

# FFmpeg bakes its version string into libavutil/ffversion.h
FF_V="$(sed -n 's/^#define FFMPEG_VERSION "\(.*\)"$/\1/p' \
        "$SRC/ffmpeg/libavutil/ffversion.h" 2>/dev/null | head -1)"
[ -n "$FF_V" ] || FF_V="git $(gitsha ffmpeg)"

MPV_SHA="$(gitsha mpv)"; FF_SHA="$(gitsha ffmpeg)"

# Fail loudly rather than shipping a release that claims "unknown" versions —
# the entire point of this file is that it is verifiable.
if [ -z "$MPV_SHA" ] || [ -z "$FF_SHA" ]; then
  echo "!! build_info: could not read upstream versions from '$SRC'" >&2
  echo "!!   mpv='$MPV_SHA' ffmpeg='$FF_SHA' (correct prefix? run after the build?)" >&2
  exit 1
fi

# ── output ────────────────────────────────────────────────────────────────────
cat <<EOF
mpv-atmos-patched — ${VARIANT} / ${PLATFORM}
built:        $(date -u '+%Y-%m-%d %H:%M UTC')
build recipe: ${RECIPE}

═══ Core ═══════════════════════════════════════════════════════════════════════
EOF
row "mpv"        "${MPV_V}   (${MPV_SHA})"
row "FFmpeg"     "${FF_V}   (${FF_SHA})"
row "libplacebo" "$(ver libplacebo)   ($(gitsha libplacebo))"

echo
echo "═══ FFmpeg libraries ═══════════════════════════════════════════════════════════"
for l in libavcodec libavformat libavutil libavfilter libavdevice libswresample libswscale; do
  v="$(pcver "$l")"; [ -n "$v" ] && row "$l" "$v"
done

echo
echo "═══ Libraries ══════════════════════════════════════════════════════════════════"
row "libass"      "$(ver libass)"
row "harfbuzz"    "$(ver harfbuzz)"
row "fribidi"     "$(ver fribidi)"
row "luajit"      "$(ver luajit)"
row "x264"        "$(ver x264)"
row "x265"        "$(ver x265)"
row   "libvpx"     "$(ver vpx libvpx)"
rowif "dav1d"      "$(ver dav1d)"          # Windows build only
row   "opus"       "$(ver opus opus)"
row   "vorbis"     "$(ver vorbis vorbis)"
row   "ogg"        "$(ver ogg ogg)"
row   "theora"     "$(ver theora theora)"
row   "libwebp"    "$(ver libwebp)"
row   "openjpeg"   "$(ver libopenjp2 openjpeg)"
row "OpenSSL"     "$(ver openssl)"
row "libssh"      "$(ver libssh)"
row "libarchive"  "$(ver libarchive)"
row "libbluray"   "$(ver libbluray)"
row "rubberband"  "$(ver rubberband)"
row "libcdio"     "$(ver libcdio)"
row "libdvdread"  "$(ver dvdread libdvdread)"
row "libdvdnav"   "$(ver dvdnav libdvdnav)"
row "shaderc"     "$(ver shaderc)"
row "Vulkan"      "$(ver vulkan vulkan-headers)"
row "wayland"     "$(ver wayland-client wayland)"

echo
echo "═══ All source commits ═════════════════════════════════════════════════════════"
echo "  (every dependency built from source, for exact reproducibility)"
for d in "$SRC"/*/; do
  n="$(basename "$d")"; s="$(gitsha "$n")"
  [ -n "$s" ] && printf '  %-20s %s\n' "$n" "$s"
done
