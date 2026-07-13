#!/usr/bin/env bash
# Compile the portable build's glibc malloc tuning directly into the mpv binary,
# so MALLOC_ARENA_MAX no longer needs to be exported by the launcher.
#
# Fixes the RAM ratchet behind the overnight OOM-freeze: every played file
# spawns fresh threads (demux thread + segmented-http workers) that allocate
# GiBs of packet buffers and then exit. glibc's default behaviour spreads these
# across unbounded per-thread arenas, so RSS climbs ~1 arena's worth per episode
# and freezes the machine after a handful of files. Capping the arena count
# (M_ARENA_MAX) forces those arenas to be REUSED instead of multiplying, so RSS
# plateaus across a long playlist instead of ratcheting up.
#
# ─── DO NOT re-add M_TRIM_THRESHOLD — it caused a KERNEL PANIC ────────────────
# This patch used to also set mallopt(M_TRIM_THRESHOLD, 128MiB). That looked
# attractive (it returns freed heap to the OS), but it has a lethal side effect:
# per glibc, setting M_TRIM_THRESHOLD *disables glibc's dynamic mmap-threshold
# adaptation*. Normally, after a big mmap'd block is freed, glibc RAISES the mmap
# threshold so future same-size allocations come from the heap and are never
# unmapped. With the adaptation disabled, every large video buffer is mmap'd and
# munmap'd on free, forever.
#
# That is fatal here, because libplacebo imports host pointers into the GPU
# (userptr / VK_EXT_external_memory_host). munmap()ing a buffer the GPU still has
# mapped fires the driver's MMU notifier on freed memory and oopses the kernel:
#
#     RIP: amdgpu_hmm_invalidate_gfx
#       __mmu_notifier_invalidate_range_start
#       __vm_munmap  <-  __x64_sys_munmap        (mpv called munmap)
#
# The GPU driver wedges in-kernel: unkillable processes, dead desktop, and a
# reboot that never completes. Reproduced on AMD/RADV by switching subtitle track
# and hovering the seekbar (the in-process thumbnailer decodes on a worker thread,
# so you get concurrent alloc/free churn while the main thread renders).
#
# M_ARENA_MAX does NOT disable the mmap adaptation, so keeping it alone is safe
# and still fixes the ratchet. The trade-off: freed memory is reused rather than
# handed back to the OS, so RSS plateaus instead of dropping. That is the correct
# price — we must never hand pages back while the GPU may still be reading them.
# ──────────────────────────────────────────────────────────────────────────────
#
# mallopt() is called at the very top of main() in osdep/main-fn-unix.c, before
# mpv_main() and before any mpv thread exists, so the arena cap is in force
# before the first worker thread can create a second arena.
#
# Usage: apply_malloc_tuning.sh <mpv-src-dir>
# Anchored + idempotent; fails loudly if an upstream anchor moved so the build
# stops instead of silently producing an unpatched (ratcheting) mpv.
set -Eeuo pipefail

MPV_SRC="${1:?usage: apply_malloc_tuning.sh <mpv-src-dir>}"
F="$MPV_SRC/osdep/main-fn-unix.c"
[ -f "$F" ] || { echo "!! $MPV_SRC is not an mpv tree (missing $F)"; exit 1; }

# Idempotency: the injected mallopt call is the marker.
if grep -qF 'M_ARENA_MAX' "$F"; then
  echo "==> malloc-tuning patch already applied."
  exit 0
fi

die_anchor() { echo "!! malloc-tuning patch: anchor not found in $F (upstream changed; patch needs updating): $1"; exit 1; }
grep -qxF '#include "main-fn.h"' "$F" || die_anchor '#include "main-fn.h"'
grep -qF 'return mpv_main(argc, argv);' "$F" || die_anchor 'return mpv_main(argc, argv);'

echo "==> Applying glibc malloc-tuning patch to $F ..."

# 1) pull in <malloc.h> (glibc-guarded) after the existing include
awk '
  { print }
  !inc && $0 == "#include \"main-fn.h\"" {
    print ""
    print "// <stdlib.h> first: __GLIBC__ is only defined once a glibc header has"
    print "// been included, and main-fn.h includes none — without this the guard"
    print "// below is silently false and the mallopt calls compile to nothing."
    print "#include <stdlib.h>"
    print "#if defined(__GLIBC__)"
    print "#include <malloc.h>"
    print "#endif"
    inc = 1
  }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

# 2) call mallopt() at the top of main(), before mpv_main(), matching indent
awk '
  !done && index($0, "return mpv_main(argc, argv);") {
    indent = $0; sub(/[^ ].*/, "", indent)
    print indent "// Portable-build RAM-ratchet fix (replaces exporting MALLOC_ARENA_MAX=2"
    print indent "// from the launcher): bound per-thread arena churn so the arenas created by"
    print indent "// the per-file demux/segmented-http threads are REUSED rather than"
    print indent "// multiplying, so RSS plateaus over a long playlist instead of climbing by"
    print indent "// roughly one arena per file."
    print indent "//"
    print indent "// Deliberately does NOT set M_TRIM_THRESHOLD: doing so disables the dynamic"
    print indent "// mmap-threshold adaptation in glibc, so every large video buffer is mmapped"
    print indent "// and munmapped on free. Because libplacebo imports host pointers into the"
    print indent "// GPU, unmapping a buffer the GPU still holds oopses the kernel inside the"
    print indent "// GPU driver (amdgpu_hmm_invalidate_gfx). See apply_malloc_tuning.sh."
    print indent "#if defined(__GLIBC__)"
    print indent "mallopt(M_ARENA_MAX, 2);"
    print indent "#endif"
    done = 1
  }
  { print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

# Verify the injection actually landed. `awk ... && mv` is NOT caught by `set -e`
# (bash exempts the left side of an && list), so a broken awk program would
# otherwise print "applied" while silently producing an unpatched, ratcheting mpv.
grep -qF 'mallopt(M_ARENA_MAX, 2);' "$F" \
  || { echo "!! malloc-tuning patch: mallopt() was NOT inserted into $F"; exit 1; }
grep -qF 'mallopt(M_TRIM_THRESHOLD' "$F" \
  && { echo "!! malloc-tuning patch: mallopt(M_TRIM_THRESHOLD) must NOT be set — it disables"; \
       echo "!! the dynamic mmap threshold, and munmapping GPU-imported buffers oopses the kernel"; \
       exit 1; }

echo "==> malloc-tuning patch applied."
