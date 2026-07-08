#!/bin/bash
set -euo pipefail

# Shared packaging constants and helpers for the bash packaging scripts.

APP_NAME="calf"
APP_NAME_TITLE="Calf"
MAINTAINER="Ene Galan <hello@enegalan.com>"
DIST_DIR="dist"
BUILD_DIR="build"

require_command() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: required command '$cmd' not found" >&2
        exit 1
    fi
}

require_directory() {
    local dir=$1
    local hint=$2
    if [[ ! -d "$dir" ]]; then
        echo "error: directory not found: $dir" >&2
        echo "hint: $hint" >&2
        exit 1
    fi
}

extract_version() {
    local go_version
    local flutter_version
    go_version=$(grep 'const Version' backend/version/version.go | sed 's/.*"\(.*\)".*/\1/')
    flutter_version=$(grep '^version:' ui/pubspec.yaml | sed 's/version: \([0-9.]*\).*/\1/')

    if [[ -z "$go_version" || -z "$flutter_version" ]]; then
        echo "error: could not extract version from backend/version/version.go and ui/pubspec.yaml" >&2
        exit 1
    fi

    if [[ "$go_version" != "$flutter_version" ]]; then
        echo "error: version mismatch: backend/version/version.go=$go_version, ui/pubspec.yaml=$flutter_version" >&2
        exit 1
    fi

    echo "$go_version"
}
