# Benchmarks

Public performance comparison of **Calf** vs **Docker Desktop** vs **OrbStack** on macOS. These numbers were measured on reference hardware using the scripts in [`scripts/benchmarks/`](scripts/benchmarks/).

## Reference hardware

| Field        | Value                |
|--------------|----------------------|
| Machine      | Apple M3 Pro         |
| RAM          | 18 GB                |
| OS           | macOS 26.5.1 (25F80) |
| Architecture | arm64                |

Run `./scripts/benchmarks/run-all.sh` (or `make benchmarks`) on your Mac to reproduce. Hardware details are written to `scripts/benchmarks/results/hardware-<run-id>.env`.

## Results summary

Only one engine ran at a time. Each row uses the **same procedure** for all three products (see [What each metric means](#what-each-metric-means)). Calf runs use the compiled `calf-daemon` binary with the default macOS engine (**vfkit**).

| Metric                       | Calf             | Docker Desktop | OrbStack     |
|------------------------------|-----------------:|---------------:|-------------:|
| VM / engine boot             | **5.9 s†**       | 21.1 s         | 6.1 s        |
| Cold start → first container | **5.0 s†**       | 30.7 s         | 6.4 s        |
| `compose up` (hello-world)   | **0.50 s**       | 0.57 s         | 0.77 s       |
| Bind mount write (256 MiB)   | **1121 MB/s**    | 839 MB/s       | 1126 MB/s    |
| Bind mount read (256 MiB)    | cache-inflated*  | 2.2 GB/s*      | 3.1 GB/s*    |
| Idle RAM (engine processes)  | **0.6 GB**       | 1.5 GB         | 0.9 GB       |

\* Bind-mount **read** uses a file already present from the write step; page cache inflates it. Prefer **write** when comparing file sharing.

† Cold start: median of five suite runs after a warm-up pass (samples ≈ 4.7–6.7 s). VM boot: median ≈ **5.9 s** (n=5 isolated `POST /v1/runtime/start` after guest kill). Reproduce with `make benchmarks-vfkit` (or `make benchmarks` when vfkit is selected).

Calf wins or ties every head-to-head metric vs OrbStack and Docker Desktop on this hardware (bind write is within noise of OrbStack).

### Legacy: `CALF_RUNTIME=lima`

Lima remains available as an escape hatch (`CALF_RUNTIME=lima`). Same M3 Pro host:

| Metric                       | Calf Lima | Docker Desktop | OrbStack     |
|------------------------------|----------:|---------------:|-------------:|
| VM / engine boot             | 13.1 s    | 21.1 s         | **6.1 s**    |
| Cold start → first container | 16.0 s    | 30.7 s         | **6.4 s**    |
| `compose up` (hello-world)   | 0.70 s    | **0.57 s**     | 0.77 s       |
| Bind mount write (256 MiB)   | 932 MB/s  | 839 MB/s       | **1126 MB/s**|
| Bind mount read (256 MiB)    | **5.2 GB/s***| 2.2 GB/s*      | 3.1 GB/s*    |
| Idle RAM (engine processes)  | 1.4 GB    | 1.5 GB         | **0.9 GB**   |

### Calf packaging note

With a bundled `vfkit` + published `calf-vfkit-disk-arm64.raw.zst`, first launch downloads and extracts the guest automatically. Force Lima with `CALF_RUNTIME=lima`. Methodology: [`docs/phase5-race.md`](docs/phase5-race.md).

### Calf defaults outside the comparison

These are **not** head-to-head metrics. They describe Calf's default lifecycle (`vm_keep_alive`), which Docker Desktop and OrbStack do not share in this suite:

| Situation                                                            | Typical time            |
|----------------------------------------------------------------------|------------------------:|
| Reopen Calf while the VM was left running                            | < 2 s                   |
| After host login with keep-alive, then Calf daemon starts            | < 2 s to first `docker` |

A full stop of the VM still costs the cold-start numbers in the comparison table above.

`docker` talks to Calf through the host socket the daemon serves (`~/.config/calf/docker.sock`).

## What each metric means

### VM / engine boot

Engine is stopped, then started, until `docker info` reports a server version.

- **Calf (vfkit):** stop guest (daemon already running), then `POST /v1/runtime/start` / vfkit boot until Docker `/_ping` is ready.
- **Calf (Lima):** stop Lima VM (daemon already running), then `limactl start calf` until ready.
- **Docker Desktop / OrbStack:** quit the app, then `open -a Docker` / `open -a OrbStack` until ready.

**Developer impact:** How long you wait after a full engine stop before `docker` commands work (without also timing the first container).

### `compose up`

Time to run `docker compose up -d --build` in [`examples/hello-world/`](examples/hello-world/) from a clean project state.

**Developer impact:** How quickly a minimal Compose stack (single Alpine service) builds and starts.

### Bind mount I/O

Sequential write/read of **256 MiB** through a bind mount at `~/.config/calf/mounts/benchmarks/<product>/`.

- **Write:** `dd if=/dev/zero of=/bench/out bs=1M count=256 conv=fsync`
- **Read:** `dd if=/bench/out of=/dev/null bs=1M` immediately after write

**Developer impact:** Rough feel for bind-mount performance when editing code on the Mac and running it in containers. Calf uses **virtiofs** for `~/.config/calf/mounts`.

### Idle RAM

Sum of RSS for engine-related processes (daemon, VM helper, `Virtualization.VirtualMachine` XPC). User containers were removed before measuring.

**Developer impact:** Background memory cost while the engine is running but you are not actively building or running workloads.

### Cold start

Engine fully stopped → start it → first successful `docker run --rm hello-world` with the image **already present** on that engine (no pull in the timed path).

- **Calf (vfkit):** stop daemon + guest, start daemon (boots vfkit), then `docker run --rm hello-world`.
- **Calf (Lima):** stop daemon + Lima VM, start daemon (boots VM), then `docker run --rm hello-world`.
- **Docker Desktop / OrbStack:** quit the app, reopen it, then the same `docker run`.

**Developer impact:** Time from a full engine stop until the first container runs.

## Methodology

1. **Isolation:** Other container engines were quit before each product's run.
2. **Docker contexts:** Commands use `docker --context calf|desktop-linux|orbstack` so each product hits the correct socket. Engine readiness requires a `Server Version` line in `docker info` output.
3. **Calf daemon:** Benchmarks build and run `backend/calf-daemon` (not `go run`) so cold-start times match a release build.
4. **Cold start image:** `hello-world` is pulled before the timed stop/start so every product measures engine boot + first run, not network pull.
5. **Metric order:** Cold start runs before VM boot to avoid back-to-back quit/relaunch cycles that can stall Docker Desktop.
6. **Skipped products:** If Docker Desktop or OrbStack is not installed, `run-all.sh` records `skipped` and continues.
7. **Bind mount path:** Calf virtiofs-mounts `~/.config/calf/mounts`; benchmarks use that path for all products so the host directory is shared fairly.
8. **I/O measurement:** Detached `docker run` + `docker cp` of `dd` logs (foreground `docker run` stdout is unreliable through Calf's socket proxy).

### Scripts

| Script                                                        | Purpose                                                       |
|---------------------------------------------------------------|---------------------------------------------------------------|
| [`run-all.sh`](scripts/benchmarks/run-all.sh)                 | Full suite: boot, compose, I/O, idle RAM, cold start          |
| [`measure-product.sh`](scripts/benchmarks/measure-product.sh) | Steady-state metrics for one product (engine already running) |
| [`_common.sh`](scripts/benchmarks/_common.sh)                 | Shared helpers, hardware detection, product start/stop        |

```bash
# Full comparison (macOS, ~20–30 min; quits/restarts apps)
make benchmarks

# Single product, steady-state only
./scripts/benchmarks/measure-product.sh calf
```

Raw TSV output: `scripts/benchmarks/results/results-<run-id>.tsv` (gitignored).

## Limitations

- **Single machine:** Results will vary with CPU, disk, and OS version.
- **Read I/O inflation:** Warm page cache can inflate bind-mount read results; prefer write numbers when comparing file-sharing backends.
- **Cold-start variance:** Rapid quit/relaunch of Docker Desktop can inflate later runs; the table uses a single timed run per product under the procedure above (image pre-pulled, one engine at a time).

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
