# CLAUDE.md

This file provides guidance to AI assistants when working with code in this repository. It must stay equivalent to `.cursor/rules/calf.mdc` — update both in the same change.

## Project Overview

**Calf** is a lightweight, open-source alternative to Docker Desktop. It consists of:

- A **Go daemon** (`backend/`) that manages containers through `containerd` + `nerdctl`, running inside a **krunkit** guest on macOS, or talking directly to the host runtime on Linux (Windows engine pending).
- A **native Flutter GUI** (`ui/`) that drives the daemon over a local REST + WebSocket API.

The Go daemon binary is embedded inside the Flutter `.app` bundle (`Contents/MacOS/calf-daemon`). When the app launches, it spawns the daemon as a subprocess and kills it on close. No separate installation or terminal setup required.

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
- **Container tooling:** shells out to `krunkit`, `gvproxy`, `docker` CLI (no Docker/containerd Go SDK dependency)

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
│   │   └── main.go                          Entrypoint: config/logger/runtime/server wiring, signal handling, PID file, stale-port takeover (cross-platform: lsof/Unix, netstat/Windows)
│   ├── internal/
│   │   ├── api/
│   │   │   ├── gateway.go                     HTTP Gateway: route registration, Run/Shutdown
│   │   │   ├── health.go                      Health HTTP handler
│   │   │   ├── status.go                      Status HTTP handler
│   │   │   ├── runtime.go                     Runtime start HTTP handler (POST /v1/runtime/start)
│   │   │   ├── config.go                      Config HTTP handler
│   │   │   ├── builds.go                      Build HTTP handlers
│   │   │   ├── containers.go                  Container HTTP handlers
│   │   │   ├── exec.go                        Exec HTTP handlers (WebSocket + one-shot)
│   │   │   ├── images.go                      Image HTTP handlers
│   │   │   ├── logs.go                        Log streaming HTTP handlers
│   │   │   ├── volumes.go                     Volume HTTP handlers
│   │   │   ├── volume_exports.go              Volume export HTTP handlers
│   │   │   ├── volume_export_schedules.go     Scheduled export HTTP handlers
│   │   │   ├── networks.go                    Network HTTP handlers
│   │   │   ├── migrate.go                     Migration HTTP handlers
│   │   │   ├── registry.go                    Registry HTTP handlers
│   │   │   └── registry_login.go              Docker Hub login HTTP handlers
│   │   ├── httpkit/
│   │   │   ├── response.go                    JSON response helpers
│   │   │   ├── json.go                        Request JSON decode helper
│   │   │   ├── route.go                       HTTP method and path routing helpers
│   │   │   ├── runtime_errors.go              Runtime error to HTTP status mapping
│   │   │   ├── ws_writer.go                   Mutex-guarded WebSocket writer
│   │   │   ├── websocket.go                   WebSocket upgrader for log/exec streams
│   │   │   └── runtime_ready.go               HTTP guard before registry operations
│   │   ├── middleware/
│   │   │   ├── middleware.go                  Middleware type and Chain helper
│   │   │   ├── cors.go                        CORS headers and OPTIONS preflight
│   │   │   ├── logging.go                     Request logging
│   │   │   └── recovery.go                    Panic recovery
│   │   ├── daemon/
│   │   │   ├── core.go                        Daemon Core struct, lifecycle, shared state
│   │   │   ├── build_sync.go                  Background buildkit history sync
│   │   │   ├── builds.go                      In-memory build history and build jobs
│   │   │   ├── export_runner.go               Volume export execution
│   │   │   ├── export_scheduler.go            Scheduled volume export background worker
│   │   │   ├── host.go                        Host CPU/memory capacity probes
│   │   │   ├── log_broadcaster.go             Fan-out of one nerdctl log stream to N subscribers
│   │   │   ├── migrate.go                     Docker Desktop migration runner
│   │   │   ├── registry_login.go              Docker Hub device-flow session manager
│   │   │   └── runtime_ready.go               Start/wait for runtime (non-HTTP)
│   │   ├── config/
│   │   │   ├── config.go                      Config struct, YAML load/save, defaults
│   │   │   └── logger.go                       slog.TextHandler setup with level parsing
│   │   ├── runtime/
│   │   │   ├── runtime.go                     Runtime interface (~30 methods) + shared types; runtime.New picks Native / Krunkit (darwin) / Unsupported (windows)
│   │   │   ├── select_darwin.go               Darwin runtime: always krunkit
│   │   │   ├── krunkit_darwin.go              macOS krunkit + gvproxy runtime
│   │   │   ├── select_other.go                Non-darwin stub for selection helper
│   │   │   ├── native.go                       Native runtime: talks directly to host nerdctl/docker.sock (Linux)
│   │   │   ├── guest_darwin.go                 Shared guest disk/EFI/vsock helpers (embedded by Krunkit)
│   │   │   ├── guest_disk_fetch_darwin.go       First-run GitHub disk download + zstd extract
│   │   │   ├── nerdctl.go                      Shared nerdctl output parsing, compose project inference, log filtering
│   │   │   ├── buildx.go                       Docker buildx build --load args, builder bootstrap
│   │   │   ├── rootless.go                     Linux native rootless Docker socket discovery + DOCKER_HOST env
│   │   │   ├── network.go                      Network list/inspect/remove via nerdctl
│   │   │   ├── proxy.go                        HTTP/HTTPS proxy application in VM/native runtime
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
│   │   ├── utils/
│   │   │   ├── http_response.go               WriteOK HTTP helper
│   │   │   └── lines.go                       ParseLines for command output
│   │   ├── constants/
│   │   │   └── constants.go                   Shared timeouts, defaults, log tail count, alpine smoke image
│   │   ├── dockercli/
│   │   │   ├── context.go                     Docker CLI context create/update/activate
│   │   │   └── manager.go                     Background context manager loop
│   │   ├── oauth/dockerhub/
│   │   │   └── device.go                      Docker Hub OAuth2 device-code flow client, PAT generation
│   │   └── browser/
│   │       └── open.go                        Cross-platform "open URL" helper (open/xdg-open/rundll32)
│   ├── test/                                External test packages (see Testing Conventions)
│   │   ├── api/api_test.go
│   │   ├── buildhistory/history_test.go
│   │   ├── buildstore/buildstore_test.go
│   │   ├── config/config_test.go
│   │   ├── dockercli/context_test.go
│   │   ├── dockerhub/device_test.go
│   │   ├── runtime/                            build_enrich, build_parser, buildx, command_error, image_history, localhost_proxy, nerdctl, network, registry, rootless, volume_detail tests
│   │   └── volumeexport/                       name_pattern, schedule_timing tests
│   ├── version/version.go                     Single Version constant
│   └── go.mod / go.sum                        Module github.com/enegalan/calf/backend, Go 1.22.1
├── ui/                                      Flutter application
│   ├── lib/
│   │   ├── main.dart                          App entrypoint; Material theme bridged from ShadThemeData (light/dark)
│   │   ├── app_shell.dart                     Sidebar nav, top bar, SettingsScreen (resources, migration, theme)
│   │   ├── api/
│   │   │   └── client.dart                    CalfClient/StatusClient interfaces + ApiClient (http + WebSocket)
│   │   ├── constants/
│   │   │   └── calf_constants.dart            Shared colors, defaults, storage filenames, GitHub repo
│   │   ├── platform/
│   │   │   ├── macos_menu.dart                Native macOS menu bar (PlatformMenuBar)
│   │   │   ├── tray_status.dart               macOS menu bar / Windows system tray status icon
│   │   │   ├── launch_at_login.dart           Optional open-at-login registration (macOS/Linux/Windows)
│   │   │   └── open_url.dart                  Platform-specific URL opener (Docker Hub sign-in)
│   │   ├── storage/
│   │   │   ├── calf_ui_storage.dart            Shared JSON file read/write helper (~/.config/calf/ui/*.json)
│   │   │   ├── container_groups.dart            Persists expanded/collapsed container groups
│   │   │   ├── logs_viewer_preferences.dart     Persists timestamp/wrap-lines toggles; LogViewerPreferencesMixin
│   │   │   ├── sidebar_preferences.dart         Persists sidebar expanded/collapsed state
│   │   │   └── update_preferences.dart          Persists update-check cache and skipped versions
│   │   ├── updates/
│   │   │   ├── update_checker.dart              GitHub Releases check + platform asset selection
│   │   │   ├── update_dialog.dart               Update-available dialog
│   │   │   └── update_info.dart                 Update check result models
│   │   ├── screens/
│   │   │   ├── containers_screen.dart          List/search/filter/group-by-compose, Timer-based polling
│   │   │   ├── container_detail_screen.dart    Tabs: logs/inspect/mounts/exec/files/stats (fl_chart, xterm)
│   │   │   ├── compose_group_detail_screen.dart Mixed-color log view per compose project
│   │   │   ├── images_screen.dart              Image list and detail
│   │   │   ├── volumes_screen.dart             Volume list (on-demand refresh)
│   │   │   ├── builds_screen.dart              Build list and polling
│   │   │   ├── build_detail_screen.dart        Build detail tabs
│   │   │   ├── networks_screen.dart            Network list and detail screens
│   │   │   ├── volume_detail_screen.dart        Stored-data / containers-in-use / exports tabs
│   │   │   ├── volume_quick_export_screen.dart  Quick export destination picker
│   │   │   └── volume_schedule_export_screen.dart  Schedule export configuration
│   │   └── widgets/
│   │       ├── about_dialog.dart               Branded About Calf dialog
│   │       ├── app_top_bar.dart                Registry auth UI
│   │       ├── calf_button.dart                Themed button (default/.outline/.ghost/.destructive)
│   │       ├── calf_tab_bar.dart               Shared detail-screen tab bar
│   │       ├── confirm_dialog.dart             Confirm and prompt dialogs
│   │       ├── detail_breadcrumb.dart          Detail view back navigation header
│   │       ├── error_text.dart                 Formatted API error text
│   │       ├── files_panel.dart                Lazy-loaded directory tree (LoadDirectoryCallback)
│   │       ├── hover_list_row.dart             Hover-state row wrapper
│   │       ├── logs_panel.dart                 Log viewer incl. multi-container "mixed" color-coded blocks
│   │       ├── poll_interval_mixin.dart        Shared Timer.periodic polling mixin
│   │       ├── resource_list_scaffold.dart     List screen layout helper
│   │       ├── running_filter_switch.dart      "Show only running" filter switch
│   │       ├── status_dot.dart                 Running/in-use status indicator dot
│   │       └── volume_export_form.dart         Shared volume export form widgets
│   ├── test/widget_test.dart                  Flutter widget test
│   ├── pubspec.yaml                           Dependencies, Dart SDK ^3.12.2
│   └── analysis_options.yaml                  flutter_lints, no custom overrides
├── examples/hello-world/                   Reference smoke-test project
│   ├── Dockerfile                             FROM alpine:3.20, trivial CMD
│   ├── compose.yaml                            build: . + sleep 300
│   └── .dockerignore
├── scripts/verify-docker-cli.sh             Verifies `docker` CLI works against Calf's socket
├── scripts/_common.sh                       Shared packaging constants and helpers sourced by the bash packaging scripts
├── scripts/package-macos.sh                 Creates macOS .dmg and .pkg installers from the release app bundle
├── scripts/package-windows.ps1              Creates Windows .exe installer via Inno Setup
├── scripts/package-linux.sh                 Creates Linux .deb, .rpm, and AppImage installers from the release bundle
├── .github/workflows/ci.yml                 CI: backend (vet/test/build) + ui (analyze/test/build) jobs, macos-latest
├── .github/workflows/release.yml            Release: builds platform installers on version bumps and creates a draft GitHub release
├── Makefile                                 dev-backend / dev-ui-macos / dev-ui-linux / dev-ui-windows / ui-macos / ui-linux / ui-windows / clean / verify-docker-cli / release / release-macos / release-linux / release-windows / package / package-macos / package-windows / package-linux targets
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
- `config.go` — defines the `Config` struct (`listen_addr`, `log_level`, `vm_name`, `docker_socket`, `poll_interval_ms`, `cpus`, `memory_gb`, `memory_swap_gb`, `disk_gb`, `http_proxy`, `https_proxy`, `no_proxy`). Loads/saves as YAML at `~/.config/calf/config.yaml`, with defaults embedded via `//go:embed config.yaml` and a `withDefaults` backfill step.
- `logger.go` — wraps `slog.NewTextHandler` with a level parser (`debug`/`warn`/`error`, default `info`).

### `internal/api/`
HTTP handlers only. Each file maps REST/WebSocket routes to `daemon.Core` and writes responses via `httpkit`.

- `gateway.go` — `Gateway` struct; registers all `/v1/...` routes; `WithMiddleware`; `Run`/`Shutdown` for the HTTP server.
- `health.go` — `/v1/health`.
- `status.go` — `/v1/status`.
- `runtime.go` — `POST /v1/runtime/start` (boot/ensure runtime while the daemon stays up).
- `config.go` — `/v1/config` handler, response shape, and update logic.
- `builds.go`, `containers.go`, `exec.go`, `images.go`, `logs.go`, `volumes.go`, `volume_exports.go`, `volume_export_schedules.go`, `networks.go`, `migrate.go`, `registry.go`, `registry_login.go` — resource HTTP handlers.

### `internal/httpkit/`
Shared HTTP utilities used by `api` handlers (not route handlers themselves).

- `response.go` — `WriteJSON`, `WriteError`, `MethodNotAllowed`.
- `json.go` — `JSONDecode`.
- `route.go` — `ServeMethods`, `ServeRoutes`, `ServePrefix`, `PathParts`.
- `runtime_errors.go` — maps runtime errors to HTTP status codes.
- `ws_writer.go` — mutex-guarded WebSocket writer.
- `websocket.go` — WebSocket upgrader for log/exec streams.
- `runtime_ready.go` — `EnsureRuntimeOrFail` HTTP guard before registry operations.

### `internal/middleware/`
HTTP middleware stack; one file per middleware, registered from `main` via `Gateway.WithMiddleware`.

- `middleware.go` — `Middleware` type and `Chain`.
- `cors.go` — `CORS`.
- `logging.go` — `Logging`.
- `recovery.go` — `Recovery`.

### `internal/daemon/`
Daemon backend: shared state, background workers, and services used by the HTTP gateway.

- `core.go` — `Core` struct; `New`/`Shutdown`.
- `build_sync.go` — periodic buildkit history import and enrichment.
- `builds.go` — in-memory build history, build jobs, persistence.
- `export_runner.go` — `ExecuteVolumeExport`.
- `export_scheduler.go` — scheduled volume export worker.
- `host.go` — host CPU/memory capacity probes.
- `log_broadcaster.go` — multiplexes one `nerdctl` log stream to N subscribers.
- `migrate.go` — Docker Desktop migration runner.
- `registry_login.go` — Docker Hub device-flow session manager.
- `runtime_ready.go` — `EnsureRuntimeRunning` (non-HTTP).

### `internal/dockercli/`
Docker CLI context management for pointing `docker` at the Calf socket.

- `context.go` — context create/update/activate and status probes.
- `manager.go` — `Manager` background loop; `Status` and `Activate`.

### `internal/utils/`
- `http_response.go` — `WriteOK`.
- `lines.go` — `ParseLines` for newline-delimited command output.

### `internal/constants/`
- `constants.go` — shared defaults (`DefaultListenAddr`, `DefaultPollIntervalMS`), `DefaultActionTimeout`, `LogTailLineCount`, `AlpineSmokeImage`.

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
- `runtime.go` — defines the `Runtime` interface (~30 methods: lifecycle, containers, images, volumes, builds, logs, exec, stats, registry) and shared JSON-tagged (snake_case) types (`Status`, `Container`, `Image`, `Volume`, `Build`, ...). `runtime.New(...)` selects `NewNative` on Linux, `NewKrunkit` on darwin, and `NewWindowsUnsupported` on Windows.
- `select_darwin.go` / `select_other.go` — Darwin always returns `NewKrunkit` (non-Darwin stub).
- `krunkit_darwin.go` — macOS krunkit + gvproxy runtime (guest disk/vsock under `~/.config/calf/guest/`; DAX remount `dax=inode` by default).
- `native.go` — `Native` runtime: talks directly to a host `nerdctl`/`docker.sock` on Linux, with optional rootless user-socket preference.
- `guest_darwin.go` — shared guest disk/EFI/vsock helpers embedded by `Krunkit`. Disk under `~/.config/calf/guest/`; release assets `calf-guest-disk-*`.
- `unsupported.go` — Windows stub Runtime until a new backend lands.
- `guest_disk_fetch_darwin.go` — first-run GitHub Release download + pure-Go zstd extract for `calf-guest-disk-<arch>.raw.zst`.
- `nerdctl.go` — shared low-level helpers: JSON-line parsing of `nerdctl ps/images/volume ls/history` output, compose project/service inference, log-line noise filtering, log streaming plumbing.
- `buildx.go` — Docker Buildx bootstrap and `buildx build --load` argument construction for guest/native builds; covered by `backend/test/runtime/buildx_test.go`.
- `rootless.go` — Linux native rootless socket discovery (`XDG_RUNTIME_DIR` / `~/.docker`) and `DOCKER_HOST` env wiring; covered by `backend/test/runtime/rootless_test.go`.
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
App entrypoint. Calls `_startDaemon()` to spawn the Go daemon binary (found next to the Flutter executable — `.app` bundle on macOS, alongside the binary on Linux/Windows) and waits for `/v1/status` to respond before showing the UI. Kills the daemon on app close. Inserts common Homebrew paths into `PATH` on macOS (no-op on other platforms). Builds a Material `ThemeData` bridged from a `ShadThemeData` (shadcn_ui), with brand primary color from `CalfColors.primary`. Light/dark `ShadThemeData` instances are built once as top-level finals.

### `app_shell.dart`
Sidebar navigation (Containers / Images / Volumes / Builds) plus the settings screen, and a top bar showing Docker Hub registry sign-in status. `SettingsScreen` handles CPU/memory/swap slider configuration (bounded by host capacity from `/v1/config`), Docker Desktop migration trigger + polling, and theme mode switching.

### `api/client.dart`
Abstract `CalfClient` / `StatusClient` interfaces with a concrete `ApiClient` implementation over `package:http`. Response models are plain immutable Dart classes with `fromJson`/`toJson` factories — no code generation. `ApiException` is the custom error type. WebSocket URIs are built manually (swapping `ws`/`wss` for `http`/`https`). Default base URL and timeouts come from `CalfDefaults` in `constants/calf_constants.dart`.

### `constants/calf_constants.dart`
Shared UI constants: `CalfColors` (primary, success, warning), `CalfDefaults` (base URL, poll interval, HTTP timeouts), `CalfStorageFiles` (JSON preference filenames), `CalfGitHub` (repository slug).

### `platform/`
- `macos_menu.dart` — wraps the app shell with a native macOS menu bar (Settings, navigation shortcuts, Docker Hub sign-in, updates, help links) via `PlatformMenuBar`.
- `tray_status.dart` — shows a Calf status icon in the macOS menu bar and Windows system tray while the app is running; removed on quit.
- `launch_at_login.dart` — optional open-at-login registration for macOS (LaunchAgent), Linux (XDG autostart), and Windows (Run registry key).
- `open_url.dart` — platform-specific "open URL" helper used for Docker Hub sign-in.

### `storage/`
Simple JSON files under `~/.config/calf/ui/<name>.json` (via `path_provider`'s application-support dir as fallback).
- `calf_ui_storage.dart` — shared file read/write helper.
- `container_groups.dart` — persists expanded/collapsed UI groups.
- `logs_viewer_preferences.dart` — persists show-timestamp/wrap-lines toggles; exposes a `LogViewerPreferencesMixin` for screens to mix in.
- `sidebar_preferences.dart` — persists sidebar expanded/collapsed state.
- `update_preferences.dart` — persists update-check cache and skipped versions.

### `updates/`
- `update_checker.dart` — queries GitHub Releases for the latest version and picks the platform installer asset.
- `update_dialog.dart` — update-available dialog shown on launch when a newer release exists.
- `update_info.dart` — update check result models.

### `screens/`
- `containers_screen.dart` — list + search/filter/group-by-compose, polling via `Timer`.
- `container_detail_screen.dart` — tabs for logs/inspect/mounts/exec/files/stats, using `fl_chart` and `xterm`.
- `compose_group_detail_screen.dart` — mixed-color log view per compose project.
- `images_screen.dart` — image list, detail, polling.
- `volumes_screen.dart` — volume list with on-demand refresh (no polling).
- `builds_screen.dart` — build list with polling.
- `build_detail_screen.dart` — build detail tabs (info, source, logs, history).
- `networks_screen.dart` — Network list (name + subnet) and detail (driver, scope, gateway, options).
- `volume_detail_screen.dart` — stored-data / containers-in-use / exports tabs.
- `volume_quick_export_screen.dart` — quick export destination picker (local file, image, registry).
- `volume_schedule_export_screen.dart` — schedule export configuration (daily/weekly/monthly).

### `widgets/`
- `about_dialog.dart` — branded About Calf dialog (logo, version, highlights, links).
- `app_top_bar.dart` — registry auth UI.
- `calf_button.dart` — themed button with named constructors for variants (default / `.outline` / `.ghost` / `.destructive`).
- `files_panel.dart` — lazy-loaded directory tree using a `LoadDirectoryCallback` typedef.
- `hover_list_row.dart` — hover-state row wrapper.
- `logs_panel.dart` — log viewer, supporting multi-container color-coded "mixed" log blocks for compose groups.
- `error_text.dart` — formatted API error text.
- `detail_breadcrumb.dart`, `calf_tab_bar.dart` — shared detail view chrome.
- `poll_interval_mixin.dart` — shared list-screen polling lifecycle.
- `resource_list_scaffold.dart`, `running_filter_switch.dart` — list screen layout helpers.
- `confirm_dialog.dart` — confirm dialog helper.
- `status_dot.dart`, `volume_export_form.dart` — status indicator and volume export shared UI.

## Testing Conventions

- **Backend:** tests live in `backend/test/<pkg>/` as external test packages (e.g. `package api_test`), **not** as `*_test.go` files alongside the source. This was a deliberate convention change (see `CHANGELOG.md`, v0.3.0: "Go tests moved to `backend/test/`"). Tests spin up a real server via `httptest.NewServer(api.New(cfg, logger, runtime.NewMock()).Handler())` and assert on raw HTTP responses.
- **UI:** standard Flutter widget tests under `ui/test/`.

## Build & Dev Commands

```
make dev-backend        # cd backend && CGO_ENABLED=0 go run ./cmd/calf
make dev-ui-macos       # flutter run -d macos
make dev-ui-linux       # flutter run -d linux
make dev-ui-windows     # flutter run -d windows
make ui-macos           # flutter build macos
make ui-linux           # flutter build linux
make ui-windows         # flutter build windows
make release            # build Go daemon + Flutter app for all platforms
make release-macos      # build Go daemon + macOS .app
make release-linux      # build Go daemon + Linux bundle
make release-windows    # build Go daemon + Windows bundle
make package-macos      # create macOS .dmg and .pkg installers
make package-linux      # create Linux .deb, .rpm, and AppImage installers
make package-windows    # create Windows .exe installer
make clean              # flutter clean
make verify-docker-cli  # runs scripts/verify-docker-cli.sh
```

CI (`.github/workflows/ci.yml`, both jobs on `macos-latest`):
- **backend job:** `go vet ./...`, `go test ./...`, `go build -o /dev/null ./cmd/calf` (all `CGO_ENABLED=0`).
- **ui job:** `flutter pub get`, `flutter analyze`, `flutter test`, `flutter build macos --no-pub`.

Release (`.github/workflows/release.yml`):
- Triggered on pushes to `main` that modify `backend/version/version.go` or `ui/pubspec.yaml`.
- Matrix builds on `macos-latest`, `windows-latest`, and `ubuntu-latest`.
- Each runner builds the platform release bundle and packages it into native installers (macOS `.dmg`/`.pkg`, Windows `.exe`, Linux `.deb`/`.rpm`/`.AppImage`).
- Artifacts are collected and published as a draft GitHub release with an auto-generated tag `v<version>`.

## Conventions

- **Language: English only.** All code, identifiers, UI strings, comments, commit messages, and documentation must be written in English — no exceptions.
- **Comments:** English only. Every function and method must have a doc comment (Go: `//` immediately above the declaration; Dart: `///`). State what it does; add the *why* when it is not obvious from the signature or body. A single line is enough for small helpers — omitting comments on functions is not allowed. Do not restate parameter names or types that are already clear from the signature.
- **Fix root causes, not symptoms.** When you encounter a bug or a design problem, find and eliminate or replace the underlying cause. Do not apply superficial patches, workarounds, or defensive band-aids that mask the real issue — this includes silently swallowing errors, adding retries around a fundamentally broken call, or special-casing a symptom instead of fixing the source.
- **Commit style:** conventional-commit-like prefixes (`feat:`, `fix:`, `refactor:`, `chore:`), occasionally scoped (`fix(ui):`, `feat(runtime):`).
- **CHANGELOG:** entries must describe changes in user-facing terms — no implementation details, library names, file paths, or protocol jargon. Write what changed from the user's perspective, not how it was built.
- **Error handling (backend):** handlers never leak raw internal errors to clients; they go through `writeRuntimeError`/`writeJSON` and map to appropriate HTTP status codes.
- **No generic catch-alls.** Never write a generic `try/catch` (or, in Go, a generic error check that just forwards `err` without identifying what failed). Catch/handle each *specific* error case individually — if that means 3, 5, or 10 separate specific handlers, write all of them. The point is that whoever reads the error (logs, UI, API response) can tell exactly which operation failed and why, not just that "something went wrong".
- **No premature abstraction:** the runtime layer has `Native`, `Krunkit` (darwin), `Unsupported` (windows), and `Mock` behind one interface — follow that pattern rather than introducing new abstraction layers for hypothetical future runtimes.
- **UI state:** keep using `StatefulWidget` + `setState` and `Timer.periodic` polling for consistency with the rest of the screens; do not introduce a new state-management library without discussing it first.
- **Concurrency and resource lifecycle (Go):**
  - Thread a `context.Context` with an explicit timeout or cancellation through every call from an HTTP handler down into the runtime layer — never call a long-running or blocking runtime operation with a bare `context.Background()` inside a handler.
  - Every goroutine started for a long-lived task (log broadcasting, migration, background polling) must be stoppable: it must observe context cancellation or an explicit stop signal, and the code that starts it must ensure it is stopped during server shutdown. Do not fire-and-forget goroutines that outlive the request or the server's lifecycle.
  - Always release resources with `defer` immediately after acquiring them — `defer f.Close()`, `defer mu.Unlock()`, `defer cancel()` — placed right next to the acquisition, not at the bottom of the function.
- **Versioning and living documentation:**
  - `backend/version/version.go` and the version in `ui/pubspec.yaml` must be bumped together — they must always refer to the same release.
  - Any user-visible change (new feature, fix, breaking change) must get an entry in `CHANGELOG.md`, following the existing Keep a Changelog + SemVer format.
  - `CLAUDE.md` and `.cursor/rules/calf.mdc` must stay equivalent: whenever a file is added, removed, or renamed under `backend/` or `ui/lib/`, update the Project Structure tree and file-reference sections in both files in the same change.
