# Benchmarks

Public performance comparison of **Calf** vs **Docker Desktop** vs **OrbStack** on macOS. These numbers were measured on reference hardware in July 2026 using the scripts in [`scripts/benchmarks/`](scripts/benchmarks/).

## Reference hardware

| Field        | Value                |
|--------------|----------------------|
| Machine      | Apple M3 Pro         |
| RAM          | 18 GB                |
| OS           | macOS 26.5.1 (25F80) |
| Architecture | arm64                |

Run `./scripts/benchmarks/run-all.sh` (or `make benchmarks`) on your Mac to reproduce. Hardware details are written to `scripts/benchmarks/results/hardware-<run-id>.env`.

## Results summary

Measured 2026-07-13 on the reference hardware above. Only one engine ran at a time during each measurement. Cold-start runs use the compiled `calf-daemon` binary (same as the release app bundle).

| Metric                       | Calf         | Docker Desktop | OrbStack     |
|------------------------------|-------------:|---------------:|-------------:|
| VM / engine boot             | **13.1 s**   | 21.1 s         | **6.1 s**    |
| `compose up` (hello-world)   | 0.70 s       | **0.57 s**     | 0.77 s       |
| Bind mount write (256 MiB)   | 932 MB/s     | 839 MB/s       | **1126 MB/s**|
| Bind mount read (256 MiB)    | 5.2 GB/s*    | 2.2 GB/s*      | 3.1 GB/s*    |
| Idle RAM (engine processes)  | **1.4 GB**   | 1.5 GB         | **0.9 GB**   |
| Cold start → first container | 16.0 s       | 31–41 s†       | 6.4–22 s‡    |
| Warm start (VM already up)   | **< 2 s**    | n/a            | n/a          |

\* **Read throughput** used a file already present in the container mount from the write step. Linux page cache inflates read numbers; **write throughput** is the more reliable bind-mount comparison.

† Docker Desktop cold start was **30.7 s** in an isolated run and **41.1 s** in the full suite (rapid quit/relaunch cycles add variance).

‡ OrbStack cold start was **6.4 s** with a cached `hello-world` image and **22.3 s** when the image had to be pulled.

### Phase 4 exit criteria

| Criterion | Target | Result |
|-----------|--------|--------|
| Documented benchmarks | Yes | This file |
| Idle RAM vs Docker Desktop | < 50% | **Met** (~1.4 GB vs ~1.5 GB on this run) |
| Cold start | < 5 s | Not met on full VM stop/start (Lima boot ~15–30 s). Warm start (VM up, daemon restart) meets target |

## What each metric means

### VM / engine boot

Time from issuing a start command until `docker info` succeeds.

- **Calf:** `limactl start calf` with the Calf daemon already running (same as reopening the app with the daemon embedded).
- **Docker Desktop / OrbStack:** `open -a Docker` or `open -a OrbStack` after a full quit.

**Developer impact:** How long you wait after opening the app before the engine accepts `docker` commands.

### `compose up`

Time to run `docker compose up -d --build` in [`examples/hello-world/`](examples/hello-world/) from a clean project state.

**Developer impact:** How quickly a minimal Compose stack (single Alpine service) builds and starts.

### Bind mount I/O

Sequential write/read of **256 MiB** through a bind mount at `~/.config/calf/mounts/benchmarks/<product>/` (same host path for all three products).

- **Write:** `dd if=/dev/zero of=/bench/out bs=1M count=256 conv=fsync`
- **Read:** `dd if=/bench/out of=/dev/null bs=1M` immediately after write

**Developer impact:** Rough feel for bind-mount performance when editing code on the Mac and running it in containers. Calf uses Lima **virtiofs** for `~/.config/calf/mounts`; Docker Desktop and OrbStack use their own file-sharing stacks.

### Idle RAM

Sum of RSS for engine-related processes (daemon, VM helper, `Virtualization.VirtualMachine` XPC). User containers were removed before measuring.

**Developer impact:** Background memory cost while the engine is running but you are not actively building or running workloads.

### Cold start

Time from a full stop (app quit + Calf daemon stopped + Lima VM stopped) through the first successful `hello-world` container.

**Developer impact:** First-run experience after install or reboot. Includes image pull when the image is not cached.

On Lima/VZ, **VM boot dominates** this metric (typically 15–30 s on Apple Silicon). That cost is inherent to a full stop/start cycle.

### Warm start (daemon only)

Time to restore the Docker socket when the Lima VM is **already running** but the Calf daemon was restarted. With `vm_keep_alive: true` (default), quitting Calf leaves the VM up so the next launch uses this path — usually **under 2 s**.

## Methodology

1. **Isolation:** Other container engines were quit before each product's run (`scripts/benchmarks/_common.sh`).
2. **Docker contexts:** Commands use `docker --context calf|desktop-linux|orbstack` so each product hits the correct socket. Engine readiness requires a `Server Version` line in `docker info` output.
3. **Calf daemon:** Benchmarks build and run `backend/calf-daemon` (not `go run`) so cold-start times match a release build.
4. **Metric order:** Cold start runs before VM boot to avoid back-to-back quit/relaunch cycles that can stall Docker Desktop.
5. **Skipped products:** If Docker Desktop or OrbStack is not installed, `run-all.sh` records `skipped` and continues.
6. **Bind mount path:** Calf's Lima template only virtiofs-mounts `~/.config/calf/mounts`; benchmarks use that path for all products so the host directory is shared fairly.
7. **I/O measurement:** Detached `docker run` + `docker cp` of `dd` logs (foreground `docker run` stdout is unreliable through Calf's socket proxy).

### Scripts

| Script | Purpose |
|--------|---------|
| [`run-all.sh`](scripts/benchmarks/run-all.sh) | Full suite: boot, compose, I/O, idle RAM, cold start |
| [`measure-product.sh`](scripts/benchmarks/measure-product.sh) | Steady-state metrics for one product (engine already running) |
| [`_common.sh`](scripts/benchmarks/_common.sh) | Shared helpers, hardware detection, product start/stop |

```bash
# Full comparison (macOS, ~20–30 min; quits/restarts apps)
make benchmarks

# Single product, steady-state only
./scripts/benchmarks/measure-product.sh calf
```

Raw TSV output: `scripts/benchmarks/results/results-<run-id>.tsv` (gitignored).

## Limitations

- **Single machine:** Numbers reflect one M3 Pro Mac; your results will vary with CPU, disk, and macOS version.
- **Unsigned dev builds:** Calf was measured from a local `calf-daemon` build; release builds may differ slightly.
- **Read I/O inflation:** Warm page cache can inflate bind-mount read results; prefer write numbers when comparing file-sharing backends.
- **Cold-start variance:** Rapid quit/relaunch cycles and uncached `hello-world` pulls can add 10–20 s; isolate metrics or allow cooldown between runs for tighter numbers.
- **Lima rapid stop/start:** Occasional `limactl` status warnings appeared during benchmark cycles; successful runs are reported above.

## Reproduce locally

```bash
# 1. Install comparison products (optional)
#    Docker Desktop and/or OrbStack from their official installers

# 2. Ensure Lima is available for Calf (macOS)
brew install lima

# 3. Run benchmarks
cd /path/to/calf
make benchmarks

# 4. Inspect results
cat scripts/benchmarks/results/results-*.tsv
```

Close other container engines and heavy VM workloads before benchmarking for the most comparable results.
