#!/usr/bin/env bash
# audit_portable_mpv.sh — find and optionally vendor system libs for a portable mpv stack
# Requires: pax-utils (lddtree). Optional: patchelf.
# Usage:
#   ./audit_portable_mpv.sh [--app-dir DIR] [--copy] [--fix-rpath]

set -Eeuo pipefail

APP_DIR="${APP_DIR:-}"
COPY=0
FIX_RPATH=0

while (( "$#" )); do
  case "$1" in
    --app-dir)   shift; APP_DIR="${1?path required}"; shift ;;
    --copy)      COPY=1; shift ;;
    --fix-rpath) FIX_RPATH=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--app-dir DIR] [--copy] [--fix-rpath]

--app-dir    Path to your portable root (contains bin/ and lib/). Defaults to \$PWD.
--copy       Copy any non-glibc libs resolved from /usr/lib into <app>/lib and add SONAME links.
--fix-rpath  Set RUNPATH to \$ORIGIN/../lib:\$ORIGIN on all ELFs in <app>/bin and <app>/lib (requires patchelf).
EOF
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${APP_DIR:-}" ]]; then
  APP_DIR="$PWD"
fi

BIN_DIR="$APP_DIR/bin"
LIB_DIR="$APP_DIR/lib"
mkdir -p "$LIB_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need lddtree
if ! command -v patchelf >/dev/null 2>&1; then
  echo "Note: patchelf not found; --fix-rpath will be skipped."
  FIX_RPATH=0
fi

echo "==> App dir: $APP_DIR"
echo "==> Bin dir: $BIN_DIR"
echo "==> Lib dir: $LIB_DIR"
echo

# Find ELFs to audit
mapfile -t ELFS < <(find "$BIN_DIR" "$LIB_DIR" -maxdepth 1 \
    \( -type f -perm -u+x -o -type f -name '*.so*' \) 2>/dev/null | sort -u)

if ((${#ELFS[@]} == 0)); then
  echo "No ELF files found in $BIN_DIR or $LIB_DIR"; exit 0
fi

# ---- State (associative maps) ----
declare -A NEED_VENDOR   # SONAME -> absolute path (first seen)
declare -A FROM_PATH     # SONAME -> resolved path we saw
declare -A FROM_WHO      # SONAME -> which ELF needed it

# Helpers
get_soname() {
  local f="$1"
  readelf -d "$f" 2>/dev/null | awk -F'[][]' '/SONAME/ {print $2; exit}'
}

ensure_soname_link() {
  local copied="$1"
  local soname; soname="$(get_soname "$copied")"
  [[ -z "$soname" ]] && return 0
  ( cd "$LIB_DIR" && ln -sfn "$(basename "$copied")" "$soname" )
}

is_glibc_core() {
  case "$1" in
    libc.so.*|libpthread.so.*|libm.so.*|libdl.so.*|librt.so.*|ld-linux*.so.*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "==> Auditing with lddtree..."
for elf in "${ELFS[@]}"; do
  echo "-- ${elf#$APP_DIR/}"
  # -a all deps, -P absolute paths, -l list format (one per line)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local_path="$line"
    # Handle "soname => path" or plain path
    if [[ "$local_path" == *"=>"* ]]; then
      soname="$(awk '{print $1}' <<<"$local_path")"
      resolved="$(awk '{print $3}' <<<"$local_path")"
    else
      soname="$(basename "$local_path")"
      resolved="$local_path"
    fi
    [[ -f "$resolved" ]] || continue
    [[ "$resolved" == "$elf" ]] && continue

    case "$resolved" in "$LIB_DIR"/*) continue ;; esac
    if is_glibc_core "$soname"; then continue; fi

    if [[ -z "${NEED_VENDOR[$soname]+set}" ]]; then
      NEED_VENDOR["$soname"]="$resolved"
      FROM_PATH["$soname"]="$resolved"
      FROM_WHO["$soname"]="$elf"
    fi
  done < <(lddtree -l -aP "$elf" 2>/dev/null || true)
done

echo
if ((${#NEED_VENDOR[@]} == 0)); then
  echo "✅ All non-glibc libs resolve inside $LIB_DIR already."
else
  echo "⚠️  Found libraries resolving from the system (recommend vendoring):"
  for s in "${!NEED_VENDOR[@]}"; do
    printf "  %-32s <- %s (needed by %s)\n" \
      "$s" "${FROM_PATH[$s]}" "${FROM_WHO[$s]#$APP_DIR/}"
  done

  if (( COPY )); then
    echo
    echo "==> Copying into $LIB_DIR and creating SONAME links..."
    for s in "${!NEED_VENDOR[@]}"; do
      src="${FROM_PATH[$s]}"
      base="$(basename "$src")"
      if [[ -L "$src" ]]; then
        real="$(readlink -f "$src")"
        install -m755 "$real" "$LIB_DIR/"
        install -m755 "$src"  "$LIB_DIR/" || true
        ensure_soname_link "$LIB_DIR/$(basename "$real")"
      else
        install -m755 "$src" "$LIB_DIR/"
        ensure_soname_link "$LIB_DIR/$base"
      fi
    done
  fi
fi

if (( FIX_RPATH )); then
  echo
  echo "==> Ensuring RUNPATH on shipped ELFs prefers \$ORIGIN/../lib:\$ORIGIN"
  for elf in "${ELFS[@]}"; do
    file "$elf" | grep -q 'ELF' || continue
    patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN' "$elf" 2>/dev/null || true
  done
fi

echo
echo "==> Re-audit after changes:"
for elf in "${ELFS[@]}"; do
  missing="$(LD_LIBRARY_PATH="$LIB_DIR" ldd -r "$elf" 2>&1 | grep 'not found' || true)"
  if [[ -n "$missing" ]]; then
    echo "❌ Missing deps for ${elf#$APP_DIR/}:"
    echo "$missing" | sed 's/^/   /'
  else
    echo "✅ ${elf#$APP_DIR/} resolves cleanly with LD_LIBRARY_PATH=$LIB_DIR"
  fi
done

echo
echo "Done."
