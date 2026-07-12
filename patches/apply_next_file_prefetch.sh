#!/usr/bin/env bash
# Apply the next-file prefetch patch to an mpv source tree.
#
# Usage: apply_next_file_prefetch.sh <mpv-src-dir>
#
# Adds player options and core plumbing so the *next* playlist entry is
# demuxer-prefetched from the moment the current file starts playing (instead
# of only near EOF), held cheap during prefetch (a per-instance demuxer cache
# cap + reduced segmented-http parallelism), and ramped to full buffering the
# instant it is promoted to the current playback entry — reusing the already
# buffered data, no stream reopen.
#
# New options (see mpv.conf):
#   --next-file-prefetch=yes|no
#   --next-file-demuxer-max-bytes-prefetch=<size>   (0 = 256MiB default)
#   --next-file-segmented-chunks=<n>   (worker count during prefetch; lives in
#                                       stream_segmented_http_conf, registered
#                                       by apply_segmented_http.sh)
#
# Works together with the segmented-http patch (stream_segmented_http.c reads
# STREAM_PREFETCH / STREAM_CTRL_SEGMENTED_ACTIVATE added here) and honours the
# demuxer-cache-unselected-audio/subs retention automatically, because prefetch
# uses mpv's own demuxer prefetch which selects all tracks.
#
# Anchored + idempotent; fails loudly if an upstream anchor moved so the build
# stops instead of silently producing an unpatched mpv.
set -Eeuo pipefail

MPV_SRC="${1:?usage: apply_next_file_prefetch.sh <mpv-src-dir>}"
PATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$MPV_SRC/stream/stream.c" ] || { echo "!! $MPV_SRC is not an mpv tree"; exit 1; }

die_anchor() { echo "!! next-file-prefetch patch: anchor not found in $1 (upstream changed; patch needs updating): $2"; exit 1; }

BLK="$(mktemp -d)"
trap 'rm -rf "$BLK"' EXIT

# insert_line <file> <exact-anchor-line> <line-to-insert> <already-substr>
insert_line() {
  local file="$1" anchor="$2" ins="$3" marker="$4"
  grep -qF "$marker" "$file" && return 0
  grep -qxF "$anchor" "$file" || die_anchor "$file" "$anchor"
  awk -v anchor="$anchor" -v ins="$ins" '
    { print }
    !done && $0 == anchor { print ins; done=1 }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# insert_block <after|before> <file> <exact-anchor-line> <blockfile> <already-substr>
insert_block() {
  local where="$1" file="$2" anchor="$3" bf="$4" marker="$5"
  grep -qF "$marker" "$file" && return 0
  grep -qxF "$anchor" "$file" || die_anchor "$file" "$anchor"
  awk -v anchor="$anchor" -v bf="$bf" -v where="$where" '
    where=="before" && !done && $0 == anchor {
      while ((getline l < bf) > 0) print l; close(bf); done=1
    }
    { print }
    where=="after" && !done && $0 == anchor {
      while ((getline l < bf) > 0) print l; close(bf); done=1
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# replace_str <file> <substr-old> <substr-new> <already-substr>  (first match)
replace_str() {
  local file="$1" old="$2" new="$3" marker="$4"
  grep -qF "$marker" "$file" && return 0
  grep -qF "$old" "$file" || die_anchor "$file" "$old"
  awk -v old="$old" -v new="$new" '
    !done && index($0, old) {
      i = index($0, old)
      $0 = substr($0, 1, i-1) new substr($0, i+length(old))
      done=1
    }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

echo "==> Applying next-file prefetch patch ..."

# ── stream/stream.h ──────────────────────────────────────────────────────────
# New stream open flag: this stream is a next-file prefetch (start reduced).
insert_line "$MPV_SRC/stream/stream.h" \
  '#define STREAM_ALLOW_PARTIAL_READ (1 << 7) // allows partial read with stream_read_file()' \
  '#define STREAM_PREFETCH           (1 << 8) // opened for next-file playlist prefetch' \
  'STREAM_PREFETCH'
# stream_t flag mirroring it (read by the segmented-http module at open).
insert_line "$MPV_SRC/stream/stream.h" \
  '    bool allow_partial_read : 1; // allows partial read with stream_read_file()' \
  '    bool prefetch : 1; // opened for next-file playlist prefetch' \
  'bool prefetch : 1;'
# Control to switch a prefetch stream to full parallelism on promotion.
insert_line "$MPV_SRC/stream/stream.h" \
  '    STREAM_CTRL_AVSEEK,' \
  '    STREAM_CTRL_SEGMENTED_ACTIVATE,' \
  'STREAM_CTRL_SEGMENTED_ACTIVATE'

# ── stream/stream.c ──────────────────────────────────────────────────────────
insert_line "$MPV_SRC/stream/stream.c" \
  '    s->allow_partial_read = flags & STREAM_ALLOW_PARTIAL_READ;' \
  '    s->prefetch = flags & STREAM_PREFETCH;' \
  's->prefetch = flags & STREAM_PREFETCH'

# ── options/options.h ────────────────────────────────────────────────────────
cat > "$BLK/opts_h" <<'EOF'
    bool next_file_prefetch;
    int64_t next_file_prefetch_max_bytes;
EOF
insert_block after "$MPV_SRC/options/options.h" \
  '    bool prefetch_open;' "$BLK/opts_h" 'next_file_prefetch;'

# ── options/options.c ────────────────────────────────────────────────────────
cat > "$BLK/opts_c" <<'EOF'
    {"next-file-prefetch", OPT_BOOL(next_file_prefetch)},
    {"next-file-demuxer-max-bytes-prefetch",
        OPT_BYTE_SIZE(next_file_prefetch_max_bytes), M_RANGE(0, M_MAX_MEM_BYTES)},
EOF
insert_block after "$MPV_SRC/options/options.c" \
  '    {"prefetch-playlist", OPT_BOOL(prefetch_open)},' "$BLK/opts_c" \
  'next-file-prefetch'

# ── demux/demux.h ────────────────────────────────────────────────────────────
cat > "$BLK/demux_h_params" <<'EOF'
    bool is_prefetch;            // opened for next-file playlist prefetch
    int64_t prefetch_max_bytes;  // demuxer cache cap while prefetching (0=default)
EOF
insert_block after "$MPV_SRC/demux/demux.h" \
  '    bool allow_playlist_create;' "$BLK/demux_h_params" 'is_prefetch;'
insert_line "$MPV_SRC/demux/demux.h" \
  'void demux_start_prefetch(struct demuxer *demuxer);' \
  'void demux_end_prefetch(struct demuxer *demuxer);' \
  'demux_end_prefetch'

# ── demux/demux.c ────────────────────────────────────────────────────────────
# demux_internal fields
cat > "$BLK/demux_c_fields" <<'EOF'

    // Next-file prefetch: while set, the demuxer cache is capped at
    // prefetch_max_bytes and the back-buffer disabled, so prefetching the next
    // playlist entry stays cheap. Cleared via prefetch_end_pending (handled on
    // the demux thread) when the entry is promoted to current playback.
    bool in_prefetch_mode;
    size_t prefetch_max_bytes;
    bool prefetch_end_pending;
EOF
insert_block after "$MPV_SRC/demux/demux.c" \
  '    char *record_filename;' "$BLK/demux_c_fields" 'in_prefetch_mode;'

# demux_open: enter prefetch mode for a top-level prefetch open
cat > "$BLK/demux_c_open" <<'EOF'

    if (params && params->is_prefetch && params->is_top_level) {
        in->in_prefetch_mode = true;
        in->prefetch_max_bytes = params->prefetch_max_bytes > 0
            ? params->prefetch_max_bytes : (256 * 1024 * 1024);
    }
EOF
insert_block after "$MPV_SRC/demux/demux.c" \
  '    mp_cond_init(&in->wakeup);' "$BLK/demux_c_open" 'in->in_prefetch_mode = true;'

# update_opts: apply the per-instance prefetch cap on top of the option values
cat > "$BLK/demux_c_cap" <<'EOF'
    if (in->in_prefetch_mode) {
        if (in->max_bytes > in->prefetch_max_bytes)
            in->max_bytes = in->prefetch_max_bytes;
        in->max_bytes_bw = 0;
    }

EOF
insert_block before "$MPV_SRC/demux/demux.c" \
  '    if (in->seekable_cache && opts->disk_cache && !in->cache) {' \
  "$BLK/demux_c_cap" 'if (in->in_prefetch_mode) {'

# demux_end_prefetch(): called by the player on promotion (main thread)
cat > "$BLK/demux_c_end" <<'EOF'
// Leave next-file prefetch mode: lift the cache cap and switch the stream to
// full parallelism. When threaded (the normal prefetch case) the demux thread
// owns the stream, so we only flag it and wake the thread; it does the work in
// thread_work(). Idempotent and safe on a demuxer that was never prefetching.
void demux_end_prefetch(struct demuxer *demuxer)
{
    struct demux_internal *in = demuxer->in;
    mp_mutex_lock(&in->lock);
    if (in->in_prefetch_mode) {
        if (in->threading) {
            in->prefetch_end_pending = true;
            mp_cond_signal(&in->wakeup);
        } else {
            in->in_prefetch_mode = false;
            update_opts(in->d_user);
            if (in->d_user->stream)
                stream_control(in->d_user->stream,
                               STREAM_CTRL_SEGMENTED_ACTIVATE, NULL);
        }
    }
    mp_mutex_unlock(&in->lock);
}

EOF
insert_block before "$MPV_SRC/demux/demux.c" \
  'static bool thread_work(struct demux_internal *in)' \
  "$BLK/demux_c_end" 'void demux_end_prefetch(struct demuxer *demuxer)'

# thread_work(): apply a pending prefetch-end on the demux thread
cat > "$BLK/demux_c_tw" <<'EOF'
    if (in->prefetch_end_pending) {
        in->prefetch_end_pending = false;
        in->in_prefetch_mode = false;
        update_opts(in->d_user);
        if (in->d_thread->stream)
            stream_control(in->d_thread->stream,
                           STREAM_CTRL_SEGMENTED_ACTIVATE, NULL);
        return true;
    }
EOF
insert_block before "$MPV_SRC/demux/demux.c" \
  '    size_t old_max_bytes = opts->max_bytes;' \
  "$BLK/demux_c_tw" 'in->prefetch_end_pending) {'

# ── player/loadfile.c ────────────────────────────────────────────────────────
# open_demux_thread(): mark the params as a prefetch open + reduce parallelism
cat > "$BLK/loadfile_params" <<'EOF'
    if (mpctx->open_for_prefetch) {
        p.is_prefetch = true;
        p.prefetch_max_bytes = mpctx->opts->next_file_prefetch_max_bytes;
        p.stream_flags |= STREAM_PREFETCH;
    }
EOF
insert_block before "$MPV_SRC/player/loadfile.c" \
  '    struct demuxer *demux =' "$BLK/loadfile_params" 'p.is_prefetch = true;'

# open_demux_reentrant(): promote a prefetched demuxer to current playback
insert_line "$MPV_SRC/player/loadfile.c" \
  '        mpctx->demuxer = mpctx->open_res_demuxer;' \
  '        demux_end_prefetch(mpctx->demuxer);' \
  'demux_end_prefetch(mpctx->demuxer)'

# prefetch_next(): also fire when --next-file-prefetch is set
replace_str "$MPV_SRC/player/loadfile.c" \
  'if (!mpctx->opts->prefetch_open || mpctx->open_active)' \
  'if ((!mpctx->opts->prefetch_open && !mpctx->opts->next_file_prefetch) || mpctx->open_active)' \
  '!mpctx->opts->next_file_prefetch)'

# ── player/playloop.c ────────────────────────────────────────────────────────
# Prefetch the next entry as soon as the current file plays smoothly, not only
# at EOF. Guarded so it never runs while the current file is stalling for cache.
replace_str "$MPV_SRC/player/playloop.c" \
  'if (s.eof && !busy)' \
  'if ((s.eof && !busy) || (mpctx->opts->next_file_prefetch && !mpctx->paused_for_cache))' \
  'mpctx->opts->next_file_prefetch && !mpctx->paused_for_cache'

echo "==> next-file prefetch patch applied."
