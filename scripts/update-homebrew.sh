#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/_common.sh"

VERSION=$(extract_version)
DMG_FILE="$DIST_DIR/Calf-${VERSION}.dmg"

if [[ ! -f "$DMG_FILE" ]]; then
    echo "error: DMG file not found: $DMG_FILE" >&2
    echo "hint: run 'make package-macos' first to generate the DMG" >&2
    exit 1
fi

echo "calculating SHA256 for $DMG_FILE ..."
SHA256=$(shasum -a 256 "$DMG_FILE" | cut -d' ' -f1)
echo "SHA256: $SHA256"

CASK_CONTENT=$(cat <<EOF
cask "calf" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/enegalan/calf/releases/download/v#{version}/Calf-#{version}.dmg"
  name "Calf"
  desc "Lightweight, open-source alternative to Docker Desktop"
  homepage "https://github.com/enegalan/calf"

  app "Calf.app"

  zap trash: [
    "~/.config/calf",
    "~/Library/Application Support/calf",
  ]
end
EOF
)

if [[ $# -gt 0 ]]; then
    TAP_DIR=$1
    if [[ ! -d "$TAP_DIR" ]]; then
        echo "error: target directory does not exist: $TAP_DIR" >&2
        exit 1
    fi
    mkdir -p "$TAP_DIR/Casks"
    echo "$CASK_CONTENT" > "$TAP_DIR/Casks/calf.rb"
    echo "successfully updated $TAP_DIR/Casks/calf.rb"
else
    mkdir -p "$DIST_DIR"
    echo "$CASK_CONTENT" > "$DIST_DIR/calf.rb"
    echo ""
    echo "========================================="
    echo " Generated Cask file at $DIST_DIR/calf.rb:"
    echo "========================================="
    echo "$CASK_CONTENT"
    echo "========================================="
    echo ""
    echo "To publish this, copy the file above to your homebrew-tap repository under Casks/calf.rb"
fi
