# Benchmarks

Calf vs Docker Desktop vs OrbStack on macOS (Apple M3 Pro, 18 GB, arm64).

Values are **medians** from repeated runs. Only one engine runs at a time.

| Metric                       | Calf            | Docker Desktop | OrbStack   |
|------------------------------|----------------:|---------------:|-----------:|
| Engine boot                  | **7.1 s**       | 87.8 s         | 31.8 s     |
| Cold start → first container | **8.0 s**       | 88.7 s         | 13.6 s     |
| Bind mount write (256 MiB)   | **1972 MiB/s**  | 1163 MiB/s     | 1690 MiB/s |
| Bind mount read (256 MiB)    | **2965 MiB/s**  | 2063 MiB/s     | 2814 MiB/s |
| Idle RAM                     | **0.07 GB**     | 0.32 GB        | 0.53 GB    |

macOS Calf uses **krunkit** (bundled in release builds; for local builds run `make krunkit-stack`).

## What we measure

- **Engine boot** — stop the engine, start it, wait until Docker is ready.
- **Cold start** — full stop → start → first `docker run hello-world` (image already pulled).
- **Bind mount I/O** — sequential 256 MiB read/write through a real host folder shared into the container.
- **Idle RAM** — memory used by the engine when nothing is running.

## Reproduce

```bash
brew tap libkrun/krun
brew install libkrun/krun/krunkit libkrun/krun/gvproxy
make krunkit-stack   # local / release prerequisite

# Fair bind-mount reads need passwordless purge once:
#   echo "$(whoami) ALL=(root) NOPASSWD: /usr/sbin/purge" | sudo tee /etc/sudoers.d/calf-purge
#   sudo chmod 440 /etc/sudoers.d/calf-purge

BENCHMARK_ALLOW_SUDO=1 make benchmarks
```

Close other container apps before running. Raw results land under `scripts/benchmarks/results/`.

## Notes

- Numbers are from one Mac device; your hardware will differ.
- Results move with heat, disk load, and OS version.
- For suite details and flags, see [`scripts/benchmarks/`](scripts/benchmarks/).
