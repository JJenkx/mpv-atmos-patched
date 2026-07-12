/*
 * Patch B: in-process, from-buffer thumbnailer -- demuxer side.
 *
 * This file is textually #included at the end of demux/demux.c so it can use
 * the private demux_internal / demux_cached_range / demux_queue structures and
 * the static cache-lookup helpers (find_cache_seek_range, find_seek_target).
 *
 * demux_get_cached_video_packets() extracts already-buffered video packets for
 * a single decodable window ending at/after `pts` and returns deep copies of
 * them. It is strictly read-only with respect to the demuxer:
 *   - it never moves any ds->reader_head (playback position is untouched);
 *   - it never issues a low-level/network seek;
 *   - it returns false when `pts` is not currently inside a cached range,
 *     which is exactly the "only thumbnail what's in the buffer" behaviour.
 *
 * The returned packets are independent deep copies (demux_copy_packet); the
 * caller owns them and must free each with free_demux_packet() and the array
 * with talloc_free().
 */

bool demux_get_cached_video_packets(struct demuxer *demuxer, int stream_index,
                                    double pts, struct demux_packet ***out_pkts,
                                    int *out_num)
{
    struct demux_internal *in = demuxer->in;

    *out_pkts = NULL;
    *out_num = 0;

    struct demux_packet **arr = NULL;
    int num = 0;
    bool ok = false;

    mp_mutex_lock(&in->lock);

    if (!in->seekable_cache)
        goto done;
    if (stream_index < 0 || stream_index >= in->num_streams)
        goto done;

    // Find a cached range that actually contains the requested time. If none
    // does, the frame simply isn't buffered -> no thumbnail, no network I/O.
    struct demux_cached_range *range = find_cache_seek_range(in, pts, 0);
    if (!range || stream_index >= range->num_streams)
        goto done;

    struct demux_queue *queue = range->streams[stream_index];
    if (!queue)
        goto done;

    // Keyframe at or before the requested time (SEEK backward, flags == 0).
    // We deliberately return only this keyframe: decoding it alone yields the
    // frame a keyframe seek would land on -- exactly what stock thumbfast shows
    // for long media (allow_fast_seek). This makes the thumbnail deterministic
    // for a given time (no per-frame jitter as the hover time wobbles, and no
    // frame-walk as the GOP fills in during buffering). find_cache_seek_range()
    // already guarantees the time is within the range's seek_end, so this is
    // the correct GOP keyframe, not an undershoot into unbuffered data.
    struct demux_packet *target = find_seek_target(queue, pts, 0);
    if (!target || target->is_cached)
        goto done;

    struct demux_packet *cl = demux_copy_packet(in->packet_pool, target);
    if (!cl)
        goto done;
    MP_TARRAY_APPEND(NULL, arr, num, cl);
    ok = true;

done:
    mp_mutex_unlock(&in->lock);
    *out_pkts = arr;
    *out_num = num;
    return ok;
}
