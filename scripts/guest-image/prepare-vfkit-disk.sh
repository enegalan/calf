#!/usr/bin/env bash
# Copy a provisioned raw disk into ~/.config/calf/vfkit/<vm>/disk.raw.
# Prefer building with: ./scripts/guest-image/build-vfkit-guest.sh [--pack]
set -euo pipefail

VM_NAME="${CALF_VM_NAME:-calf}"
DEST_DIR="${HOME}/.config/calf/vfkit/${VM_NAME}"
DEST_DISK="${DEST_DIR}/disk.raw"
SOURCE_DISK="${1:-}"

if [[ -z "$SOURCE_DISK" ]]; then
  echo "usage: $0 /path/to/provisioned/raw/disk" >&2
  echo "or build one: $(dirname "$0")/build-vfkit-guest.sh [--pack]" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
echo "copying $SOURCE_DISK -> $DEST_DISK (sparse)"
cp -c "$SOURCE_DISK" "$DEST_DISK" 2>/dev/null || cp "$SOURCE_DISK" "$DEST_DISK"
if [[ -f "$(dirname "$SOURCE_DISK")/vz-efi" ]]; then
  cp "$(dirname "$SOURCE_DISK")/vz-efi" "${DEST_DIR}/efi-store"
fi
echo "ready: Calf auto-selects vfkit when vfkit is on PATH or bundled"
echo "disk: $DEST_DISK"
