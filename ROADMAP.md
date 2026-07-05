# Roadmap — Calf as a Docker Desktop Replacement

Calf is a lightweight alternative for running and managing containers on your local machine. This roadmap defines the phases required to cover the workflows that today depend on Docker Desktop, without prematurely replicating every feature.

## Goal

Be a **valid** Docker Desktop replacement for local development: same CLI (`docker`, `docker compose`), same workflows (`run`, `build`, `up`, `exec`, `logs`), lower resource usage, and an open license.

## What Docker Desktop Is Not (conscious scope)

| Area                                   | Decision             |
|----------------------------------------|----------------------|
| Built-in Kubernetes                    | Out of initial scope |
| Extensions marketplace                 | Not a priority       |
| Docker Scout / AI / Cloud              | Out of scope         |
| Advanced BuildKit (SBOM, attestations) | Phase 4+             |
| Windows support                        | Phase 3; macOS first |

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
│  containerd + nerdctl  (or Podman API)                   │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────┐
│  Lightweight VM (macOS/Windows) or native runtime (Linux)│
│  Lima / vz + virtiofs                                    │
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

## Phase 1 — Container engine *(mostly complete — v0.3.0)*

**Goal:** `docker run hello-world` works with Calf as the backend.

### 1.1 Runtime

- [x] Integrate lightweight VM on macOS (Lima + vz, virtiofs for bind mounts)
- [x] Install and manage `containerd` + `nerdctl` inside the VM
- [x] Automatic VM start/stop with the daemon
- [x] Linux: native runtime without a VM

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
  | `docker network *`           | Engine-level; no UI yet |
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

## Phase 2 — Compose and development workflows *(in progress)*

**Goal:** `docker compose up` works friction-free on real projects.

### 2.1 Engine and CLI

- [x] `docker compose` v2 support (plugin pointing at Calf socket)
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
- [x] Volumes list, detail, file browser, clone, and remove
- [x] Image layers, run, and push actions
- [x] Builds list (history persisted to disk)
- [x] Docker Hub registry login (device flow)
- [x] Network management UI
- [x] Build detail view UI

**Exit criteria:** 3 reference stacks (LAMP, Node+Postgres, Laravel Sail) start with `docker compose up -d` without modifications.

---

## Phase 3 — Product experience and cross-platform

**Goal:** polished installer, background startup, and Windows support.

### 3.1 Installation and lifecycle

- [ ] macOS installer (.dmg / .pkg) with signing and notarization
- [ ] Daemon as a user service (launchd / systemd)
- [ ] In-app updates or Homebrew cask
- [ ] Windows installer (WSL2 + integration)
- [ ] Linux installer (.deb / .rpm / AppImage)

### 3.2 Settings

- [x] CPU/RAM/disk limits for the VM
- [x] HTTP/HTTPS proxy
- [x] Auto-start on login (optional)

### 3.3 Full UI

- [x] Volume management
- [x] Network management
- [x] Consistent light/dark theme (shadcn_ui)
- [ ] MacOS MenuActions (topbar actions exist; native menu integration pending)

**Exit criteria:** a new developer installs Calf in < 5 minutes and works a full day without Docker Desktop.

---

## Phase 4 — Performance, reliability, and ecosystem

**Goal:** Calf is preferable to Docker Desktop for speed and resource usage.

- [ ] Public benchmarks vs Docker Desktop and OrbStack (VM boot, `compose up`, bind mount I/O)
- [ ] Cold start optimization (< 5 s to first `docker run`)
- [ ] Image and layer cache across restarts
- [ ] Rootless mode where the OS allows it
- [ ] Basic `buildx` support (optional multi-arch)
- [ ] Image export/import (`docker save` / `docker load`)
- [ ] Opt-in telemetry (errors and performance, no container data)

**Exit criteria:** documented benchmarks; idle RAM usage < 50% of Docker Desktop on reference hardware.

---

## Reference competitors

| Product             | What to learn from                  | What to avoid                       |
|---------------------|-------------------------------------|-------------------------------------|
| **OrbStack**        | Speed, macOS UX, low resource usage | Closing off the ecosystem too much  |
| **Rancher Desktop** | containerd + nerdctl, open source   | Heavy UI, K8s complexity by default |
| **Colima**          | VM simplicity                       | No GUI; fragmented experience       |
| **Podman Desktop**  | Rootless, modular                   | Inconsistent compose compatibility  |

**Calf differentiator:** minimal Go daemon + native cross-platform Flutter UI, 100% local development focus, no commercial license or cloud bundling.

---

## Success metrics

| Metric                                 | Target              | Current (approx.)                |
|----------------------------------------|---------------------|----------------------------------|
| Cold start time                        | < 5 s               | Not benchmarked                  |
| Idle RAM (macOS)                       | < 1 GB              | Not benchmarked                  |
| Reference compose projects             | 3/3 without changes | In validation                    |
| Docker CLI compatibility               | 100%                | ~100% (`make verify-docker-cli`) |
| Install to first container             | < 5 min             | Dev setup ~5 min                 |

---

## Contributing

Each phase must close with:

1. Verifiable exit criteria
2. Documentation in `CHANGELOG.md`
3. No regressions in reference stacks
