#!/usr/bin/env bash
# Windows analog of patches/apply_malloc_tuning.sh (the Linux glibc mallopt fix).
#
# The Linux RAM ratchet was glibc giving every fresh thread (demux + segmented-
# http workers) its own arena that is never returned to the OS, so RSS climbed
# ~1 arena per played file. Windows has NO per-thread arenas — every thread
# shares the one process heap — so that exact ratchet does not occur, and mpv
# already enables heap decommit once at startup in microsoft_nonsense()
# (HeapSetInformation(NULL, HeapOptimizeResources, ...)). What is missing is the
# equivalent of glibc's M_TRIM_THRESHOLD *periodic* trim: over a long playlist
# the CRT heap can retain the large freed packet buffers an 8 GiB back-buffer
# produces. This patch spawns a tiny background thread that re-runs the very
# same HeapOptimizeResources decommit on a 30 s timer, returning that freed heap
# to the OS so RSS holds flat instead of drifting up.
#
# HeapOptimizeResources only decommits FREE blocks; it never evicts the in-use
# working set (unlike SetProcessWorkingSetSize), so there is no page-fault /
# playback-stutter cost. Reuses the HEAP_OPTIMIZE_RESOURCES_INFORMATION struct
# and version macro mpv already defines at the top of osdep/main-fn-win.c.
#
# Usage: apply_malloc_tuning_win.sh <mpv-src-dir>
# Anchored + idempotent; fails loudly if an upstream anchor moved so the build
# stops instead of silently producing an unpatched (drifting) mpv.exe.
set -Eeuo pipefail

MPV_SRC="${1:?usage: apply_malloc_tuning_win.sh <mpv-src-dir>}"
F="$MPV_SRC/osdep/main-fn-win.c"
[ -f "$F" ] || { echo "!! $MPV_SRC is not an mpv tree (missing $F)"; exit 1; }

# Idempotency: the injected trim thread is the marker.
if grep -qF 'mp_heap_trim_thread' "$F"; then
  echo "==> malloc-tuning (win) patch already applied."
  exit 0
fi

die_anchor() { echo "!! malloc-tuning (win) patch: anchor not found in $F (upstream changed; patch needs updating): $1"; exit 1; }
grep -qF 'HEAP_OPTIMIZE_RESOURCES_CURRENT_VERSION' "$F" || die_anchor 'HEAP_OPTIMIZE_RESOURCES_CURRENT_VERSION'
grep -qxF 'int main(void)' "$F" || die_anchor 'int main(void)'
grep -qF 'microsoft_nonsense();' "$F" || die_anchor 'microsoft_nonsense();'

echo "==> Applying Windows heap-trim patch to $F ..."

# 1) define the background trim thread just before main()
awk '
  !done && $0 == "int main(void)" {
    print "// Portable-build RAM fix (Windows analog of the Linux glibc"
    print "// M_TRIM_THRESHOLD trim): periodically decommit freed heap back to the"
    print "// OS so a long playlist holds RSS flat. HeapOptimizeResources touches"
    print "// only FREE blocks, so the in-use working set (and playback) is unaffected."
    print "static DWORD WINAPI mp_heap_trim_thread(LPVOID param)"
    print "{"
    print "    HEAP_OPTIMIZE_RESOURCES_INFORMATION heap_info = {"
    print "        .Version = HEAP_OPTIMIZE_RESOURCES_CURRENT_VERSION"
    print "    };"
    print "    for (;;) {"
    print "        Sleep(30000); // 30 s"
    print "        HeapSetInformation(NULL, HeapOptimizeResources, &heap_info,"
    print "                           sizeof(heap_info));"
    print "    }"
    print "    return 0;"
    print "}"
    print ""
    done = 1
  }
  { print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

# 2) start it right after microsoft_nonsense() at the top of main(), matching indent
awk '
  !done && index($0, "microsoft_nonsense();") {
    print
    indent = $0; sub(/[^ ].*/, "", indent)
    print ""
    print indent "// Start the periodic heap-trim thread (see mp_heap_trim_thread above)."
    print indent "// Detached: it runs for the process lifetime; handle is closed immediately."
    print indent "HANDLE trim_thread = CreateThread(NULL, 0, mp_heap_trim_thread, NULL, 0, NULL);"
    print indent "if (trim_thread)"
    print indent "    CloseHandle(trim_thread);"
    done = 1
    next
  }
  { print }
' "$F" > "$F.tmp" && mv "$F.tmp" "$F"

echo "==> malloc-tuning (win) patch applied."
