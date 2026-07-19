# Phase 5 race — beat OrbStack

Goal: **Calf #1** on the public macOS table in [BENCHMARKS.md](../BENCHMARKS.md).

Reference OrbStack (M3 Pro): cold start **6.4 s**, VM boot **6.1 s**, idle RAM **0.9 GB**, bind write **1126 MB/s**.

| Stage | Target | Status | Result |
|-------|--------|--------|--------|
| 0 — Lima VZ save/restore | Decide path | **Done — no-go** | Restore works on macOS 26.5; ~13–15 s (SSH gate) |
| 1 — Early Docker ready (Lima) | &lt; 10 s | **Done** | Best **11.57 s** (was 15.48 s); not enough alone |
| 2 — Direct VZ via `vfkit` + vsock | &lt; 8 s | **Done** | Cold start median **~5.0 s** (n=5); beats OrbStack 6.4 s |
| 3 — Save/restore | ~5–6 s | **Skipped** | Already at OrbStack cold-start band without snapshots |
| 4 — RAM + virtiofs + publish | Full table #1 | **Mostly done** | Bind write ~1121 MB/s; idle ~0.6 GB; VM boot median **~5.9 s** (beats OrbStack 6.1 s) |

Default UX `vm_keep_alive` unchanged. Fair cold start always forces a full VM stop. **vfkit is the preferred macOS engine** when a guest disk/seed or bundled `vfkit` is available; Lima remains the `CALF_RUNTIME=lima` escape hatch.

## Stage 1 — Early Docker ready (Lima)

**Change:** [`lima.go`](../backend/internal/runtime/lima.go) starts `limactl start` in the background and returns when Docker `/_ping` answers, without waiting for Lima’s SSH/boot-script READY gate. Shell ops wait on `waitForShellReady`. Guest boot provision short-circuits when services are already active ([`lima.yaml`](../backend/internal/runtime/lima.yaml)).

| Sample | Cold start |
|--------|----------:|
| Baseline (pre-change) | 15.48 s |
| Stage 1 best | **11.57 s** |
| Stage 1 later samples | 14.89 s / 33 s (outlier) |

**Verdict:** Real gain when Docker comes up before Lima READY; still above 10 s and far from OrbStack.

## Stage 2 — `vfkit` + virtio-vsock

**Breakthrough:** same Ubuntu+Docker disk booted with [vfkit](https://github.com/crc-org/vfkit) (no Lima/SSH) and Docker exposed on the host via `virtio-vsock`.

| Path | Cold start → hello-world |
|------|-------------------------:|
| Raw `vfkit` + vsock | **3.9–4.8 s** |
| Calf daemon `CALF_RUNTIME=vfkit` (median n=5) | **~5.0 s** |
| OrbStack (published) | 6.4 s |
| Calf Lima (published) | 16.0 s |

**Code:** [`vfkit_darwin.go`](../backend/internal/runtime/vfkit_darwin.go), selected when `CALF_RUNTIME=vfkit` on darwin ([`runtime.go`](../backend/internal/runtime/runtime.go)). `POST /v1/runtime/start` boots the guest while the daemon stays up (fair VM-boot metric).

**Disk provision:** [`scripts/guest-image/prepare-vfkit-disk.sh`](../scripts/guest-image/prepare-vfkit-disk.sh) copies a guest that runs:

`socat VSOCK-LISTEN:2375,reuseaddr,fork UNIX-CONNECT:/var/run/docker.sock`

Guest extras: static DNS, `systemd-networkd` on `enp0s1`, `calf-virtiofs` → `/mnt/calf`, symlink so host `~/.config/calf/mounts` bind mounts work.

## Stage 3 — Save/restore

Skipped. Cold start already matches/beats OrbStack without VZ machine-state files.

## Stage 4 — Published vfkit numbers (M3 Pro)

`make benchmarks-vfkit` (or `CALF_RUNTIME=vfkit ./scripts/benchmarks/run-all.sh --products calf`). Suite disables Lima start-at-login for the run so a second Virtualization helper does not inflate idle RAM.

| Metric | Calf `vfkit` | OrbStack | Winner |
|--------|-------------:|---------:|--------|
| Cold start (median n=5) | **~5.0 s** | 6.4 s | Calf |
| VM boot (median n=5) | **~5.9 s** | 6.1 s | Calf |
| `compose up` | **~0.50 s** | 0.77 s | Calf |
| Bind write (256 MiB) | **~1121 MB/s** | 1126 MB/s | Tie |
| Idle RAM | **~0.6 GB** | 0.9 GB | Calf |

Rosetta device is opt-in (`CALF_VFKIT_ROSETTA=1`). Memory override: `CALF_VFKIT_MEMORY_GB` (benches default to 2).

## How to try vfkit runtime

```bash
brew install vfkit docker zstd limactl
make guest-vfkit          # builds + packs ~/.config/calf/vfkit/calf/disk.raw(.zst)
make dev-backend          # auto-selects vfkit when disk + binary exist
# force Lima: CALF_RUNTIME=lima make dev-backend
make benchmarks-vfkit
```

On macOS, `runtime.New` prefers vfkit when a local `disk.raw` / `.zst` seed exists, or when `vfkit` is **bundled** next to `calf-daemon` (first Start downloads `calf-vfkit-disk-<arch>.raw.zst` from GitHub Releases). Force Lima with `CALF_RUNTIME=lima`. Disable download with `CALF_VFKIT_NO_DOWNLOAD=1`. Override URL with `CALF_VFKIT_DISK_URL`.

Release builds (`make release-macos`) copy Homebrew `vfkit` into the app. The release workflow also runs `make guest-vfkit` and attaches `calf-vfkit-disk-*.raw.zst` (and optional EFI) to the GitHub release.

## Remaining work after claiming table #1

1. Keep guest disk assets on every release (`calf-vfkit-disk-<arch>.raw.zst`); GHA nested VZ is unreliable — prefer local `make guest-vfkit` + `gh release upload` when CI fails.
2. Optional vfkit login-item keep-alive (Lima start-at-login equivalent).
3. Replace host Docker CLI shell-outs with direct Docker HTTP API where practical.
4. Rebuild guest image when dnsmasq/`host.docker.internal` provision changes so first-run disks include DNS without a runtime refresh.
