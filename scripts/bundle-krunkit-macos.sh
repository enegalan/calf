#!/usr/bin/env bash
# Bundle the Calf krunkit stack + gvproxy into a macOS .app for release/dev.
# Requires: make krunkit-stack (or CALF_KRUNKIT_PREFIX) and gvproxy on PATH.
#
# Usage:
#   ./scripts/bundle-krunkit-macos.sh path/to/Calf.app
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP/Contents" ]]; then
  echo "usage: $0 path/to/Calf.app" >&2
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

cp "$KRUNKIT_BIN" "$RES_DIR/bin/krunkit"
cp -R "${PREFIX}/lib/." "$RES_DIR/lib/"
if [[ -d "$FIRMWARE_DIR" ]]; then
  cp -R "${FIRMWARE_DIR}/." "$RES_DIR/share/krunkit/"
elif [[ -f /opt/homebrew/share/krunkit/KRUN_EFI.silent.fd ]]; then
  cp /opt/homebrew/share/krunkit/KRUN_EFI.silent.fd "$RES_DIR/share/krunkit/"
else
  echo "error: KRUN_EFI.silent.fd not found under $FIRMWARE_DIR" >&2
  exit 1
fi
cp "$GVPROXY_SRC" "$MACOS_DIR/gvproxy"
chmod +x "$RES_DIR/bin/krunkit" "$MACOS_DIR/gvproxy"

# Relocatable dylib load path (SIP ignores DYLD_LIBRARY_PATH for signed binaries).
desired="@loader_path/../lib/libkrun.1.dylib"
current="$(otool -L "$RES_DIR/bin/krunkit" | awk '/libkrun/{print $1; exit}')"
if [[ -n "$current" && "$current" != "$desired" ]]; then
  install_name_tool -change "$current" "$desired" "$RES_DIR/bin/krunkit"
fi

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
for dylib in "$RES_DIR"/lib/libkrun*.dylib; do
  [[ -f "$dylib" ]] || continue
  codesign_bin "$dylib" "com.enegalan.calf.libkrun"
done
codesign_bin "$MACOS_DIR/gvproxy" "com.enegalan.calf.gvproxy"

echo "bundled krunkit stack → $RES_DIR (+ gvproxy in MacOS)"
