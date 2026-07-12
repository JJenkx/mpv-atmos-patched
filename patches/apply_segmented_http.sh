#!/usr/bin/env bash
# Apply the segmented parallel HTTP download patch to an mpv source tree.
#
# Usage: apply_segmented_http.sh <mpv-src-dir>
#
# Copies stream_segmented_http.c into stream/ and inserts the four small
# hooks (stream registry, meson sources, option group registration) using
# anchored edits. Idempotent: safe to run on an already-patched tree.
# Fails loudly if an upstream anchor moved so the build stops instead of
# silently producing an unpatched mpv.
set -Eeuo pipefail

MPV_SRC="${1:?usage: apply_segmented_http.sh <mpv-src-dir>}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SRC="$PATCH_DIR/stream_segmented_http.c"

[ -f "$MODULE_SRC" ] || { echo "!! missing $MODULE_SRC"; exit 1; }
[ -f "$MPV_SRC/stream/stream.c" ] || { echo "!! $MPV_SRC is not an mpv tree"; exit 1; }

die_anchor() { echo "!! segmented-http patch: anchor not found in $1 (upstream changed; patch needs updating)"; exit 1; }

# insert_after <file> <anchor-substring> <line-to-insert> <already-substring>
# Fixed-string matching throughout (no regex), so C/meson punctuation is safe.
insert_after() {
  local file="$1" anchor="$2" insert="$3" marker="$4"
  grep -qF "$marker" "$file" && return 0
  grep -qF "$anchor" "$file" || die_anchor "$file"
  awk -v anchor="$anchor" -v ins="$insert" '
    { print }
    !done && index($0, anchor) { print ins; done=1 }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

echo "==> Applying segmented parallel HTTP download patch ..."

cp -f "$MODULE_SRC" "$MPV_SRC/stream/stream_segmented_http.c"

# 1. stream/stream.c: declare + register the stream, ahead of stream_lavf
insert_after "$MPV_SRC/stream/stream.c" \
  'extern const stream_info_t stream_info_ffmpeg;' \
  'extern const stream_info_t stream_info_segmented_http;' \
  'stream_info_segmented_http;'
insert_after "$MPV_SRC/stream/stream.c" \
  '    &stream_info_fd,' \
  '    &stream_info_segmented_http,' \
  '&stream_info_segmented_http,'

# 2. meson.build: compile the new module
insert_after "$MPV_SRC/meson.build" \
  "'stream/stream_lavf.c'," \
  "    'stream/stream_segmented_http.c'," \
  'stream_segmented_http.c'

# 3. options/options.c: register the option group (--segmented-chunks etc.)
insert_after "$MPV_SRC/options/options.c" \
  'extern const struct m_sub_options stream_lavf_conf;' \
  'extern const struct m_sub_options stream_segmented_http_conf;' \
  'stream_segmented_http_conf;'
insert_after "$MPV_SRC/options/options.c" \
  'OPT_SUBSTRUCT(stream_lavf_opts, stream_lavf_conf)' \
  '    {"", OPT_SUBSTRUCT(stream_segmented_http_opts, stream_segmented_http_conf)},' \
  'stream_segmented_http_opts, stream_segmented_http_conf'

# 4. options/options.h: MPOpts field backing the substruct
# (upstream renamed the type struct lavf_opts -> struct stream_lavf_opts)
insert_after "$MPV_SRC/options/options.h" \
  'struct stream_lavf_opts *stream_lavf_opts;' \
  '    struct segmented_http_opts *stream_segmented_http_opts;' \
  'segmented_http_opts *stream_segmented_http_opts;'

echo "==> segmented-http patch applied."
