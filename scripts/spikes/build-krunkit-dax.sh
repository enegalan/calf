#!/usr/bin/env bash
# Build a local krunkit that passes a non-zero virtiofs DAX shm window to libkrun.
# Stock Homebrew krunkit hardcodes shm_size=0, so guest `dax=` mounts cannot work.
#
# Usage:
#   ./scripts/spikes/build-krunkit-dax.sh
#   # binary + firmware layout at /tmp/calf-krunkit-dax/prefix/bin/krunkit
set -euo pipefail

ROOT="${CALF_KRUNKIT_DAX_ROOT:-/tmp/calf-krunkit-dax}"
SRC="${ROOT}/src"
PREFIX="${ROOT}/prefix"
SHM_SIZE="${KRUN_SHM_SIZE:-1073741824}" # 1 GiB default; 2 GiB often fails VmCreate

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing $1" >&2
    exit 1
  }
}

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:${PATH}"
# A leftover CARGO_TARGET_DIR (e.g. from libkrun experiments) redirects the binary away from target/release.
unset CARGO_TARGET_DIR

require git
require cargo
require python3
require make

if [[ ! -d /opt/homebrew/opt/libkrun ]]; then
  echo "error: install libkrun (brew tap libkrun/krun && brew install libkrun/krun/libkrun libkrun/krun/krunkit)" >&2
  exit 1
fi

rm -rf "$SRC"
git clone --depth 1 --branch v1.3.2 https://github.com/libkrun/krunkit.git "$SRC"
cd "$SRC"

python3 - <<PY
from pathlib import Path
import re
p = Path("src/virtio.rs")
s = p.read_text()
s2, n = re.subn(
    r"(shared_dir_cstr\.as_ptr\(\),\n\s+)\d+(,\n\s+false,)",
    rf"\g<1>${SHM_SIZE}\2",
    s,
    count=1,
)
if n != 1:
    raise SystemExit("failed to patch krun_add_virtiofs4 shm_size")
p.write_text(s2)
print(f"patched shm_size=${SHM_SIZE}")
PY

export LIBRARY_PATH="/opt/homebrew/lib:${LIBRARY_PATH:-}"
export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:${PATH}"
make PREFIX=/opt/homebrew

mkdir -p "${PREFIX}/bin" "${PREFIX}/share/krunkit"
cp target/release/krunkit "${PREFIX}/bin/"
cp /opt/homebrew/share/krunkit/KRUN_EFI.silent.fd "${PREFIX}/share/krunkit/"
codesign --entitlements krunkit.entitlements --force -s - "${PREFIX}/bin/krunkit" >/dev/null

echo "built ${PREFIX}/bin/krunkit (DAX shm=${SHM_SIZE})"
echo "run with PATH=${PREFIX}/bin:\$PATH and guest mount -o dax=always,noatime"
