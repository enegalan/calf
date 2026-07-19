#!/usr/bin/env bash
# Extract a compressed vfkit guest disk into ~/.config/calf/vfkit/<vm>/.
# Usage: ./scripts/guest-image/unpack-vfkit-disk.sh /path/to/disk.raw.zst
set -euo pipefail

ARCHIVE="${1:-}"
VM_NAME="${CALF_VM_NAME:-calf}"
DEST_DIR="${HOME}/.config/calf/vfkit/${VM_NAME}"
DEST_DISK="${DEST_DIR}/disk.raw"

if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo "usage: $0 /path/to/disk.raw.zst" >&2
  exit 1
fi
if ! command -v zstd >/dev/null 2>&1; then
  echo "error: zstd required (brew install zstd)" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
echo "extracting $ARCHIVE -> $DEST_DISK"
zstd -f -d -o "$DEST_DISK" "$ARCHIVE"
EFI_ZST="$(dirname "$ARCHIVE")/efi-store.zst"
if [[ -f "$EFI_ZST" ]]; then
  zstd -f -d -o "${DEST_DIR}/efi-store" "$EFI_ZST"
fi
echo "ready: Calf will prefer vfkit automatically when vfkit is on PATH or bundled"
echo "disk: $DEST_DISK"
echo "force Lima: export CALF_RUNTIME=lima"
