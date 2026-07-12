#!/usr/bin/env bash
# collect_dlls.sh — assemble the flat, shippable Windows bundle (dist-win/)
# and audit its DLL closure.
#
# Windows replacement for the ELF logic in build_mpv.sh (patchelf/RUNPATH,
# SONAME symlinks, ldd checks) and audit_portable_mpv.sh (lddtree): walks the
# PE import tables with objdump, copies every non-system DLL next to the
# exes, and FAILS if any import can neither be found in our prefix nor
# matched against the Windows system-DLL allowlist. A passing run IS the
# portability audit.
#
# Usage: ./collect_dlls.sh
#   APP_DIR=...   prefix produced by build_mpv_windows.sh (default ./mpv-win)
#   DIST_DIR=...  output bundle                            (default ./dist-win)
#   CONFIG_DIR=.. portable config to bundle (default ./windows_config/portable_config)
#   STRIP=0       skip stripping
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIPLE=x86_64-w64-mingw32
OBJDUMP="$TRIPLE-objdump"

APP_DIR="${APP_DIR:-"$SCRIPT_DIR/mpv-win"}"
DIST_DIR="${DIST_DIR:-"$SCRIPT_DIR/dist-win"}"
CONFIG_DIR="${CONFIG_DIR:-"$SCRIPT_DIR/windows_config/portable_config"}"
MANIFEST="$DIST_DIR/dist-manifest.txt"

SEEDS=(mpv.exe mpv.com ffmpeg.exe ffprobe.exe)
SEARCH_DIRS=("$APP_DIR/bin" "$APP_DIR/lib" "/usr/$TRIPLE/bin")

# Windows system DLLs (lowercase, no .dll): resolved from the OS, never shipped.
# vulkan-1 is deliberately here — the loader must come from the GPU driver.
ALLOW_REGEX='^(api-ms-win-.*|ucrtbase|msvcrt|msvcp[0-9]*|vcruntime[0-9]*|kernel32|kernelbase|user32|gdi32|gdiplus|shell32|shlwapi|advapi32|ole32|oleaut32|uuid|comdlg32|comctl32|ws2_32|winmm|imm32|version|setupapi|cfgmgr32|bcrypt|ncrypt|crypt32|secur32|ntdll|psapi|iphlpapi|userenv|avrt|dwmapi|uxtheme|shcore|windowscodecs|d3d11|d3d9|d3dcompiler_[0-9]+|dxgi|dwrite|opengl32|glu32|vulkan-1|mf|mfplat|mfreadwrite|mfuuid|ksuser|wldap32|powrprof|pdh|winhttp|wininet|normaliz|dnsapi|hid|dinput8|xinput1_[0-9]|xinput9_1_0|winusb|propsys|runtimeobject|dbghelp|synchronization|bthprops|wtsapi32|netapi32|rpcrt4|xmllite|avicap32|msacm32)$'

command -v "$OBJDUMP" >/dev/null 2>&1 || { echo "!! $OBJDUMP not found (install mingw-w64-binutils)"; exit 2; }
for s in "${SEEDS[@]}"; do
  [ -f "$APP_DIR/bin/$s" ] || { echo "!! Missing seed binary: $APP_DIR/bin/$s (run build_mpv_windows.sh first)"; exit 2; }
done

mkdir -p "$DIST_DIR"
: > "$MANIFEST"

imports_of() { "$OBJDUMP" -p "$1" 2>/dev/null | awk '/DLL Name:/{print $3}'; }

# Case-insensitive lookup of a DLL name in the search dirs.
resolve_dll() {
  local want_lc="$1" dir f
  for dir in "${SEARCH_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.dll "$dir"/*.DLL; do
      [ -e "$f" ] || continue
      if [ "$(basename "$f" | tr '[:upper:]' '[:lower:]')" = "$want_lc" ]; then
        echo "$f"; return 0
      fi
    done
  done
  return 1
}

declare -A DONE            # dll name (lowercase) -> handled
declare -A SYSTEM_USED     # allowlisted names seen
QUEUE=()
FAIL=0

echo "==> Seeding: ${SEEDS[*]}"
for s in "${SEEDS[@]}"; do
  cp -f "$APP_DIR/bin/$s" "$DIST_DIR/"
  QUEUE+=("$DIST_DIR/$s")
  printf '%-40s %s\n' "$s" "$APP_DIR/bin/$s" >> "$MANIFEST"
done

while ((${#QUEUE[@]} > 0)); do
  cur="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    dep_lc="$(echo "$dep" | tr '[:upper:]' '[:lower:]')"
    base_lc="${dep_lc%.dll}"
    [ -n "${DONE[$dep_lc]:-}" ] && continue
    DONE[$dep_lc]=1
    if [[ "$base_lc" =~ $ALLOW_REGEX ]]; then
      SYSTEM_USED[$dep_lc]=1
      continue
    fi
    if src="$(resolve_dll "$dep_lc")"; then
      cp -f "$src" "$DIST_DIR/$dep"
      printf '%-40s %-60s (first needed by %s)\n' "$dep" "$src" "$(basename "$cur")" >> "$MANIFEST"
      QUEUE+=("$DIST_DIR/$dep")
    else
      echo "!! UNRESOLVED import: $dep (needed by $(basename "$cur"))" >&2
      printf '%-40s UNRESOLVED (needed by %s)\n' "$dep" "$(basename "$cur")" >> "$MANIFEST"
      FAIL=1
    fi
  done < <(imports_of "$cur")
done

if [ "${STRIP:-1}" != "0" ]; then
  echo "==> Stripping PE binaries ..."
  for f in "$DIST_DIR"/*.exe "$DIST_DIR"/*.dll; do
    [ -e "$f" ] || continue
    [ "$(basename "$f")" = "mpv.com" ] && continue
    "$TRIPLE-strip" "$f" 2>/dev/null || true
  done
fi

# Bundle the portable config
if [ -d "$CONFIG_DIR" ]; then
  echo "==> Bundling portable_config from $CONFIG_DIR"
  rm -rf "$DIST_DIR/portable_config"
  cp -a "$CONFIG_DIR" "$DIST_DIR/portable_config"
else
  echo "!! No portable config at $CONFIG_DIR — dist has no config" >&2
fi

echo
echo "==> System DLLs relied on (resolved from Windows itself):"
printf '    %s\n' "${!SYSTEM_USED[@]}" | sort
echo
_ndll="$(find "$DIST_DIR" -maxdepth 1 -name '*.dll' | wc -l)"
echo "==> Bundled: 4 executables + $_ndll DLLs -> $DIST_DIR"
echo "==> Manifest: $MANIFEST"

# Sanity assertions from the plan
if [ -e "$DIST_DIR/vulkan-1.dll" ]; then
  echo "!! ERROR: vulkan-1.dll must NOT be shipped (comes from the GPU driver)"; FAIL=1
fi
if [ ! -e "$DIST_DIR/libwinpthread-1.dll" ]; then
  echo "!! WARNING: libwinpthread-1.dll not bundled — check /usr/$TRIPLE/bin was searched"
fi

if [ "$FAIL" != "0" ]; then
  echo "!! DLL closure INCOMPLETE — see manifest"; exit 1
fi
echo "==> DLL closure complete — bundle is self-contained."
