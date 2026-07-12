#!/usr/bin/env bash
# Expose the segmented downloader's real per-thread + combined download speed
# to mpv scripts, on top of the segmented-http patch.
#
# Usage: apply_segmented_speed.sh <mpv-src-dir>
#
# The stream-module side (per-worker byte counters, the EMA, and the
# STREAM_CTRL_GET_SEGMENTED_SPEED handler) lives in stream_segmented_http.c,
# which apply_segmented_http.sh copies in wholesale. This script only inserts
# the small hooks that carry that value up through the core:
#   stream.h   : new STREAM_CTRL enum value + result struct
#   demux.h    : segmented_* fields on demux_reader_state
#   demux.c    : query the stream in update_cache(), stash + publish the value
#   command.c  : add segmented-input-rate / segmented-worker-rates to
#                the demuxer-cache-state property (uosc already observes it)
#
# Idempotent: safe to run on an already-patched tree. Fails loudly if an
# upstream anchor moved so the build stops instead of silently dropping the
# feature.
set -Eeuo pipefail

MPV_SRC="${1:?usage: apply_segmented_speed.sh <mpv-src-dir>}"

[ -f "$MPV_SRC/stream/stream.h" ] || { echo "!! $MPV_SRC is not an mpv tree"; exit 1; }

die_anchor() { echo "!! segmented-speed patch: anchor not found in $1 (upstream changed; patch needs updating)"; exit 1; }

# insert_after <file> <anchor-substring> <text-to-insert> <already-substring>
# Fixed-string matching (no regex); the insert may span multiple lines.
insert_after() {
  local file="$1" anchor="$2" insert="$3" marker="$4"
  grep -qF "$marker" "$file" && return 0
  grep -qF "$anchor" "$file" || die_anchor "$file"
  awk -v anchor="$anchor" -v ins="$insert" '
    { print }
    !done && index($0, anchor) { print ins; done=1 }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

echo "==> Applying segmented download-speed exposure patch ..."

# 1. stream/stream.h: new STREAM_CTRL + result struct
# Anchor on the upstream-native STREAM_CTRL_AVSEEK (first enum member) rather than
# STREAM_CTRL_SEGMENTED_ACTIVATE, which is added by apply_next_file_prefetch.sh —
# that runs *after* this script, so its enum value isn't present yet here.
insert_after "$MPV_SRC/stream/stream.h" \
  '    STREAM_CTRL_AVSEEK,' \
  '    STREAM_CTRL_GET_SEGMENTED_SPEED,' \
  'STREAM_CTRL_GET_SEGMENTED_SPEED,'

insert_after "$MPV_SRC/stream/stream.h" \
  'struct stream_open_args;' \
  '// for STREAM_CTRL_GET_SEGMENTED_SPEED (segmented_http downloader)
struct stream_segmented_speed {
    int num_workers;
    uint64_t total_bps;         // combined download rate of all connections
    uint64_t worker_bps[16];    // per-connection rate (MAX_WORKERS)
};' \
  'struct stream_segmented_speed {'

# 2. demux/demux.h: fields on the public reader state
insert_after "$MPV_SRC/demux/demux.h" \
  '    uint64_t bytes_per_second; // low level statistics' \
  '    // segmented_http downloader: true network download rate (see
    // STREAM_CTRL_GET_SEGMENTED_SPEED). Distinct from bytes_per_second, which
    // for that stream measures the reader draining prefetched slot buffers.
    bool segmented_active;
    uint64_t segmented_total_bps;
    int segmented_num_workers;
    uint64_t segmented_worker_bps[16];' \
  'uint64_t segmented_total_bps;'

# 3. demux/demux.c
# 3a. internal accounting fields
insert_after "$MPV_SRC/demux/demux.c" \
  '    uint64_t bytes_per_second;' \
  '    bool segmented_active;
    uint64_t segmented_total_bps;
    int segmented_num_workers;
    uint64_t segmented_worker_bps[16];' \
  '    bool segmented_active;'

# 3b. locals in update_cache() to hold the queried value
insert_after "$MPV_SRC/demux/demux.c" \
  '    struct mp_tags *stream_metadata = NULL;' \
  '    struct stream_segmented_speed seg_speed = {0};
    bool seg_speed_ok = false;' \
  'struct stream_segmented_speed seg_speed'

# 3c. query the stream (unlocked, right after the metadata query, inside if(stream))
insert_after "$MPV_SRC/demux/demux.c" \
  '        stream_control(stream, STREAM_CTRL_GET_METADATA, &stream_metadata);' \
  '        seg_speed_ok = stream_control(stream, STREAM_CTRL_GET_SEGMENTED_SPEED, &seg_speed) == STREAM_OK;' \
  'STREAM_CTRL_GET_SEGMENTED_SPEED, &seg_speed)'

# 3d. stash into demux_internal after re-lock (anchors on the update_cache() call)
insert_after "$MPV_SRC/demux/demux.c" \
  '    update_bytes_read(in);' \
  '    in->segmented_active = seg_speed_ok;
    in->segmented_total_bps = seg_speed_ok ? seg_speed.total_bps : 0;
    in->segmented_num_workers = seg_speed_ok ? seg_speed.num_workers : 0;
    for (int sn = 0; sn < in->segmented_num_workers && sn < 16; sn++)
        in->segmented_worker_bps[sn] = seg_speed.worker_bps[sn];' \
  'in->segmented_active = seg_speed_ok;'

# 3e. publish scalars into demux_reader_state initializer
insert_after "$MPV_SRC/demux/demux.c" \
  '        .bytes_per_second = in->bytes_per_second,' \
  '        .segmented_active = in->segmented_active,
        .segmented_total_bps = in->segmented_total_bps,
        .segmented_num_workers = in->segmented_num_workers,' \
  '.segmented_active = in->segmented_active,'

# 3f. copy the per-worker array (after the initializer)
insert_after "$MPV_SRC/demux/demux.c" \
  '    bool any_packets = false;' \
  '    for (int sn = 0; sn < r->segmented_num_workers && sn < 16; sn++)
        r->segmented_worker_bps[sn] = in->segmented_worker_bps[sn];' \
  'r->segmented_worker_bps[sn] = in->segmented_worker_bps[sn];'

# 3g. Keep the value live even after update_cache() stops ticking (e.g. once the
# file is fully buffered to EOF, mpv stops the cache updater that queries us).
# Re-query the segmented stream on every reader-state read so the rate decays to
# 0 instead of freezing. seg_control is non-blocking (only takes its own lock),
# so this is safe under in->lock. Gated on segmented_active so non-segmented
# streams are never touched.
insert_after "$MPV_SRC/demux/demux.c" \
  '        r->segmented_worker_bps[sn] = in->segmented_worker_bps[sn];' \
  '    if (in->segmented_active && in->d_thread && in->d_thread->stream) {
        struct stream_segmented_speed seg_live = {0};
        if (stream_control(in->d_thread->stream,
                           STREAM_CTRL_GET_SEGMENTED_SPEED, &seg_live) == STREAM_OK) {
            r->segmented_total_bps = seg_live.total_bps;
            r->segmented_num_workers = seg_live.num_workers;
            for (int sn = 0; sn < seg_live.num_workers && sn < 16; sn++)
                r->segmented_worker_bps[sn] = seg_live.worker_bps[sn];
        }
    }' \
  'STREAM_CTRL_GET_SEGMENTED_SPEED, &seg_live)'

# 4. player/command.c: add to the demuxer-cache-state property node. The current
# file comes from reader-state s; the next-file prefetch stream (buffering in
# parallel) is reached via mpctx->open_res_demuxer once its open completed.
insert_after "$MPV_SRC/player/command.c" \
  '        node_map_add_int64(r, "raw-input-rate", s.bytes_per_second);' \
  '    if (s.segmented_active) {
        node_map_add_int64(r, "segmented-input-rate", s.segmented_total_bps);
        struct mpv_node *sws =
            node_map_add(r, "segmented-worker-rates", MPV_FORMAT_NODE_ARRAY);
        for (int sn = 0; sn < s.segmented_num_workers; sn++)
            node_array_add(sws, MPV_FORMAT_INT64)->u.int64 = s.segmented_worker_bps[sn];
    }
    if (mpctx->open_res_demuxer && atomic_load(&mpctx->open_done) &&
        mpctx->open_res_demuxer != mpctx->demuxer)
    {
        struct demux_reader_state ps;
        demux_get_reader_state(mpctx->open_res_demuxer, &ps);
        if (ps.segmented_active) {
            node_map_add_int64(r, "segmented-prefetch-input-rate", ps.segmented_total_bps);
            struct mpv_node *pws =
                node_map_add(r, "segmented-prefetch-worker-rates", MPV_FORMAT_NODE_ARRAY);
            for (int sn = 0; sn < ps.segmented_num_workers; sn++)
                node_array_add(pws, MPV_FORMAT_INT64)->u.int64 = ps.segmented_worker_bps[sn];
        }
    }' \
  '"segmented-input-rate"'

echo "==> segmented download-speed patch applied."
