# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-07-05

### Added

- Volume **Exports** tab with export history and download
- **Quick export** to a local tar file, an existing local image, a new image built from the volume, or a registry push
- Export file/image name patterns with `{volume}` and `{timestamp}` placeholders (static names allowed with overwrite warning)
- **Scheduled exports** with per-weekday times, enable/disable from the schedule list, and a background scheduler in the daemon
- Backend volume export API: `GET/POST /v1/volumes/{name}/exports` and `GET .../exports/{id}/download`
- Backend schedule API: `GET/POST /v1/volumes/{name}/export-schedules` and `PUT/DELETE .../export-schedules/{id}`

## [0.3.0] - 2026-07-01

### Added

- Lima VM runtime on macOS with containerd, nerdctl, and Docker socket forwarding
- Linux native runtime path via nerdctl
- `calf start`, `calf stop`, and `calf status` CLI commands
- Container and image REST API endpoints
- WebSocket container log streaming at `/v1/containers/{id}/logs`
- Flutter UI screens for containers, images, and live logs
- `examples/hello-world/` reference project
- `scripts/verify-docker-cli.sh` P0 Docker CLI verification script
- Docker Desktop migration guide in `DEVELOPMENT.md`

### Changed

- `/v1/status` now includes runtime mode, state, and Docker socket path
- Go tests moved to `backend/test/`

## [0.2.0] - 2026-07-01

### Added

- Daemon layout under `backend/cmd/calf` with `internal/api` and `internal/config`
- Versioned REST API: `GET /v1/health`, `GET /v1/status`
- Persistent configuration at `~/.config/calf/config.yaml`
- Structured logging (`slog`), request logging, and panic recovery middleware
- Flutter UI with sidebar navigation, daemon status, and read-only settings screens
- `Makefile` for local builds (`make backend`, `make ui`, `make build`)
- GitHub Actions CI on macOS for backend and Flutter UI

### Changed

- Backend entry point moved from `go run .` to `go run ./cmd/calf`
- UI now consumes `/v1/status` instead of `/hello`

### Removed

- `/hello` placeholder endpoint

## [0.1.0] - 2026-07-01

### Added

- Project scaffolding
- Go backend (`backend/`) with HTTP API
- CORS support on API routes for local UI development
- Flutter UI (`ui/`) with `shadcn_ui`, fetching daemon response on startup
- `DEVELOPMENT.md` with quick-start instructions for backend and UI
- `README.md` with project overview and MIT license reference
