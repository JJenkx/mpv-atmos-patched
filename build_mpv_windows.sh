#!/usr/bin/env bash
# build_mpv_windows.sh — cross-compile the patched mpv+FFmpeg stack for Windows x86_64
# using the mingw-w64 toolchain on Arch Linux.
#
# Windows counterpart of build_mpv.sh (which stays Linux-only). Everything is
# built from source into a private prefix ($APP_DIR) so the result depends on
# no system libraries — neither this build host's nor the target Windows
# machine's (no system ffmpeg/codec DLLs are ever used).
#
# Output:
#   $APP_DIR/bin/{mpv.exe,mpv.com,ffmpeg.exe,ffprobe.exe} + all dependency DLLs
# Afterwards run ./collect_dlls.sh to assemble the flat, shippable dist-win/.
#
# Resumable: each dependency step is skipped when its marker exists in
# $PREFIX/lib. FORCE_REBUILD=1 rebuilds everything. FFmpeg and mpv are always
# rebuilt so the custom patches are freshly applied.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIPLE=x86_64-w64-mingw32
# Passed as --build to every autotools configure: with wine's binfmt handler
# registered, cross-compiled conftest.exe binaries RUN on this host, which
# makes autoconf silently decide it is not cross-compiling. An explicit
# build!=host forces deterministic cross mode.
BUILD_TRIPLE="$(gcc -dumpmachine)"

# ─────────────────────────── Preflight: check build deps ────────────────────────────
# Check-only (no sudo inside the script). Prints the pacman command when
# something is missing.
_need_bins=(
  "$TRIPLE-gcc" "$TRIPLE-g++" "$TRIPLE-windres" "$TRIPLE-ar" "$TRIPLE-objdump"
  gendef git curl tar make gcc g++ python3 cmake meson ninja pkg-config perl
  autoconf automake libtool nasm yasm
)
_missing=()
for b in "${_need_bins[@]}"; do
  command -v "$b" >/dev/null 2>&1 || _missing+=("$b")
done
python3 -c 'import jinja2' 2>/dev/null || _missing+=("python-jinja(module jinja2)")
if ((${#_missing[@]} > 0)); then
  echo "!! Missing build tools:" >&2
  printf '   %s\n' "${_missing[@]}" >&2
  echo >&2
  echo "Install with:" >&2
  echo "  sudo pacman -S --needed mingw-w64-gcc mingw-w64-binutils mingw-w64-crt \\" >&2
  echo "       mingw-w64-headers mingw-w64-winpthreads mingw-w64-tools \\" >&2
  echo "       base-devel git curl cmake meson ninja pkgconf nasm yasm python-jinja wine" >&2
  exit 2
fi
# ─────────────────────────────────────────────────────────────────────────────────────

APP_DIR="${APP_DIR:-"$PWD/mpv-win"}"

# ── Build variant / licensing toggles (see build_mpv.sh for full docs) ─────────
#   VARIANT=enhanced (default) — Atmos patch + all streaming patches + RAM fix
#   VARIANT=stock              — stock mpv + ONLY the Atmos/TrueHD spdifenc patch
#   DISTRIBUTABLE=1            — redistributable GPLv3 (drops nonfree + libfdk-aac)
#   DISTRIBUTABLE=0 (default)  — personal build, keeps nonfree (NOT redistributable)
VARIANT="${VARIANT:-enhanced}"
DISTRIBUTABLE="${DISTRIBUTABLE:-0}"
case "$VARIANT" in stock|enhanced) ;; *) echo "!! VARIANT must be 'stock' or 'enhanced' (got '$VARIANT')"; exit 2;; esac
echo "==> Build config: VARIANT=$VARIANT DISTRIBUTABLE=$DISTRIBUTABLE"

# ── Repos / refs ──────────────────────────────────────────────────────────────
FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_REF="${FFMPEG_REF:-}"

MPV_REPO="${MPV_REPO:-https://github.com/mpv-player/mpv.git}"
MPV_REF="${MPV_REF:-}"

LUAJIT_REPO="${LUAJIT_REPO:-https://github.com/LuaJIT/LuaJIT.git}"
LUAJIT_REF="${LUAJIT_REF:-}"

ZLIB_REPO="${ZLIB_REPO:-https://github.com/madler/zlib.git}"
ZLIB_REF="${ZLIB_REF:-}"

BZIP2_VER="${BZIP2_VER:-1.0.8}"
BZIP2_URL="${BZIP2_URL:-https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VER}.tar.gz}"

XZ_VER="${XZ_VER:-5.8.1}"
XZ_URL="${XZ_URL:-https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.gz}"

LIBICONV_VER="${LIBICONV_VER:-1.18}"   # >=1.18 required with GCC 15+/C23
LIBICONV_URL="${LIBICONV_URL:-https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${LIBICONV_VER}.tar.gz}"
LIBICONV_URL_MIRROR="https://ftpmirror.gnu.org/libiconv/libiconv-${LIBICONV_VER}.tar.gz"

FREETYPE_REPO="${FREETYPE_REPO:-https://gitlab.freedesktop.org/freetype/freetype.git}"
FREETYPE_REF="${FREETYPE_REF:-}"

UCHARDET_REPO="${UCHARDET_REPO:-https://gitlab.freedesktop.org/uchardet/uchardet.git}"
UCHARDET_REF="${UCHARDET_REF:-}"

LCMS2_REPO="${LCMS2_REPO:-https://github.com/mm2/Little-CMS.git}"
LCMS2_REF="${LCMS2_REF:-}"

DAV1D_REPO="${DAV1D_REPO:-https://code.videolan.org/videolan/dav1d.git}"
DAV1D_REF="${DAV1D_REF:-}"

NVCODEC_REPO="${NVCODEC_REPO:-https://github.com/FFmpeg/nv-codec-headers.git}"
NVCODEC_REF="${NVCODEC_REF:-}"

VULKAN_HEADERS_REPO="${VULKAN_HEADERS_REPO:-https://github.com/KhronosGroup/Vulkan-Headers.git}"
VULKAN_HEADERS_REF="${VULKAN_HEADERS_REF:-}"
VULKAN_LOADER_REPO="${VULKAN_LOADER_REPO:-https://github.com/KhronosGroup/Vulkan-Loader.git}"
VULKAN_LOADER_REF="${VULKAN_LOADER_REF:-}"

SHADERC_REPO="${SHADERC_REPO:-https://github.com/google/shaderc.git}"
SHADERC_REF="${SHADERC_REF:-}"

SPIRV_CROSS_REPO="${SPIRV_CROSS_REPO:-https://github.com/KhronosGroup/SPIRV-Cross.git}"
SPIRV_CROSS_REF="${SPIRV_CROSS_REF:-}"

LIBPLACEBO_REPO="${LIBPLACEBO_REPO:-https://github.com/haasn/libplacebo.git}"
LIBPLACEBO_REF="${LIBPLACEBO_REF:-}"

OPENSSL_REPO="${OPENSSL_REPO:-https://github.com/openssl/openssl.git}"
OPENSSL_REF="${OPENSSL_REF:-}"
LIBVPX_REPO="${LIBVPX_REPO:-https://chromium.googlesource.com/webm/libvpx}"
LIBVPX_REF="${LIBVPX_REF:-}"
LIBOGG_REPO="${LIBOGG_REPO:-https://gitlab.xiph.org/xiph/ogg.git}"
LIBOGG_REF="${LIBOGG_REF:-}"
LIBVORBIS_REPO="${LIBVORBIS_REPO:-https://gitlab.xiph.org/xiph/vorbis.git}"
LIBVORBIS_REF="${LIBVORBIS_REF:-}"
LIBOPUS_REPO="${LIBOPUS_REPO:-https://gitlab.xiph.org/xiph/opus.git}"
LIBOPUS_REF="${LIBOPUS_REF:-}"
X264_REPO="${X264_REPO:-https://code.videolan.org/videolan/x264.git}"
X264_REF="${X264_REF:-stable}"
X265_REPO="${X265_REPO:-https://bitbucket.org/multicoreware/x265_git.git}"
X265_REF="${X265_REF:-}"
LIBFDK_AAC_REPO="${LIBFDK_AAC_REPO:-https://github.com/mstorsjo/fdk-aac.git}"
LIBFDK_AAC_REF="${LIBFDK_AAC_REF:-}"
LIBWEBP_REPO="${LIBWEBP_REPO:-https://chromium.googlesource.com/webm/libwebp}"
LIBWEBP_REF="${LIBWEBP_REF:-}"
LIBTHEORA_REPO="${LIBTHEORA_REPO:-https://gitlab.xiph.org/xiph/theora.git}"
LIBTHEORA_REF="${LIBTHEORA_REF:-}"
LIBOPENJPEG_REPO="${LIBOPENJPEG_REPO:-https://github.com/uclouvain/openjpeg.git}"
LIBOPENJPEG_REF="${LIBOPENJPEG_REF:-}"
FRIBIDI_REPO="${FRIBIDI_REPO:-https://github.com/fribidi/fribidi.git}"
FRIBIDI_REF="${FRIBIDI_REF:-}"
HARFBUZZ_REPO="${HARFBUZZ_REPO:-https://github.com/harfbuzz/harfbuzz.git}"
HARFBUZZ_REF="${HARFBUZZ_REF:-}"
LIBASS_REPO="${LIBASS_REPO:-https://github.com/libass/libass.git}"
LIBASS_REF="${LIBASS_REF:-}"
LIBSSH_REPO="${LIBSSH_REPO:-https://git.libssh.org/projects/libssh.git}"
LIBSSH_REF="${LIBSSH_REF:-}"
LIBARCHIVE_REPO="${LIBARCHIVE_REPO:-https://github.com/libarchive/libarchive.git}"
LIBARCHIVE_REF="${LIBARCHIVE_REF:-}"
RUBBERBAND_REPO="${RUBBERBAND_REPO:-https://github.com/breakfastquay/rubberband.git}"
RUBBERBAND_REF="${RUBBERBAND_REF:-}"
LIBDVDREAD_REPO="${LIBDVDREAD_REPO:-https://code.videolan.org/videolan/libdvdread.git}"
LIBDVDREAD_REF="${LIBDVDREAD_REF:-}"
LIBDVDNAV_REPO="${LIBDVDNAV_REPO:-https://code.videolan.org/videolan/libdvdnav.git}"
LIBDVDNAV_REF="${LIBDVDNAV_REF:-}"
LIBBLURAY_REPO="${LIBBLURAY_REPO:-https://code.videolan.org/videolan/libbluray.git}"
LIBBLURAY_REF="${LIBBLURAY_REF:-}"

# ── Paths ─────────────────────────────────────────────────────────────────────
SRC_DIR="$APP_DIR/src"
PREFIX="$APP_DIR"
MPV_SRC="$SRC_DIR/mpv"
FFMPEG_SRC="$SRC_DIR/ffmpeg"
MPV_BUILD_DIR="$MPV_SRC/build"

mkdir -p "$PREFIX" "$SRC_DIR" "$PREFIX"/{bin,lib,include,share} "$PREFIX/lib/pkgconfig"

# ── Cross environment ─────────────────────────────────────────────────────────
# PKG_CONFIG_LIBDIR (not _PATH) so ONLY our prefix's .pc files are visible —
# no host library can leak into the Windows binaries.
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR

export CC="$TRIPLE-gcc" CXX="$TRIPLE-g++" AR="$TRIPLE-ar" RANLIB="$TRIPLE-ranlib"
export WINDRES="$TRIPLE-windres" RC="$TRIPLE-windres" STRIP="$TRIPLE-strip"
export CFLAGS="${CFLAGS:-} -O2 -I$PREFIX/include"
export CXXFLAGS="${CXXFLAGS:-} -O2 -I$PREFIX/include"
export LDFLAGS="${LDFLAGS:-} -L$PREFIX/lib"
unset LD_LIBRARY_PATH

export PATH="$PREFIX/bin:$PATH"

# Prefixed pkg-config wrapper (some autoconf projects look for $TRIPLE-pkg-config)
cat > "$PREFIX/bin/$TRIPLE-pkg-config" <<EOS
#!/bin/sh
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH
exec pkg-config "\$@"
EOS
chmod +x "$PREFIX/bin/$TRIPLE-pkg-config"

# Meson cross file
MESON_CROSS="$APP_DIR/mingw64-cross.txt"
cat > "$MESON_CROSS" <<EOS
[binaries]
c = '$TRIPLE-gcc'
cpp = '$TRIPLE-g++'
ar = '$TRIPLE-ar'
strip = '$TRIPLE-strip'
windres = '$TRIPLE-windres'
pkg-config = '$PREFIX/bin/$TRIPLE-pkg-config'

[properties]
pkg_config_libdir = ['$PREFIX/lib/pkgconfig', '$PREFIX/share/pkgconfig']

[built-in options]
c_args = ['-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
cpp_args = ['-I$PREFIX/include']
cpp_link_args = ['-L$PREFIX/lib']

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOS

# CMake toolchain file
CMAKE_TC="$APP_DIR/mingw64-toolchain.cmake"
cat > "$CMAKE_TC" <<EOS
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $TRIPLE-gcc)
set(CMAKE_CXX_COMPILER $TRIPLE-g++)
set(CMAKE_RC_COMPILER $TRIPLE-windres)
set(CMAKE_FIND_ROOT_PATH "$PREFIX" /usr/$TRIPLE)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_PREFIX_PATH "$PREFIX")
EOS

# ── Helper functions ──────────────────────────────────────────────────────────

retry() {
  local tries="${RETRY_TRIES:-5}" delay="${RETRY_DELAY:-5}" n=1
  until "$@"; do
    if (( n >= tries )); then
      echo "!! '$*' failed after $tries attempts" >&2
      return 1
    fi
    echo "!! '$*' failed (attempt $n/$tries); retrying in ${delay}s ..." >&2
    sleep "$delay"
    n=$((n + 1)); delay=$((delay * 2))
  done
}

# Resumable builds: skip a step when its marker exists in $PREFIX/lib.
# Markers are import libs (libfoo.dll.a), static libs (libfoo.a) or .pc files.
built() {
  [ -z "${FORCE_REBUILD:-}" ] && [ -e "$PREFIX/lib/$1" ]
}

clone_or_update() {
  local url="$1" dest="$2" depth="${3:-1}"
  if [ -d "$dest/.git" ]; then
    echo "==> Updating $(basename "$dest")"
    git -C "$dest" remote set-url origin "$url"
    retry git -C "$dest" fetch --prune --tags --depth="$depth" origin \
      || retry git -C "$dest" fetch --prune --tags origin
  else
    echo "==> Cloning $(basename "$dest")"
    [ -e "$dest" ] && rm -rf "$dest"
    retry git clone --origin origin --depth="$depth" "$url" "$dest"
  fi
}

# ensure_checkout <dir> [ref] [submodules]; "no" skips submodules (see build_mpv.sh).
_submods(){ [ "${1:-recursive}" = no ] && return 0; git -C "$2" submodule update --init --recursive --depth 1 --jobs "$(nproc)"; }
ensure_checkout(){
  local dir="$1" ref="${2:-}" submods="${3:-recursive}"
  _submods "$submods" "$dir"
  [ -z "$ref" ] && return 0
  echo "==> Ensuring ref '$ref' in $(basename "$dir")"
  if git -C "$dir" ls-remote --exit-code --tags origin "refs/tags/$ref" >/dev/null 2>&1; then
    git -C "$dir" fetch --depth=1 origin "refs/tags/$ref:refs/tags/$ref" \
      || git -C "$dir" fetch origin "refs/tags/$ref:refs/tags/$ref"
    git -C "$dir" checkout --detach "refs/tags/$ref"
  elif git -C "$dir" ls-remote --exit-code --heads origin "$ref" >/dev/null 2>&1; then
    git -C "$dir" fetch --depth=1 origin "refs/heads/$ref:refs/remotes/origin/$ref" \
      || git -C "$dir" fetch origin "refs/heads/$ref:refs/remotes/origin/$ref"
    git -C "$dir" checkout -B "$ref" "refs/remotes/origin/$ref"
  elif git -C "$dir" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
    git -C "$dir" checkout --detach "$ref"
  else
    echo "!! Ref '$ref' not found; staying on default branch"
    git -C "$dir" fetch origin --unshallow || true
  fi
  _submods "$submods" "$dir"
}

fetch_tarball() {
  local url="$1" mirror="${2:-}" tarball
  tarball="$SRC_DIR/$(basename "$url")"
  if [ ! -f "$tarball" ]; then
    retry curl -fL "$url" -o "$tarball" \
      || { [ -n "$mirror" ] && retry curl -fL "$mirror" -o "$tarball"; }
  fi
  echo "$tarball"
}

# ── STEP 1: zlib ──────────────────────────────────────────────────────────────
if built libz.dll.a; then echo "==> zlib already built, skipping"; else
clone_or_update "$ZLIB_REPO" "$SRC_DIR/zlib" 1
ensure_checkout "$SRC_DIR/zlib" "$ZLIB_REF"
pushd "$SRC_DIR/zlib" >/dev/null
make -f win32/Makefile.gcc clean >/dev/null 2>&1 || true
make -f win32/Makefile.gcc -j"$(nproc)" PREFIX="$TRIPLE-" SHARED_MODE=1
make -f win32/Makefile.gcc install PREFIX="$TRIPLE-" SHARED_MODE=1 \
  INCLUDE_PATH="$PREFIX/include" LIBRARY_PATH="$PREFIX/lib" BINARY_PATH="$PREFIX/bin"
popd >/dev/null
[ -f "$PREFIX/lib/libz.dll.a" ] || { echo "!! zlib build failed"; exit 1; }
fi

# ── STEP 2: bzip2 (static; 8 C files, no DLL needed) ─────────────────────────
if built libbz2.a; then echo "==> bzip2 already built, skipping"; else
_tb="$(fetch_tarball "$BZIP2_URL")"
rm -rf "$SRC_DIR/bzip2-$BZIP2_VER"
tar xf "$_tb" -C "$SRC_DIR"
pushd "$SRC_DIR/bzip2-$BZIP2_VER" >/dev/null
make libbz2.a CC="$CC" AR="$AR" RANLIB="$RANLIB" \
  CFLAGS="-O2 -D_FILE_OFFSET_BITS=64 -DWIN32"
install -m644 bzlib.h "$PREFIX/include/"
install -m644 libbz2.a "$PREFIX/lib/"
popd >/dev/null
[ -f "$PREFIX/lib/libbz2.a" ] || { echo "!! bzip2 build failed"; exit 1; }
fi

# ── STEP 3: xz / liblzma ──────────────────────────────────────────────────────
if built liblzma.dll.a; then echo "==> liblzma already built, skipping"; else
_tb="$(fetch_tarball "$XZ_URL")"
rm -rf "$SRC_DIR/xz-$XZ_VER"
tar xf "$_tb" -C "$SRC_DIR"
pushd "$SRC_DIR/xz-$XZ_VER" >/dev/null
./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" \
  --enable-shared --disable-static \
  --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
  --disable-lzma-links --disable-scripts --disable-doc
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/liblzma.dll.a" ] || { echo "!! liblzma build failed"; exit 1; }
fi

# ── STEP 4: libiconv ──────────────────────────────────────────────────────────
if built libiconv.dll.a; then echo "==> libiconv already built, skipping"; else
_tb="$(fetch_tarball "$LIBICONV_URL" "$LIBICONV_URL_MIRROR")"
rm -rf "$SRC_DIR/libiconv-$LIBICONV_VER"
tar xf "$_tb" -C "$SRC_DIR"
pushd "$SRC_DIR/libiconv-$LIBICONV_VER" >/dev/null
./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" \
  --enable-shared --disable-static --disable-nls
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libiconv.dll.a" ] || { echo "!! libiconv build failed"; exit 1; }
fi

# ── STEP 5: freetype ──────────────────────────────────────────────────────────
# Mandatory for libass on every platform (DirectWrite is only a font provider).
if built libfreetype.dll.a; then echo "==> freetype already built, skipping"; else
clone_or_update "$FREETYPE_REPO" "$SRC_DIR/freetype" 1
ensure_checkout "$SRC_DIR/freetype" "$FREETYPE_REF"
pushd "$SRC_DIR/freetype" >/dev/null
rm -rf build
meson setup build . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Dharfbuzz=disabled -Dbrotli=disabled -Dpng=disabled \
  -Dbzip2=disabled -Dzlib=system
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libfreetype.dll.a" ] || { echo "!! freetype build failed"; exit 1; }
fi

# ── STEP 6: uchardet ──────────────────────────────────────────────────────────
if built libuchardet.dll.a; then echo "==> uchardet already built, skipping"; else
clone_or_update "$UCHARDET_REPO" "$SRC_DIR/uchardet" 1
ensure_checkout "$SRC_DIR/uchardet" "$UCHARDET_REF"
pushd "$SRC_DIR/uchardet" >/dev/null
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DBUILD_BINARY=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libuchardet.dll.a" ] || { echo "!! uchardet build failed"; exit 1; }
fi

# ── STEP 7: lcms2 (libplacebo ICC profiles) ───────────────────────────────────
if built liblcms2.dll.a; then echo "==> lcms2 already built, skipping"; else
clone_or_update "$LCMS2_REPO" "$SRC_DIR/lcms2" 1
ensure_checkout "$SRC_DIR/lcms2" "$LCMS2_REF"
pushd "$SRC_DIR/lcms2" >/dev/null
if [ -f meson.build ]; then
  rm -rf build
  meson setup build . --cross-file="$MESON_CROSS" \
    --prefix="$PREFIX" --buildtype=release \
    -Ddefault_library=shared -Dutils=false
  meson compile -C build -j"$(nproc)"
  meson install -C build
else
  autoreconf -fi
  ./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" --enable-shared --disable-static
  make -j"$(nproc)" && make install
fi
popd >/dev/null
[ -f "$PREFIX/lib/liblcms2.dll.a" ] || { echo "!! lcms2 build failed"; exit 1; }
fi

# ── STEP 8: dav1d (AV1 decoder) ───────────────────────────────────────────────
if built libdav1d.dll.a; then echo "==> dav1d already built, skipping"; else
clone_or_update "$DAV1D_REPO" "$SRC_DIR/dav1d" 1
ensure_checkout "$SRC_DIR/dav1d" "$DAV1D_REF"
pushd "$SRC_DIR/dav1d" >/dev/null
rm -rf build
meson setup build . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Denable_tools=false -Denable_tests=false
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libdav1d.dll.a" ] || { echo "!! dav1d build failed"; exit 1; }
fi

# ── STEP 9: nv-codec-headers (NVDEC/CUVID hwaccel; header-only) ───────────────
if built pkgconfig/ffnvcodec.pc; then echo "==> nv-codec-headers already installed, skipping"; else
clone_or_update "$NVCODEC_REPO" "$SRC_DIR/nv-codec-headers" 1
ensure_checkout "$SRC_DIR/nv-codec-headers" "$NVCODEC_REF"
make -C "$SRC_DIR/nv-codec-headers" install PREFIX="$PREFIX"
[ -f "$PREFIX/lib/pkgconfig/ffnvcodec.pc" ] || { echo "!! nv-codec-headers install failed"; exit 1; }
fi

# ── STEP 10: Vulkan-Headers ───────────────────────────────────────────────────
if [ -z "${FORCE_REBUILD:-}" ] && [ -f "$PREFIX/include/vulkan/vulkan.h" ]; then
  echo "==> Vulkan-Headers already installed, skipping"
else
clone_or_update "$VULKAN_HEADERS_REPO" "$SRC_DIR/vulkan-headers" 1
ensure_checkout "$SRC_DIR/vulkan-headers" "$VULKAN_HEADERS_REF"
pushd "$SRC_DIR/vulkan-headers" >/dev/null
cmake -B build -S . -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release
cmake --install build
popd >/dev/null
[ -f "$PREFIX/include/vulkan/vulkan.h" ] || { echo "!! Vulkan-Headers install failed"; exit 1; }
fi

# ── STEP 11: Vulkan-Loader (link-time only; vulkan-1.dll is NOT shipped — the
#             real one comes from the GPU driver via System32) ────────────────
if built libvulkan-1.dll.a || built libvulkan.dll.a; then echo "==> Vulkan-Loader already built, skipping"; else
clone_or_update "$VULKAN_LOADER_REPO" "$SRC_DIR/vulkan-loader" 1
ensure_checkout "$SRC_DIR/vulkan-loader" "$VULKAN_LOADER_REF"
pushd "$SRC_DIR/vulkan-loader" >/dev/null
rm -rf build
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DUPDATE_DEPS=OFF -DBUILD_TESTS=OFF -DENABLE_WERROR=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
_vk_implib="$(find "$PREFIX/lib" -maxdepth 1 -name 'libvulkan*.dll.a' | head -1)"
[ -n "$_vk_implib" ] || { echo "!! Vulkan-Loader build failed (no import lib)"; \
  echo "   Fallback: extract MSYS2 mingw-w64-x86_64-vulkan-loader, or gendef a Windows vulkan-1.dll"; exit 1; }
fi

# Hand-write vulkan.pc if the loader didn't install one (libplacebo/mpv use pkg-config)
if [ ! -f "$PREFIX/lib/pkgconfig/vulkan.pc" ]; then
  _vk_implib="$(find "$PREFIX/lib" -maxdepth 1 -name 'libvulkan*.dll.a' | head -1)"
  _vk_lname="$(basename "$_vk_implib" .dll.a)"; _vk_lname="${_vk_lname#lib}"
  _vk_patch="$(sed -n 's/^#define VK_HEADER_VERSION \([0-9]*\)$/\1/p' "$PREFIX/include/vulkan/vulkan_core.h" | head -1)"
  cat > "$PREFIX/lib/pkgconfig/vulkan.pc" <<EOFPC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Vulkan-Loader
Description: Vulkan Loader
Version: 1.4.${_vk_patch:-0}
Libs: -L\${libdir} -l${_vk_lname}
Cflags: -I\${includedir}
EOFPC
  echo "==> Wrote vulkan.pc (-l${_vk_lname})"
fi

# ── STEP 12: shaderc (static; SPIR-V compiler for libplacebo/vulkan) ──────────
if built libshaderc_combined.a; then echo "==> shaderc already built, skipping"; else
clone_or_update "$SHADERC_REPO" "$SRC_DIR/shaderc" 1
ensure_checkout "$SRC_DIR/shaderc" "$SHADERC_REF"
pushd "$SRC_DIR/shaderc" >/dev/null
retry python3 utils/git-sync-deps
rm -rf build
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
  -DSHADERC_SKIP_COPYRIGHT_CHECK=ON
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libshaderc_combined.a" ] || { echo "!! shaderc build failed"; exit 1; }
fi

# Make pkg-config 'shaderc' resolve to the static combined lib. It is C++
# linked into C programs (mpv), so the C++ runtime must ride along explicitly.
if [ -f "$PREFIX/lib/pkgconfig/shaderc_combined.pc" ]; then
  sed -e 's/^Name: shaderc_combined/Name: shaderc/' \
      -e 's/^Libs: \(.*\)-lshaderc_combined\(.*\)$/Libs: \1-lshaderc_combined -lstdc++\2/' \
    "$PREFIX/lib/pkgconfig/shaderc_combined.pc" > "$PREFIX/lib/pkgconfig/shaderc.pc"
  grep -q 'lstdc++' "$PREFIX/lib/pkgconfig/shaderc.pc" \
    || sed -i 's/^Libs: .*/& -lstdc++/' "$PREFIX/lib/pkgconfig/shaderc.pc"
fi

# ── STEP 13: SPIRV-Cross (mpv d3d11 fallback renderer) ────────────────────────
if built libspirv-cross-c-shared.dll.a; then echo "==> SPIRV-Cross already built, skipping"; else
clone_or_update "$SPIRV_CROSS_REPO" "$SRC_DIR/spirv-cross" 1
ensure_checkout "$SRC_DIR/spirv-cross" "$SPIRV_CROSS_REF"
pushd "$SRC_DIR/spirv-cross" >/dev/null
rm -rf build
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_STATIC=OFF \
  -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_ENABLE_TESTS=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libspirv-cross-c-shared.dll.a" ] || { echo "!! SPIRV-Cross build failed"; exit 1; }
fi

# ── STEP 14: libplacebo ───────────────────────────────────────────────────────
if built libplacebo.dll.a; then echo "==> libplacebo already built, skipping"; else
clone_or_update "$LIBPLACEBO_REPO" "$SRC_DIR/libplacebo" 1
ensure_checkout "$SRC_DIR/libplacebo" "$LIBPLACEBO_REF"
pushd "$SRC_DIR/libplacebo" >/dev/null
rm -rf build
meson setup build . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Dvulkan=enabled -Dshaderc=enabled -Dglslang=disabled \
  -Dd3d11=enabled -Dlcms=enabled \
  -Ddemos=false -Dtests=false
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libplacebo.dll.a" ] || { echo "!! libplacebo build failed"; exit 1; }
fi

# ── STEP 15: LuaJIT ───────────────────────────────────────────────────────────
if built liblua51.dll.a; then echo "==> LuaJIT already built, skipping"; else
clone_or_update "$LUAJIT_REPO" "$SRC_DIR/luajit" 1
ensure_checkout "$SRC_DIR/luajit" "$LUAJIT_REF"
pushd "$SRC_DIR/luajit" >/dev/null
make clean >/dev/null 2>&1 || true
make -j"$(nproc)" HOST_CC="gcc" CROSS="$TRIPLE-" TARGET_SYS=Windows BUILDMODE=dynamic amalg
# Cross make install doesn't understand Windows layouts — install manually.
install -m755 src/lua51.dll "$PREFIX/bin/"
if [ -f src/libluajit-5.1.dll.a ]; then
  install -m644 src/libluajit-5.1.dll.a "$PREFIX/lib/liblua51.dll.a"
else
  ( cd src && gendef lua51.dll && \
    "$TRIPLE-dlltool" -d lua51.def -D lua51.dll -l "$PREFIX/lib/liblua51.dll.a" )
fi
mkdir -p "$PREFIX/include/luajit-2.1"
install -m644 src/lua.h src/lauxlib.h src/lualib.h src/luaconf.h src/lua.hpp src/luajit.h \
  "$PREFIX/include/luajit-2.1/"
cat > "$PREFIX/lib/pkgconfig/luajit.pc" <<EOFPC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/luajit-2.1

Name: LuaJIT
Description: Just-in-time compiler for Lua
Version: 2.1.9999
Libs: -L\${libdir} -llua51
Cflags: -I\${includedir}
EOFPC
popd >/dev/null
[ -f "$PREFIX/lib/liblua51.dll.a" ] || { echo "!! LuaJIT build failed"; exit 1; }
fi

# ── STEP 16: OpenSSL ──────────────────────────────────────────────────────────
if built libssl.dll.a; then echo "==> OpenSSL already built, skipping"; else
clone_or_update "$OPENSSL_REPO" "$SRC_DIR/openssl" 1
ensure_checkout "$SRC_DIR/openssl" "$OPENSSL_REF" no   # skip test-only quiche/boringssl submodules
pushd "$SRC_DIR/openssl" >/dev/null
# OpenSSL derives the toolchain from --cross-compile-prefix; a set CC would
# be double-prefixed. Run in a cleaned subshell.
(
  unset CC CXX AR RANLIB WINDRES RC STRIP CROSS_COMPILE
  ./Configure mingw64 --cross-compile-prefix="$TRIPLE-" \
    --prefix="$PREFIX" --openssldir="$PREFIX/ssl" --libdir=lib \
    shared no-tests no-docs
  make -j"$(nproc)"
  make install_sw
)
popd >/dev/null
[ -f "$PREFIX/lib/libssl.dll.a" ] || { echo "!! OpenSSL build failed"; exit 1; }
fi

# ── STEP 17: libvpx (static — shared is unsupported for win64 targets) ────────
if built libvpx.a; then echo "==> libvpx already built, skipping"; else
clone_or_update "$LIBVPX_REPO" "$SRC_DIR/libvpx" 1
ensure_checkout "$SRC_DIR/libvpx" "$LIBVPX_REF"
pushd "$SRC_DIR/libvpx" >/dev/null
(
  unset CC CXX AR RANLIB
  export CROSS="$TRIPLE-"
  ./configure --prefix="$PREFIX" --target=x86_64-win64-gcc \
    --enable-static --disable-shared \
    --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth \
    --enable-runtime-cpu-detect \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests
  make -j"$(nproc)"
  make install
)
popd >/dev/null
[ -f "$PREFIX/lib/libvpx.a" ] || { echo "!! libvpx build failed"; exit 1; }
fi

# ── STEP 18: libogg ───────────────────────────────────────────────────────────
if built libogg.dll.a; then echo "==> libogg already built, skipping"; else
clone_or_update "$LIBOGG_REPO" "$SRC_DIR/ogg" 1
ensure_checkout "$SRC_DIR/ogg" "$LIBOGG_REF"
pushd "$SRC_DIR/ogg" >/dev/null
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DINSTALL_DOCS=OFF
cmake --build build -j"$(nproc)"
cmake --install build
# The import lib records the DLL as 'ogg.dll' while cmake names the file
# libogg.dll; ship it under the name consumers actually load.
[ -f "$PREFIX/bin/libogg.dll" ] && cp -f "$PREFIX/bin/libogg.dll" "$PREFIX/bin/ogg.dll"
popd >/dev/null
[ -f "$PREFIX/lib/libogg.dll.a" ] || { echo "!! libogg build failed"; exit 1; }
fi

# ── STEP 19: libvorbis ────────────────────────────────────────────────────────
if built libvorbis.dll.a; then echo "==> libvorbis already built, skipping"; else
clone_or_update "$LIBVORBIS_REPO" "$SRC_DIR/vorbis" 1
ensure_checkout "$SRC_DIR/vorbis" "$LIBVORBIS_REF"
pushd "$SRC_DIR/vorbis" >/dev/null
# autotools, not cmake: vorbis's cmake passes win32/vorbis.def straight to the
# link line, which mingw ld rejects; libtool handles exports itself.
( ./autogen.sh || autoreconf -fi ) >/dev/null 2>&1 || true
./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" \
  --enable-shared --disable-static \
  --disable-examples --disable-docs \
  --with-ogg="$PREFIX"
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libvorbis.dll.a" ] || { echo "!! libvorbis build failed"; exit 1; }
fi

# ── STEP 20: libopus ──────────────────────────────────────────────────────────
if built libopus.dll.a; then echo "==> libopus already built, skipping"; else
clone_or_update "$LIBOPUS_REPO" "$SRC_DIR/opus" 1
ensure_checkout "$SRC_DIR/opus" "$LIBOPUS_REF"
pushd "$SRC_DIR/opus" >/dev/null
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libopus.dll.a" ] || { echo "!! libopus build failed"; exit 1; }
fi

# ── STEP 21: libx264 ──────────────────────────────────────────────────────────
if built libx264.dll.a; then echo "==> libx264 already built, skipping"; else
clone_or_update "$X264_REPO" "$SRC_DIR/x264" 1
ensure_checkout "$SRC_DIR/x264" "$X264_REF"
pushd "$SRC_DIR/x264" >/dev/null
./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" --cross-prefix="$TRIPLE-" \
  --enable-shared --disable-static --disable-cli --disable-opencl
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libx264.dll.a" ] || { echo "!! libx264 build failed"; exit 1; }
fi

# ── STEP 22: libx265 ──────────────────────────────────────────────────────────
if built libx265.dll.a || built libx265.a; then echo "==> libx265 already built, skipping"; else
clone_or_update "$X265_REPO" "$SRC_DIR/x265" 1
ensure_checkout "$SRC_DIR/x265" "$X265_REF"
# x265's cmake needs `git describe` to see a tag; a depth=1 clone has none.
retry git -C "$SRC_DIR/x265" fetch --unshallow --tags \
  || retry git -C "$SRC_DIR/x265" fetch --tags || true
pushd "$SRC_DIR/x265" >/dev/null
rm -rf build
cmake -B build -S source -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=ON
cmake --build build -j"$(nproc)"
cmake --install build
# mingw quirk fallbacks: DLL sometimes only lands in the build dir, and the
# .pc file is not always generated.
if [ ! -f "$PREFIX/lib/libx265.dll.a" ] && [ -f build/libx265.dll.a ]; then
  cp build/libx265.dll.a "$PREFIX/lib/"
fi
_x265dll="$(find build -maxdepth 1 -name 'libx265*.dll' | head -1)"
if [ -n "$_x265dll" ] && [ ! -f "$PREFIX/bin/$(basename "$_x265dll")" ]; then
  cp "$_x265dll" "$PREFIX/bin/"
fi
if [ ! -f "$PREFIX/lib/pkgconfig/x265.pc" ]; then
  _x265ver="$(grep -m1 'set(X265_BUILD' source/CMakeLists.txt | grep -o '[0-9]*')"
  cat > "$PREFIX/lib/pkgconfig/x265.pc" <<EOFPC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: ${_x265ver:-216}
Libs: -L\${libdir} -lx265
Libs.private: -lstdc++ -lm
Cflags: -I\${includedir}
EOFPC
fi
popd >/dev/null
[ -f "$PREFIX/lib/libx265.dll.a" ] || { echo "!! libx265 build failed"; exit 1; }
fi

# ── STEP 23: libfdk-aac ───────────────────────────────────────────────────────
# GPL-incompatible: skipped for DISTRIBUTABLE=1 release builds.
if [ "$DISTRIBUTABLE" = 1 ]; then echo "==> DISTRIBUTABLE=1: skipping libfdk-aac (nonfree)"; elif built libfdk-aac.dll.a; then echo "==> libfdk-aac already built, skipping"; else
clone_or_update "$LIBFDK_AAC_REPO" "$SRC_DIR/fdk-aac" 1
ensure_checkout "$SRC_DIR/fdk-aac" "$LIBFDK_AAC_REF"
pushd "$SRC_DIR/fdk-aac" >/dev/null
autoreconf -fi
./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" --enable-shared --disable-static
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libfdk-aac.dll.a" ] || { echo "!! libfdk-aac build failed"; exit 1; }
fi

# ── STEP 24: libwebp ──────────────────────────────────────────────────────────
if built libwebp.dll.a; then echo "==> libwebp already built, skipping"; else
clone_or_update "$LIBWEBP_REPO" "$SRC_DIR/libwebp" 1
ensure_checkout "$SRC_DIR/libwebp" "$LIBWEBP_REF"
pushd "$SRC_DIR/libwebp" >/dev/null
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
  -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
  -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_EXTRAS=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libwebp.dll.a" ] || { echo "!! libwebp build failed"; exit 1; }
fi

# ── STEP 25: libtheora ────────────────────────────────────────────────────────
if built libtheora.dll.a; then echo "==> libtheora already built, skipping"; else
clone_or_update "$LIBTHEORA_REPO" "$SRC_DIR/theora" 1
ensure_checkout "$SRC_DIR/theora" "$LIBTHEORA_REF"
pushd "$SRC_DIR/theora" >/dev/null
( ./autogen.sh || autoreconf -fi ) >/dev/null 2>&1 || true
# theora's codebase predates C11; GCC 15+ defaults to C23 which breaks it
CFLAGS="$CFLAGS -std=gnu17" \
./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" \
  --enable-shared --disable-static \
  --disable-examples --disable-doc --disable-spec \
  --with-ogg-libraries="$PREFIX/lib" --with-ogg-includes="$PREFIX/include" \
  --with-vorbis-libraries="$PREFIX/lib" --with-vorbis-includes="$PREFIX/include"
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libtheora.dll.a" ] || { echo "!! libtheora build failed"; exit 1; }
fi

# ── STEP 26: libopenjpeg ──────────────────────────────────────────────────────
if built libopenjp2.dll.a; then echo "==> libopenjpeg already built, skipping"; else
clone_or_update "$LIBOPENJPEG_REPO" "$SRC_DIR/openjpeg" 1
ensure_checkout "$SRC_DIR/openjpeg" "$LIBOPENJPEG_REF"
pushd "$SRC_DIR/openjpeg" >/dev/null
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_CODEC=OFF -DBUILD_DOC=OFF -DBUILD_TESTING=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libopenjp2.dll.a" ] || { echo "!! libopenjpeg build failed"; exit 1; }
fi

# ── STEP 27: fribidi ──────────────────────────────────────────────────────────
if built libfribidi.dll.a; then echo "==> fribidi already built, skipping"; else
clone_or_update "$FRIBIDI_REPO" "$SRC_DIR/fribidi" 1
ensure_checkout "$SRC_DIR/fribidi" "$FRIBIDI_REF"
pushd "$SRC_DIR/fribidi" >/dev/null
rm -rf build
meson setup build . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Ddocs=false -Dtests=false -Dbin=false
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libfribidi.dll.a" ] || { echo "!! fribidi build failed"; exit 1; }
fi

# ── STEP 28: harfbuzz ─────────────────────────────────────────────────────────
if built libharfbuzz.dll.a; then echo "==> harfbuzz already built, skipping"; else
clone_or_update "$HARFBUZZ_REPO" "$SRC_DIR/harfbuzz" 1
ensure_checkout "$SRC_DIR/harfbuzz" "$HARFBUZZ_REF"
pushd "$SRC_DIR/harfbuzz" >/dev/null
rm -rf build
meson setup build . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Dutilities=disabled \
  -Dtests=disabled -Ddocs=disabled -Dbenchmark=disabled \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
  -Dchafa=disabled -Dintrospection=disabled \
  -Dicu=disabled -Dgraphite=disabled -Dgraphite2=disabled \
  -Ddirectwrite=disabled \
  -Dfreetype=enabled
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libharfbuzz.dll.a" ] || { echo "!! harfbuzz build failed"; exit 1; }
fi

# ── STEP 29: libass (DirectWrite font provider; NO fontconfig) ────────────────
if built libass.dll.a; then echo "==> libass already built, skipping"; else
clone_or_update "$LIBASS_REPO" "$SRC_DIR/libass" 1
ensure_checkout "$SRC_DIR/libass" "$LIBASS_REF"
pushd "$SRC_DIR/libass" >/dev/null
./autogen.sh
./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" \
  --enable-shared --disable-static \
  --disable-fontconfig 2>&1 | tee configure.out
grep -Eiq 'directwrite:? *(yes|true)' configure.out \
  || echo "!! WARNING: libass configure summary did not confirm DirectWrite — check configure.out"
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libass.dll.a" ] || { echo "!! libass build failed"; exit 1; }
fi

# ── STEP 30: libssh ───────────────────────────────────────────────────────────
if built libssh.dll.a; then echo "==> libssh already built, skipping"; else
clone_or_update "$LIBSSH_REPO" "$SRC_DIR/libssh" 1
ensure_checkout "$SRC_DIR/libssh" "$LIBSSH_REF"
pushd "$SRC_DIR/libssh" >/dev/null
rm -rf build
cmake -B build -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DWITH_STATIC_LIB=OFF \
  -DOPENSSL_ROOT_DIR="$PREFIX" \
  -DWITH_SERVER=OFF -DWITH_GSSAPI=OFF -DWITH_NACL=OFF -DWITH_ZLIB=ON \
  -DWITH_TESTING=OFF -DWITH_EXAMPLES=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libssh.dll.a" ] || { echo "!! libssh build failed"; exit 1; }
fi

# ── STEP 31: libarchive ───────────────────────────────────────────────────────
if built libarchive.dll.a; then echo "==> libarchive already built, skipping"; else
clone_or_update "$LIBARCHIVE_REPO" "$SRC_DIR/libarchive" 1
ensure_checkout "$SRC_DIR/libarchive" "$LIBARCHIVE_REF"
pushd "$SRC_DIR/libarchive" >/dev/null
# libarchive keeps its CMake modules in build/cmake — restore it (an earlier
# run's `rm -rf build` clobbered it) and build out of a separate dir.
git checkout -- build 2>/dev/null || true
# CMake 4 removed the CheckHeaderDirent module some libarchive revisions still
# INCLUDE from CMake itself; shim it into the tree's module dir if absent.
if [ ! -f build/cmake/CheckHeaderDirent.cmake ]; then
  cat > build/cmake/CheckHeaderDirent.cmake <<'EOFCM'
include(CheckIncludeFiles)
macro(CHECK_HEADER_DIRENT)
  check_include_files("${INCLUDES};dirent.h" HAVE_DIRENT_H)
  if(NOT HAVE_DIRENT_H)
    check_include_files("${INCLUDES};sys/ndir.h" HAVE_SYS_NDIR_H)
    if(NOT HAVE_SYS_NDIR_H)
      check_include_files("${INCLUDES};ndir.h" HAVE_NDIR_H)
      if(NOT HAVE_NDIR_H)
        check_include_files("${INCLUDES};sys/dir.h" HAVE_SYS_DIR_H)
      endif()
    endif()
  endif()
endmacro()
EOFCM
fi
rm -rf build-cross
cmake -B build-cross -S . -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DENABLE_TEST=OFF \
  -DOPENSSL_ROOT_DIR="$PREFIX" \
  -DENABLE_XML2=OFF -DENABLE_LZ4=OFF -DENABLE_ZSTD=OFF \
  -DENABLE_LIBB2=OFF -DENABLE_EXPAT=OFF \
  -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF
cmake --build build-cross -j"$(nproc)"
cmake --install build-cross
popd >/dev/null
[ -f "$PREFIX/lib/libarchive.dll.a" ] || { echo "!! libarchive build failed"; exit 1; }
fi

# ── STEP 32: rubberband ───────────────────────────────────────────────────────
# builtin fft AND builtin resampler (the Linux build's -Dresampler=speex was
# silently linking the build host's speexdsp).
if built librubberband.dll.a; then echo "==> rubberband already built, skipping"; else
clone_or_update "$RUBBERBAND_REPO" "$SRC_DIR/rubberband" 1
ensure_checkout "$SRC_DIR/rubberband" "$RUBBERBAND_REF"
pushd "$SRC_DIR/rubberband" >/dev/null
rm -rf build
meson setup build . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Dfft=builtin -Dresampler=builtin \
  -Djni=disabled -Dladspa=disabled -Dlv2=disabled -Dvamp=disabled \
  -Dcmdline=disabled -Dtests=disabled
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/librubberband.dll.a" ] || { echo "!! rubberband build failed"; exit 1; }
fi

# ── STEP 33: libdvdread ───────────────────────────────────────────────────────
if built libdvdread.dll.a; then echo "==> libdvdread already built, skipping"; else
clone_or_update "$LIBDVDREAD_REPO" "$SRC_DIR/libdvdread" 1
ensure_checkout "$SRC_DIR/libdvdread" "$LIBDVDREAD_REF"
pushd "$SRC_DIR/libdvdread" >/dev/null
rm -rf build
meson setup build . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Denable_docs=false
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libdvdread.dll.a" ] || { echo "!! libdvdread build failed"; exit 1; }
fi

# ── STEP 34: libdvdnav ────────────────────────────────────────────────────────
if built libdvdnav.dll.a; then echo "==> libdvdnav already built, skipping"; else
clone_or_update "$LIBDVDNAV_REPO" "$SRC_DIR/libdvdnav" 1
ensure_checkout "$SRC_DIR/libdvdnav" "$LIBDVDNAV_REF"
pushd "$SRC_DIR/libdvdnav" >/dev/null
rm -rf build
meson setup build . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libdvdnav.dll.a" ] || { echo "!! libdvdnav build failed"; exit 1; }
fi

# ── STEP 35: libbluray ────────────────────────────────────────────────────────
if built libbluray.dll.a; then echo "==> libbluray already built, skipping"; else
clone_or_update "$LIBBLURAY_REPO" "$SRC_DIR/libbluray" 1
ensure_checkout "$SRC_DIR/libbluray" "$LIBBLURAY_REF"
pushd "$SRC_DIR/libbluray" >/dev/null
if [ -f meson.build ]; then
  rm -rf build
  meson setup build . --cross-file="$MESON_CROSS" \
    --prefix="$PREFIX" --buildtype=release \
    -Ddefault_library=shared \
    -Dbdj_jar=disabled -Denable_tools=false \
    -Dfontconfig=disabled -Dfreetype=disabled -Dlibxml2=disabled
  meson compile -C build -j"$(nproc)"
  meson install -C build
else
  ( ./bootstrap || autoreconf -fi || true ) >/dev/null 2>&1 || true
  ./configure --prefix="$PREFIX" --build="$BUILD_TRIPLE" --host="$TRIPLE" \
    --enable-shared --disable-static \
    --disable-bdjava-jar --without-bdjava --without-fontconfig --without-libxml2
  make -j"$(nproc)"
  make install
fi
popd >/dev/null
[ -f "$PREFIX/lib/libbluray.dll.a" ] || { echo "!! libbluray build failed"; exit 1; }
fi

# ── STEP 36: FFmpeg (TrueHD-patched) ──────────────────────────────────────────
# Always rebuilt so the spdifenc.c patch is freshly applied.
clone_or_update "$FFMPEG_REPO" "$FFMPEG_SRC" 1
ensure_checkout "$FFMPEG_SRC" "$FFMPEG_REF"
echo "==> Cleaning FFmpeg source tree ..."
pushd "$FFMPEG_SRC" >/dev/null
( make distclean || true ) >/dev/null 2>&1 || true
git reset --hard
git clean -fdx
popd >/dev/null

SPDIF_PATCH="$SCRIPT_DIR/patches/spdifenc.c"
if [ -f "$SPDIF_PATCH" ]; then
  echo "==> Applying patched spdifenc.c (TrueHD/Atmos MAT padding fix, FFmpeg PR #23542) ..."
  cp -f "$SPDIF_PATCH" "$FFMPEG_SRC/libavformat/spdifenc.c"
else
  echo "!! Patch $SPDIF_PATCH not found; building with upstream spdifenc.c"
fi

echo "==> Configuring FFmpeg (mingw-w64 cross) ..."
pushd "$FFMPEG_SRC" >/dev/null
# nonfree/fdk-aac only for personal (non-distributable) builds.
FF_NONFREE=()
if [ "$DISTRIBUTABLE" != 1 ]; then
  FF_NONFREE=(--enable-nonfree --enable-libfdk-aac)
fi
./configure \
  --prefix="$PREFIX" \
  --target-os=mingw32 --arch=x86_64 --cross-prefix="$TRIPLE-" --enable-cross-compile \
  --pkg-config=pkg-config \
  --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
  --enable-gpl --enable-version3 \
  "${FF_NONFREE[@]}" \
  --enable-shared --disable-static \
  --enable-openssl --disable-schannel \
  --enable-libx264 --enable-libx265 \
  --enable-libvpx --enable-libdav1d --enable-libopus --enable-libvorbis \
  --enable-libass --enable-libfreetype \
  --enable-libbluray --enable-libwebp --enable-libtheora \
  --enable-libopenjpeg --enable-libssh \
  --enable-mediafoundation --enable-d3d11va --enable-dxva2 \
  --enable-lzma --enable-zlib --enable-bzlib
make -j"$(nproc)" V=1
make install
popd >/dev/null
[ -f "$PREFIX/bin/ffmpeg.exe" ] || { echo "!! FFmpeg build failed"; exit 1; }

# ── STEP 37: mpv ──────────────────────────────────────────────────────────────
clone_or_update "$MPV_REPO" "$MPV_SRC" 1
git -C "$MPV_SRC" reset --hard
git -C "$MPV_SRC" clean -fdx -e build
ensure_checkout "$MPV_SRC" "$MPV_REF"

# Streaming enhancements + RAM fix = "enhanced" variant only. "stock" ships
# stock mpv (the Atmos/TrueHD spdifenc patch is in the FFmpeg step, both variants).
if [ "$VARIANT" = enhanced ]; then

# Custom patches — identical set and order to the Linux build (all are
# platform-agnostic anchored edits; they abort loudly if upstream moved).
for p in apply_segmented_http.sh apply_segmented_speed.sh \
         apply_demux_cache_unselected_subs.sh apply_thumbnail_cache.sh \
         apply_next_file_prefetch.sh; do
  PATCH="$SCRIPT_DIR/patches/$p"
  if [ -x "$PATCH" ]; then
    "$PATCH" "$MPV_SRC"
  else
    echo "!! $PATCH not found; building without it"
  fi
done

# Windows-only RAM fix: the Linux malloc patch (patches/apply_malloc_tuning.sh)
# targets glibc/osdep/main-fn-unix.c, which is not compiled here. Its Windows
# analog periodically decommits freed heap back to the OS via
# osdep/main-fn-win.c so a long playlist holds RSS flat.
MALLOC_WIN_PATCH="$SCRIPT_DIR/patches/apply_malloc_tuning_win.sh"
if [ -x "$MALLOC_WIN_PATCH" ]; then
  "$MALLOC_WIN_PATCH" "$MPV_SRC"
else
  echo "!! $MALLOC_WIN_PATCH not found; building without Windows heap-trim fix"
fi

else
  echo "==> VARIANT=stock: skipping streaming patches and the RAM/heap-trim patch"
fi

rm -rf "$MPV_BUILD_DIR"
pushd "$MPV_SRC" >/dev/null
meson setup "$MPV_BUILD_DIR" . --cross-file="$MESON_CROSS" \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Dlibmpv=true -Dcplugins=auto \
  -Dlua=luajit -Dlibarchive=enabled -Drubberband=enabled \
  -Duchardet=enabled -Diconv=enabled \
  -Ddvdnav=enabled -Dcdda=disabled -Dvapoursynth=disabled \
  -Dvulkan=enabled -Dd3d11=enabled -Dgl-win32=enabled -Dspirv-cross=enabled
ninja -C "$MPV_BUILD_DIR" -j"$(nproc)"
ninja -C "$MPV_BUILD_DIR" install
popd >/dev/null
[ -f "$PREFIX/bin/mpv.exe" ] || { echo "!! mpv build failed"; exit 1; }

echo
echo "==> Windows cross-build complete."
echo "    Prefix:   $PREFIX"
echo "    Binaries: $PREFIX/bin/{mpv.exe,mpv.com,ffmpeg.exe,ffprobe.exe}"
echo
echo "Next: ./collect_dlls.sh   (assembles the flat dist-win/ bundle + verifies DLL closure)"
