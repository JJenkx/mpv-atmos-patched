#!/usr/bin/env bash
# build_missing_codecs.sh — only build libvpx and/or libbluray into the existing portable prefix
# Arch (KDE Wayland) friendly. No rebuild of mpv/ffmpeg unless you choose to.
set -Eeuo pipefail

# ───────────────────────────────── Config ─────────────────────────────────
APP_DIR="${APP_DIR:-"$PWD/mpv"}"
PREFIX="$APP_DIR"
SRC_DIR="$PREFIX/src"

# Repos + optional refs
LIBVPX_REPO="${LIBVPX_REPO:-https://chromium.googlesource.com/webm/libvpx}"
LIBVPX_REF="${LIBVPX_REF:-}"                           # e.g. v1.13.1 (optional)
LIBBLURAY_REPO="${LIBBLURAY_REPO:-https://code.videolan.org/videolan/libbluray.git}"
LIBBLURAY_REF="${LIBBLURAY_REF:-}"                     # e.g. 1.3.4 (optional)

# Toggle: also analyze existing binaries with ldd -r to detect missing libs
CHECK_BINARIES="${CHECK_BINARIES:-1}"

# Optional: patch RUNPATH on existing binaries (mpv/ffmpeg/ffprobe) to ensure local libs are found
PATCH_RPATH="${PATCH_RPATH:-1}"

# Force rebuild even if a lib seems present
FORCE_REBUILD_VPX="${FORCE_REBUILD_VPX:-0}"
FORCE_REBUILD_BLURAY="${FORCE_REBUILD_BLURAY:-0}"

# Parallelism
JOBS="${JOBS:-"$(nproc)"}"

# ────────────────────────────── Preflight deps ───────────────────────────
# Only what we need for these two libs (and common build tools).
_PKGS=(git curl autoconf automake libtool make gcc pkgconf yasm nasm perl libxml2 freetype2 fontconfig meson ninja)
# libbluray needs these headers at build time:
_PKGS+=("libxml2" "freetype2" "fontconfig")

if ! command -v pacman >/dev/null 2>&1; then
  echo "⚠️  pacman not found (non-Arch?). Continuing, but ensure deps exist."
else
  if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    echo "❌ Need sudo to install missing pre-reqs (or run as root)."; exit 1
  fi
  _missing=()
  for p in "${_PKGS[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 || _missing+=("$p")
  done
  if ((${#_missing[@]})); then
    echo "==> Installing missing packages:"
    printf '    %s\n' "${_missing[@]}"
    sudo pacman -S --needed "${_missing[@]}"
  fi
fi

# ────────────────────────────── Build env ────────────────────────────────
mkdir -p "$PREFIX" "$SRC_DIR" "$PREFIX"/{bin,lib,include,share}

export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CFLAGS="${CFLAGS:-} -fPIC"
export CXXFLAGS="${CXXFLAGS:-} -fPIC"
export LDFLAGS="${LDFLAGS:-} -Wl,-rpath,\$ORIGIN/../lib -Wl,-rpath-link,$PREFIX/lib"

clone_or_update() {
  local url="$1" dest="$2" depth="${3:-1}"
  if [ -d "$dest/.git" ]; then
    echo "==> Updating $(basename "$dest")"
    git -C "$dest" remote set-url origin "$url"
    git -C "$dest" fetch --prune --tags --depth="$depth" origin || git -C "$dest" fetch --prune --tags origin
  else
    echo "==> Cloning $(basename "$dest")"
    git clone --origin origin --depth="$depth" "$url" "$dest"
  fi
}

ensure_checkout() {
  local dir="$1" ref="${2:-}"
  git -C "$dir" submodule update --init --recursive || true
  [ -z "$ref" ] && return 0
  echo "==> Ensuring ref '$ref' in $(basename "$dir")"
  if git -C "$dir" ls-remote --exit-code --tags origin "refs/tags/$ref" >/dev/null 2>&1; then
    git -C "$dir" fetch --depth=1 origin "refs/tags/$ref:refs/tags/$ref" || true
    git -C "$dir" checkout --detach "refs/tags/$ref"
  elif git -C "$dir" ls-remote --exit-code --heads origin "$ref" >/dev/null 2>&1; then
    git -C "$dir" fetch --depth=1 origin "refs/heads/$ref:refs/remotes/origin/$ref" || true
    git -C "$dir" checkout -B "$ref" "refs/remotes/origin/$ref"
  elif git -C "$dir" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
    git -C "$dir" checkout --detach "$ref"
  else
    echo "!! Ref '$ref' not found; staying on default branch"
    git -C "$dir" fetch origin --unshallow || true
  fi
  git -C "$dir" submodule update --init --recursive || true
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

need_vpx() {
  (( FORCE_REBUILD_VPX == 1 )) && return 0
  # Typical targets consumers look for:
  [ -f "$PREFIX/lib/libvpx.so.9" ] || [ -f "$PREFIX/lib/libvpx.so" ] || return 0
  # If both exist, probably fine:
  return 1
}

need_bluray() {
  (( FORCE_REBUILD_BLURAY == 1 )) && return 0
  [ -f "$PREFIX/lib/libbluray.so.2" ] || [ -f "$PREFIX/lib/libbluray.so" ] || return 0
  return 1
}

bins_report_missing=()
if (( CHECK_BINARIES )); then
  for exe in "$PREFIX/bin/mpv" "$PREFIX/bin/ffmpeg"; do
    if [ -x "$exe" ]; then
      echo "==> Checking linkages for $(basename "$exe")"
      if ! out="$(LD_LIBRARY_PATH="$PREFIX/lib" ldd -r "$exe" 2>&1 || true)"; then
        out=""
      fi
      if grep -q "not found" <<<"$out"; then
        echo "$out"
        bins_report_missing+=("$exe")
      fi
    fi
  done
fi

# ─────────────────────────────── Build libvpx ───────────────────────────────
build_libvpx() {
  local src="$SRC_DIR/libvpx"
  clone_or_update "$LIBVPX_REPO" "$src" 1
  ensure_checkout "$src" "$LIBVPX_REF"
  pushd "$src" >/dev/null
  # libvpx uses its own configure (requires yasm/nasm)
  ./configure --prefix="$PREFIX" \
    --enable-shared --disable-static \
    --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth \
    --enable-runtime-cpu-detect
  make -j"$JOBS"
  make install
  popd >/dev/null
  ensure_sonames "$PREFIX/lib"
  echo "✅ libvpx installed into $PREFIX/lib"
}

# ────────────────────────────── Build libbluray ──────────────────────────────
build_libbluray() {
  local src="$SRC_DIR/libbluray"
  clone_or_update "$LIBBLURAY_REPO" "$src" 1
  ensure_checkout "$src" "$LIBBLURAY_REF"
  pushd "$src" >/dev/null

  if [ -f meson.build ]; then
    echo "==> libbluray: Meson build detected"
    # Fresh build dir each time
    rm -rf build
    meson setup build . \
      --prefix="$PREFIX" \
      --buildtype=release \
      -Ddefault_library=shared
      # NOTE: We intentionally do NOT pass a bdj/BD-J toggle here because Meson
      # option names vary across versions. With no JDK/Ant present, BD-J won't build.
    meson compile -C build -j"${JOBS:-$(nproc)}"
    meson install -C build
  else
    echo "==> libbluray: Autotools build detected (release tarball style)"
    # Generate configure if needed
    ( ./bootstrap || autoreconf -fi || true ) >/dev/null 2>&1 || true
    if [ ! -x ./configure ]; then
      echo "❌ Could not generate ./configure; ensure autoconf/automake/libtool are installed."
      exit 1
    fi
    ./configure --prefix="$PREFIX" \
      --enable-shared --disable-static \
      --disable-bdjava-jar --without-bdjava
    make -j"${JOBS:-$(nproc)}"
    make install
  fi

  popd >/dev/null
  ensure_sonames "$PREFIX/lib"
  echo "✅ libbluray installed into $PREFIX/lib"
}

# ───────────────────────────── Determine needs ──────────────────────────────
do_vpx=0
do_bluray=0

# Simple file existence checks
if need_vpx; then do_vpx=1; fi
if need_bluray; then do_bluray=1; fi

# If ldd reported misses, refine decisions
if ((${#bins_report_missing[@]})); then
  # Scan again and look for specific names
  for exe in "${bins_report_missing[@]}"; do
    out="$(LD_LIBRARY_PATH="$PREFIX/lib" ldd -r "$exe" 2>&1 || true)"
    grep -q "libvpx.so" <<<"$out" && do_vpx=1
    grep -q "libbluray.so" <<<"$out" && do_bluray=1
  done
fi

# ───────────────────────────── Execute builds ───────────────────────────────
if (( do_vpx == 0 && do_bluray == 0 )); then
  echo "==> Both libvpx and libbluray appear present already (or FORCE flags not set). Nothing to do."
else
  (( do_vpx ))    && build_libvpx
  (( do_bluray )) && build_libbluray
fi

# ───────────────────────────── Optional: patch rpath ────────────────────────
if (( PATCH_RPATH )) && command -v patchelf >/dev/null 2>&1; then
  echo "==> Patching RUNPATH on existing binaries (if present)"
  for bin in "$PREFIX/bin/mpv" "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe"; do
    [ -f "$bin" ] || continue
    patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN' "$bin" || true
  done
fi

# ───────────────────────────── Final verification ───────────────────────────
echo "==> Final linkage check (mpv / ffmpeg if present)"
for exe in "$PREFIX/bin/mpv" "$PREFIX/bin/ffmpeg"; do
  if [ -x "$exe" ]; then
    echo "---- $(basename "$exe") ----"
    LD_LIBRARY_PATH="$PREFIX/lib" ldd -r "$exe" | sed 's/^/    /'
  fi
done

echo "✅ Done."
