#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/_common.sh"

VERSION=$(extract_version)
APP_BUNDLE="ui/build/macos/Build/Products/Release/Calf.app"

require_directory "$APP_BUNDLE" "run 'make release-macos' first"
require_command hdiutil
require_command pkgbuild
require_command create-dmg

mkdir -p "$DIST_DIR"

build_dmg() {
    local output="$DIST_DIR/${APP_NAME_TITLE}-${VERSION}.dmg"
    echo "creating $output ..."
    rm -f "$output"

    # Create temporary staging directory for create-dmg
    local stage_dir
    stage_dir=$(mktemp -d -t "calf-dmg-XXXXXX")
    cp -R "$APP_BUNDLE" "$stage_dir/"

    create-dmg \
        --volname "$APP_NAME_TITLE" \
        --background "ui/assets/brand/dmg_background.tiff" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 128 \
        --icon "${APP_NAME_TITLE}.app" 170 200 \
        --hide-extension "${APP_NAME_TITLE}.app" \
        --app-drop-link 490 200 \
        "$output" \
        "$stage_dir"

    rm -rf "$stage_dir"
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
