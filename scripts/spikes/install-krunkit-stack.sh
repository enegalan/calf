#!/usr/bin/env bash
# Build and install the macOS krunkit stack into ~/.config/calf/krunkit/
# (DAX shm=1 GiB krunkit + libkrun virtiofs 8×4096, CachePolicy Always, DAX O_RDWR).
# Required for local macOS engine and for release-macos bundling.
#
# Usage:
#   ./scripts/spikes/install-krunkit-stack.sh
#   make dev-backend
# Default guest mount is dax=inode; CALF_KRUN_DAX_MODE=always for max bind-write.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="${CALF_KRUNKIT_PREFIX:-$HOME/.config/calf/krunkit}"
LIBKRUN_BUILD="${CALF_LIBKRUN_Q4_ROOT:-/tmp/calf-libkrun-q4}"
KRUNKIT_BUILD="${CALF_KRUNKIT_DAX_ROOT:-/tmp/calf-krunkit-dax}"

export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:${PATH}"
unset CARGO_TARGET_DIR
export LIBCLANG_PATH="${LIBCLANG_PATH:-/opt/homebrew/opt/llvm/lib}"
export DYLD_LIBRARY_PATH="${LIBCLANG_PATH}:${DYLD_LIBRARY_PATH:-}"
export DYLD_FALLBACK_LIBRARY_PATH="${LIBCLANG_PATH}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing $1" >&2
    exit 1
  }
}

require git
require cargo
require python3
require make
require install_name_tool
require codesign

if [[ ! -d /opt/homebrew/opt/libkrun ]]; then
  echo "error: brew install libkrun krunkit (slp/krun tap)" >&2
  exit 1
fi

echo "[1/3] building DAX krunkit..."
CALF_KRUNKIT_DAX_ROOT="$KRUNKIT_BUILD" "$ROOT/scripts/spikes/build-krunkit-dax.sh"

echo "[2/3] building libkrun q4 (BLK=1 NET=1 GPU=1 TIMESYNC=1, writeback=false)..."
# Build libkrun with brew feature flags + virtiofs writeback patch.
SRC="${LIBKRUN_BUILD}/src"
LIBDIR="${LIBKRUN_BUILD}/lib"
LIBKRUN_REF="${LIBKRUN_REF:-v1.19.4}"
rm -rf "$SRC"
git clone --depth 1 --branch "$LIBKRUN_REF" https://github.com/containers/libkrun.git "$SRC" \
  || git clone --depth 1 https://github.com/containers/libkrun.git "$SRC"
cd "$SRC"
git checkout "$LIBKRUN_REF" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
import re
candidates = list(Path(".").rglob("virtio/fs/mod.rs"))
if not candidates:
    raise SystemExit("virtio/fs/mod.rs not found")
p = candidates[0]
s = p.read_text()
s2, n1 = re.subn(r"(NUM_QUEUES:\s*usize\s*=\s*)\d+", r"\g<1>8", s, count=1)
s2, n2 = re.subn(r"(QUEUE_SIZE:\s*u16\s*=\s*)\d+", r"\g<1>4096", s2, count=1)
if n1 != 1 or n2 != 1:
    raise SystemExit(f"queue patch failed n1={n1} n2={n2}")
p.write_text(s2)
print(f"patched queues 8x4096 in {p}")

srv = list(Path(".").rglob("virtio/fs/server.rs"))
if not srv:
    raise SystemExit("virtio/fs/server.rs not found")
sp = srv[0]
ss = sp.read_text()
ss2, n3 = re.subn(
    r"const MAX_BUFFER_SIZE: u32 = 1 << 20;",
    "const MAX_BUFFER_SIZE: u32 = 1 << 23; // Calf: 8MiB fuse max_write/read",
    ss,
    count=1,
)
if n3 != 1:
    raise SystemExit(f"MAX_BUFFER_SIZE patch failed n={n3}")
sp.write_text(ss2)
print(f"patched MAX_BUFFER_SIZE 8MiB in {sp}")
ss3 = sp.read_text()
old_ra = "                    max_readahead,\n                    flags: enabled as u32,"
new_ra = "                    max_readahead: MAX_BUFFER_SIZE, // Calf: allow guest BDI readahead > 128KiB\n                    flags: enabled as u32,"
if old_ra in ss3:
    sp.write_text(ss3.replace(old_ra, new_ra, 1))
    print(f"patched max_readahead=MAX_BUFFER_SIZE in {sp}")
elif "max_readahead: MAX_BUFFER_SIZE" in ss3:
    print(f"max_readahead already patched in {sp}")
else:
    raise SystemExit("max_readahead patch failed")

mac = list(Path(".").rglob("virtio/fs/macos/passthrough.rs"))
if not mac:
    raise SystemExit("macos passthrough.rs not found")
mp = mac[0]
ms = mp.read_text()
pat = r"let open_flags = if \(flags & fuse::SetupmappingFlags::WRITE\.bits\(\)\) != 0 \{\s*libc::O_RDWR\s*\} else \{\s*libc::O_RDONLY\s*\};"
repl = "let open_flags = libc::O_RDWR; // Calf: O_RDONLY DAX maps fail on APFS → guest EINVAL"
ms2, n = re.subn(pat, repl, ms, count=1)
if n != 1:
    raise SystemExit(f"setupmapping O_RDWR patch failed n={n}")
ms3, n2 = re.subn(
    r"cache_policy:\s*Default::default\(\)",
    "cache_policy: CachePolicy::Always",
    ms2,
    count=1,
)
if n2 != 1:
    raise SystemExit(f"CachePolicy::Always patch failed n={n2}")
# Host read path: drop the handle RwLock before preadv so parallel queue threads
# are not serialized on the same file. Do not F_RDADVISE on every read (hurts cold
# sequential throughput under dax=inode on APFS).
if "do not close the shared fd" not in ms3:
    old_read = (
        "        let f = data.file.read().unwrap();\n"
        "        w.write_from(&f, size as usize, offset)"
    )
    n_read = ms3.count(old_read)
    if n_read != 1:
        raise SystemExit(f"host read-path patch failed n={n_read}")
    ms3 = ms3.replace(
        old_read,
        "        let fd = data.file.read().unwrap().as_raw_fd();\n"
        "        // Safety: handle keeps the File open for the lifetime of this HandleData.\n"
        "        let f = unsafe { std::fs::File::from_raw_fd(fd) };\n"
        "        let n = w.write_from(&f, size as usize, offset);\n"
        "        std::mem::forget(f); // do not close the shared fd\n"
        "        n",
        1,
    )
# Keep writeback=false: true coalesces writes but tanks bind-mount write median on APFS+DAX.
ms4, n3 = re.subn(
    r"(writeback:\s*)true(\s*,)",
    r"\1false\2",
    ms3,
    count=1,
)
if n3 != 1:
    raise SystemExit(f"writeback→false patch failed n={n3}")
mp.write_text(ms4)
print(f"patched DAX open_flags + CachePolicy::Always in {mp} (writeback→false n={n3})")
PY

# Thread-per-queue FsWorker (stock only polls queues 0/1 on one thread).
WORKER_DST=$(python3 - <<'PY'
from pathlib import Path
c = list(Path(".").rglob("virtio/fs/worker.rs"))
print(c[0] if c else "")
PY
)
WORKER_SRC="$ROOT/scripts/spikes/patches/libkrun-fs-worker.rs"
if [[ -z "$WORKER_DST" || ! -f "$WORKER_SRC" ]]; then
  echo "error: fs worker patch missing (dst='$WORKER_DST' src='$WORKER_SRC')" >&2
  exit 1
fi
cp "$WORKER_SRC" "$WORKER_DST"
echo "patched thread-per-queue FsWorker → $WORKER_DST"

mkdir -p target/release target/release/deps
if [[ -f "${LIBCLANG_PATH}/libclang.dylib" ]]; then
  ln -sfn "${LIBCLANG_PATH}/libclang.dylib" target/release/libclang.dylib
  ln -sfn "${LIBCLANG_PATH}/libclang.dylib" target/release/deps/libclang.dylib
fi
make BLK=1 NET=1 GPU=1 TIMESYNC=1
mkdir -p "$LIBDIR"
dylib=$(find target/release -maxdepth 1 -name 'libkrun*.dylib' -type f | head -1)
if [[ -z "$dylib" ]]; then
  echo "error: no libkrun dylib produced" >&2
  exit 1
fi
cp "$dylib" "$LIBDIR/$(basename "$dylib")"
base=$(basename "$dylib")
ln -sfn "$base" "$LIBDIR/libkrun.1.dylib"
ln -sfn "$base" "$LIBDIR/libkrun.dylib"
if [[ -f hvf-entitlements.plist ]]; then
  codesign --entitlements hvf-entitlements.plist --force -s - "$LIBDIR/$base" >/dev/null
fi

echo "[3/3] installing into ${PREFIX}..."
mkdir -p "${PREFIX}/bin" "${PREFIX}/lib" "${PREFIX}/share/krunkit"
cp "${KRUNKIT_BUILD}/prefix/bin/krunkit" "${PREFIX}/bin/krunkit"
cp -R "${KRUNKIT_BUILD}/prefix/share/krunkit/." "${PREFIX}/share/krunkit/" 2>/dev/null || \
  cp /opt/homebrew/share/krunkit/KRUN_EFI.silent.fd "${PREFIX}/share/krunkit/"
cp "$LIBDIR/$base" "${PREFIX}/lib/"
ln -sfn "$base" "${PREFIX}/lib/libkrun.1.dylib"
ln -sfn "$base" "${PREFIX}/lib/libkrun.dylib"
install_name_tool -change /opt/homebrew/opt/libkrun/lib/libkrun.1.dylib \
  "${PREFIX}/lib/libkrun.1.dylib" "${PREFIX}/bin/krunkit"
codesign --entitlements "${KRUNKIT_BUILD}/src/krunkit.entitlements" --force -s - \
  "${PREFIX}/bin/krunkit" >/dev/null
if [[ -f "${SRC}/hvf-entitlements.plist" ]]; then
  codesign --entitlements "${SRC}/hvf-entitlements.plist" --force -s - \
    "${PREFIX}/lib/$base" >/dev/null
fi

cat >"${PREFIX}/env.sh" <<EOF
# Optional PATH helpers (daemon finds this prefix automatically):
#   source ${PREFIX}/env.sh
#   make dev-backend
export CALF_KRUNKIT_BIN=${PREFIX}/bin/krunkit
export PATH="${PREFIX}/bin:\$PATH"
EOF

echo "installed ${PREFIX}"
echo "run: make dev-backend"
