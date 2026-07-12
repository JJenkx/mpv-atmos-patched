#!/usr/bin/env bash
# Compile the portable build's glibc malloc tuning directly into the mpv binary,
# so MALLOC_ARENA_MAX / MALLOC_TRIM_THRESHOLD_ no longer need to be exported by
# the launcher (mpv_patched.sh).
#
# Fixes the RAM ratchet behind the overnight OOM-freeze: every played file
# spawns fresh threads (demux thread + segmented-http workers) that allocate
# GiBs of packet buffers and then exit. glibc's default behaviour spreads these
# across unbounded per-thread arenas and does NOT return the freed heap to the
# OS, so RSS climbs ~1 arena's worth per episode and freezes the machine after a
# handful of files. Capping the arena count (M_ARENA_MAX) forces reuse; setting
# M_TRIM_THRESHOLD forces the heap to be trimmed back to the OS AND freezes
# glibc's dynamic mmap threshold at its 128KiB default, so the big video packets
# an 8GiB back-buffer produces get mmap'd and reliably returned on free. Net
# effect: RSS stays flat across a long playlist instead of ratcheting up.
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
    print indent "// Portable-build RAM-ratchet fix (replaces exporting"
    print indent "// MALLOC_ARENA_MAX=2 / MALLOC_TRIM_THRESHOLD_=134217728 from the launcher):"
    print indent "// bound per-thread arena churn and force freed heap back to the OS so a"
    print indent "// long playlist holds RSS flat instead of climbing ~1 arena per file."
    print indent "#if defined(__GLIBC__)"
    print indent "mallopt(M_ARENA_MAX, 2);"
    print indent "mallopt(M_TRIM_THRESHOLD, 134217728); // 128 MiB; also freezes the mmap threshold"
    print indent "#endif"
    done = 1
  }
  { print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

echo "==> malloc-tuning patch applied."
