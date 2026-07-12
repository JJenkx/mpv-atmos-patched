/*
 * Patch B: in-process, from-buffer thumbnailer -- command entry point.
 */
#ifndef MP_PLAYER_THUMBNAIL_H
#define MP_PLAYER_THUMBNAIL_H

// Handler for the "thumbnail-cache" command. Runs on a worker thread
// (mp_cmd_def.spawn_thread). See patches/README_thumbnail_cache.md.
void cmd_thumbnail_cache(void *p);

#endif
