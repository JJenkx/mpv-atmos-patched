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
# stock | enhanced — selects the app name/id baked into the installer
VARIANT="${VARIANT:-${1:-enhanced}}"

export WINEPREFIX="${WINEPREFIX:-"$SCRIPT_DIR/wine-inno"}"
export WINEDEBUG="${WINEDEBUG:--all}"
# No display needed; Inno's compiler is console-only, installer runs silent.
export WINEDLLOVERRIDES="mscoree=;mshtml="

# jrsoftware moved distribution to GitHub Releases; the old files.jrsoftware.org
# paths now 404 and download.php/is.exe just serves an HTML page (which wine then
# rejects with "Bad format"). Pin the latest Inno Setup 6, whose language the .iss
# targets. Override with INNO_URL= if you need a different one.
INNO_VER="${INNO_VER:-6.7.3}"
INNO_TAG="is-${INNO_VER//./_}"
INNO_URL="${INNO_URL:-https://github.com/jrsoftware/issrc/releases/download/${INNO_TAG}/innosetup-${INNO_VER}.exe}"

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
    curl -fL "$INNO_URL" -o "$IS_EXE"
    # A stray HTML error page here becomes wine's cryptic "Bad format"; fail clearly.
    case "$(file -b "$IS_EXE" 2>/dev/null)" in
      *executable*|*PE32*) : ;;
      *) echo "!! $INNO_URL did not return a Windows executable:"; file -b "$IS_EXE"; exit 1 ;;
    esac
  fi
  wine "$IS_EXE" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- 2>/dev/null
  # wine returns before all async registration settles
  wineserver -w || true
  ISCC="$(find_iscc || true)"
  [ -n "$ISCC" ] || { echo "!! Inno Setup install under wine failed"; exit 1; }
fi

echo "==> Compiling installer ($ISCC) ..."
# Per-variant identity. The AppId MUST differ between variants, or installing one
# would upgrade/uninstall the other and they could not coexist.
case "$VARIANT" in
  enhanced)
    APPNAME="mpv-enhanced-atmos"
    DISPLAYNAME="mpv (Enhanced + Atmos)"
    APPID="{{1F0B7C4E-2A55-4E1B-9C3D-7A6E51D2B084}"
    ;;
  *)
    APPNAME="mpv-atmos"
    DISPLAYNAME="mpv (Atmos)"
    APPID="{{9E6A2A6B-30F2-4D2C-9E7A-5B1C64A1E58D}"
    ;;
esac

# ISCC is a Windows program: give it Windows-style paths into the wine drive.
DIST_WIN_PATH="$(winepath -w "$DIST_DIR" 2>/dev/null || echo 'Z:'"${DIST_DIR//\//\\}")"
ICON_SRC="${ICON_SRC:-$SCRIPT_DIR/mpv-win/src/mpv/etc/mpv-icon.ico}"
ICON_WIN_PATH="$(winepath -w "$ICON_SRC" 2>/dev/null || echo 'Z:'"${ICON_SRC//\//\\}")"

echo "==> Building installer: $DISPLAYNAME  (id=$APPNAME)"
cd "$SCRIPT_DIR/installer"
wine "$ISCC" \
  "/DAppName=$APPNAME" \
  "/DDisplayName=$DISPLAYNAME" \
  "/DAppId=$APPID" \
  "/DDistDir=$DIST_WIN_PATH" \
  "/DIconFile=$ICON_WIN_PATH" \
  mpv-atmos.iss 2>/dev/null
wineserver -w || true

OUT="$SCRIPT_DIR/installer/Output/${APPNAME}-setup.exe"
[ -f "$OUT" ] || { echo "!! ISCC did not produce $OUT"; ls -la Output 2>/dev/null; exit 1; }
echo
echo "==> Installer built: $OUT ($(du -h "$OUT" | cut -f1))"
