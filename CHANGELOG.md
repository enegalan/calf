# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Disk image settings** — Settings → System includes a disk image size slider and a disk image location field (default `~/.config/calf/guest/<vm>/disk.raw`).
- **Engine status bar** — a bottom bar shows whether the engine is running, Start/Stop/Kill controls, RAM and disk used versus reserved, and the app version; the menu opens Settings.
- **Container Stats history** — Stats keep a rolling ~15 minute resource history while the engine is running, so charts survive leaving and reopening a container; history is cleared when the container is removed.

### Fixed

- **Guest disk arch on Apple Silicon** — when the Go toolchain runs under Rosetta, Calf still selects the arm64 guest disk instead of looking for an amd64 asset.
- **Engine start** — starting gvproxy no longer fails when its pid file is written a moment after the process starts.
- **Status polling** — engine RAM/disk stats use fast host probes so `/v1/status` stays responsive for the UI.
- **Engine status bar** — the bar also shows live engine CPU usage.
- **Engine RAM/CPU** — status bar RAM and CPU use the macOS process API (not `/bin/ps`), so values stay correct when the daemon runs under an IDE sandbox that blocks `ps`.
- **Engine Start/Stop/Kill** — bottom-bar engine actions wait long enough for a slow VM boot, and failed actions no longer crash when showing an error.
- **Published ports after restart** — reopening Calf no longer spams gvproxy errors when a port forward was already active from the previous session.

### Changed

- **Mounts tab** — mount rows open bind paths in the system file manager and copy the host path.
- **UI toolkit** — the app uses Material Design 3 for theme and controls; the previous shadcn-based UI kit is gone. Icons use Lucide.

### Fixed

- **Bind mounts** — the same mount no longer appears twice when the engine reports it in both Mounts and HostConfig.Binds.

## [0.9.8] - 2026-07-23

### Added

- **Faster macOS engine** — release builds include the new macOS container engine; local builds can enable it with the documented setup steps.

### Changed

- **macOS startup and file I/O** — quicker engine start and faster bind-mount reads and writes on the reference Mac (see `BENCHMARKS.md`).
- **Guest disk persistence** — container images and data survive engine restarts on a durable guest disk downloaded on first start when needed.
- **Container networking** — published container ports are reachable on the host.

### Fixed

- **Volumes list** — opening Volumes no longer fails when a container shows up in the engine list but cannot be inspected.
- **Volume stored data** — browsing files inside a volume works again on macOS (paths are read from the guest, not the Mac host).
- **Chart tooltips** — build History uses a real floating overlay tooltip (not clipped by tabs); container Stats tooltips stay readable inside the plot.
- **Stopped containers** — Files works when a container is stopped (reads the filesystem without exec); Inspect and Bind mounts show a clear “container not found” error for broken entries instead of “operation failed”.
- **Container list** — corrupt engine leftovers that appear in `ps` but cannot be inspected are no longer shown in the list.
- **Container Stats** — the “only for running containers” note uses the same muted style as Exec, not an error color.

## [0.9.7] - 2026-07-19

### Removed

- **Lima product runtime** — macOS now always uses vfkit; Windows has no container engine until a new backend lands (clear unsupported error). Guest disk baking may still use `limactl` locally via `make guest-vfkit` (not the app runtime).
- **VFKit guest CI workflow** — nested Virtualization on GitHub Actions cannot bake the guest; attach `calf-vfkit-disk-*.raw.zst` to releases from a real Mac.

### Changed

- **Public docs and benchmarks** — Lima escape hatch and legacy bench table removed; architecture is Native (Linux) + vfkit (macOS).

## [0.9.6] - 2026-07-19

### Added

- **vfkit feature parity** — buildx builds, `host.docker.internal` (dnsmasq + gateway refresh), localhost `::1` port proxies, HTTP proxy apply inside the guest, and Rosetta on by default on Apple silicon (`CALF_VFKIT_ROSETTA=0` to disable).

### Changed

- **Public benchmarks** — the primary `BENCHMARKS.md` table now uses the vfkit engine (Calf leads or ties OrbStack on every metric on the reference Mac); Lima numbers move to a legacy section.

## [0.9.5] - 2026-07-19

### Added

- **Experimental fast-boot engine (macOS)** — when a provisioned vfkit guest disk (or release seed) and `vfkit` binary are present, Calf prefers that engine automatically; bundled apps download `calf-vfkit-disk-<arch>.raw.zst` from GitHub Releases on first start; build locally with `make guest-vfkit` (see `BENCHMARKS.md`).
- **Runtime start API** — `POST /v1/runtime/start` boots the container runtime while the daemon stays up (used for fair VM-boot benches on vfkit).

### Changed

- **Lima startup** — the Docker API can become ready before Lima finishes its SSH/boot-script gates, so the engine is usable sooner after a full VM stop.

## [0.9.4] - 2026-07-18

### Added

- **Performance benchmarks** — macOS comparison of Calf vs Docker Desktop vs OrbStack (startup, Compose, bind-mount I/O, idle memory), with reproduction steps in `BENCHMARKS.md`.
- **Menu bar / system tray icon** — Calf shows the white calf logo in the macOS menu bar and Windows notification area while the app is running; the tray menu lists running containers, Help links (repository, report issue, restart, updates), Docker Hub sign-in, Settings, and Quit; removed on **Calf → Quit**.
- **Buildx builds** — image builds inside the VM use Docker Buildx with BuildKit, including cross-architecture builds via Rosetta when a platform is set.
- **Rootless on Linux** — when `rootless: true` (default), Calf prefers a user Docker engine when available and falls back to the system engine if none is present; ignored on macOS/Windows (Lima).

### Fixed

- **Linux packaging** — Linux release builds install AppIndicator so the system tray can compile; the `.deb` package declares the matching runtime library.
- **Benchmark reliability** — cold-start measurements now use the compiled daemon, correct Docker contexts, and no longer fail when Docker Desktop is installed.
- **VM startup polling** — faster engine readiness checks during Lima boot reduce time-to-ready after the VM is running.

### Changed

- **Lima cold start** — the Docker-compatible API is available sooner during VM boot via a lightweight readiness probe instead of a full engine info round-trip; Buildx setup no longer blocks engine readiness.
- **VM keep-alive** — on macOS and Windows, quitting Calf leaves the Lima VM running so the next Calf launch reaches a ready engine in under 2 seconds (configurable via `vm_keep_alive`). With keep-alive enabled, the VM also starts automatically at login via Lima; `docker` against the Calf context is ready once the Calf app is running again (typically under 2 seconds when the VM was already up).
- **Cold-start target** — the fair stop→start benchmark target is under 20 seconds (Calf measures ~16 s on the reference Mac, ahead of Docker Desktop); keep-alive reopen is documented separately and is not used as that metric.

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
