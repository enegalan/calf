#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/_common.sh"

VERSION=$(extract_version)
APP_BUNDLE="ui/build/macos/Build/Products/Release/Calf.app"

require_directory "$APP_BUNDLE" "run 'make release-macos' first"
require_command hdiutil
require_command pkgbuild

mkdir -p "$DIST_DIR"

build_dmg() {
    local output="$DIST_DIR/${APP_NAME_TITLE}-${VERSION}.dmg"
    echo "creating $output ..."
    rm -f "$output"
    hdiutil create -volname "$APP_NAME_TITLE" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$output"
}

build_pkg() {
    local output="$DIST_DIR/${APP_NAME_TITLE}-${VERSION}.pkg"
    echo "creating $output ..."
    pkgbuild --component "$APP_BUNDLE" --install-location /Applications \
        --identifier "com.enegalan.$APP_NAME" \
        --version "$VERSION" \
        "$output"
}

build_dmg
build_pkg

echo "done: $(ls -1 "$DIST_DIR")"
