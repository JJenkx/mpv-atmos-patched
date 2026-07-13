#!/usr/bin/env bash
# bundle_deps.sh <payload-root>
#
# Makes the Linux payload actually self-contained.
#
# The build installs -dev packages, so mpv/FFmpeg link against libraries that are
# NOT present on a stock target install (e.g. Ubuntu 22.04 desktop has no
# libXpresent.so.1, libXv.so.1, liblcms2.so.2 or libxcb-shape.so.0 — mpv would not
# even start). This walks the dependency closure of the executables and bundled
# libs and copies in anything missing.
#
# It deliberately does NOT bundle system/driver-coupled libraries. Those MUST come
# from the target machine, because the user's GPU driver links them too and a
# bundled copy would shadow it — that is how we previously killed Vulkan for every
# Mesa user (see patches/ and the README). glibc and the C++ runtime likewise must
# match the host.
set -Eeuo pipefail

ROOT="${1:?usage: bundle_deps.sh <payload-root>}"
LIB="$ROOT/lib"
[ -d "$LIB" ] || { echo "!! no $LIB"; exit 1; }

# Libraries that must ALWAYS come from the target system, never from us.
# Matched as a prefix against the soname.
is_excluded() {
  case "$1" in
    # glibc / loader / compiler runtime — must match the host
    ld-linux*|libc.so*|libm.so*|libmvec.so*|libdl.so*|libpthread.so*|librt.so*|\
    libresolv.so*|libnsl.so*|libanl.so*|libutil.so*|libcrypt.so*|\
    libstdc++.so*|libgcc_s.so*) return 0 ;;
    # GPU driver + loaders: bundling these breaks the user's driver
    libGL.so*|libGLX.so*|libGLdispatch.so*|libEGL.so*|libOpenGL.so*|libGLESv2.so*|\
    libgbm.so*|libdrm*.so*|libvulkan.so*) return 0 ;;
    # core X11/XCB — the GPU driver links these too
    libX11.so*|libX11-xcb.so*|libxcb.so*|libXext.so*|libXfixes.so*|libXrandr.so*|\
    libXi.so*|libXau.so*|libXdmcp.so*|libxshmfence.so*|libXrender.so*|libXcursor.so*|\
    libxcb-dri2.so*|libxcb-dri3.so*|libxcb-present.so*|libxcb-sync.so*|\
    libxcb-xfixes.so*|libxcb-randr.so*|libxcb-shm.so*|libxcb-glx.so*|\
    libxcb-keysyms.so*) return 0 ;;
    # Mesa/LLVM's own deps — shadowing these breaks the driver
    libLLVM*.so*|libelf.so*|libz.so*|libzstd.so*|libexpat.so*|libffi.so*|\
    libxml2.so*|libicu*.so*|libedit.so*|libncurses*.so*|libtinfo.so*|\
    libSPIRV-Tools*.so*|libdisplay-info.so*) return 0 ;;
    # sound servers + system daemons — must be the host's
    libasound.so*|libpulse*.so*|libjack*.so*|libpipewire*.so*|\
    libudev.so*|libsystemd.so*|libcap.so*|libselinux.so*|libdbus*.so*) return 0 ;;
    # fontconfig reads the HOST's /etc/fonts. A bundled (older) fontconfig cannot
    # parse a newer host's config — on Arch it spews "invalid attribute 'xsi:nil'"
    # for every conf.d file and mis-resolves fonts. It, and freetype alongside it,
    # must come from the system. (Every desktop has both.) libbrotli* is only
    # pulled in as freetype's dependency, so it drops out with it.
    libfontconfig.so*|libfreetype.so*|libbrotli*.so*) return 0 ;;
    # xkb/wayland: we bundle wayland ourselves (deliberately, as a superset) —
    # leave whatever is already in lib/ alone, but never pull in the host's.
    libxkbcommon*.so*) return 0 ;;
  esac
  return 1
}

added=1 total=0
while [ "$added" -gt 0 ]; do
  added=0
  # every ELF we ship: the executables plus everything already in lib/
  mapfile -t objs < <(find "$ROOT/bin" -maxdepth 1 -type f 2>/dev/null; find "$LIB" -maxdepth 1 -name '*.so*' -type f)
  for o in "${objs[@]}"; do
    # "libfoo.so.1 => not found"  OR  "libfoo.so.1 => /usr/lib/x86_64-linux-gnu/libfoo.so.1"
    while read -r soname _ path _; do
      [ -n "$soname" ] || continue
      [ -e "$LIB/$soname" ] && continue          # already bundled
      is_excluded "$soname" && continue          # must come from the host
      # resolve it on the build system
      if [ "$path" = "not" ] || [ -z "$path" ] || [ ! -e "$path" ]; then
        path="$(ldconfig -p 2>/dev/null | awk -v s="$soname" '$1==s {print $NF; exit}')"
      fi
      [ -n "$path" ] && [ -e "$path" ] || { echo "!! cannot resolve $soname"; continue; }
      cp -L "$path" "$LIB/$soname"
      patchelf --set-rpath '$ORIGIN' "$LIB/$soname" 2>/dev/null || true
      echo "  + bundled $soname"
      added=$((added+1)); total=$((total+1))
    done < <(ldd "$o" 2>/dev/null | sed -n 's/^\s*\(\S*\.so[^ ]*\) => \(.*\)$/\1 => \2/p' | awk '{print $1, $2, $3, $4}')
  done
done

echo "==> bundle_deps: added $total librarie(s)"

# Nothing may be left unresolved except the excluded (host-provided) ones.
missing=0
for o in "$ROOT"/bin/* "$LIB"/*.so*; do
  [ -f "$o" ] || continue
  while read -r s; do
    is_excluded "$s" && continue
    echo "!! STILL MISSING: $s (needed by $(basename "$o"))"; missing=1
  done < <(ldd "$o" 2>/dev/null | awk '/not found/{print $1}')
done
[ "$missing" = 0 ] || { echo "!! payload is not self-contained"; exit 1; }
echo "==> dependency closure complete — payload is self-contained"
