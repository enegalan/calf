# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Performance benchmarks** — macOS comparison of Calf vs Docker Desktop vs OrbStack (startup, Compose, bind-mount I/O, idle memory), with reproduction steps in `BENCHMARKS.md`.

### Fixed

- **Benchmark reliability** — cold-start measurements now use the compiled daemon, correct Docker contexts, and no longer fail when Docker Desktop is installed.
- **VM startup polling** — faster nerdctl readiness checks during Lima boot reduce time-to-ready after the VM is running.

### Changed

- **Lima cold start** — the Docker socket is brought up before the VM boots and readiness uses a lightweight `/_ping` check instead of a full `nerdctl info` shell round-trip.
- **VM keep-alive** — on macOS and Windows, quitting Calf leaves the Lima VM running so the next launch reaches a ready engine in under 2 seconds (configurable via `vm_keep_alive` in `~/.config/calf/config.yaml`).

### Added

- **Menu bar / system tray icon** — Calf shows the white calf logo in the macOS menu bar and Windows notification area while the app is running; clicking it opens a context menu with Open and Quit; removed on **Calf → Quit**.

## [0.9.3] - 2026-07-12

### Changed

- **Settings validation** — CPU, memory, and proxy values are checked on the server before they are saved.
- **Startup port handling** — Calf only reclaims the listen port from another Calf instance, not unrelated processes.

### Fixed

- **Shutdown** — background migration and Docker Hub sign-in stop cleanly when the app closes.
- **Error messages** — container operations no longer expose low-level runtime output in API responses.

## [0.9.2] - 2026-07-09

### Added

- **Update notifications** — Calf checks for updates on launch and in Settings, shows when a newer version is available, and opens the right installer for your platform.
- **macOS menu bar** — Settings, section navigation, Docker Hub sign-in, update checks, and help links are available from the native menu bar.
- **Open at login** — optional setting in Settings to start Calf automatically when you sign in.
- **Branded macOS installer** — the `.dmg` uses a drag-to-Applications layout with a custom background.
- **Installation guide** — step-by-step install instructions for macOS (including Homebrew), Windows, and Linux are in the README.

### Changed

- **Sidebar** — collapses manually and automatically when the window is narrow.
- **Linux AppImage builds** — packaging downloads and validates the build tool more reliably on CI.

### Fixed

- **Image push errors** — pushing an image to a registry now shows a clearer message when authentication fails.
- **Volume export file names** — quick exports and scheduled exports now sanitize file names the same way.
- **Container exec** — opening the Exec tab no longer shows a Lima provisioning warning on startup.
- **Build source tab** — the Source tab in build details now shows the Dockerfile for builds imported from build history.

## [0.9.1] - 2026-07-08

### Fixed

- **Windows installer** — the `.exe` packaging script resolves paths correctly so release builds produce the installer reliably.
- **Linux `.rpm` installer** — the RPM build step uses a stable working directory so packaging no longer fails on CI.

## [0.9.0] - 2026-07-08

### Added

- **Automated releases** — bumping the version on `main` builds and publishes macOS, Windows, and Linux installers to GitHub Releases.

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
