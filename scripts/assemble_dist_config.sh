#!/usr/bin/env bash
# assemble_dist_config.sh <portable_config_dir> <stock|enhanced> <linux|windows>
#
# Produces the distributable portable_config from the bundled config tree:
#   - the user's personal mpv.conf / input.conf are NEVER shipped as the active
#     config; if present they are kept only as *.example
#   - the active mpv.conf is generated from dist_config/mpv.conf.<variant> plus
#     the platform-specific audio example block (commented out by default)
# All other bundled content (scripts, shaders, fonts, script-opts) is untouched.
set -Eeuo pipefail

CFG="${1:?usage: assemble_dist_config.sh <portable_config_dir> <variant> <platform>}"
VARIANT="${2:?variant: stock|enhanced}"
PLATFORM="${3:?platform: linux|windows}"
DC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist_config"

case "$VARIANT" in stock|enhanced) ;; *) echo "!! bad variant '$VARIANT'"; exit 2;; esac
case "$PLATFORM" in linux|windows) ;; *) echo "!! bad platform '$PLATFORM'"; exit 2;; esac
[ -d "$CFG" ] || { echo "!! not a dir: $CFG"; exit 1; }
[ -f "$DC/mpv.conf.$VARIANT" ]   || { echo "!! missing $DC/mpv.conf.$VARIANT"; exit 1; }
[ -f "$DC/audio.$PLATFORM.conf" ] || { echo "!! missing $DC/audio.$PLATFORM.conf"; exit 1; }

# Never ship the user's personal configs as active — demote any to *.example.
[ -f "$CFG/mpv.conf" ]   && mv -f "$CFG/mpv.conf"   "$CFG/mpv.conf.example"
[ -f "$CFG/input.conf" ] && mv -f "$CFG/input.conf" "$CFG/input.conf.example"

# Generate the active, curated mpv.conf (variant defaults + audio example block).
{
  cat "$DC/mpv.conf.$VARIANT"
  cat "$DC/audio.$PLATFORM.conf"
} > "$CFG/mpv.conf"

echo "==> assembled $VARIANT/$PLATFORM active mpv.conf ($(grep -c . "$CFG/mpv.conf") non-blank lines)"
echo "    examples present: $(cd "$CFG" && ls *.example 2>/dev/null | tr '\n' ' ')"
