#!/usr/bin/env bash
# Build a reproducible vfkit guest disk via a throwaway Lima VM, then copy/pack it.
#
# Requires: limactl, (optional) zstd for --pack
#
# Usage:
#   ./scripts/guest-image/build-vfkit-guest.sh
#   ./scripts/guest-image/build-vfkit-guest.sh --pack
#   CALF_VM_NAME=calf ./scripts/guest-image/build-vfkit-guest.sh --pack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE="${SCRIPT_DIR}/lima-vfkit.yaml"
VM_NAME="${CALF_VM_NAME:-calf}"
BUILD_VM="${CALF_VFKIT_BUILD_VM:-calf-vfkit-build}"
DEST_DIR="${HOME}/.config/calf/vfkit/${VM_NAME}"
DEST_DISK="${DEST_DIR}/disk.raw"
LIMA_HOME_BUILD="${CALF_VFKIT_LIMA_HOME:-${TMPDIR:-/tmp}/calf-vfkit-build-lima}"
PACK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack) PACK=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command '$1' not found" >&2
    exit 1
  }
}

require limactl
export LIMA_HOME="$LIMA_HOME_BUILD"
mkdir -p "$LIMA_HOME"

echo "LIMA_HOME=$LIMA_HOME"
echo "build VM=$BUILD_VM"
echo "template=$TEMPLATE"

# Recreate throwaway builder so provision always runs from a clean image.
if limactl list -q 2>/dev/null | grep -qx "$BUILD_VM"; then
  echo "deleting existing builder VM $BUILD_VM"
  limactl stop -f "$BUILD_VM" >/dev/null 2>&1 || true
  limactl delete -f "$BUILD_VM" >/dev/null 2>&1 || true
fi

echo "creating and provisioning $BUILD_VM (first boot installs Docker — several minutes)..."
limactl start --name="$BUILD_VM" --tty=false "$TEMPLATE"

echo "waiting for docker inside builder..."
for _ in $(seq 1 120); do
  if limactl shell "$BUILD_VM" -- sudo docker info >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! limactl shell "$BUILD_VM" -- sudo docker info >/dev/null 2>&1; then
  echo "error: docker did not become ready in builder VM" >&2
  exit 1
fi

# Ensure vsock proxy and virtiofs unit are active before snapshotting.
limactl shell "$BUILD_VM" -- sudo systemctl enable --now docker-vsock-proxy
limactl shell "$BUILD_VM" -- sudo systemctl enable calf-virtiofs.service || true
limactl shell "$BUILD_VM" -- sudo docker pull alpine:3.20 >/dev/null
limactl shell "$BUILD_VM" -- sudo docker pull hello-world >/dev/null

echo "stopping builder to flush disk..."
limactl stop "$BUILD_VM"

INSTANCE_DIR="${LIMA_HOME}/${BUILD_VM}"
SOURCE_DISK=""
for candidate in "${INSTANCE_DIR}/disk" "${INSTANCE_DIR}/disk.img" "${INSTANCE_DIR}/basedisk"; do
  if [[ -f "$candidate" ]]; then
    SOURCE_DISK="$candidate"
    break
  fi
done
if [[ -z "$SOURCE_DISK" ]]; then
  echo "error: could not find Lima disk under $INSTANCE_DIR" >&2
  ls -la "$INSTANCE_DIR" >&2 || true
  exit 1
fi

mkdir -p "$DEST_DIR"
echo "copying $SOURCE_DISK -> $DEST_DISK (sparse)"
rm -f "$DEST_DISK"
cp -c "$SOURCE_DISK" "$DEST_DISK" 2>/dev/null || cp "$SOURCE_DISK" "$DEST_DISK"
if [[ -f "${INSTANCE_DIR}/vz-efi" ]]; then
  cp "${INSTANCE_DIR}/vz-efi" "${DEST_DIR}/efi-store"
fi

echo "ready disk: $DEST_DISK"
ls -lh "$DEST_DISK"

if [[ "$PACK" == "true" ]]; then
  require zstd
  "${SCRIPT_DIR}/pack-vfkit-disk.sh" "$DEST_DISK" "$DEST_DIR"
fi

echo
echo "Calf will auto-select vfkit when this disk + vfkit binary exist."
echo "Test: make dev-backend"
echo "Force Lima: CALF_RUNTIME=lima make dev-backend"
echo "Optional cleanup: LIMA_HOME=$LIMA_HOME limactl delete -f $BUILD_VM"
