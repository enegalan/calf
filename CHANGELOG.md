# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] - 2026-07-08

### Added

- **Official platform installers** — macOS `.dmg`/`.pkg`, Windows `.exe`, and Linux `.deb`/`.rpm`/`.AppImage` installers are now available from GitHub Releases.

## [0.7.0] - 2026-07-08

### Added

- **Cross-platform support** — Calf now runs on Linux, macOS, and Windows.
- **Automated cross-platform builds** verified in CI for Linux and Windows.
- **Windows port conflict cleanup** — stale daemon instances are detected and removed on Windows.
- **Linux build target** — `make ui-linux` and `make release-linux` are available.
- **Windows build target** — `make ui-windows` and `make release-windows` are available.
- **`docker compose` no longer hangs** — compose commands finish reliably.

### Changed

- Port conflict cleanup works across operating systems.
- PATH setup on macOS prefers Homebrew paths while leaving other systems unchanged.
- Links and URLs open with the platform handler on all supported systems.
- The bundled daemon binary is discovered next to the app executable on all platforms.
- Startup socket checks log missing sockets at Debug level instead of Warn.
- macOS release entitlements tightened: removed unsafe memory and library-validation exceptions. The app sandbox remains off so the backend can run required external tools.

### Fixed

- Container list parsing handles both structured and comma-separated labels.
- Streaming log and interactive exec commands consistently route through the VM runtime.
- macOS release build produces a single daemon binary that works on both Intel and Apple Silicon Macs, and signs it correctly so the app can launch the backend.
- UI startup spinner clears transient daemon errors once the runtime reaches the running state and no longer pretends the app is ready after the timeout expires.

## [0.6.0] - 2026-07-06

### Changed

- **Proxy settings** redesigned with clearer layout, icons for each field, and one-tap clear buttons

## [0.5.0] - 2026-07-05

### Added

- **Networks screen** in the sidebar — browse networks and see their details
- **Proxy settings** in Settings — configure HTTP, HTTPS, and no-proxy for image downloads
- **host.docker.internal** now works from inside containers on macOS
- Port forwarding from containers now recovers automatically after sleep/wake

## [0.4.0] - 2026-07-05

### Added

- **Volume exports** — download a snapshot of any volume as a tar file
- **Quick export** — send a volume to a local file, an existing image, a new image, or a registry
- **Scheduled exports** — set up daily, weekly, or monthly exports with per-weekday schedules

## [0.3.0] - 2026-07-01

### Added

- First usable release with container and image management
- **macOS support** via a managed Linux VM
- **Linux support** running directly on the host
- Start, stop, and check status from the command line
- **Containers screen** — list, start, stop, delete containers
- **Images screen** — browse and delete images
- **Live logs** — stream container logs in real time
- Reference project in `examples/hello-world/`

## [0.2.0] - 2026-07-01

### Added

- Basic sidebar navigation between screens
- **Settings screen** — read-only view of configuration
- Status banner showing daemon connection state
- Configuration file saved at `~/.config/calf/config.yaml`
- Build scripts for development

### Changed

- Backend restructured for easier development

## [0.1.0] - 2026-07-01

### Added

- Project bootstrap with Go backend and Flutter UI
- Health check endpoint
- CORS support for local development
- Quick-start guide in `DEVELOPMENT.md`
