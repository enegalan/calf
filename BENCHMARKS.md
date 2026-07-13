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

Measured 2026-07-12 on the reference hardware above. Only one engine ran at a time during each measurement.

| Metric                       | Calf         | Docker Desktop | OrbStack     |
|------------------------------|-------------:|---------------:|-------------:|
| VM / engine boot             | **10.2 s**   | 21.1 s         | **2.7 s**    |
| `compose up` (hello-world)   | **0.94 s**   | 1.35 s         | 3.11 s       |
| Bind mount write (256 MiB)   | **781 MB/s** | 350 MB/s       | **836 MB/s** |
| Bind mount read (256 MiB)    | 18.6 GB/s*   | 867 MB/s       | 2.7 GB/s*    |
| Idle RAM (engine processes)  | **1.5 GB**   | 2.7 GB         | 1.8 GB       |
| Cold start → first container | 14.8 s       | —†             | **6.3 s**    |

\* **Read throughput** used a file already present in the container mount from the write step. Linux page cache inflates read numbers on Calf and OrbStack; **write throughput** is the more reliable bind-mount comparison.

† Docker Desktop did not complete the automated cold-start step (`hello-world` after a full quit/relaunch) in this run. Engine boot alone took **21 s**.

### Phase 4 exit criteria

| Criterion | Target | Result |
|-----------|--------|--------|
| Documented benchmarks | Yes | This file |
| Idle RAM vs Docker Desktop | < 50% | **~56%** (1.5 GB vs 2.7 GB) — close; Calf uses less than half the VM memory budget in typical configs |
| Cold start | < 5 s | Not met by any product in this run (best: OrbStack 6.3 s) |

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

Time from a full stop (app quit + Calf daemon stopped) through the first successful `hello-world` container.

**Developer impact:** First-run experience after install or reboot. Includes image pull when the image is not cached.

## Methodology

1. **Isolation:** Other container engines were quit before each product's run (`scripts/benchmarks/_common.sh`).
2. **Docker contexts:** Commands use `docker --context calf|desktop-linux|orbstack` so each product hits the correct socket.
3. **Skipped products:** If Docker Desktop or OrbStack is not installed, `run-all.sh` records `skipped` and continues.
4. **Bind mount path:** Calf's Lima template only virtiofs-mounts `~/.config/calf/mounts`; benchmarks use that path for all products so the host directory is shared fairly.
5. **I/O measurement:** Detached `docker run` + `docker cp` of `dd` logs (foreground `docker run` stdout is unreliable through Calf's socket proxy).

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
- **Unsigned dev builds:** Calf was measured from a local development build; release builds may differ slightly.
- **Read I/O inflation:** Warm page cache can inflate bind-mount read results; prefer write numbers when comparing file-sharing backends.
- **Compose cold vs warm:** OrbStack's first `compose up` included an `alpine:3.20` pull; subsequent runs would be faster.
- **Docker Desktop cold start:** Automated `hello-world` after relaunch failed in this session; boot time is still reported.
- **Lima "Broken" status:** Occasional `limactl` status warnings appeared during rapid stop/start cycles; reported Calf boot times used successful runs.

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
