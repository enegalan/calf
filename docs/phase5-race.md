# Phase 5 race — beat OrbStack

Goal: **Calf #1** on the public macOS table in [BENCHMARKS.md](../BENCHMARKS.md).

Reference OrbStack (M3 Pro): cold start **6.4 s**, VM boot **6.1 s**, idle RAM **0.9 GB**, bind write **1126 MB/s**.

| Stage | Target | Status | Result |
|-------|--------|--------|--------|
| 0 — Lima VZ save/restore | Decide path | **Done — no-go** | Restore works on macOS 26.5; ~13–15 s (SSH gate); Lima later removed from product |
| 1 — Early Docker ready (Lima) | &lt; 10 s | **Superseded** | Best **11.57 s**; not enough alone |
| 2 — Direct VZ via `vfkit` + vsock | &lt; 8 s | **Done** | Cold start median **~5.0 s** (n=5); beats OrbStack 6.4 s |
| 3 — Save/restore | ~5–6 s | **Skipped** | Already at OrbStack cold-start band without snapshots |
| 4 — RAM + virtiofs + publish | Full table #1 | **Done** | Bind write ~1121 MB/s; idle ~0.6 GB; VM boot median **~5.9 s** |
| 5 — Drop Lima product runtime | vfkit only | **Done** | macOS always vfkit; Windows unsupported stub |

Default UX `vm_keep_alive` unchanged. Fair cold start always forces a full guest stop. **vfkit is the only macOS engine.**

## Stage 2 — `vfkit` + virtio-vsock

**Breakthrough:** same Ubuntu+Docker disk booted with [vfkit](https://github.com/crc-org/vfkit) (no limactl/SSH) and Docker exposed on the host via `virtio-vsock`.

| Path | Cold start → hello-world |
|------|-------------------------:|
| Raw `vfkit` + vsock | **3.9–4.8 s** |
| Calf daemon vfkit (median n=5) | **~5.0 s** |
| OrbStack (published) | 6.4 s |

**Code:** [`vfkit_darwin.go`](../backend/internal/runtime/vfkit_darwin.go), selected for all Darwin builds ([`select_darwin.go`](../backend/internal/runtime/select_darwin.go)). `POST /v1/runtime/start` boots the guest while the daemon stays up (fair VM-boot metric).

**Disk provision:** [`scripts/guest-image/build-vfkit-guest.sh`](../scripts/guest-image/build-vfkit-guest.sh) uses a throwaway `limactl` bake (`guest-provision.yaml`) only as an image builder, then packs `disk.raw.zst`. That is not the product runtime.

Guest extras: static DNS / dnsmasq for `host.docker.internal`, `systemd-networkd`, `calf-virtiofs` → `/mnt/calf`, vsock Docker proxy.

## How to run

```bash
brew install vfkit docker zstd
make guest-vfkit          # optional local bake; or first-run download from Releases
make dev-backend
make benchmarks           # or make benchmarks-vfkit
```

Release builds (`make release-macos`) require bundled `vfkit`. Attach `calf-vfkit-disk-*.raw.zst` to GitHub Releases from a real Mac (`make guest-vfkit` + `gh release upload`); GHA nested VZ cannot bake the disk.

## Remaining follow-ups

1. Optional vfkit login-item keep-alive.
2. Replace host Docker CLI shell-outs with direct Docker HTTP API where practical.
3. Replace limactl guest bake with a non-Lima provisioner when convenient.
4. New Windows container backend (not Lima).
