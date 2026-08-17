# Roadmap — calf as a Docker Desktop Replacement

calf is a lightweight alternative for running and managing containers on your local machine. This roadmap defines the phases required to cover the workflows that today depend on Docker Desktop, without prematurely replicating every feature.

## Goal

Be a **valid** Docker Desktop replacement for local development: same CLI (`docker`, `docker compose`), same workflows (`run`, `build`, `up`, `exec`, `logs`), lower resource usage, and an open license.

## What Docker Desktop Is Not (conscious scope)

| Area                                   | Decision             |
|----------------------------------------|----------------------|
| Built-in Kubernetes                    | Out of initial scope |
| Extensions marketplace                 | Not a priority       |
| Docker Scout / AI / Cloud              | Out of scope         |
| Advanced BuildKit (SBOM, attestations) | Phase 4+             |
| Windows support                        | Linux containers via WSL 2; Windows containers later |

## Target architecture

```
┌──────────────────────────────────────────────────────────┐
│  Flutter UI (macOS / Linux / Windows)                    │
│  containers · images · logs · networks · volumes         │
└────────────────────────┬─────────────────────────────────┘
                         │ REST / WebSocket
┌────────────────────────▼─────────────────────────────────┐
│  calf-daemon (Go)                                        │
│  API · lifecycle · settings · socket proxy               │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────┐
│  Container engine                                        │
│  Docker / containerd (guest or native)                     │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────┐
│  krunkit+virtiofs (macOS); native (Linux); WSL 2 (Windows) │
└──────────────────────────────────────────────────────────┘
```

---

## Phase 0 — Foundations *(complete — v0.2.0)*

**Goal:** stable daemon, versioned API, and connected UI. No real containers yet.

- [x] Repository, Go backend, and Flutter UI
- [x] Daemon structure: `cmd/`, `internal/api`, `internal/config`
- [x] Versioned REST API (`/v1/health`, `/v1/status`)
- [x] Persistent configuration (`~/.config/calf/config.yaml`)
- [x] Structured logging and uniform error handling
- [x] UI: navigation shell (left sidebar), daemon status, basic settings screen
- [x] Local packaging: `go build` + `flutter build macos`
- [x] CI: lint, test, and build on macOS

**Exit criteria:** the app starts, shows daemon status, and survives restarts.

---

## Phase 1 — Container engine *(complete — v0.3.0+)*

**Goal:** `docker run hello-world` works with calf as the backend.

### 1.1 Runtime

- [x] Integrate lightweight VM on macOS (Lima + vz, virtiofs for bind mounts)
- [x] Install and manage `containerd` + `nerdctl` inside the VM
- [x] Automatic VM start/stop with the daemon
- [x] Linux: native runtime without a VM
- [x] Windows: WSL 2 Linux engine (Linux containers; Windows containers later)

### 1.2 Docker CLI compatibility

- [x] Expose Docker API-compatible socket (`~/.config/calf/docker.sock`)
- [x] Verify essential commands (manual + integration tests + `scripts/verify-docker-cli.sh`):

  | Command                      | Status                  |
  |------------------------------|-------------------------|
  | `docker run` / `stop` / `rm` | Done                    |
  | `docker ps` / `inspect`      | Done                    |
  | `docker images` / `rmi`      | Done                    |
  | `docker pull` / `push`       | Done                    |
  | `docker build`               | Done                    |
  | `docker exec` / `logs`       | Done                    |
  | `docker network *`           | Done                    |
  | `docker volume *`            | Done                    |
  | `docker compose`             | Done                    |

- [x] Document migration from Docker Desktop (`DEVELOPMENT.md` + in-app migration wizard)

### 1.3 Minimal UI

- [x] Container list (running / stopped) with start/stop/remove actions
- [x] Image list with pull and remove
- [x] Real-time log viewer (WebSocket)
- [x] Container detail: inspect, bind mounts, exec, files, stats

**Exit criteria:** a sample project with `Dockerfile` + `docker run` works without Docker Desktop installed.

---

## Phase 2 — Compose and development workflows *(complete — v0.8.0)*

**Goal:** `docker compose up` works friction-free on real projects.

### 2.1 Engine and CLI

- [x] `docker compose` v2 support (plugin pointing at calf socket)
- [x] Bridge networks between services (engine-level; validated on real stacks)
- [x] Named volumes and bind mounts with acceptable performance (virtiofs in Lima)
- [x] `host.docker.internal` on macOS
- [x] Stable port mapping after sleep/wake
- [x] localhost port conflict detection and proxy (macOS; API port reservation)

### 2.2 Docker Desktop migration

- [x] Automated migration wizard (images, volumes, containers)
- [x] Compose project detection and staging (`com.docker.compose.*` labels)
- [x] Compose stack recreation via `nerdctl compose up` with fallback to labeled `create`

### 2.3 UI

- [x] Compose groups in container list + compose group detail screen
- [x] Integrated terminal (`docker exec` via WebSocket, xterm)
- [x] Basic metrics (CPU, RAM, network per container)
- [x] Volumes list, detail, file browser, clone, remove, and export (quick + scheduled)
- [x] Image layers, run, and push actions
- [x] Builds list (history persisted to disk)
- [x] Docker Hub registry login (device flow)
- [x] Network management UI
- [x] Build detail view UI

**Exit criteria:** 3 reference stacks (LAMP, Node+Postgres, Laravel Sail) start with `docker compose up -d` without modifications.

---

## Phase 3 — Product experience and polish *(complete for 1.0 — signing deferred)*

**Goal:** Improve product in-app UX, and native platform polish.

### 3.1 Installation and lifecycle

- [x] macOS `.dmg` / `.pkg` installers (v0.8.0+; unsigned; Homebrew is the recommended macOS path for 1.0)
- [ ] Apple signing and notarization (post-1.0 / later 1.x when Developer Program is available)
- [x] Homebrew cask (`brew install --cask enegalan/calf-homebrew/calf`)
- [x] Daemon embedded in app bundle, spawned by Flutter app on launch, killed on close
- [x] In-app update check and download links (GitHub Releases; auto-install pending signing)
- [x] Windows `.exe` installer (v0.8.0); engine is WSL 2 Linux containers, not Lima
- [x] Linux `.deb` / `.rpm` / `.AppImage` installers (v0.8.0)
- [x] Auto-start on sign-in in to computer (optional)

### 3.2 Settings

- [x] CPU/RAM/disk limits for the VM
- [x] HTTP/HTTPS proxy
- [x] Docker context management (`docker context use calf`)

### 3.3 Full UI

- [x] Volume management
- [x] Network management
- [x] Consistent light/dark theme (Material Design 3)
- [x] Collapsible sidebar with persisted state and auto-collapse on narrow windows
- [x] macOS native menu bar actions (Settings, navigation, Docker Hub, updates, help)

**Exit criteria:** a new developer installs calf in < 5 minutes and works a full day without Docker Desktop.

---

## Phase 4 — Performance, reliability, and ecosystem

**Goal:** calf is preferable to Docker Desktop for speed and resource usage.

- [x] Public benchmarks vs Docker Desktop and OrbStack (VM boot, cold start, bind mount I/O, idle RAM)
- [x] Warm start optimization (< 2 s when the guest VM is kept alive via `vm_keep_alive`)
- [x] Fair cold start (same stop→start procedure as competitors) under 20 s on reference hardware (krunkit median ~8 s; faster than Docker Desktop)
- [x] Image and layer cache across restarts (guest disk persistence)
- [x] Rootless mode where the OS allows it (Linux native: prefer user Docker socket; macOS guest stays rootful)
- [x] Basic `buildx` support (`docker buildx build --load`, Rosetta cross-arch; multi-arch push later)
- [ ] ~~Opt-in telemetry (errors and performance, no container data)~~ – Cancelled

**Exit criteria:** documented benchmarks; idle RAM usage < 50% of Docker Desktop on reference hardware; fair cold start < 20 s.

---

## Phase 5 — Fast boot runtime *(complete — macOS krunkit)*

**Goal:** close the remaining cold-start gap with OrbStack (and beat it).

- [x] Evaluate Lima VZ save/restore vs custom/Apple-style guest
- [x] Stretch cold start under 8 s — median **~5–8 s** fair stop→start→`hello-world` on M3 Pro (see `BENCHMARKS.md`)
- [x] Keep `vm_keep_alive` as the default UX for quit/reopen; do not use it as the cold-start benchmark
- [x] Beat OrbStack on bind-mount write **and** cold bind-read — krunkit `dax=inode` (see `BENCHMARKS.md`)
  - Release bundles patched krunkit + libkrun + gvproxy; local: `make krunkit-stack`
  - Fair suite reads calf `dd` logs from the host share (`docker cp` over vsock is unreliable)
- [x] macOS always uses krunkit; guest disk download on first start (`~/.config/calf/guest/`)
- [x] Reproducible guest build (`make guest-disk` / `scripts/guest-image/build-guest.sh`) + first-run `.zst` extract; host bind-mount symlink via `/mnt/calf`
- [x] Guest disk release asset (`calf-guest-disk-<arch>.raw.zst`) + first-run download/extract (pure Go zstd); bake on a real Mac (not GHA nested VZ)
- [x] buildx / `host.docker.internal` / localhost port-proxy on the macOS guest
- [x] Remove Lima product runtime; promote krunkit as the only macOS engine

**Exit criteria:** published cold-start number approaches (or beats) OrbStack under the same procedure as Docker Desktop; full table competitiveness documented in `BENCHMARKS.md`.

---

## Phase 6 — CLI drop-in

**Goal:** `docker` / `docker compose` keep working after uninstalling Docker Desktop.

- [x] Detect and optionally install the Docker CLI (Homebrew or calf bin)
- [x] Shell completions toggle
- [x] Optional `/var/run/docker.sock` helper and privileged published ports
- [x] Host `calf` commands (`status`, `start`, `stop`, `restart`, `logs`, `diagnose`)
- [x] Warn when another product owns the default Docker socket or CLI path

---

## Phase 7 — Guest engine / network / shares (macOS)

- [x] Extra file shares (virtiofs; restart the engine after changing the list)
- [x] SSH agent via vsock (`SSH_AUTH_SOCK` in containers)
- [x] `gateway.docker.internal` next to `host.docker.internal`
- [x] `daemon.json` overlay, Docker subnet, bind published ports to localhost
- [x] Host networking for `--net=host` containers
- [x] amd64 emulation toggle (binfmt)
- [x] Buildx builder list in Settings

---

## Phase 8 — Dashboard

- [x] Pause/resume, run image with options, pull by name, Hub repositories
- [x] Create volume/network; empty/import volume; save files in the file browser
- [x] Copy `docker run` from inspect; unified Logs screen

---

## Phase 9 — Platform polish

- [x] Diagnostics zip from Troubleshoot and `calf diagnose`
- [x] Open window on launch
- [x] About shows Compose and Buildx versions
- [ ] Auto-install updates (blocked on Apple signing)

---

## Phase 10 — Windows engine (WSL 2)

- [x] Linux containers via a calf WSL distro (`wsl -d calf`)
- [ ] WSL integration for extra distros
- [ ] Windows containers toggle
- [ ] GPU-PV (NVIDIA)

---

## Later / on demand (Phase 11)

Not in the current product. Build only if still demanded:

- Synchronized file shares
- VMM picker / gRPC-FUSE fallback (calf stays krunkit-only on macOS)
- UDP kernel networking toggle
- PAC / system proxy / NTLM
- Volume export to S3/Azure/GCS
- Build traces (Jaeger/OTLP), SBOM attestations, multi-arch `--load` of a full index
- Docker Debug toolbox
- Host Dashboard terminal

---

## Reference competitors

| Product             | What to learn from                  | What to avoid                       |
|---------------------|-------------------------------------|-------------------------------------|
| **OrbStack**        | Speed, macOS UX, low resource usage | Closing off the ecosystem too much  |
| **Rancher Desktop** | containerd + nerdctl, open source   | Heavy UI, K8s complexity by default |
| **Colima**          | VM simplicity                       | No GUI; fragmented experience       |
| **Podman Desktop**  | Rootless, modular                   | Inconsistent compose compatibility  |

**calf differentiator:** minimal Go daemon + native cross-platform Flutter UI, 100% local development focus, no commercial license or cloud bundling.

---

## Success metrics

| Metric                                 | Target                | Current (approx.)                |
|----------------------------------------|-----------------------|----------------------------------|
| Cold start → first container (fair stop→start) | < 20 s                | **krunkit 8.0 s** (see `BENCHMARKS.md`) |
| Idle RAM (engine idle RSS)                     | < 1 GB                | **krunkit 0.07 GB** (see `BENCHMARKS.md`) |
| Reference compose projects             | 3/3 without changes   | In validation                    |
| Docker CLI compatibility               | 100%                  | ~100% (`make verify-docker-cli`) |
| Install to first container             | < 5 min               | ~5 min                           |
| Supported platforms                    | macOS, Linux, Windows | macOS, Linux, Windows            |

---

## Contributing

Each phase must close with:

1. Verifiable exit criteria
2. Documentation in `CHANGELOG.md`
3. No regressions in reference stacks
