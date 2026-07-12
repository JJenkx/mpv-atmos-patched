#!/usr/bin/env bash
# install_portable_launchers.sh
# Installs/updates Jellyfin Search and MPV (Patched) launchers.
# - Arch + KDE Wayland friendly (correct Wayland app-id / X11 WM_CLASS mapping)
# - Writes .desktop files to APP DIR and USER DIR (~/.local/share/applications)
# - Uses official MPV artwork from your portable tree by default

set -Eeuo pipefail

### ───────────────────────── User-tweakable (env overrides OK) ─────────────────────────
J_APP_ID="${J_APP_ID:-jellyfin-search}"          # desktop id & icon name for Jellyfin
J_APP_NAME="${J_APP_NAME:-Jellyfin Search}"
PY_BIN="${PY_BIN:-/usr/bin/python3}"             # python interpreter for Jellyfin
J_ENTRY_NAME="${J_ENTRY_NAME:-jellyfin.py}"      # your Jellyfin entry script
J_ICON_CANDIDATES="${J_ICON_CANDIDATES:-icons/${J_APP_ID}.svg ${J_APP_ID}.svg icon.svg assets/${J_APP_ID}.svg assets/icon.svg}"

M_APP_ID="${M_APP_ID:-mpv-patched}"              # desktop id & icon name for MPV wrapper
M_APP_NAME="${M_APP_NAME:-MPV (Patched)}"
MPV_WRAPPER_NAME="${MPV_WRAPPER_NAME:-mpv_patched.sh}"

# Prefer official MPV icons found in your portable tree; fall back to local project icons.
M_ICON_CANDIDATES="${M_ICON_CANDIDATES:-\
mpv/share/icons/hicolor/scalable/apps/mpv.svg \
mpv/share/icons/hicolor/256x256/apps/mpv.png \
mpv/share/icons/hicolor/128x128/apps/mpv.png \
mpv/share/icons/hicolor/64x64/apps/mpv.png \
icons/${M_APP_ID}.svg ${M_APP_ID}.svg icons/mpv.svg mpv.svg assets/${M_APP_ID}.svg assets/mpv.svg}"

### ───────────────────────────── Derived paths ─────────────────────────────
APP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
J_ENTRY="${APP_ROOT}/${J_ENTRY_NAME}"
M_WRAPPER="${APP_ROOT}/${MPV_WRAPPER_NAME}"

WRAP_DIR="${APP_ROOT}/.portable"
J_WRAP="${WRAP_DIR}/launch_${J_APP_ID}.py"       # helper to set Wayland app_id for Jellyfin (Qt)

# Where we also copy desktop entries for system to pick up
APPS_DIR="${HOME}/.local/share/applications"

# Icons go to hicolor theme
ICON_BASE="${HOME}/.local/share/icons/hicolor"
ICON_DIR_SVG="${ICON_BASE}/scalable/apps"
ICON_DIR_PNG="${ICON_BASE}/256x256/apps"

# Paths for installed icons
J_SVG="${ICON_DIR_SVG}/${J_APP_ID}.svg"
J_PNG="${ICON_DIR_PNG}/${J_APP_ID}.png"
M_SVG="${ICON_DIR_SVG}/${M_APP_ID}.svg"
M_PNG="${ICON_DIR_PNG}/${M_APP_ID}.png"

# Desktop entries (both in APP DIR and USER DIR)
J_DESKTOP_APPDIR="${APP_ROOT}/${J_APP_ID}.desktop"
M_DESKTOP_APPDIR="${APP_ROOT}/${M_APP_ID}.desktop"
J_DESKTOP_USER="${APPS_DIR}/${J_APP_ID}.desktop"
M_DESKTOP_USER="${APPS_DIR}/${M_APP_ID}.desktop"

say()  { printf "\033[1;36m[setup]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m[error]\033[0m %s\n" "$*"; exit 1; }

### ─────────────────────────── CLI flags ───────────────────────────
ONLY=""
UNINSTALL_TARGET=""
INSTALL_TO_USER=1   # copy desktop files to ~/.local/share/applications as well
while (( $# )); do
  case "$1" in
    --only)        ONLY="${2:-}"; shift 2;;
    --uninstall)   UNINSTALL_TARGET="${2:-all}"; shift 2;;
    --no-user)     INSTALL_TO_USER=0; shift;;
    *)
      die "Unknown arg: $1
Usage:
  --only [mpv|jellyfin]     Install only one launcher
  --uninstall [mpv|jellyfin|all]
  --no-user                 Do NOT copy .desktop files into ~/.local/share/applications"
      ;;
  esac
done

### ─────────────────────────── Helpers ────────────────────────────
# KDE cache tool (safe if missing)
if command -v kbuildsycoca6 >/dev/null 2>&1; then
  KBUILDER=kbuildsycoca6
elif command -v kbuildsycoca5 >/dev/null 2>&1; then
  KBUILDER=kbuildsycoca5
else
  KBUILDER=:
fi

refresh_caches() {
  $KBUILDER --noincremental || true
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${APPS_DIR}" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache   >/dev/null 2>&1 && gtk-update-icon-cache -f "${ICON_BASE}" >/dev/null 2>&1 || true
  command -v xdg-desktop-menu        >/dev/null 2>&1 && xdg-desktop-menu forceupdate || true
}

write_file() {
  # $1 target, then heredoc follows via caller
  local tgt="$1"; shift
  install -D -m 0644 /dev/null "$tgt"
  cat > "$tgt"
  chmod 0644 "$tgt"
}

choose_icon() {
  local base="$1"; shift
  for c in "$@"; do
    [[ -f "${base}/${c}" ]] && { echo "${base}/${c}"; return 0; }
  done
  return 1
}

write_fallback_svg_mpv() {
  # $1 = path
  cat > "$1" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg width="512" height="512" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#4F46E5"/><stop offset="50%" stop-color="#3B82F6"/>
    <stop offset="100%" stop-color="#22D3EE"/></linearGradient></defs>
  <rect width="512" height="512" rx="96" ry="96" fill="#0f1126"/>
  <circle cx="256" cy="256" r="156" fill="url(#g)"/>
  <polygon points="228,192 352,256 228,320" fill="#0f1126" />
</svg>
SVG
}

write_fallback_svg_jellyfin() {
  # $1 = path
  cat > "$1" <<'SVG'
<?xml version="1.0" encoding="UTF-8"?>
<svg width="512" height="512" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#10B981"/><stop offset="50%" stop-color="#06B6D4"/>
    <stop offset="100%" stop-color="#6366F1"/></linearGradient></defs>
  <rect width="512" height="512" rx="96" ry="96" fill="#0f1126"/>
  <circle cx="232" cy="236" r="120" fill="url(#g)"/>
  <g transform="translate(0,0)" fill="none" stroke="#eaf2ff" stroke-width="28" stroke-linecap="round">
    <circle cx="232" cy="236" r="84"/>
    <line x1="292" y1="296" x2="362" y2="366"/>
  </g>
</svg>
SVG
}

render_png_if_possible() {
  # $1 = svg path, $2 = png path
  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 256 -h 256 "$1" -o "$2" || true
  elif command -v magick >/dev/null 2>&1; then
    magick "$1" -resize 256x256 "$2" || true
  fi
}

install_icon_pair() {
  # $1 = svg_target, $2 = png_target, $3... = candidates (absolute)
  local svg="$1"; shift
  local png="$1"; shift
  local src=""
  for cand in "$@"; do
    [[ -f "$cand" ]] && { src="$cand"; break; }
  done
  if [[ -n "$src" ]]; then
    say "Installing icon: $src → $svg"
    install -D -m 0644 -T "$src" "$svg"
  else
    # Pick distinct fallbacks based on target name
    say "No local icon found; writing fallback → $svg"
    install -D -m 0644 /dev/null "$svg"
    case "$svg" in
      *"/${M_APP_ID}.svg")      write_fallback_svg_mpv "$svg" ;;
      *"/${J_APP_ID}.svg")      write_fallback_svg_jellyfin "$svg" ;;
      *)                        write_fallback_svg_mpv "$svg" ;; # default
    esac
  fi
  render_png_if_possible "$svg" "$png"
}

### ─────────────────────────── Installers ───────────────────────────
install_jellyfin() {
  command -v "$PY_BIN" >/dev/null || die "Python not found at: $PY_BIN"
  [[ -f "$J_ENTRY" ]] || die "Jellyfin entry not found: $J_ENTRY"

  # Icons
  say "Installing Jellyfin icon(s)…"
  local j_candidates=()
  # shellcheck disable=SC2206
  j_candidates=($J_ICON_CANDIDATES)
  local j_abs=()
  for c in "${j_candidates[@]}"; do j_abs+=("${APP_ROOT}/${c}"); done
  install_icon_pair "$J_SVG" "$J_PNG" "${j_abs[@]}"

  # Wrapper to set desktop filename for Wayland app_id in Qt
  say "Preparing wrapper → $J_WRAP"
  install -d "$WRAP_DIR"
  cat > "$J_WRAP" <<'PY'
#!/usr/bin/env python3
import os, sys, runpy
try:
    from PySide6.QtGui import QGuiApplication
    # Hint Plasma to map this window to jellyfin-search.desktop
    QGuiApplication.setDesktopFileName("jellyfin-search.desktop")
except Exception:
    pass
target = os.environ.get("JELLYFIN_REAL_ENTRY")
if not target:
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(os.path.dirname(here), "jellyfin.py")
sys.argv[0] = target
runpy.run_path(target, run_name="__main__")
PY
  chmod +x "$J_WRAP"

  # Desktop file content (single source used for both APP DIR and USER DIR)
  local j_content; j_content="$(cat <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=${J_APP_NAME}
Comment=Launch the Jellyfin search UI
TryExec=${PY_BIN}
Exec=${PY_BIN} ${J_WRAP@Q}
Icon=${J_APP_ID}
Terminal=false
Categories=AudioVideo;Video;Network;
StartupNotify=true
StartupWMClass=${J_APP_ID}
X-KDE-WaylandAppId=${J_APP_ID}
X-Exec-Env=JELLYFIN_REAL_ENTRY=${J_ENTRY@Q}
EOF
)"

  say "Writing Jellyfin desktop (app dir) → $J_DESKTOP_APPDIR"
  write_file "$J_DESKTOP_APPDIR" <<<"$j_content"

  if (( INSTALL_TO_USER )); then
    say "Installing Jellyfin desktop (user) → $J_DESKTOP_USER"
    write_file "$J_DESKTOP_USER" <<<"$j_content"
  fi
}

install_mpv() {
  [[ -f "$M_WRAPPER" ]] || die "MPV wrapper not found: $M_WRAPPER"
  chmod +x "$M_WRAPPER" || true

  # Icons (prefer official mpv.svg/png from your portable tree)
  say "Installing MPV icon(s)…"
  local m_candidates=()
  # shellcheck disable=SC2206
  m_candidates=($M_ICON_CANDIDATES)
  local m_abs=()
  for c in "${m_candidates[@]}"; do m_abs+=("${APP_ROOT}/${c}"); done
  install_icon_pair "$M_SVG" "$M_PNG" "${m_abs[@]}"

  # Desktop file content (Wayland/X11 hints MUST match wrapper's --wayland-app-id/--x11-name)
  local m_content; m_content="$(cat <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=${M_APP_NAME}
Comment=Launch MPV via portable patched wrapper
TryExec=${M_WRAPPER@Q}
Exec=${M_WRAPPER@Q} %U
Icon=${M_APP_ID}
Terminal=false
Categories=AudioVideo;Video;Player;
StartupNotify=true
# Ensure Plasma maps the window to THIS launcher (Wayland + X11)
StartupWMClass=${M_APP_ID}
X-KDE-WaylandAppId=${M_APP_ID}
# Accept URLs/files
MimeType=video/*;audio/*;application/x-matroska;application/ogg;application/x-ogm-video;application/x-mpegurl;application/vnd.rn-realmedia;application/x-shorten;application/x-flac;audio/x-flac;application/x-cue;
EOF
)"

  say "Writing MPV desktop (app dir) → $M_DESKTOP_APPDIR"
  write_file "$M_DESKTOP_APPDIR" <<<"$m_content"

  if (( INSTALL_TO_USER )); then
    say "Installing MPV desktop (user) → $M_DESKTOP_USER"
    write_file "$M_DESKTOP_USER" <<<"$m_content"
  fi

  # Sanity warning if wrapper doesn't enforce the app-id/class
  if ! grep -q -- '--wayland-app-id' "$M_WRAPPER" 2>/dev/null; then
    warn "Your $MPV_WRAPPER_NAME doesn't set --wayland-app-id=${M_APP_ID}. Add:
      --wayland-app-id='${M_APP_ID}' --x11-name='${M_APP_ID}'
    to the final mpv exec in the wrapper to guarantee icon mapping."
  fi
}

uninstall_target() {
  local t="$1"
  case "$t" in
    jellyfin)
      say "Uninstalling Jellyfin launcher & icons…"
      rm -f -- "$J_DESKTOP_USER" "$J_SVG" "$J_PNG" "$J_DESKTOP_APPDIR" ;;
    mpv)
      say "Uninstalling MPV launcher & icons…"
      rm -f -- "$M_DESKTOP_USER" "$M_SVG" "$M_PNG" "$M_DESKTOP_APPDIR" ;;
    all|*)
      say "Uninstalling ALL launchers & icons…"
      rm -f -- "$J_DESKTOP_USER" "$J_SVG" "$J_PNG" "$M_DESKTOP_USER" "$M_SVG" "$M_PNG" \
               "$J_DESKTOP_APPDIR" "$M_DESKTOP_APPDIR" ;;
  esac
  refresh_caches
  say "Done."
}

### ─────────────────────────── Main ───────────────────────────
install -d "$APPS_DIR" "$ICON_DIR_SVG" "$ICON_DIR_PNG" "$WRAP_DIR"

if [[ -n "${UNINSTALL_TARGET}" ]]; then
  uninstall_target "$UNINSTALL_TARGET"
  exit 0
fi

case "$ONLY" in
  jellyfin) install_jellyfin ;;
  mpv)      install_mpv ;;
  "")       install_jellyfin; install_mpv ;;
  *)        die "--only must be 'jellyfin' or 'mpv'" ;;
esac

say "Refreshing caches…"
refresh_caches
say "Done. Desktop entries written to:"
say "  APP DIR: ${J_DESKTOP_APPDIR##${APP_ROOT}/}, ${M_DESKTOP_APPDIR##${APP_ROOT}/}"
if (( INSTALL_TO_USER )); then
  say "  USER DIR: ${J_DESKTOP_USER##${HOME}/}, ${M_DESKTOP_USER##${HOME}/}"
fi
say "Tip: Ensure ${MPV_WRAPPER_NAME} ends with:
  --wayland-app-id='${M_APP_ID}' --x11-name='${M_APP_ID}'"
