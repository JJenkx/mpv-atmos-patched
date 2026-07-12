#!/usr/bin/env bash
# Apply the demuxer sub-track cache patch to an mpv source tree.
#
# Usage: apply_demux_cache_unselected_subs.sh <mpv-src-dir>
#
# Adds --demuxer-cache-unselected-subs (default yes): subtitle-track packets
# are cached even while the track is deselected (network/seekable-cache
# playback only), so enabling or switching subtitle tracks reuses the cached
# packets instead of issuing a refresh seek that drops the whole forward
# cache and forces the readahead to be re-downloaded.
# Idempotent: skips if the option is already present; fails loudly if the
# git patch no longer applies so the build stops instead of silently
# producing an unpatched mpv.
set -Eeuo pipefail

MPV_SRC="${1:?usage: apply_demux_cache_unselected_subs.sh <mpv-src-dir>}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$PATCH_DIR/demux_cache_unselected_subs.patch"

[ -f "$PATCH" ] || { echo "!! missing $PATCH"; exit 1; }
[ -f "$MPV_SRC/demux/demux.c" ] || { echo "!! $MPV_SRC is not an mpv tree"; exit 1; }

if grep -qF 'demuxer-cache-unselected-subs' "$MPV_SRC/demux/demux.c"; then
  echo "==> demux cache-unselected-subs patch already applied; skipping"
  exit 0
fi

if git -C "$MPV_SRC" apply --check "$PATCH" 2>/dev/null; then
  git -C "$MPV_SRC" apply "$PATCH"
  echo "==> applied demux_cache_unselected_subs.patch"
else
  echo "!! demux_cache_unselected_subs.patch no longer applies (upstream demux.c changed; patch needs rebasing)"
  exit 1
fi
