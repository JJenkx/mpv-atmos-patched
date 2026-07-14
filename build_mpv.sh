#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────── Preflight: ensure build deps ───────────────────────────
# Distro-aware: pacman on Arch (local dev), apt on Debian/Ubuntu (the older-glibc
# container used for portable release builds in CI). Everything else is built
# from source below, so only build tools + a handful of system libs are needed.
if [[ $EUID -eq 0 ]]; then
  _SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  _SUDO="sudo"
else
  echo "'sudo' is not installed and you're not root."; exit 1
fi

if command -v pacman >/dev/null 2>&1; then
  _PKG_GROUPS=(base-devel)
  _PKGS=(
    git curl python python-pip
    cmake meson ninja pkgconf
    autoconf automake libtool m4
    yasm nasm
    gcc gcc-libs binutils make
    perl texinfo
    libx11 libxcb libxext xorgproto
    wayland wayland-protocols
    vulkan-headers uchardet libxpresent
    libxml2 freetype2 fontconfig
    patchelf
    libpng
  )
  _missing=()
  for p in "${_PKGS[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 || _missing+=("$p")
  done
  if ((${#_missing[@]} > 0)); then
    echo "==> Installing missing build dependencies via pacman:"
    printf '    %s\n' "${_PKG_GROUPS[@]}" "${_missing[@]}"
    $_SUDO pacman -S --needed ${CI:+--noconfirm} "${_PKG_GROUPS[@]}" "${_missing[@]}"
  else
    echo "==> All required build dependencies already present."
  fi
elif command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  _APT=(
    build-essential git curl ca-certificates pkg-config cmake
    python3 python3-pip python3-setuptools
    ninja-build autoconf automake libtool libtool-bin m4
    bison flex gettext patch file
    yasm nasm perl texinfo patchelf xz-utils zip
    xorg-dev libx11-dev libxext-dev libxpresent-dev
    libxcb1-dev libxcb-shm0-dev libxcb-shape0-dev libxcb-xfixes0-dev
    libxrandr-dev libxinerama-dev libxss-dev libxkbcommon-dev
    libwayland-dev wayland-protocols
    libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev
    libvulkan-dev libdrm-dev
    libpulse-dev libasound2-dev
    libfreetype-dev libfontconfig1-dev libxml2-dev libpng-dev libuchardet-dev
    libffi-dev libexpat1-dev liblcms2-dev
    ca-certificates
    zlib1g-dev liblzma-dev libbz2-dev
  )
  echo "==> Installing build dependencies via apt-get ..."
  $_SUDO apt-get update -qq
  $_SUDO apt-get install -y --no-install-recommends "${_APT[@]}"
  # Ubuntu's packaged meson is too old for mpv/libplacebo — get a current one.
  $_SUDO pip3 install --upgrade meson
else
  echo "!! No supported package manager (pacman/apt-get) found; install deps manually." >&2
fi
# ────────────────────────────────────────────────────────────────────────────────────

APP_DIR="${APP_DIR:-"$PWD/mpv"}"

# ── Build variant / licensing toggles ─────────────────────────────────────────
# VARIANT: which patch set to compile in.
#   enhanced (default) — Atmos/TrueHD spdifenc patch + all streaming patches
#                        (segmented HTTP, speed telemetry, demux-cache, in-process
#                        thumbnails, next-file prefetch) + the RAM/malloc fix.
#   stock              — stock mpv + stock FFmpeg + ONLY the Atmos/TrueHD patch.
# The spdifenc (Atmos) patch is applied in BOTH variants — it is what makes this
# an "atmos-patched" build.
VARIANT="${VARIANT:-enhanced}"

# DISTRIBUTABLE: 1 = build a legally redistributable GPLv3 binary (drops
# --enable-nonfree and --enable-libfdk-aac; native AAC decoder is used instead,
# which is lossless for a player). 0 (default) = personal build, keeps nonfree +
# fdk-aac (NOT redistributable). CI sets DISTRIBUTABLE=1 for public releases.
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

SHADERC_REPO="${SHADERC_REPO:-https://github.com/google/shaderc}"
SHADERC_REF="${SHADERC_REF:-}"

LIBCDIO_REPO="${LIBCDIO_REPO:-https://git.savannah.gnu.org/git/libcdio.git}"
LIBCDIO_REF="${LIBCDIO_REF:-}"
LIBCDIO_PARANOIA_REPO="${LIBCDIO_PARANOIA_REPO:-https://git.savannah.gnu.org/git/libcdio-paranoia.git}"
LIBCDIO_PARANOIA_REF="${LIBCDIO_PARANOIA_REF:-}"

LIBVPX_REPO="${LIBVPX_REPO:-https://chromium.googlesource.com/webm/libvpx}"
LIBVPX_REF="${LIBVPX_REF:-}"

LIBBLURAY_REPO="${LIBBLURAY_REPO:-https://code.videolan.org/videolan/libbluray.git}"
LIBBLURAY_REF="${LIBBLURAY_REF:-}"

LIBPLACEBO_REPO="${LIBPLACEBO_REPO:-https://github.com/haasn/libplacebo.git}"
LIBPLACEBO_REF="${LIBPLACEBO_REF:-}"

# Codec / media libs built from source to avoid SONAME breakage on system updates
OPENSSL_REPO="${OPENSSL_REPO:-https://github.com/openssl/openssl.git}"
OPENSSL_REF="${OPENSSL_REF:-}"
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

# ── Paths ─────────────────────────────────────────────────────────────────────
SRC_DIR="$APP_DIR/src"
PREFIX="$APP_DIR"
LUAJIT_SRC="$SRC_DIR/luajit"
FFMPEG_SRC="$SRC_DIR/ffmpeg"
MPV_SRC="$SRC_DIR/mpv"
SHADERC_SRC="$SRC_DIR/shaderc"
LIBCDIO_SRC="$SRC_DIR/libcdio"
LIBCDIOP_SRC="$SRC_DIR/libcdio-paranoia"
LIBVPX_SRC="$SRC_DIR/libvpx"
LIBBLURAY_SRC="$SRC_DIR/libbluray"
LIBPLACEBO_SRC="$SRC_DIR/libplacebo"
MPV_BUILD_DIR="$MPV_SRC/build"

OPENSSL_SRC="$SRC_DIR/openssl"
LIBOGG_SRC="$SRC_DIR/ogg"
LIBVORBIS_SRC="$SRC_DIR/vorbis"
LIBOPUS_SRC="$SRC_DIR/opus"
X264_SRC="$SRC_DIR/x264"
X265_SRC="$SRC_DIR/x265"
LIBFDK_AAC_SRC="$SRC_DIR/fdk-aac"
LIBWEBP_SRC="$SRC_DIR/libwebp"
LIBTHEORA_SRC="$SRC_DIR/theora"
LIBOPENJPEG_SRC="$SRC_DIR/openjpeg"
FRIBIDI_SRC="$SRC_DIR/fribidi"
HARFBUZZ_SRC="$SRC_DIR/harfbuzz"
LIBASS_SRC="$SRC_DIR/libass"
LIBSSH_SRC="$SRC_DIR/libssh"
LIBARCHIVE_SRC="$SRC_DIR/libarchive"
RUBBERBAND_SRC="$SRC_DIR/rubberband"
LIBDVDREAD_SRC="$SRC_DIR/libdvdread"
LIBDVDNAV_SRC="$SRC_DIR/libdvdnav"

mkdir -p "$PREFIX" "$SRC_DIR" "$PREFIX"/{bin,lib,include,share}

# ── Tooling ───────────────────────────────────────────────────────────────────
need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; MISSING=1; }; }
MISSING=0
for c in git curl tar make gcc python3 cmake meson ninja pkg-config perl autoconf automake libtool; do need_cmd "$c"; done
[ "$MISSING" = "1" ] && { echo "Install missing tools and re-run."; exit 2; }

export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CFLAGS="${CFLAGS:-} -fPIC"
export CXXFLAGS="${CXXFLAGS:-} -fPIC"
export LDFLAGS="${LDFLAGS:-} -Wl,-rpath,\$ORIGIN/../lib -Wl,-rpath-link,$PREFIX/lib"

# ── Helper functions ──────────────────────────────────────────────────────────

# Retry a command a few times with exponential backoff.
# Many upstream git hosts intermittently return HTTP 502/timeouts.
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

# Resumable builds: skip a library step when its installed marker already exists.
# Set FORCE_REBUILD=1 to rebuild everything.
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

# ensure_checkout <dir> [ref] [submodules]
#   submodules: "recursive" (default) inits submodules shallowly + in parallel;
#               "no" skips them (e.g. OpenSSL, whose only submodules are the
#               huge test-only cloudflare-quiche/boringssl/rust tree).
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

ensure_sonames() {
  local dir="$1"
  shopt -s nullglob
  for real in "$dir"/lib*.so.*.* "$dir"/lib*.so.[0-9]*; do
    local base name major
    base="$(basename -- "$real")"
    if [[ "$base" =~ ^(lib[^.]+)\.so\.([0-9]+)\.[0-9]+(\.[0-9]+)?$ ]]; then
      name="${BASH_REMATCH[1]}"; major="${BASH_REMATCH[2]}"
      ln -sfn "$base" "$dir/$name.so.$major"
      ln -sfn "$name.so.$major" "$dir/$name.so"
    elif [[ "$base" =~ ^(lib[^.]+)\.so\.([0-9]+)$ ]]; then
      name="${BASH_REMATCH[1]}"; major="${BASH_REMATCH[2]}"
      ln -sfn "$base" "$dir/$name.so" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
}

# ── STEP: shaderc (SPIR-V compiler — libplacebo needs it for Vulkan) ──────────
# MUST be built before libplacebo. Without it libplacebo silently builds with NO
# SPIR-V compiler and Vulkan dies at runtime with "Failed initializing any SPIR-V
# compiler!". This went unnoticed on Arch (which has shaderc system-wide); the
# clean Ubuntu container has neither shaderc nor glslang.
# Built static (libshaderc_combined.a) so libplacebo embeds it and there is
# nothing extra to ship. PIC is required because it is linked into a shared lib.
if built libshaderc_combined.a; then echo "==> shaderc already built, skipping"; else
clone_or_update "$SHADERC_REPO" "$SHADERC_SRC" 1
ensure_checkout "$SHADERC_SRC" "$SHADERC_REF"
pushd "$SHADERC_SRC" >/dev/null
retry python3 utils/git-sync-deps
rm -rf build
cmake -B build -S . -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
  -DSHADERC_SKIP_COPYRIGHT_CHECK=ON
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libshaderc_combined.a" ] || { echo "!! shaderc build failed"; exit 1; }
# libplacebo looks up pkg-config 'shaderc', but the static build only ships
# shaderc_combined.pc. Synthesize shaderc.pc from it, pulling in libstdc++
# (shaderc is C++, and it gets linked via a C driver).
sed -e 's/^Name: shaderc_combined/Name: shaderc/' \
    -e 's/^Libs: \(.*\)-lshaderc_combined\(.*\)$/Libs: \1-lshaderc_combined -lstdc++\2/' \
  "$PREFIX/lib/pkgconfig/shaderc_combined.pc" > "$PREFIX/lib/pkgconfig/shaderc.pc"
grep -q 'lstdc++' "$PREFIX/lib/pkgconfig/shaderc.pc" \
  || sed -i 's/^Libs: .*/& -lstdc++/' "$PREFIX/lib/pkgconfig/shaderc.pc"
fi

# ── STEP: libplacebo (GPU shader / tone-mapping library for mpv) ──────────────
if built libplacebo.so; then echo "==> libplacebo already built, skipping"; else
clone_or_update "$LIBPLACEBO_REPO" "$LIBPLACEBO_SRC" 1
ensure_checkout "$LIBPLACEBO_SRC" "$LIBPLACEBO_REF"
pushd "$LIBPLACEBO_SRC" >/dev/null
rm -rf build
meson setup build . --libdir=lib \
  --prefix="$PREFIX" \
  --buildtype=release \
  -Ddefault_library=shared \
  -Dvulkan=enabled \
  -Dshaderc=enabled \
  -Dlcms=enabled
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libplacebo.so" ] || { echo "!! libplacebo build failed"; exit 1; }
# Guard against the silent-degradation that shipped a Vulkan-less build: assert
# libplacebo really did pick up a SPIR-V compiler (and LittleCMS), rather than
# quietly configuring them away.
grep -qE '^#define PL_HAVE_SHADERC 1' "$PREFIX/include/libplacebo/config.h" 2>/dev/null \
  || { echo "!! libplacebo built WITHOUT shaderc — Vulkan would fail at runtime"; exit 1; }
fi

# ── STEP 1: LuaJIT ───────────────────────────────────────────────────────────
if built libluajit-5.1.so; then echo "==> LuaJIT already built, skipping"; else
clone_or_update "$LUAJIT_REPO" "$LUAJIT_SRC" 1
ensure_checkout "$LUAJIT_SRC" "$LUAJIT_REF"
pushd "$LUAJIT_SRC" >/dev/null
make -j"$(nproc)"
make install PREFIX="$PREFIX"
popd >/dev/null
[ -f "$PREFIX/lib/pkgconfig/luajit.pc" ] || [ -f "$PREFIX/lib/pkgconfig/luajit-2.1.pc" ] \
  || { echo "!! LuaJIT pkg-config missing"; exit 1; }
fi

# ── STEP 2: libcdio ──────────────────────────────────────────────────────────
if built libcdio.so; then echo "==> libcdio already built, skipping"; else
clone_or_update "$LIBCDIO_REPO" "$LIBCDIO_SRC" 1
ensure_checkout "$LIBCDIO_SRC" "$LIBCDIO_REF"
pushd "$LIBCDIO_SRC" >/dev/null
( ./bootstrap || autoreconf -fi || true ) >/dev/null 2>&1 || true
export MAKEINFO=true
export HELP2MAN=true
./configure --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --disable-dependency-tracking --disable-maintainer-mode \
  --without-cddb || true
if [ -d src ]; then
  for m in cd-drive cd-info cd-read iso-info iso-read cdda-player mmc-tool; do
    : > "src/$m.1" || true
  done
fi
[ -d doc ] && : > doc/version.texi
make -j"$(nproc)"
make install
popd >/dev/null
fi

# ── STEP 3: libcdio-paranoia ─────────────────────────────────────────────────
if built libcdio_paranoia.so; then echo "==> libcdio-paranoia already built, skipping"; else
LIBCDIO_PARANOIA_VER="${LIBCDIO_PARANOIA_VER:-10.2+2.0.2}"
LIBCDIO_PARANOIA_TARBALL="libcdio-paranoia-${LIBCDIO_PARANOIA_VER}.tar.gz"
LIBCDIO_PARANOIA_URL_PRIMARY="https://ftp.gnu.org/gnu/libcdio/${LIBCDIO_PARANOIA_TARBALL}"
LIBCDIO_PARANOIA_URL_MIRROR="https://ftpmirror.gnu.org/libcdio/${LIBCDIO_PARANOIA_TARBALL}"

mkdir -p "$SRC_DIR"
pushd "$SRC_DIR" >/dev/null
if [ ! -f "$LIBCDIO_PARANOIA_TARBALL" ]; then
  if ! curl -fL "$LIBCDIO_PARANOIA_URL_PRIMARY" -o "$LIBCDIO_PARANOIA_TARBALL"; then
    curl -fL "$LIBCDIO_PARANOIA_URL_MIRROR" -o "$LIBCDIO_PARANOIA_TARBALL"
  fi
fi
rm -rf "libcdio-paranoia-${LIBCDIO_PARANOIA_VER}"
tar xf "$LIBCDIO_PARANOIA_TARBALL"
LIBCDIOP_SRC="$SRC_DIR/libcdio-paranoia-${LIBCDIO_PARANOIA_VER}"
popd >/dev/null

pushd "$LIBCDIOP_SRC" >/dev/null
( test -x ./configure || autoreconf -fi ) >/dev/null 2>&1 || true
export MAKEINFO=true
export HELP2MAN=true
./configure --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --disable-dependency-tracking --disable-maintainer-mode
[ -d doc ] && : > doc/version.texi
make -j"$(nproc)"
make install
popd >/dev/null
fi

# ── STEP 4: libvpx ───────────────────────────────────────────────────────────
if built libvpx.so; then echo "==> libvpx already built, skipping"; else
clone_or_update "$LIBVPX_REPO" "$LIBVPX_SRC" 1
ensure_checkout "$LIBVPX_SRC" "$LIBVPX_REF"
pushd "$LIBVPX_SRC" >/dev/null
./configure --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth \
  --enable-runtime-cpu-detect
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libvpx.so" ] || { echo "!! libvpx build failed"; exit 1; }
fi

# ── STEP 5: libbluray ────────────────────────────────────────────────────────
if built libbluray.so; then echo "==> libbluray already built, skipping"; else
clone_or_update "$LIBBLURAY_REPO" "$LIBBLURAY_SRC" 1
ensure_checkout "$LIBBLURAY_SRC" "$LIBBLURAY_REF"
pushd "$LIBBLURAY_SRC" >/dev/null
if [ -f meson.build ]; then
  rm -rf build
  meson setup build . --libdir=lib \
    --prefix="$PREFIX" \
    --buildtype=release \
    -Ddefault_library=shared
  meson compile -C build -j"$(nproc)"
  meson install -C build
else
  ( ./bootstrap || autoreconf -fi || true ) >/dev/null 2>&1 || true
  ./configure --prefix="$PREFIX" \
    --enable-shared --disable-static \
    --disable-bdjava-jar --without-bdjava
  make -j"$(nproc)"
  make install
fi
popd >/dev/null
[ -f "$PREFIX/lib/libbluray.so" ] || { echo "!! libbluray build failed"; exit 1; }
fi

# ── STEP 6: OpenSSL ──────────────────────────────────────────────────────────
if built libssl.so; then echo "==> OpenSSL already built, skipping"; else
clone_or_update "$OPENSSL_REPO" "$OPENSSL_SRC" 1
ensure_checkout "$OPENSSL_SRC" "$OPENSSL_REF" no   # skip test-only quiche/boringssl submodules
pushd "$OPENSSL_SRC" >/dev/null
# --openssldir must point at the SYSTEM trust store, not our prefix: it is baked
# into libcrypto at compile time as the default CA location, and a prefix path
# ("/__w/.../mpv/ssl") exists on no user's machine — every HTTPS connection then
# fails with "certificate verify failed". /etc/ssl is correct on Debian/Ubuntu/
# Arch/SUSE, and Fedora/RHEL symlink it. We use `make install_sw` below, so
# nothing is ever written into /etc/ssl. The launcher additionally exports
# SSL_CERT_FILE (system store preferred, bundled cacert.pem as fallback).
./config --prefix="$PREFIX" --openssldir=/etc/ssl --libdir=lib \
  shared no-tests
make -j"$(nproc)"
make install_sw
popd >/dev/null
[ -f "$PREFIX/lib/libssl.so" ] || { echo "!! OpenSSL build failed"; exit 1; }
fi

# ── STEP 7: libogg ───────────────────────────────────────────────────────────
if built libogg.so; then echo "==> libogg already built, skipping"; else
clone_or_update "$LIBOGG_REPO" "$LIBOGG_SRC" 1
ensure_checkout "$LIBOGG_SRC" "$LIBOGG_REF"
pushd "$LIBOGG_SRC" >/dev/null
if [ -f CMakeLists.txt ]; then
  cmake -B build -S . -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON
  cmake --build build -j"$(nproc)" && cmake --install build
else
  autoreconf -fi
  ./configure --prefix="$PREFIX" --enable-shared --disable-static
  make -j"$(nproc)" && make install
fi
popd >/dev/null
[ -f "$PREFIX/lib/libogg.so" ] || { echo "!! libogg build failed"; exit 1; }
fi

# ── STEP 8: libvorbis ────────────────────────────────────────────────────────
if built libvorbis.so; then echo "==> libvorbis already built, skipping"; else
clone_or_update "$LIBVORBIS_REPO" "$LIBVORBIS_SRC" 1
ensure_checkout "$LIBVORBIS_SRC" "$LIBVORBIS_REF"
pushd "$LIBVORBIS_SRC" >/dev/null
if [ -f CMakeLists.txt ]; then
  cmake -B build -S . -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DOGG_INCLUDE_DIR="$PREFIX/include" -DOGG_LIBRARY="$PREFIX/lib/libogg.so"
  cmake --build build -j"$(nproc)" && cmake --install build
else
  autoreconf -fi
  ./configure --prefix="$PREFIX" --enable-shared --disable-static \
    --with-ogg="$PREFIX"
  make -j"$(nproc)" && make install
fi
popd >/dev/null
[ -f "$PREFIX/lib/libvorbis.so" ] || { echo "!! libvorbis build failed"; exit 1; }
fi

# ── STEP 9: libopus ──────────────────────────────────────────────────────────
if built libopus.so; then echo "==> libopus already built, skipping"; else
clone_or_update "$LIBOPUS_REPO" "$LIBOPUS_SRC" 1
ensure_checkout "$LIBOPUS_SRC" "$LIBOPUS_REF"
pushd "$LIBOPUS_SRC" >/dev/null
if [ -f CMakeLists.txt ]; then
  cmake -B build -S . -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF
  cmake --build build -j"$(nproc)" && cmake --install build
else
  autoreconf -fi
  ./configure --prefix="$PREFIX" --enable-shared --disable-static
  make -j"$(nproc)" && make install
fi
popd >/dev/null
[ -f "$PREFIX/lib/libopus.so" ] || { echo "!! libopus build failed"; exit 1; }
fi

# ── STEP 10: libx264 ─────────────────────────────────────────────────────────
if built libx264.so; then echo "==> libx264 already built, skipping"; else
clone_or_update "$X264_REPO" "$X264_SRC" 1
ensure_checkout "$X264_SRC" "$X264_REF"
pushd "$X264_SRC" >/dev/null
./configure --prefix="$PREFIX" --enable-shared --disable-static \
  --enable-pic --disable-opencl
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libx264.so" ] || { echo "!! libx264 build failed"; exit 1; }
fi

# ── STEP 11: libx265 ─────────────────────────────────────────────────────────
if built libx265.so; then echo "==> libx265 already built, skipping"; else
clone_or_update "$X265_REPO" "$X265_SRC" 1
ensure_checkout "$X265_SRC" "$X265_REF"
pushd "$X265_SRC" >/dev/null
cmake -B build -S source -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DENABLE_CLI=ON
cmake --build build -j"$(nproc)"
cmake --install build
if [ ! -f "$PREFIX/lib/libx265.so" ]; then
  _x265so="$(find build -maxdepth 1 -name 'libx265.so.*' ! -type l | head -1)"
  [ -n "$_x265so" ] && cp "$_x265so" "$PREFIX/lib/" && \
    ln -sfn "$(basename "$_x265so")" "$PREFIX/lib/libx265.so"
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
Libs.private: -lm -lstdc++ -lgcc_s -lgcc -lpthread -ldl
Cflags: -I\${includedir}
EOFPC
fi
popd >/dev/null
[ -f "$PREFIX/lib/libx265.so" ] || { echo "!! libx265 build failed"; exit 1; }
fi

# ── STEP 12: libfdk-aac ──────────────────────────────────────────────────────
# GPL-incompatible: only built (and only linked below) for non-distributable
# personal builds. Skipped entirely for DISTRIBUTABLE=1 release builds.
if [ "$DISTRIBUTABLE" = 1 ]; then echo "==> DISTRIBUTABLE=1: skipping libfdk-aac (nonfree)"; elif built libfdk-aac.so; then echo "==> libfdk-aac already built, skipping"; else
clone_or_update "$LIBFDK_AAC_REPO" "$LIBFDK_AAC_SRC" 1
ensure_checkout "$LIBFDK_AAC_SRC" "$LIBFDK_AAC_REF"
pushd "$LIBFDK_AAC_SRC" >/dev/null
autoreconf -fi
./configure --prefix="$PREFIX" --enable-shared --disable-static
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libfdk-aac.so" ] || { echo "!! libfdk-aac build failed"; exit 1; }
fi

# ── STEP 13: libwebp ─────────────────────────────────────────────────────────
if built libwebp.so; then echo "==> libwebp already built, skipping"; else
clone_or_update "$LIBWEBP_REPO" "$LIBWEBP_SRC" 1
ensure_checkout "$LIBWEBP_SRC" "$LIBWEBP_REF"
pushd "$LIBWEBP_SRC" >/dev/null
cmake -B build -S . -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
  -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
  -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_EXTRAS=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libwebp.so" ] || { echo "!! libwebp build failed"; exit 1; }
fi

# ── STEP 14: libtheora ───────────────────────────────────────────────────────
if built libtheora.so; then echo "==> libtheora already built, skipping"; else
clone_or_update "$LIBTHEORA_REPO" "$LIBTHEORA_SRC" 1
ensure_checkout "$LIBTHEORA_SRC" "$LIBTHEORA_REF"
pushd "$LIBTHEORA_SRC" >/dev/null
( ./autogen.sh || autoreconf -fi ) >/dev/null 2>&1 || true
./configure --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --disable-examples --disable-doc \
  --with-ogg-libraries="$PREFIX/lib" --with-ogg-includes="$PREFIX/include" \
  --with-vorbis-libraries="$PREFIX/lib" --with-vorbis-includes="$PREFIX/include"
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libtheora.so" ] || { echo "!! libtheora build failed"; exit 1; }
fi

# ── STEP 15: libopenjpeg ─────────────────────────────────────────────────────
if built libopenjp2.so; then echo "==> libopenjpeg already built, skipping"; else
clone_or_update "$LIBOPENJPEG_REPO" "$LIBOPENJPEG_SRC" 1
ensure_checkout "$LIBOPENJPEG_SRC" "$LIBOPENJPEG_REF"
pushd "$LIBOPENJPEG_SRC" >/dev/null
cmake -B build -S . -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_CODEC=OFF -DBUILD_DOC=OFF -DBUILD_TESTING=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libopenjp2.so" ] || { echo "!! libopenjpeg build failed"; exit 1; }
fi

# ── STEP 16: fribidi ─────────────────────────────────────────────────────────
if built libfribidi.so; then echo "==> fribidi already built, skipping"; else
clone_or_update "$FRIBIDI_REPO" "$FRIBIDI_SRC" 1
ensure_checkout "$FRIBIDI_SRC" "$FRIBIDI_REF"
pushd "$FRIBIDI_SRC" >/dev/null
meson setup build . --libdir=lib \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Ddocs=false -Dtests=false -Dbin=false
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libfribidi.so" ] || { echo "!! fribidi build failed"; exit 1; }
fi

# ── STEP 17: harfbuzz ────────────────────────────────────────────────────────
if built libharfbuzz.so; then echo "==> harfbuzz already built, skipping"; else
clone_or_update "$HARFBUZZ_REPO" "$HARFBUZZ_SRC" 1
ensure_checkout "$HARFBUZZ_SRC" "$HARFBUZZ_REF"
pushd "$HARFBUZZ_SRC" >/dev/null
meson setup build . --libdir=lib \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Dutilities=disabled \
  -Dtests=disabled -Ddocs=disabled -Dbenchmark=disabled \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
  -Dchafa=disabled -Dintrospection=disabled \
  -Dicu=disabled -Dgraphite=disabled -Dgraphite2=disabled \
  -Dfreetype=auto
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libharfbuzz.so" ] || { echo "!! harfbuzz build failed"; exit 1; }
fi

# ── STEP 18: libass ──────────────────────────────────────────────────────────
if built libass.so; then echo "==> libass already built, skipping"; else
clone_or_update "$LIBASS_REPO" "$LIBASS_SRC" 1
ensure_checkout "$LIBASS_SRC" "$LIBASS_REF"
pushd "$LIBASS_SRC" >/dev/null
./autogen.sh
./configure --prefix="$PREFIX" \
  --enable-shared --disable-static \
  --enable-harfbuzz --enable-fontconfig
make -j"$(nproc)"
make install
popd >/dev/null
[ -f "$PREFIX/lib/libass.so" ] || { echo "!! libass build failed"; exit 1; }
fi

# ── STEP 19: libssh ──────────────────────────────────────────────────────────
if built libssh.so; then echo "==> libssh already built, skipping"; else
clone_or_update "$LIBSSH_REPO" "$LIBSSH_SRC" 1
ensure_checkout "$LIBSSH_SRC" "$LIBSSH_REF"
pushd "$LIBSSH_SRC" >/dev/null
cmake -B build -S . -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON -DWITH_STATIC_LIB=OFF \
  -DOPENSSL_ROOT_DIR="$PREFIX" \
  -DWITH_TESTING=OFF -DWITH_EXAMPLES=OFF
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libssh.so" ] || { echo "!! libssh build failed"; exit 1; }
fi

# ── STEP 20: libarchive ──────────────────────────────────────────────────────
if built libarchive.so; then echo "==> libarchive already built, skipping"; else
clone_or_update "$LIBARCHIVE_REPO" "$LIBARCHIVE_SRC" 1
ensure_checkout "$LIBARCHIVE_SRC" "$LIBARCHIVE_REF"
pushd "$LIBARCHIVE_SRC" >/dev/null
cmake -B build -S . -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_TEST=OFF \
  -DOPENSSL_ROOT_DIR="$PREFIX"
cmake --build build -j"$(nproc)"
cmake --install build
popd >/dev/null
[ -f "$PREFIX/lib/libarchive.so" ] || { echo "!! libarchive build failed"; exit 1; }
fi

# ── STEP 21: rubberband ──────────────────────────────────────────────────────
if built librubberband.so; then echo "==> rubberband already built, skipping"; else
clone_or_update "$RUBBERBAND_REPO" "$RUBBERBAND_SRC" 1
ensure_checkout "$RUBBERBAND_SRC" "$RUBBERBAND_REF"
pushd "$RUBBERBAND_SRC" >/dev/null
meson setup build . --libdir=lib \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Dfft=builtin -Dresampler=speex
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/librubberband.so" ] || { echo "!! rubberband build failed"; exit 1; }
fi

# ── STEP 22: libdvdread ──────────────────────────────────────────────────────
if built libdvdread.so; then echo "==> libdvdread already built, skipping"; else
clone_or_update "$LIBDVDREAD_REPO" "$LIBDVDREAD_SRC" 1
ensure_checkout "$LIBDVDREAD_SRC" "$LIBDVDREAD_REF"
pushd "$LIBDVDREAD_SRC" >/dev/null
meson setup build . --libdir=lib \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Denable_docs=false
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libdvdread.so" ] || { echo "!! libdvdread build failed"; exit 1; }
fi

# ── STEP 23: libdvdnav ───────────────────────────────────────────────────────
if built libdvdnav.so; then echo "==> libdvdnav already built, skipping"; else
clone_or_update "$LIBDVDNAV_REPO" "$LIBDVDNAV_SRC" 1
ensure_checkout "$LIBDVDNAV_SRC" "$LIBDVDNAV_REF"
pushd "$LIBDVDNAV_SRC" >/dev/null
meson setup build . --libdir=lib \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared
meson compile -C build -j"$(nproc)"
meson install -C build
popd >/dev/null
[ -f "$PREFIX/lib/libdvdnav.so" ] || { echo "!! libdvdnav build failed"; exit 1; }
fi

# ── STEP 24: FFmpeg (TrueHD-patched) ─────────────────────────────────────────
# Incremental: skip the full rebuild when the FFmpeg source HEAD, the spdifenc
# patch, and the DISTRIBUTABLE config are all unchanged since the last successful
# build (big win on a warm/persistent workspace). FORCE_FFMPEG=1 forces a rebuild.
clone_or_update "$FFMPEG_REPO" "$FFMPEG_SRC" 1
ensure_checkout "$FFMPEG_SRC" "$FFMPEG_REF"
SPDIF_PATCH="$SCRIPT_DIR/patches/spdifenc.c"
FF_STAMP="$PREFIX/.ffmpeg.stamp"
FF_WANT="$(git -C "$FFMPEG_SRC" rev-parse HEAD 2>/dev/null):$( [ -f "$SPDIF_PATCH" ] && sha256sum "$SPDIF_PATCH" | cut -c1-16 || echo nopatch):D=$DISTRIBUTABLE"
if [ "${FORCE_FFMPEG:-0}" != 1 ] && [ -f "$PREFIX/lib/libavcodec.so" ] \
   && [ "$(cat "$FF_STAMP" 2>/dev/null)" = "$FF_WANT" ]; then
  echo "==> FFmpeg unchanged (HEAD+patch+config); skipping rebuild"
else
  echo "==> Cleaning FFmpeg source tree ..."
  pushd "$FFMPEG_SRC" >/dev/null
  ( make distclean || true ) || true
  git reset --hard
  git clean -fdx
  popd >/dev/null

  # Apply the patched spdifenc.c (TrueHD/Atmos MAT padding fix, FFmpeg PR #23542)
  # after cleaning, so it survives the clean and gets compiled into libavformat.
  if [ -f "$SPDIF_PATCH" ]; then
    echo "==> Applying patched spdifenc.c (TrueHD MAT padding fix, FFmpeg PR #23542) ..."
    cp -f "$SPDIF_PATCH" "$FFMPEG_SRC/libavformat/spdifenc.c"
  else
    echo "!! Patch $SPDIF_PATCH not found; building with upstream spdifenc.c"
  fi

  echo "==> Configuring FFmpeg ..."
  pushd "$FFMPEG_SRC" >/dev/null
  # nonfree/fdk-aac only for personal (non-distributable) builds. OpenSSL 3 is
  # Apache-2.0 (GPLv3-compatible) so --enable-openssl stays in both modes.
  FF_NONFREE=()
  if [ "$DISTRIBUTABLE" != 1 ]; then
    FF_NONFREE=(--enable-nonfree --enable-libfdk-aac)
  fi
  ./configure \
    --prefix="$PREFIX" \
    --enable-gpl --enable-version3 \
    --enable-shared --enable-openssl \
    "${FF_NONFREE[@]}" \
    --enable-libx264 --enable-libx265 \
    --enable-libvpx --enable-libopus --enable-libvorbis \
    --enable-libass --enable-fontconfig --enable-libfreetype \
    --enable-libbluray --enable-libwebp --enable-libtheora \
    --enable-libopenjpeg --enable-libssh \
    --enable-libdrm --enable-libpulse --enable-libxcb --enable-xlib \
    --enable-lzma --enable-zlib --enable-bzlib \
    --enable-rpath
  make -j"$(nproc)" V=1
  make install
  popd >/dev/null
  echo "$FF_WANT" > "$FF_STAMP"
fi

# ── STEP 24b: wayland (mpv master outpaces Ubuntu 22.04 and released tags) ────
# libwayland: build from source only when the system's is too old (mpv needs
# >= 1.23; Ubuntu 22.04 ships 1.20), because the resulting libwayland-client gets
# BUNDLED and therefore SHADOWS the target machine's own copy.
#
# That shadowing is why we must track *main* here, not a fixed tag. The target's
# Mesa/GPU driver links libwayland-client too, and resolves against whichever copy
# is loaded — ours. Ship an older one and the driver breaks on newer systems with
# "undefined symbol: wl_display_dispatch_queue_timeout" -> the Vulkan ICD fails to
# load -> "no suitable device". So the bundled libwayland must be a SUPERSET of
# any released one. (Bundling is unavoidable: our old-glibc floor has wayland too
# old for mpv, so old distros need our copy.)
if pkg-config --atleast-version=1.23.0 wayland-client 2>/dev/null; then
  echo "==> System libwayland >= 1.23; using it"
else
  echo "==> Building libwayland from source (main: must be >= any distro's) ..."
  clone_or_update "https://gitlab.freedesktop.org/wayland/wayland.git" "$SRC_DIR/wayland" 1
  ensure_checkout "$SRC_DIR/wayland" "${WAYLAND_REF:-main}"
  pushd "$SRC_DIR/wayland" >/dev/null
  rm -rf build
  meson setup build . --libdir=lib --prefix="$PREFIX" --buildtype=release \
    -Ddefault_library=shared -Ddocumentation=false -Dtests=false
  meson compile -C build -j"$(nproc)"
  meson install -C build
  popd >/dev/null
  [ -f "$PREFIX/lib/libwayland-client.so" ] || { echo "!! wayland build failed"; exit 1; }
fi

# wayland-protocols: always install the latest from main. mpv master uses the
# newest *staging* protocols (e.g. color-representation-v1) whose XML revisions
# outrun any released tag or distro package. Data only (no compile) so it's cheap
# to (re)install each run; the persistent workspace makes the fetch incremental.
echo "==> Installing latest wayland-protocols (main) ..."
clone_or_update "https://gitlab.freedesktop.org/wayland/wayland-protocols.git" "$SRC_DIR/wayland-protocols" 1
ensure_checkout "$SRC_DIR/wayland-protocols" "${WAYLAND_PROTOCOLS_REF:-main}"
pushd "$SRC_DIR/wayland-protocols" >/dev/null
rm -rf build
# Install the XML data + pkgconfig only. wayland-protocols would otherwise
# generate per-protocol enum headers whenever wayland-scanner is found, but the
# newest staging protocols need a newer scanner than we bundle — and mpv scans
# the XMLs itself and never uses those headers. Hiding wayland-scanner
# (its lookup is required:tests=false) skips that generation cleanly.
# PKG_CONFIG_LIBDIR="" replaces the whole pkg-config search path (PKG_CONFIG_PATH
# alone still hits the default system dirs), so wayland-scanner genuinely isn't
# found and the enum-header generation is skipped.
PKG_CONFIG_LIBDIR="" PKG_CONFIG_PATH="" meson setup build . --libdir=lib \
  --prefix="$PREFIX" --buildtype=release -Dtests=false
meson install -C build
popd >/dev/null
pkg-config --atleast-version=1.38 wayland-protocols || { echo "!! wayland-protocols build failed"; exit 1; }

# ── STEP 24c: Vulkan headers + loader (Ubuntu 22.04's are too old for mpv) ────
# mpv master needs vulkan >= 1.3.238; Ubuntu 22.04 ships 1.3.204. Build the
# Khronos headers + loader from source into the prefix, version-gated (Arch
# skips). The loader is portable: at runtime it still discovers the target
# system's GPU driver ICDs via the standard /usr/share/vulkan paths.
if pkg-config --atleast-version=1.3.238 vulkan 2>/dev/null; then
  echo "==> System vulkan new enough; skipping vulkan source build"
else
  echo "==> Building Vulkan-Headers + Vulkan-Loader from source ..."
  clone_or_update "https://github.com/KhronosGroup/Vulkan-Headers.git" "$SRC_DIR/vulkan-headers" 1
  ensure_checkout "$SRC_DIR/vulkan-headers" "${VULKAN_HEADERS_REF:-}"
  pushd "$SRC_DIR/vulkan-headers" >/dev/null
  cmake -B build -S . -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  cmake --install build
  popd >/dev/null

  clone_or_update "https://github.com/KhronosGroup/Vulkan-Loader.git" "$SRC_DIR/vulkan-loader" 1
  ensure_checkout "$SRC_DIR/vulkan-loader" "${VULKAN_LOADER_REF:-}"
  pushd "$SRC_DIR/vulkan-loader" >/dev/null
  cmake -B build -S . -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DVULKAN_HEADERS_INSTALL_DIR="$PREFIX" -DBUILD_TESTS=OFF -DUPDATE_DEPS=OFF
  cmake --build build -j"$(nproc)"
  cmake --install build
  popd >/dev/null
  pkg-config --atleast-version=1.3.238 vulkan || { echo "!! vulkan build failed"; exit 1; }
fi

# ── STEP 25: mpv ─────────────────────────────────────────────────────────────
clone_or_update "$MPV_REPO" "$MPV_SRC" 1
# Start from a pristine tree so re-applying the segmented-http patch is clean.
git -C "$MPV_SRC" reset --hard
git -C "$MPV_SRC" clean -fdx -e build
ensure_checkout "$MPV_SRC" "$MPV_REF"

# The streaming enhancements + RAM fix below are the "enhanced" variant only.
# The "stock" variant ships stock mpv (the Atmos/TrueHD spdifenc patch lives in
# the FFmpeg step above and is applied in both variants).
if [ "$VARIANT" = enhanced ]; then

# Segmented parallel HTTP downloading (--segmented-chunks / --segment-size).
# Adds stream/stream_segmented_http.c + registry/options/meson hooks.
SEGMENTED_PATCH="$SCRIPT_DIR/patches/apply_segmented_http.sh"
if [ -x "$SEGMENTED_PATCH" ]; then
  "$SEGMENTED_PATCH" "$MPV_SRC"
else
  echo "!! $SEGMENTED_PATCH not found; building without segmented downloading"
fi

# Expose the segmented downloader's true per-thread + combined download rate via
# demuxer-cache-state (segmented-input-rate / segmented-worker-rates), for the
# uosc seek-bar download-speed readout. Depends on the segmented-http patch above.
SEGSPEED_PATCH="$SCRIPT_DIR/patches/apply_segmented_speed.sh"
if [ -x "$SEGSPEED_PATCH" ]; then
  "$SEGSPEED_PATCH" "$MPV_SRC"
else
  echo "!! $SEGSPEED_PATCH not found; building without segmented download-speed reporting"
fi

# Cache subtitle/audio-track packets while deselected
# (--demuxer-cache-unselected-subs/-audio) so enabling/switching tracks on
# network streams doesn't drop the forward cache.
SUBCACHE_PATCH="$SCRIPT_DIR/patches/apply_demux_cache_unselected_subs.sh"
if [ -x "$SUBCACHE_PATCH" ]; then
  "$SUBCACHE_PATCH" "$MPV_SRC"
else
  echo "!! $SUBCACHE_PATCH not found; building without sub-track cache retention"
fi

# In-process, from-buffer thumbnailer (thumbnail-cache command): decode seekbar
# thumbnails out of the already-buffered demuxer cache with no subprocess fork
# (avoids the spdif-underrun wedge) and no extra network I/O.
THUMBCACHE_PATCH="$SCRIPT_DIR/patches/apply_thumbnail_cache.sh"
if [ -x "$THUMBCACHE_PATCH" ]; then
  "$THUMBCACHE_PATCH" "$MPV_SRC"
else
  echo "!! $THUMBCACHE_PATCH not found; building without in-process thumbnailer"
fi

# Next-file prefetch (immediate + reduced-cost prefetch of the next playlist
# entry, ramped to full buffering on promotion). Depends on the segmented-http
# patch above for STREAM_PREFETCH / STREAM_CTRL_SEGMENTED_ACTIVATE consumers.
NEXTFILE_PATCH="$SCRIPT_DIR/patches/apply_next_file_prefetch.sh"
if [ -x "$NEXTFILE_PATCH" ]; then
  "$NEXTFILE_PATCH" "$MPV_SRC"
else
  echo "!! $NEXTFILE_PATCH not found; building without next-file prefetch"
fi

# Compile glibc malloc tuning (M_ARENA_MAX=2 / M_TRIM_THRESHOLD=128MiB) into
# main() so the portable build holds RSS flat across a long playlist instead of
# ratcheting up ~1 arena per file (overnight OOM-freeze fix), without needing
# the launcher to export MALLOC_ARENA_MAX / MALLOC_TRIM_THRESHOLD_. Linux-only
# (patches osdep/main-fn-unix.c).
MALLOC_PATCH="$SCRIPT_DIR/patches/apply_malloc_tuning.sh"
if [ -x "$MALLOC_PATCH" ]; then
  "$MALLOC_PATCH" "$MPV_SRC"
else
  echo "!! $MALLOC_PATCH not found; building without compiled-in malloc tuning"
fi

else
  echo "==> VARIANT=stock: skipping streaming patches (segmented HTTP, speed telemetry, demux-cache, in-process thumbnails, next-file prefetch) and the RAM/malloc patch"
fi

rm -rf "$MPV_BUILD_DIR"
pushd "$MPV_SRC" >/dev/null
meson setup "$MPV_BUILD_DIR" . --libdir=lib \
  --prefix="$PREFIX" --buildtype=release \
  -Ddefault_library=shared \
  -Dcdda=enabled -Dcplugins=enabled -Ddvdnav=enabled \
  -Dgl-x11=enabled -Dlibarchive=enabled -Dlibmpv=true \
  -Dlua=luajit -Drubberband=enabled -Dspirv-cross=disabled \
  -Duchardet=enabled -Dvapoursynth=auto \
  -Dvulkan=enabled -Dwayland=enabled -Dx11=enabled
ninja -C "$MPV_BUILD_DIR" -j"$(nproc)" -v
ninja -C "$MPV_BUILD_DIR" install
popd >/dev/null

# ── Portable environment file ─────────────────────────────────────────────────
cat > "$APP_DIR/env.sh" <<'EOS'
# Portable environment for mpv stack (source from your wrapper if desired)
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PATH="$APP_DIR/bin:$PATH"
export PKG_CONFIG_PATH="$APP_DIR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$APP_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
EOS
chmod +x "$APP_DIR/env.sh"

# Internal portable launcher (inside $APP_DIR; the main launcher is mpv_patched.sh above)
cat > "$APP_DIR/mpv_patched.sh" <<'EOS'
#!/usr/bin/env bash
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$APP_DIR/env.sh"
exec "$APP_DIR/bin/mpv" "$@"
EOS
chmod +x "$APP_DIR/mpv_patched.sh"

# ── SONAME symlinks ───────────────────────────────────────────────────────────
echo "==> Ensuring SONAME symlinks in $PREFIX/lib ..."
ensure_sonames "$PREFIX/lib"

# ── RUNPATH via patchelf ──────────────────────────────────────────────────────
if command -v patchelf >/dev/null 2>&1; then
  echo "==> Setting RUNPATH via patchelf ..."
  set_rpath() {
    local bin="$1"; [ -f "$bin" ] || return 0
    patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN' "$bin" || true
  }
  set_rpath "$PREFIX/bin/mpv"
  set_rpath "$PREFIX/bin/ffmpeg"
  set_rpath "$PREFIX/bin/ffprobe"

  # Every bundled library also needs $ORIGIN so it can find its siblings.
  # patchelf writes DT_RUNPATH, which the loader applies ONLY to an object's own
  # direct dependencies — it does NOT propagate to transitive ones. Without this,
  # e.g. libavformat cannot find libssl.so.4 sitting right next to it and the
  # portable build fails to start ("cannot open shared object file") on any
  # machine that lacks those libs system-wide. This also strips the absolute
  # build-machine path the linker baked into the libs' RUNPATH.
  _nso=0
  shopt -s nullglob
  for _so in "$PREFIX"/lib/*.so "$PREFIX"/lib/*.so.*; do
    [ -L "$_so" ] && continue          # skip symlinks (patch the real file once)
    [ -f "$_so" ] || continue
    patchelf --set-rpath '$ORIGIN' "$_so" 2>/dev/null && _nso=$((_nso+1))
  done
  shopt -u nullglob
  echo "==> RUNPATH set on 3 executables + $_nso bundled libraries"
else
  echo "!! patchelf not found; relying on LD_LIBRARY_PATH + linker rpath"
fi

# ── Runtime linkage sanity check ─────────────────────────────────────────────
echo "==> Verifying runtime linkages ..."
check_missing() {
  local exe="$1"; [ -x "$exe" ] || return 0
  local out; out="$(LD_LIBRARY_PATH="$PREFIX/lib" ldd -r "$exe" 2>&1 || true)"
  if grep -q "not found" <<<"$out"; then
    echo "!! Missing libraries for: $exe"
    echo "$out" | sed 's/^/   /'
    return 1
  fi
}
check_missing "$PREFIX/bin/mpv"
check_missing "$PREFIX/bin/ffmpeg" || true
check_missing "$PREFIX/bin/ffprobe" || true

echo
echo "Portable mpv installed to: $APP_DIR"
echo "Use your wrapper: $SCRIPT_DIR/mpv_patched.sh <file>"
