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

## Phase 0 — Foundations *(current state → technical MVP)*

**Goal:** stable daemon, versioned API, and connected UI. No real containers yet.

- [x] Repository, Go backend, and Flutter UI
- [ ] Daemon structure: `cmd/`, `internal/api`, `internal/config`
- [ ] Versioned REST API (`/v1/health`, `/v1/status`)
- [ ] Persistent configuration (`~/.config/calf/config.yaml`)
- [ ] Structured logging and uniform error handling
- [ ] UI: navigation shell (left sidebar), daemon status, basic settings screen
- [ ] Local packaging: `go build` + `flutter build macos`
- [ ] CI: lint, test, and build on macOS

**Exit criteria:** the app starts, shows daemon status, and survives restarts.

---

## Phase 1 — Container engine *(basic CLI parity)*

**Goal:** `docker run hello-world` works with Calf as the backend.

### 1.1 Runtime

- [ ] Integrate lightweight VM on macOS (Lima + vz, virtiofs for bind mounts)
- [ ] Install and manage `containerd` + `nerdctl` inside the VM
- [ ] Automatic VM start/stop with the daemon
- [ ] Linux: native runtime without a VM

### 1.2 Docker CLI compatibility

- [ ] Expose Docker API-compatible socket (`/var/run/docker.sock` or proxy)
- [ ] Verify essential commands:

  | Command | Priority |
  |---------|----------|
  | `docker run` / `stop` / `rm` | P0 |
  | `docker ps` / `inspect` | P0 |
  | `docker images` / `rmi` | P0 |
  | `docker pull` / `push` | P0 |
  | `docker build` | P0 |
  | `docker exec` / `logs` | P0 |
  | `docker network *` | P1 |
  | `docker volume *` | P1 |
  | `docker compose` | P0 (phase 2) |

- [ ] `calf` wrapper command: `calf start`, `calf stop`, `calf status`
- [ ] Document migration from Docker Desktop (export images, switch context)

### 1.3 Minimal UI

- [ ] Container list (running / stopped) with start/stop/remove actions
- [ ] Image list with pull and remove
- [ ] Real-time log viewer (WebSocket)

**Exit criteria:** a sample project with `Dockerfile` + `docker run` works without Docker Desktop installed.

---

## Phase 2 — Compose and development workflows *(daily parity)*

**Goal:** `docker compose up` works friction-free on real projects.

- [ ] `docker compose` v2 support (plugin pointing at Calf socket)
- [ ] Bridge networks between services
- [ ] Named volumes and bind mounts with acceptable performance (virtiofs tuning)
- [ ] `host.docker.internal` on macOS
- [ ] Stable port mapping after sleep/wake
- [ ] UI: Compose view per project (detect `compose.yaml` in recent directories)
- [ ] UI: integrated terminal (`docker exec`) for running containers
- [ ] UI: basic metrics (CPU, RAM, network per container)

**Exit criteria:** 3 reference stacks (LAMP, Node+Postgres, Laravel Sail) start with `docker compose up -d` without modifications.

---

## Phase 3 — Product experience and cross-platform

**Goal:** polished installer, background startup, and Windows support.

### 3.1 Installation and lifecycle

- [ ] macOS installer (.dmg / .pkg) with signing and notarization
- [ ] Daemon as a user service (launchd / systemd)
- [ ] Menu bar icon: status, start/stop, open UI
- [ ] In-app updates or Homebrew cask
- [ ] Windows installer (WSL2 + integration)
- [ ] Linux installer (.deb / .rpm / AppImage)

### 3.2 Settings

- [ ] CPU/RAM/disk limits for the VM
- [ ] Configurable shared directories
- [ ] HTTP/HTTPS proxy
- [ ] Private registries and credential helper
- [ ] Auto-start on login (optional)

### 3.3 Full UI

- [ ] Network and volume management
- [ ] Consistent light/dark theme (shadcn_ui)
- [ ] Keyboard shortcuts and basic accessibility
- [ ] MacOS MenuActions (topbar actions)

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
- [ ] Integration with common tools: Laravel Sail, DDEV, Dev Containers (validation, not development)
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

| Metric                                 | Target              |
|----------------------------------------|---------------------|
| Cold start time                        | < 5 s               |
| Idle RAM (macOS)                       | < 1 GB              |
| Reference compose projects             | 3/3 without changes |
| Docker CLI compatibility (P0 commands) | 100%                |
| Install to first container             | < 5 min             |

---

## Contributing

Each phase must close with:

1. Verifiable exit criteria
2. Documentation in `CHANGELOG.md`
3. No regressions in reference stacks
