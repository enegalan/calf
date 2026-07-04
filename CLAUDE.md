# CLAUDE.md

This file provides guidance to Claude Code (or any AI assistant) when working with code in this repository.

## Project Overview

**Calf** is a lightweight, open-source alternative to Docker Desktop. It consists of:

- A **Go daemon** (`backend/`) that manages containers through `containerd` + `nerdctl`, running inside a **Lima** VM on macOS/Windows, or talking directly to the host runtime on Linux.
- A **native Flutter GUI** (`ui/`) that drives the daemon over a local REST + WebSocket API.

The daemon also exposes a Docker-API-compatible socket (`~/.config/calf/docker.sock`), so the real `docker` / `docker compose` CLI can point at Calf via `DOCKER_HOST`.

Non-goals (see `ROADMAP.md`): no built-in Kubernetes, no extensions marketplace, no Scout/AI/Cloud features.

## Tech Stack

### Backend (`backend/`)
- **Language:** Go 1.22.1
- **Module:** `github.com/enegalan/calf/backend`
- **HTTP:** standard library `net/http.ServeMux` — no router framework
- **WebSockets:** `github.com/gorilla/websocket`
- **PTY / interactive exec:** `github.com/creack/pty`
- **Config format:** YAML via `gopkg.in/yaml.v3`
- **Logging:** standard library `log/slog` (text handler)
- **Container tooling:** shells out to `nerdctl`, `limactl`, `docker` CLI (no Docker/containerd Go SDK dependency)

### UI (`ui/`)
- **Language/Framework:** Dart / Flutter, SDK `^3.12.2`
- **UI kit:** `shadcn_ui` (theme, buttons, sliders, switches, progress bars)
- **Networking:** `http`, `web_socket_channel`
- **Terminal emulation:** `xterm` (used for interactive exec)
- **Charts:** `fl_chart` (container stats)
- **State management:** plain `StatefulWidget` + `setState`. No Provider/Riverpod/Bloc/GetX. Screens own their mutable state and poll the backend with `Timer.periodic`.
- **Local persistence:** hand-rolled JSON files under `~/.config/calf/ui/*.json` (via `path_provider`), not `shared_preferences`.
- **Models:** plain Dart classes with manual `fromJson`/`toJson`. No code generation (`json_serializable`/`freezed` are not used).
- **Linting:** `flutter_lints` via `analysis_options.yaml` (no custom rule overrides).

### Communication
- UI and backend talk over **REST (JSON) + WebSocket** on `127.0.0.1:8765` by default (`listen_addr` in config).
- WebSocket is used specifically for:
  - `/v1/containers/{id}/logs` — line-by-line log streaming with ping/pong keep-alive.
  - `/v1/containers/{id}/exec` — bidirectional PTY stream, with JSON control messages (e.g. `{"type":"resize","rows":...,"cols":...}`) multiplexed into the binary stream.
- All other endpoints are plain HTTP request/response.

## Project Structure

```
calf/
├── backend/                                Go daemon
│   ├── cmd/calf/
│   │   └── main.go                          Entrypoint: config/logger/runtime/server wiring, signal handling, PID file, stale-port takeover
│   ├── internal/
│   │   ├── api/
│   │   │   ├── server.go                     Server struct, route registration for all /v1/... endpoints
│   │   │   ├── handlers.go                    Health/status/config endpoints
│   │   │   ├── middleware.go                  Request logging, panic recovery, CORS
│   │   │   ├── json.go                        Small JSON decode helper
│   │   │   ├── ws_writer.go                   Mutex-guarded WebSocket writer with write deadline
│   │   │   ├── log_broadcaster.go              Fan-out of one nerdctl log stream to N WebSocket subscribers
│   │   │   ├── runtime_ready.go                Blocks until the runtime is running (used before registry login)
│   │   │   ├── runtime_errors.go               Maps ErrRuntimeNotRunning -> 503
│   │   │   ├── builds.go                       In-memory build history, POST triggers RunBuild
│   │   │   ├── containers.go                   Container CRUD + subresources
│   │   │   ├── exec.go                         Interactive/one-shot exec endpoints
│   │   │   ├── images.go                       Image list/inspect/remove endpoints
│   │   │   ├── logs.go                         Log streaming endpoints (WebSocket)
│   │   │   ├── volumes.go                      Volume CRUD + subresources
│   │   │   ├── migrate.go                       Docker Desktop migration orchestration + status polling
│   │   │   ├── registry.go                      Registry login/logout
│   │   │   └── registry_login.go                Docker Hub OAuth device-flow browser login
│   │   ├── config/
│   │   │   ├── config.go                      Config struct, YAML load/save, defaults, legacy migration
│   │   │   └── logger.go                       slog.TextHandler setup with level parsing
│   │   ├── runtime/
│   │   │   ├── runtime.go                     Runtime interface (~30 methods) + shared types; runtime.New picks Native/Lima
│   │   │   ├── native.go                       Native runtime: talks directly to host nerdctl/docker.sock (Linux)
│   │   │   ├── lima.go                         Lima runtime: manages the Lima VM, runs ops via `limactl shell ... nerdctl`
│   │   │   ├── nerdctl.go                      Shared nerdctl output parsing, compose project inference, log filtering
│   │   │   ├── mock.go                         In-memory Runtime implementation used by backend tests
│   │   │   ├── exec.go                         exec.CommandContext wrapper with transient-error retry
│   │   │   ├── exec_attach.go                  PTY-based interactive exec attach (stdin/stdout/resize)
│   │   │   ├── container_detail.go             Inspect/mount/`ls -la`/stats parsing for containers
│   │   │   ├── volume_detail.go                 Volume inspect/clone/list-files/usage, relative time formatting
│   │   │   ├── inspect_decode.go               Generic decoder for JSON-array or NDJSON nerdctl inspect output
│   │   │   ├── localhost_proxy.go               macOS-only TCP proxy + port-conflict detection
│   │   │   ├── registry.go                      Docker config.json auth parsing/login/logout
│   │   │   ├── errors.go                        ErrRuntimeNotRunning sentinel + guard helpers
│   │   │   └── command_error.go                 Shell output cleanup, transient-error classification, auth-failure hints
│   │   ├── migration/
│   │   │   ├── docker_desktop.go               Orchestrator: preflight -> config -> images -> volumes -> containers -> builds
│   │   │   ├── compose_migration.go             Groups containers by compose project, stages/patches compose YAML
│   │   │   ├── disk.go                          Free-disk-space check before migrating
│   │   │   └── status.go                        Phase/Status/Summary types
│   │   ├── oauth/dockerhub/
│   │   │   └── device.go                      Docker Hub OAuth2 device-code flow client, PAT generation
│   │   └── browser/
│   │       └── open.go                        Cross-platform "open URL" helper (open/xdg-open/rundll32)
│   ├── test/                                External test packages (see Testing Conventions)
│   │   ├── api/api_test.go
│   │   ├── config/config_test.go
│   │   └── runtime/                            command_error, image_history, localhost_proxy, nerdctl, registry, volume_detail tests
│   ├── version/version.go                     Single Version constant
│   ├── go.mod / go.sum                        Module github.com/enegalan/calf/backend, Go 1.22.1
│   └── lima.yaml                              Embedded Lima VM template (go:embed)
├── ui/                                      Flutter application
│   ├── lib/
│   │   ├── main.dart                          App entrypoint; Material theme bridged from ShadThemeData (light/dark)
│   │   ├── app_shell.dart                     Sidebar nav, top bar, SettingsScreen (resources, migration, theme)
│   │   ├── api/
│   │   │   └── client.dart                    CalfClient/StatusClient interfaces + ApiClient (http + WebSocket)
│   │   ├── platform/
│   │   │   └── open_url.dart                  Platform-specific URL opener (Docker Hub sign-in)
│   │   ├── storage/
│   │   │   ├── calf_ui_storage.dart            Shared JSON file read/write helper (~/.config/calf/ui/*.json)
│   │   │   ├── container_groups.dart            Persists expanded/collapsed container groups
│   │   │   └── logs_viewer_preferences.dart     Persists timestamp/wrap-lines toggles; LogViewerPreferencesMixin
│   │   ├── screens/
│   │   │   ├── containers_screen.dart          List/search/filter/group-by-compose, Timer-based polling
│   │   │   ├── container_detail_screen.dart    Tabs: logs/inspect/mounts/exec/files/stats (fl_chart, xterm)
│   │   │   ├── compose_group_detail_screen.dart Mixed-color log view per compose project
│   │   │   ├── resources_screen.dart           Images/Volumes/Builds screens
│   │   │   └── volume_detail_screen.dart        Stored-data / containers-in-use tabs
│   │   └── widgets/
│   │       ├── app_top_bar.dart                Registry auth UI
│   │       ├── calf_button.dart                Themed button (default/.outline/.ghost/.destructive)
│   │       ├── files_panel.dart                Lazy-loaded directory tree (LoadDirectoryCallback)
│   │       ├── hover_list_row.dart             Hover-state row wrapper
│   │       └── logs_panel.dart                 Log viewer incl. multi-container "mixed" color-coded blocks
│   ├── test/widget_test.dart                  Flutter widget test
│   ├── pubspec.yaml                           Dependencies, Dart SDK ^3.12.2
│   └── analysis_options.yaml                  flutter_lints, no custom overrides
├── examples/hello-world/                   Reference smoke-test project
│   ├── Dockerfile                             FROM alpine:3.20, trivial CMD
│   ├── compose.yaml                            build: . + sleep 300
│   └── .dockerignore
├── scripts/verify-docker-cli.sh             Verifies `docker` CLI works against Calf's socket
├── .github/workflows/ci.yml                 CI: backend (vet/test/build) + ui (analyze/test/build) jobs, macos-latest
├── Makefile                                 dev-backend / dev-ui / ui / clean / verify-docker-cli targets
├── README.md                                Project pitch + quick start
├── DEVELOPMENT.md                           Dev setup, config file example, Docker Desktop migration walkthrough
├── ROADMAP.md                                Phased plan, architecture diagram, non-goals, competitor comparison
├── CHANGELOG.md                             Keep a Changelog + SemVer history
└── LICENSE                                  MIT
```

## Backend File Reference (`backend/`)

### `cmd/calf/main.go`
Entrypoint. Loads config, builds the logger, constructs the `runtime.Runtime` and `api.Server`, handles `SIGINT`/`SIGTERM` via `signal.NotifyContext`, manages a PID file at `~/.config/calf/calf.pid`, and has `ensurePort` logic that terminates a stale previous `calf` process holding the listen port before starting. The runtime starts asynchronously in a goroutine (failure is non-fatal at startup); shutdown stops both the HTTP server and the runtime with timeouts.

### `internal/config/`
- `config.go` — defines the `Config` struct (`listen_addr`, `log_level`, `vm_name`, `docker_socket`, `poll_interval_ms`, `cpus`, `memory_gb`, `memory_swap_gb`, `disk_gb`). Loads/saves as YAML at `~/.config/calf/config.yaml`, with defaults embedded via `//go:embed config.yaml`, a `withDefaults` backfill step, and `migrateLegacyDefaults` (rewrites the old `:8080` port to `:8765`).
- `logger.go` — wraps `slog.NewTextHandler` with a level parser (`debug`/`warn`/`error`, default `info`).

### `internal/api/`
HTTP server built on `net/http.ServeMux`. Every handler follows the same shape: check `OPTIONS` → `204`, switch on method, call into `s.runtime.X(ctx, ...)`, translate errors via `writeRuntimeError` (`503` for `ErrRuntimeNotRunning`, else `500`), otherwise `writeJSON`.

- `server.go` — `Server` struct (config, logger, `runtime.Runtime`, build history, migration status, registry sessions, log broadcaster); registers all `/v1/...` routes.
- `handlers.go` — health/status/config endpoints.
- `middleware.go` — request logging, panic recovery, CORS (`*`). Composed as `corsMiddleware(recoveryMiddleware(logger(...)))`.
- `json.go` — small JSON decode helper.
- `ws_writer.go` — mutex-guarded WebSocket writer with a write deadline.
- `log_broadcaster.go` — multiplexes one `nerdctl` log stream to N WebSocket subscribers, keeps a 500-line history ring buffer, tears the stream down when the last subscriber disconnects.
- `runtime_ready.go` — blocks until the runtime is running (3-minute timeout); used before registry login.
- `runtime_errors.go` — maps `ErrRuntimeNotRunning` to `503`.
- `builds.go` — in-memory build history; `POST` triggers `RunBuild`.
- `containers.go` / `exec.go` / `images.go` / `logs.go` / `volumes.go` — CRUD plus subresources (logs, inspect, mounts, files, exec, stats). Exec/logs use WebSocket; other operations use one-shot HTTP.
- `migrate.go` — orchestrates the Docker Desktop migration in a background goroutine, exposes status polling.
- `registry.go` / `registry_login.go` — basic registry login/logout plus Docker Hub OAuth device-flow browser login with session polling.

### `internal/browser/open.go`
Cross-platform URL opener (`open` / `xdg-open` / `rundll32`).

### `internal/migration/`
Docker Desktop → Calf migration engine.
- `docker_desktop.go` — orchestrator (`RunFromDockerDesktop`): preflight → config → images → volumes → containers → builds, each step reporting a `Status` via callback. Uses the `docker` CLI against the Docker Desktop socket, and either `nerdctl` (via an injected `RunNerdctl` func) or a raw docker-CLI-against-Calf-socket fallback.
- `compose_migration.go` — groups migrated containers by compose project label, stages/copies compose project directories into `~/.config/calf/mounts/compose/...`, and patches compose YAML (rewrites `build:` to `image:`, injects captured env) via `yaml.v3` node manipulation.
- `disk.go` — checks free VM disk space against the estimated migration size before starting.
- `status.go` — `Phase` / `Status` / `Summary` types shared across the migration engine.

### `internal/oauth/dockerhub/device.go`
Docker Hub OAuth2 device-code flow client. Polls for a token, decodes JWT claims for the username, and generates a PAT used as the nerdctl registry login password.

### `internal/runtime/` (core abstraction)
- `runtime.go` — defines the `Runtime` interface (~30 methods: lifecycle, containers, images, volumes, builds, logs, exec, stats, registry) and shared JSON-tagged (snake_case) types (`Status`, `Container`, `Image`, `Volume`, `Build`, ...). `runtime.New(...)` selects `NewNative` on Linux, otherwise `NewLima`.
- `native.go` — `Native` runtime: talks directly to a `nerdctl`/`docker.sock` already available on the Linux host, no VM involved.
- `lima.go` — `Lima` runtime: manages a Lima VM (embeds a `lima.yaml` template via `go:embed`), starts/creates/stops the instance via `limactl`, runs all container operations via `limactl shell <vm> -- sudo nerdctl ...`. Includes `localhostProxies` for macOS port-forwarding and conflict detection.
- `nerdctl.go` — shared low-level helpers: JSON-line parsing of `nerdctl ps/images/volume ls/history` output, compose project/service inference, log-line noise filtering, log streaming plumbing.
- `mock.go` — in-memory `Mock` implementation of the full `Runtime` interface, used by backend tests.
- `exec.go` — generic `exec.CommandContext` wrapper with retry logic (`runCommandWithRetry`, retries only on `isTransientCommandError`).
- `exec_attach.go` — PTY-based interactive exec attach (`creack/pty`), wiring stdin/stdout/resize channels.
- `container_detail.go` — inspect JSON parsing, mount parsing, `ls -la` parsing for the file browser, stats parsing, `InspectSection` extraction.
- `volume_detail.go` — volume inspect/clone/list-files/container-usage logic, human-readable relative time formatting.
- `inspect_decode.go` — generic decoder tolerant of both JSON-array and NDJSON-style nerdctl inspect output.
- `localhost_proxy.go` — macOS-only TCP proxy forwarding `::1:<port>` to `127.0.0.1:<port>` inside the VM; detects port conflicts via `lsof`. No-op on non-Darwin platforms.
- `registry.go` — Docker `config.json` auth parsing/login/logout, registry-key normalization.
- `errors.go` — `ErrRuntimeNotRunning` sentinel and `requireRunning`/`emptyXIfStopped` guard helpers.
- `command_error.go` — shell output cleanup (strips ANSI escapes, extracts `nerdctl` fatal messages), transient-error classification for retry, and an auth-failure hint wrapper for push errors.

## UI File Reference (`ui/lib/`)

### `main.dart`
Builds a Material `ThemeData` bridged from a `ShadThemeData` (shadcn_ui), with a hardcoded brand primary color (`#2496ED`). Light/dark `ShadThemeData` instances are built once as top-level finals.

### `app_shell.dart`
Sidebar navigation (Containers / Images / Volumes / Builds) plus the settings screen, and a top bar showing Docker Hub registry sign-in status. `SettingsScreen` handles CPU/memory/swap slider configuration (bounded by host capacity from `/v1/config`), Docker Desktop migration trigger + polling, and theme mode switching.

### `api/client.dart`
Abstract `CalfClient` / `StatusClient` interfaces with a concrete `ApiClient` implementation over `package:http`. Response models are plain immutable Dart classes with `fromJson`/`toJson` factories — no code generation. `ApiException` is the custom error type. WebSocket URIs are built manually (swapping `ws`/`wss` for `http`/`https`). Default base URL: `http://127.0.0.1:8765`.

### `platform/open_url.dart`
Platform-specific "open URL" helper used for Docker Hub sign-in.

### `storage/`
Simple JSON files under `~/.config/calf/ui/<name>.json` (via `path_provider`'s application-support dir as fallback).
- `calf_ui_storage.dart` — shared file read/write helper.
- `container_groups.dart` — persists expanded/collapsed UI groups.
- `logs_viewer_preferences.dart` — persists show-timestamp/wrap-lines toggles; exposes a `LogViewerPreferencesMixin` for screens to mix in.

### `screens/`
- `containers_screen.dart` — list + search/filter/group-by-compose, polling via `Timer`.
- `container_detail_screen.dart` — tabs for logs/inspect/mounts/exec/files/stats, using `fl_chart` and `xterm`.
- `compose_group_detail_screen.dart` — mixed-color log view per compose project.
- `resources_screen.dart` — Images/Volumes/Builds screens.
- `volume_detail_screen.dart` — stored-data / containers-in-use tabs.

### `widgets/`
- `app_top_bar.dart` — registry auth UI.
- `calf_button.dart` — themed button with named constructors for variants (default / `.outline` / `.ghost` / `.destructive`).
- `files_panel.dart` — lazy-loaded directory tree using a `LoadDirectoryCallback` typedef.
- `hover_list_row.dart` — hover-state row wrapper.
- `logs_panel.dart` — log viewer, supporting multi-container color-coded "mixed" log blocks for compose groups.

## Testing Conventions

- **Backend:** tests live in `backend/test/<pkg>/` as external test packages (e.g. `package api_test`), **not** as `*_test.go` files alongside the source. This was a deliberate convention change (see `CHANGELOG.md`, v0.3.0: "Go tests moved to `backend/test/`"). Tests spin up a real server via `httptest.NewServer(api.New(cfg, logger, runtime.NewMock()).Handler())` and assert on raw HTTP responses.
- **UI:** standard Flutter widget tests under `ui/test/`.

## Build & Dev Commands

```
make dev-backend        # cd backend && CGO_ENABLED=0 go run ./cmd/calf
make dev-ui              # flutter run -d macos
make ui                  # flutter build macos  (alias: make build)
make clean                # flutter clean
make verify-docker-cli    # runs scripts/verify-docker-cli.sh
```

CI (`.github/workflows/ci.yml`, both jobs on `macos-latest`):
- **backend job:** `go vet ./...`, `go test ./...`, `go build -o /dev/null ./cmd/calf` (all `CGO_ENABLED=0`).
- **ui job:** `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build macos --no-pub`.

## Conventions

- **Language: English only.** All code, identifiers, UI strings, comments, commit messages, and documentation must be written in English — no exceptions.
- **Comments:** English only, and only where the *why* isn't obvious from the code itself. Do not restate what the code already says.
- **Fix root causes, not symptoms.** When you encounter a bug or a design problem, find and eliminate or replace the underlying cause. Do not apply superficial patches, workarounds, or defensive band-aids that mask the real issue — this includes silently swallowing errors, adding retries around a fundamentally broken call, or special-casing a symptom instead of fixing the source.
- **Commit style:** conventional-commit-like prefixes (`feat:`, `fix:`, `refactor:`, `chore:`), occasionally scoped (`fix(ui):`, `feat(runtime):`).
- **Error handling (backend):** handlers never leak raw internal errors to clients; they go through `writeRuntimeError`/`writeJSON` and map to appropriate HTTP status codes.
- **No generic catch-alls.** Never write a generic `try/catch` (or, in Go, a generic error check that just forwards `err` without identifying what failed). Catch/handle each *specific* error case individually — if that means 3, 5, or 10 separate specific handlers, write all of them. The point is that whoever reads the error (logs, UI, API response) can tell exactly which operation failed and why, not just that "something went wrong".
- **No premature abstraction:** the runtime layer has exactly three implementations (`Native`, `Lima`, `Mock`) behind one interface — follow that pattern rather than introducing new abstraction layers for hypothetical future runtimes.
- **UI state:** keep using `StatefulWidget` + `setState` and `Timer.periodic` polling for consistency with the rest of the screens; do not introduce a new state-management library without discussing it first.
- **Concurrency and resource lifecycle (Go):**
  - Thread a `context.Context` with an explicit timeout or cancellation through every call from an HTTP handler down into the runtime layer — never call a long-running or blocking runtime operation with a bare `context.Background()` inside a handler.
  - Every goroutine started for a long-lived task (log broadcasting, migration, background polling) must be stoppable: it must observe context cancellation or an explicit stop signal, and the code that starts it must ensure it is stopped during server shutdown. Do not fire-and-forget goroutines that outlive the request or the server's lifecycle.
  - Always release resources with `defer` immediately after acquiring them — `defer f.Close()`, `defer mu.Unlock()`, `defer cancel()` — placed right next to the acquisition, not at the bottom of the function.
- **Versioning and living documentation:**
  - `backend/version/version.go` and the version in `ui/pubspec.yaml` must be bumped together — they must always refer to the same release.
  - Any user-visible change (new feature, fix, breaking change) must get an entry in `CHANGELOG.md`, following the existing Keep a Changelog + SemVer format.
  - `CLAUDE.md` and `.cursor/rules/calf.mdc` are living documents: whenever a file is added, removed, or renamed under `backend/` or `ui/lib/`, update the Project Structure tree and the relevant file-reference section in the same change. Do not let these docs drift out of sync with the actual codebase.
