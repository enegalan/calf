#!/usr/bin/env bash
# Compress a provisioned guest disk for distribution (not embedded in the .app).
# Usage: ./scripts/guest-image/pack-guest-disk.sh [disk.raw]
set -euo pipefail

VM_NAME="${CALF_VM_NAME:-calf}"
SRC="${1:-${HOME}/.config/calf/guest/${VM_NAME}/disk.raw}"
OUT_DIR="${2:-${HOME}/.config/calf/guest/${VM_NAME}}"
OUT="${OUT_DIR}/disk.raw.zst"

if [[ ! -f "$SRC" ]]; then
  echo "error: disk not found: $SRC" >&2
  echo "prepare one with: ./scripts/guest-image/prepare-guest-disk.sh /path/to/disk" >&2
  exit 1
fi
if ! command -v zstd >/dev/null 2>&1; then
  echo "error: zstd required (brew install zstd)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
echo "compressing $SRC -> $OUT"
zstd -f -T0 -19 -o "$OUT" "$SRC"
EFI_OUT=""
if [[ -f "${OUT_DIR}/efi-store" ]]; then
  EFI_OUT="${OUT_DIR}/efi-store.zst"
  zstd -f -T0 -19 -o "$EFI_OUT" "${OUT_DIR}/efi-store"
fi
ls -lh "$OUT"

# Also emit GitHub Release asset names under dist/ when packing for CI/release.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64) ARCH=amd64 ;;
  *) ARCH="$ARCH_RAW" ;;
esac
DIST_DIR="${ROOT_DIR}/dist"
mkdir -p "$DIST_DIR"
RELEASE_DISK="${DIST_DIR}/calf-guest-disk-${ARCH}.raw.zst"
cp "$OUT" "$RELEASE_DISK"
echo "release asset: $RELEASE_DISK"
if [[ -n "$EFI_OUT" ]]; then
  RELEASE_EFI="${DIST_DIR}/calf-guest-efi-${ARCH}.zst"
  cp "$EFI_OUT" "$RELEASE_EFI"
  echo "release asset: $RELEASE_EFI"
fi
echo "users extract with scripts/guest-image/unpack-guest-disk.sh or Calf first-run download"
