#!/usr/bin/env bash
# Apply the in-process, from-buffer thumbnailer (Patch B) to an mpv source tree.
#
# Usage: apply_thumbnail_cache.sh <mpv-src-dir>
#
# Adds a "thumbnail-cache <time> <w> <h> <file>" command that decodes a single
# video frame straight out of the demuxer's seekable cache (already-downloaded
# packets only -- no network I/O, no fork, no disturbance to playback) and
# writes it as raw BGRA for the uosc/thumbfast overlay pipeline. See
# patches/README_thumbnail_cache.md for design and limitations.
#
# Idempotent: re-running is a no-op once applied. Fails loudly if an expected
# anchor is missing (upstream moved) so the build stops instead of silently
# producing an mpv without the feature.
set -Eeuo pipefail

MPV_SRC="${1:?usage: apply_thumbnail_cache.sh <mpv-src-dir>}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$PATCH_DIR/thumbnail_cache"

[ -f "$MPV_SRC/demux/demux.c" ]   || { echo "!! $MPV_SRC is not an mpv tree"; exit 1; }
[ -d "$SRC" ]                     || { echo "!! missing $SRC"; exit 1; }

if grep -qF 'cmd_thumbnail_cache' "$MPV_SRC/player/command.c"; then
  echo "==> thumbnail-cache patch already applied; skipping"
  exit 0
fi

echo "==> copying thumbnail-cache sources"
cp -f "$SRC/thumbnail.c"          "$MPV_SRC/player/thumbnail.c"
cp -f "$SRC/thumbnail.h"          "$MPV_SRC/player/thumbnail.h"
cp -f "$SRC/demux_thumb_cache.c"  "$MPV_SRC/demux/demux_thumb_cache.c"

python3 - "$MPV_SRC" <<'PY'
import sys, io, os

root = sys.argv[1]

def edit(relpath, transform):
    path = os.path.join(root, relpath)
    with io.open(path, "r", encoding="utf-8") as f:
        text = f.read()
    new = transform(text)
    if new is None:
        sys.exit("!! anchor not found in %s (upstream changed; rebase patch)" % relpath)
    if new != text:
        with io.open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print("   patched %s" % relpath)

# 1) demux.c: pull in the cache-extraction helper (needs private structs, so it
#    is textually included at end of the translation unit).
def demux_c(t):
    inc = '#include "demux_thumb_cache.c"'
    if inc in t:
        return t
    return t.rstrip("\n") + "\n\n// Patch B: in-process from-buffer thumbnailer.\n" + inc + "\n"
edit("demux/demux.c", demux_c)

# 2) demux.h: public prototype for the helper.
def demux_h(t):
    if "demux_get_cached_video_packets" in t:
        return t
    anchor = "int demux_get_num_stream(struct demuxer *demuxer);\n"
    if anchor not in t:
        return None
    proto = (anchor +
             "// Patch B: read-only extraction of already-buffered video packets.\n"
             "bool demux_get_cached_video_packets(struct demuxer *demuxer,\n"
             "                                    int stream_index, double pts,\n"
             "                                    struct demux_packet ***out_pkts,\n"
             "                                    int *out_num);\n")
    return t.replace(anchor, proto, 1)
edit("demux/demux.h", demux_h)

# 3) command.c: include header + register the command in the mp_cmds[] table.
def command_c(t):
    if "cmd_thumbnail_cache" in t:
        return t
    inc_anchor = '#include "screenshot.h"\n'
    if inc_anchor not in t:
        return None
    t = t.replace(inc_anchor, inc_anchor + '#include "thumbnail.h"\n', 1)

    tbl_anchor = '    { "loadfile", cmd_loadfile,\n'
    if tbl_anchor not in t:
        return None
    row = (
        '    { "thumbnail-cache", cmd_thumbnail_cache,\n'
        '        {\n'
        '            {"time", OPT_TIME(v.d)},\n'
        '            {"width", OPT_INT(v.i)},\n'
        '            {"height", OPT_INT(v.i)},\n'
        '            {"filename", OPT_STRING(v.s)},\n'
        '        },\n'
        '        .spawn_thread = true,\n'
        '    },\n'
    )
    return t.replace(tbl_anchor, row + tbl_anchor, 1)
edit("player/command.c", command_c)

# 4) meson.build: compile the new source.
def meson(t):
    if "player/thumbnail.c" in t:
        return t
    anchor = "    'player/screenshot.c',\n"
    if anchor not in t:
        return None
    return t.replace(anchor, anchor + "    'player/thumbnail.c',\n", 1)
edit("meson.build", meson)
PY

echo "==> thumbnail-cache patch applied"
