#!/usr/bin/env bash
# Bundle the calf krunkit stack + gvproxy into a macOS .app for release/dev.
# Requires: make krunkit-stack (or CALF_KRUNKIT_PREFIX) and gvproxy on PATH.
#
# Usage:
#   ./scripts/bundle-krunkit-macos.sh path/to/calf.app
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP/Contents" ]]; then
  echo "usage: $0 path/to/calf.app" >&2
  exit 1
fi

PREFIX="${CALF_KRUNKIT_PREFIX:-$HOME/.config/calf/krunkit}"
KRUNKIT_BIN="${PREFIX}/bin/krunkit"
LIBKRUN="${PREFIX}/lib/libkrun.1.dylib"
FIRMWARE_DIR="${PREFIX}/share/krunkit"

if [[ ! -x "$KRUNKIT_BIN" ]]; then
  echo "error: krunkit stack missing at $KRUNKIT_BIN (run: make krunkit-stack)" >&2
  exit 1
fi
if [[ ! -f "$LIBKRUN" ]]; then
  echo "error: libkrun missing at $LIBKRUN (run: make krunkit-stack)" >&2
  exit 1
fi

GVPROXY_SRC="${CALF_GVPROXY_BIN:-}"
if [[ -z "$GVPROXY_SRC" ]] && command -v gvproxy >/dev/null 2>&1; then
  GVPROXY_SRC="$(command -v gvproxy)"
fi
if [[ -z "$GVPROXY_SRC" || ! -x "$GVPROXY_SRC" ]]; then
  echo "error: gvproxy not found (brew tap libkrun/krun && brew install libkrun/krun/gvproxy)" >&2
  exit 1
fi

MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources/krunkit"
mkdir -p "$MACOS_DIR" "$RES_DIR/bin" "$RES_DIR/lib" "$RES_DIR/share/krunkit"

# Stage from PREFIX into a temp dir first. PREFIX may be inside the app (dev rebundle),
# and we delete RES_DIR/lib before copying.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/calf-krunkit-bundle.XXXXXX")"
cleanup_stage() { rm -rf "$STAGE"; }
trap cleanup_stage EXIT
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share/krunkit"
cp "$KRUNKIT_BIN" "$STAGE/bin/krunkit"
cp "$GVPROXY_SRC" "$STAGE/bin/gvproxy"
cp -R "${PREFIX}/lib/." "$STAGE/lib/"
if [[ -d "$FIRMWARE_DIR" ]]; then
  cp -R "${FIRMWARE_DIR}/." "$STAGE/share/krunkit/"
elif [[ -f /opt/homebrew/share/krunkit/KRUN_EFI.silent.fd ]]; then
  cp /opt/homebrew/share/krunkit/KRUN_EFI.silent.fd "$STAGE/share/krunkit/"
else
  echo "error: KRUN_EFI.silent.fd not found under $FIRMWARE_DIR" >&2
  exit 1
fi

# rm before cp: brew binaries are often mode 555; a prior bundle leaves non-writable dests.
rm -f "$RES_DIR/bin/krunkit" "$MACOS_DIR/gvproxy"
rm -rf "$RES_DIR/lib" "$RES_DIR/share/krunkit"
mkdir -p "$RES_DIR/lib" "$RES_DIR/share/krunkit"

cp "$STAGE/bin/krunkit" "$RES_DIR/bin/krunkit"
cp "$STAGE/bin/gvproxy" "$MACOS_DIR/gvproxy"
cp -R "$STAGE/lib/." "$RES_DIR/lib/"
cp -R "$STAGE/share/krunkit/." "$RES_DIR/share/krunkit/"
chmod u+w,a+x "$RES_DIR/bin/krunkit" "$MACOS_DIR/gvproxy"

# Relocatable dylib load path (SIP ignores DYLD_LIBRARY_PATH for signed binaries).
desired="@loader_path/../lib/libkrun.1.dylib"
current="$(otool -L "$RES_DIR/bin/krunkit" | awk '/libkrun/{print $1; exit}')"
if [[ -n "$current" && "$current" != "$desired" ]]; then
  install_name_tool -change "$current" "$desired" "$RES_DIR/bin/krunkit"
fi

# Vendor Homebrew-linked dylibs (libepoxy, virglrenderer, MoltenVK, …) next to libkrun
# and rewrite install names to @loader_path so release users need no Homebrew GPU stack.
is_bundled_or_system() {
  case "$1" in
    /System/*|/usr/lib/*|@loader_path/*|@rpath/*|@executable_path/*) return 0 ;;
    *libkrun*) return 0 ;;
    *) return 1 ;;
  esac
}

rewrite_dep() {
  local target=$1
  local old=$2
  local new=$3
  if otool -L "$target" 2>/dev/null | awk '{print $1}' | grep -Fxq "$old"; then
    install_name_tool -change "$old" "$new" "$target"
  fi
}

queue=()
LIBKRUN_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RES_DIR/lib/libkrun.1.dylib")"
queue+=("$LIBKRUN_REAL")

while ((${#queue[@]})); do
  lib="${queue[0]}"
  queue=("${queue[@]:1}")
  [[ -f "$lib" ]] || continue
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    if is_bundled_or_system "$dep"; then
      continue
    fi
    if [[ ! -f "$dep" ]]; then
      echo "error: missing dylib dependency $dep (needed by $lib)" >&2
      exit 1
    fi
    base="$(basename "$dep")"
    dest="$RES_DIR/lib/$base"
    if [[ ! -f "$dest" ]]; then
      cp "$dep" "$dest"
      chmod u+w "$dest"
      install_name_tool -id "@loader_path/$base" "$dest"
      queue+=("$dest")
    fi
    # krunkit binary lives in bin/ → ../lib; dylibs live in lib/ → same dir.
    rewrite_dep "$RES_DIR/bin/krunkit" "$dep" "@loader_path/../lib/$base"
    for other in "$RES_DIR"/lib/*.dylib; do
      [[ -f "$other" ]] || continue
      rewrite_dep "$other" "$dep" "@loader_path/$base"
    done
  done < <(otool -L "$lib" | awk 'NR>1{print $1}')
done

ENTITLEMENTS=""
# Prefer entitlements from the krunkit build tree used by install-krunkit-stack.
if [[ -f /tmp/calf-krunkit-dax/src/krunkit.entitlements ]]; then
  ENTITLEMENTS=/tmp/calf-krunkit-dax/src/krunkit.entitlements
elif [[ -f /tmp/calf-libkrun-q4/src/hvf-entitlements.plist ]]; then
  ENTITLEMENTS=/tmp/calf-libkrun-q4/src/hvf-entitlements.plist
fi

codesign_bin() {
  local path=$1
  local id=$2
  if [[ -n "$ENTITLEMENTS" ]]; then
    codesign --force --sign - --identifier "$id" --entitlements "$ENTITLEMENTS" "$path" >/dev/null
  else
    codesign --force --sign - --identifier "$id" "$path" >/dev/null
  fi
}

codesign_bin "$RES_DIR/bin/krunkit" "com.enegalan.calf.krunkit"
for dylib in "$RES_DIR"/lib/*.dylib; do
  [[ -f "$dylib" ]] || continue
  codesign_bin "$dylib" "com.enegalan.calf.libkrun"
done
codesign_bin "$MACOS_DIR/gvproxy" "com.enegalan.calf.gvproxy"

echo "bundled krunkit stack → $RES_DIR (+ gvproxy in MacOS)"
