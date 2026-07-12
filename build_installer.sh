#!/usr/bin/env bash
# build_installer.sh — compile the Inno Setup installer under Wine.
#
# Downloads Inno Setup 6 into a dedicated Wine prefix (first run only), then
# compiles installer/mpv-patched.iss against the dist-win/ payload produced by
# build_mpv_windows.sh + collect_dlls.sh.
#
# Output: installer/Output/mpv-patched-setup.exe
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${DIST_DIR:-"$SCRIPT_DIR/dist-win"}"

export WINEPREFIX="${WINEPREFIX:-"$SCRIPT_DIR/wine-inno"}"
export WINEDEBUG="${WINEDEBUG:--all}"
# No display needed; Inno's compiler is console-only, installer runs silent.
export WINEDLLOVERRIDES="mscoree=;mshtml="

INNO_URL="${INNO_URL:-https://files.jrsoftware.org/is/6/innosetup-6.5.4.exe}"
INNO_FALLBACK_URL="https://jrsoftware.org/download.php/is.exe"

command -v wine >/dev/null 2>&1 || { echo "!! wine not installed (pacman -S wine)"; exit 2; }
[ -f "$DIST_DIR/mpv.exe" ] || { echo "!! $DIST_DIR/mpv.exe missing — run build_mpv_windows.sh && collect_dlls.sh first"; exit 2; }

find_iscc() {
  find "$WINEPREFIX/drive_c" -iname 'ISCC.exe' -path '*Inno Setup*' 2>/dev/null | head -1
}

ISCC="$(find_iscc || true)"
if [ -z "$ISCC" ]; then
  echo "==> Installing Inno Setup 6 into Wine prefix $WINEPREFIX ..."
  mkdir -p "$WINEPREFIX"
  IS_EXE="$SCRIPT_DIR/installer/innosetup-installer.exe"
  if [ ! -f "$IS_EXE" ]; then
    curl -fL "$INNO_URL" -o "$IS_EXE" || curl -fL "$INNO_FALLBACK_URL" -o "$IS_EXE"
  fi
  wine "$IS_EXE" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- 2>/dev/null
  # wine returns before all async registration settles
  wineserver -w || true
  ISCC="$(find_iscc || true)"
  [ -n "$ISCC" ] || { echo "!! Inno Setup install under wine failed"; exit 1; }
fi

echo "==> Compiling installer ($ISCC) ..."
cd "$SCRIPT_DIR/installer"
wine "$ISCC" mpv-patched.iss 2>/dev/null
wineserver -w || true

OUT="$SCRIPT_DIR/installer/Output/mpv-patched-setup.exe"
[ -f "$OUT" ] || { echo "!! ISCC did not produce $OUT"; exit 1; }
echo
echo "==> Installer built: $OUT ($(du -h "$OUT" | cut -f1))"
