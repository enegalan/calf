# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.16] - 2026-08-16

### Fixed

- **File bind mounts on macOS** — Compose binds like `./file.conf:/etc/file.conf` no longer fail with "not a directory" after an engine restart. calf remounts your home folder into the VM on every start so those paths stay real files.

## [1.0.15] - 2026-08-16

### Changed

- **Toasts** — errors, warnings, and in-progress actions (starting or stopping containers, the engine, and similar work) show as toasts instead of messages inside the screens.

## [1.0.14] - 2026-08-16

### Fixed

- **Resource Saver lists** — Containers, Images, Volumes, and Networks stay visible while Resource Saver has stopped the engine, instead of looking like a stopped engine with empty lists.
- **Start from Resource Saver** — starting or restarting a container, or running an image, wakes the engine instead of failing with "runtime is not running".

## [1.0.13] - 2026-08-16

### Fixed

- **Quit from Dock** — quitting calf from the Dock or with Cmd+Q now stops the embedded engine instead of leaving it running after the window closes.

## [1.0.12] - 2026-08-16

### Fixed

- **Container list after engine wake** — listing containers no longer fails when a leftover disk snapshot is missing. On macOS, calf talks to the guest engine with an API version it can serve, so the engine stays up instead of cycling between idle shutdown and wake.

## [1.0.11] - 2026-08-16

### Changed

- **Close to menu bar / tray** — closing the main window keeps calf running in the background. Use Quit from the menu-bar or system-tray icon to exit (or calf → Quit on macOS).

## [1.0.10] - 2026-08-16

### Fixed

- **Engine starting** — the status bar shows Engine starting while the container engine is booting, including the first launch and after Restart. A lost daemon connection shows as unknown, not as starting.

## [1.0.9] - 2026-08-16

### Fixed

- **`docker compose up --build` EOF on macOS** — newer host Docker CLIs no longer fail with EOF or version errors when building through calf. calf keeps the CLI socket compatible and finishes each plain call cleanly so compose/buildx probes stay reliable.

## [1.0.8] - 2026-08-16

### Fixed

- **Docker CLI plugins after leaving Docker Desktop** — calf detects broken `docker-buildx` / `docker-compose` symlinks under `~/.docker/cli-plugins/` (common after trashing Docker Desktop) and relinks working copies from Homebrew, OrbStack, or PATH so `docker compose up --build` keeps working. Settings shows an install hint when a plugin is still missing.

## [1.0.7] - 2026-08-15

### Fixed

- **Docker CLI EOF on macOS** — parallel `docker` / Compose calls no longer leave stuck engine-socket connections that make later commands fail with EOF. calf limits concurrent vsock use so the guest socket stays responsive under load.
- **Empty `docker run` / `docker exec` output on macOS** — attach streams keep working through `docker.sock`. calf does not half-close the engine vsock after the CLI finishes sending a hijacked request, and plain API calls use `Connection: close` so keep-alive cannot wedge the socket under load.
- **Empty resource lists** — Containers, Images, Volumes, and similar API lists return `[]` when empty instead of `null`.
- **Guest helper leftovers** — interrupted guest setup commands no longer leave behind `calf-guestcmd-*` containers; calf retries cleanup and prunes them on engine start.
- **Anonymous alpine leftovers on macOS** — guest mount setup no longer leaves nameless helper containers behind after a socket blip. Corrupt engine entries that show in `docker ps` but cannot be inspected are cleaned up when the engine starts.

### Changed

- **`verify-docker-cli`** — uses `docker compose` when available, otherwise falls back to `docker-compose`, and counts compose step failures correctly.

## [1.0.6] - 2026-08-15

### Changed

- **Containers list** — compose group rows show Start all when every container is stopped, and Stop all when any are running.

## [1.0.5] - 2026-08-14

### Fixed

- **Build history** — Builds list syncs from the engine guest on macOS, so missing or broken host Docker Desktop buildx plugins no longer block history import.
- **Containers list** — child rows under an expanded compose group vertically center the container icon and action buttons.

## [1.0.4] - 2026-08-14

### Fixed

- **Containers list** — containers stay on screen during a brief engine connection blip, instead of vanishing and coming back.

## [1.0.3] - 2026-08-14

### Fixed

- **Debug switch** — turning Debug on or off no longer restarts the container engine.
- **HTTP proxy** — applying proxy settings no longer kills the engine helper mid-run.

## [1.0.2] - 2026-08-14

### Added

- **Debug logs** — Settings has a Debug switch. When it is on, a bug button appears in the top bar so you can copy daemon logs and send them when reporting a problem.

## [1.0.1] - 2026-08-14

### Changed

- **Update available dialog** — clearer layout with version chips (current → latest); no release notes in the prompt.
- **Settings → Updates** — shows that a version is available with download only; no changelog text.
- **Update prompts** — no “Skip this version”; users can choose Later and will be reminded again.

## [1.0.0] - 2026-07-25

### Added

- **Clean unused data** — Troubleshoot opens a clean screen that previews reclaimable stopped containers, unused images, unused volumes, unused networks, and build cache, then removes only the categories you select (same idea as `docker system prune -a --volumes`).
- **macOS Help menu** — Troubleshoot is available from Help in the native menu bar.
- **Global search** — ⌘K (Ctrl+K on Linux/Windows) opens a palette to find and jump to containers, images, volumes, networks, and builds.
- **Disk usage on Clean unused data** — the clean screen shows an Images / Containers / Local Volumes / Build Cache Size and Reclaimable breakdown (same idea as `docker system df`) above the prune categories.

### Changed

- **Overflow menus** — three-dot and contextual menus use a shared bordered surface matching dialogs and panels.
- **Typography** — UI uses Geist; logs and code use Geist Mono.

### Fixed

- **Published port links** — clicking a host port in the containers list opens `https://` when the app speaks TLS (for example `npm run start:https`), instead of always using `http://`.
- **Engine stop/kill, status, purge, and factory reset errors** — these now show a clear message instead of raw internal error text when the operation fails.
- **Deep links from search** — opening a container, image, volume, network, or build from global search no longer crashes with a build-phase `setState` error.
- **`docker compose` “Cannot connect to the Docker daemon”** — large Compose projects no longer overwhelm the engine socket. calf keeps a queued proxy on `docker.sock` instead of pointing the CLI straight at the guest, so parallel image checks wait instead of failing.
- **Containers list timing out** — with many containers the list often failed after 5 seconds. calf now reuses recent list results inside the engine and the UI waits longer for big lists.
- **False “port in use” warnings for published ports** — when nginx (or any container) publishes 80/443, calf no longer shows red errors claiming localhost is blocked. Those ports are already forwarded by calf’s network proxy.
- **Host bind mounts under your home folder** — macOS now shares your home directory into the VM, so `docker` / Compose binds like `/Users/.../project` see real files (and file mounts work). Before, those paths became empty folders on the guest disk and many apps failed to start.
- **Docker CLI socket after Resource Saver / app restart** — calf keeps owning `docker.sock` as a real proxy socket, so `docker` / `compose` no longer hit EOF when the engine was stopped or the app restarted. The first CLI command while idle wakes the engine.
- **Docker CLI required on macOS** — start error now tells you to install the CLI with `brew install docker` (Docker Desktop is not required).
- **macOS engine libraries** — release builds bundle libkrun GPU dependencies (libepoxy, virglrenderer, MoltenVK) so Start engine works without Homebrew.
- **macOS engine first start** — calf finds `calf-guest-disk-*` across GitHub releases when the current tag is missing it, checks free disk space before extracting (~40 GB), and shows a clearer error when start fails for those reasons. First-run download can take longer without aborting the boot wait.
- **macOS app icon** — follows Apple's 824×824 grid on a 1024 canvas with transparent corners outside the rounded icon.

## [0.9.20] - 2026-08-12

### Fixed

- **`docker compose` “Cannot connect to the Docker daemon”** — large Compose projects no longer overwhelm the engine socket. calf keeps a queued proxy on `docker.sock` instead of pointing the CLI straight at the guest, so parallel image checks wait instead of failing.

## [0.9.19] - 2026-08-12

### Fixed

- **Containers list timing out** — with many containers the list often failed after 5 seconds. calf now reuses recent list results inside the engine and the UI waits longer for big lists.

## [0.9.18] - 2026-08-12

### Fixed

- **False “port in use” warnings for published ports** — when nginx (or any container) publishes 80/443, calf no longer shows red errors claiming localhost is blocked. Those ports are already forwarded by calf’s network proxy.

## [0.9.17] - 2026-08-12

### Fixed

- **Host bind mounts under your home folder** — macOS now shares your home directory into the VM, so `docker` / Compose binds like `/Users/.../project` see real files (and file mounts work). Before, those paths became empty folders on the guest disk and many apps failed to start.

## [0.9.16] - 2026-08-12

### Fixed

- **Docker compose EOF / stale docker.sock** — while the engine is running, calf points the CLI socket straight at the guest (no extra proxy hop). After stop or a broken symlink from an upgrade, it restores wake-on-connect listen mode and repairs the path every few seconds.

## [0.9.15] - 2026-08-12

### Fixed

- **Docker CLI socket after Resource Saver / app restart** — calf keeps owning `docker.sock` as a real proxy socket (no hand-off symlink), so `docker` / `compose` no longer hit EOF when the engine was stopped or the app restarted.

## [0.9.14] - 2026-08-12

### Fixed

- **Docker CLI during Resource Saver** — `docker` / `docker compose` against calf still work when the engine is idle: the first command wakes the engine instead of failing because the socket was missing.

## [0.9.13] - 2026-08-12

### Fixed

- **Docker CLI required on macOS** — start error now tells you to install the CLI with `brew install docker` (Docker Desktop is not required).
- **macOS engine libraries** — release builds bundle libkrun GPU dependencies (libepoxy, virglrenderer, MoltenVK) so Start engine works without Homebrew.

## [0.9.12] - 2026-08-11

### Fixed

- **macOS engine first start** — calf finds `calf-guest-disk-*` across GitHub releases when the current tag is missing it, checks free disk space before extracting (~40 GB), and shows a clearer error when start fails for those reasons. First-run download can take longer without aborting the boot wait.

## [0.9.11] - 2026-08-11

### Fixed

- **macOS app icon size** — icon follows Apple's 824×824 grid on a 1024 canvas so it matches other Launchpad and Dock icons.

## [0.9.10] - 2026-08-11

### Fixed

- **macOS app icon** — corners outside the rounded icon are now transparent (no black square behind the icon).

## [0.9.9] - 2026-07-24

### Security

- **Local API bind** — the daemon listens on `127.0.0.1:8765` by default (not all interfaces); CORS and WebSocket origins accept only localhost. Existing configs that still used `:8765` or `0.0.0.0:8765` are migrated to loopback on load.
- **Volume export paths** — local-file exports reject absolute or `..` file names and require an absolute destination folder under the chosen path.
- **Volume file browser** — paths with `.` or `..` segments are rejected so browsing cannot leave the volume.

### Added

- **Volume containers in use** — Container names in a volume's Container in-use tab open that container's detail.
- **Build logs toolbar** — Build detail Logs tab has list / plain-text toggles, expand and collapse all steps, and copy to clipboard.
- **Build logs timeline** — List view shows a fixed duration ruler with a marker for the build time window matching the scrolled log position (when the build lasted more than 0s).
- **Build dependency actions** — Dependencies rows include a menu to open the image on Docker Hub.
- **Build result download** — Build results rows include a menu to download the artifact as `sha256_<digest>.json`.
- **Build row icons** — Dependencies and Build results show custom icons (chain / provenance telescope), with a generic placeholder when the type is unknown.
- **Resource Saver** — Settings → System can enable idle engine shutdown after no containers have been running (30 seconds, then every 5 minutes up to 60 minutes; default on at 5 minutes); the status bar shows Resource Saver mode while the engine is paused.
- **Troubleshoot** — the engine menu opens a Troubleshoot view to restart calf, get support, purge engine data, reset to factory defaults, or uninstall.
- **Disk image settings** — Settings → System includes a disk image size slider and a disk image location field (default `~/.config/calf/guest/<vm>/disk.raw`).
- **Engine status bar** — Start/Stop are a single play/pause control; the overflow menu covers sign-in, Settings, Troubleshoot, About, Docker Hub, updates, Restart, and Quit.
- **Container Stats history** — Stats keep a rolling ~15 minute resource history while the engine is running, so charts survive leaving and reopening a container; history is cleared when the container is removed.
- **Destructive action confirms** — deleting containers, images, volumes, or networks, and Kill engine, ask for confirmation first.
- **Start engine from empty lists** — when the runtime is stopped, empty resource lists offer a Start engine button.

### Changed

- **Volumes list** — Volumes updates on the same poll interval as Containers, Images, Networks, and Builds (no manual refresh control).
- **Action feedback** — Checking for updates, Docker Desktop migration, engine start/stop, deletes, sign-out, exports/downloads, and copy-to-clipboard show calf-styled confirmation toasts (stacked bottom-right) with a close button.
- **Build logs steps** — Expandable log steps show a chevron (down when collapsed, up when expanded).
- **Build timing charts** — Info tab timing matches Docker Desktop: titled pies in one row (2×2 when narrow), one shared legend, and a start/end/steps summary underneath.
- **Theme switching** — light/dark transitions use one shared timing; borders and surfaces no longer lag behind the rest of the UI.
- **Theme settings** — Light, Dark, and System use preview cards instead of plain radios.
- **Mounts tab** — mount rows open bind paths in the system file manager and copy the host path.
- **UI toolkit** — the app uses Material Design 3 for theme and controls; the previous shadcn-based UI kit is gone. Icons use Lucide.
- **Settings** — Close control to leave Settings; clearer selected sidebar color; sidebar collapse control stays lightly visible.
- **Resource lists** — shared search, loading spinner, centered empty states, and consistent Remove actions across Images, Volumes, Networks, and Builds.
- **What's New** — shows GitHub release notes for the installed version as rendered markdown; notes are cached so the dialog opens quickly after the first load (with a link to Releases when offline).
- **About** — logo-first layout with GitHub, Docs, and Report issue links.
- **Status bar** — tapping RAM/CPU/Disk opens Settings.

### Fixed

- **Troubleshoot Restart calf** — in development mode (external daemon), Restart explains that the backend must be restarted manually instead of claiming the app restarted.
- **Deep links** — opening a container or image from another screen waits until the list has a match instead of dropping the pending target.
- **Daemon crash loop** — restart attempts only reset after the daemon stays up for 30 seconds, so a crashing binary hits the restart limit.
- **Docker Hub Sign in** — brief network errors during browser sign-in keep polling instead of closing the dialog; Cancel ends the server session.
- **Restart labels** — Troubleshoot Restart calf restarts the daemon; tray Restart Engine only restarts the container engine.
- **Status when daemon dies** — silent list polls and the status bar show an error after repeated failures instead of a stale “running” snapshot.
- **Published port label** — container detail shows the real host:container mapping.
- **Update check** — skipped when the app version is unavailable so it does not report a fake update.
- **Compose group detail** — closes when every container in the group is gone.
- **Build history memory** — in-memory build history is capped like on-disk history.
- **Builds on quit** — in-flight builds cancel when the daemon shuts down.
- **Docker Hub login hang** — OAuth HTTP calls use a timeout; missing `expires_in` defaults to 15 minutes.
- **Engine start errors** — failed Start returns a clear message without leaking internal paths.
- **Build timing chart tooltip** — hovering the Info tab timing chart no longer crashes the UI.
- **Build logs toolbar** — switching to plain-text view hides expand/collapse without shifting the other toolbar buttons.
- **Build logs step bars** — per-step duration bars on the right are removed; the fixed timeline ruler covers that role.
- **Build dependency digests** — Dependencies show the image digest when the local image is available.
- **Build source details** — the Info tab no longer repeats the Dockerfile path under both File name and Dockerfile.
- **Compose group containers** — each container shows a status dot (with tooltip), links to its image detail, and opens published ports in the browser when clicked.
- **Containers list** — each container links to its image detail; published ports show as `localhost` links (one plus a `(N)` expand control when there are several), each opening in the browser.
- **Docker Hub Sign in** — Sign in no longer fails with "method not allowed".
- **Docker Hub account** — after browser sign-in, the UI shows your username instead of staying on Sign in (credentials stored in the macOS keychain are detected).
- **Docker Hub Sign in dialog** — the login page opens only when you click Open login page, not when the dialog appears.
- **Docker Hub account chip** — when signed in, the top bar shows a truncated username next to the avatar.
- **Guest disk arch on Apple Silicon** — when the Go toolchain runs under Rosetta, calf still selects the arm64 guest disk instead of looking for an amd64 asset.
- **Engine start** — starting gvproxy no longer fails when its pid file is written a moment after the process starts.
- **Status polling** — engine RAM/disk stats use fast host probes so `/v1/status` stays responsive for the UI.
- **Engine status bar** — the bar also shows live engine CPU usage.
- **Engine RAM/CPU** — status bar RAM and CPU use the macOS process API (not `/bin/ps`), so values stay correct when the daemon runs under an IDE sandbox that blocks `ps`.
- **Engine Start/Stop/Kill** — bottom-bar engine actions wait long enough for a slow VM boot, and failed actions no longer crash when showing an error.
- **Engine Stop** — Stop from the status bar always shuts down the engine; keep-alive only leaves the VM running when you quit calf.
- **Engine status feedback** — while Start, Stop, or Kill is in progress, the status bar shows a spinner and a starting/stopping/killing label.
- **Published ports after restart** — reopening calf no longer spams gvproxy errors when a port forward was already active from the previous session.
- **Settings save errors** — failed Apply now shows an error instead of failing silently.
- **Registry sign-in errors** — Docker Hub status, sign-in, and sign-out failures show a message in the UI.
- **Dark theme errors** — error text is readable on dark backgrounds.
- **Dialog borders** — confirmation and other modals use the same outlined edge as About, so they stay visible on light and dark surfaces.
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

- **Public benchmarks** — the primary `BENCHMARKS.md` table now uses the vfkit engine (calf leads or ties OrbStack on every metric on the reference Mac); Lima numbers move to a legacy section.

## [0.9.5] - 2026-07-19

### Added

- **Experimental fast-boot engine (macOS)** — when a provisioned vfkit guest disk (or release seed) and `vfkit` binary are present, calf prefers that engine automatically; bundled apps download `calf-vfkit-disk-<arch>.raw.zst` from GitHub Releases on first start; build locally with `make guest-vfkit` (see `BENCHMARKS.md`).
- **Runtime start API** — `POST /v1/runtime/start` boots the container runtime while the daemon stays up (used for fair VM-boot benches on vfkit).

### Changed

- **Lima startup** — the Docker API can become ready before Lima finishes its SSH/boot-script gates, so the engine is usable sooner after a full VM stop.

## [0.9.4] - 2026-07-18

### Added

- **Performance benchmarks** — macOS comparison of calf vs Docker Desktop vs OrbStack (startup, Compose, bind-mount I/O, idle memory), with reproduction steps in `BENCHMARKS.md`.
- **Menu bar / system tray icon** — calf shows the white calf logo in the macOS menu bar and Windows notification area while the app is running; the tray menu lists running containers, Help links (repository, report issue, restart, updates), Docker Hub sign-in, Settings, and Quit; removed on **calf → Quit**.
- **Buildx builds** — image builds inside the VM use Docker Buildx with BuildKit, including cross-architecture builds via Rosetta when a platform is set.
- **Rootless on Linux** — when `rootless: true` (default), calf prefers a user Docker engine when available and falls back to the system engine if none is present; ignored on macOS/Windows (Lima).

### Fixed

- **Linux packaging** — Linux release builds install AppIndicator so the system tray can compile; the `.deb` package declares the matching runtime library.
- **Benchmark reliability** — cold-start measurements now use the compiled daemon, correct Docker contexts, and no longer fail when Docker Desktop is installed.
- **VM startup polling** — faster engine readiness checks during Lima boot reduce time-to-ready after the VM is running.

### Changed

- **Lima cold start** — the Docker-compatible API is available sooner during VM boot via a lightweight readiness probe instead of a full engine info round-trip; Buildx setup no longer blocks engine readiness.
- **VM keep-alive** — on macOS and Windows, quitting calf leaves the Lima VM running so the next calf launch reaches a ready engine in under 2 seconds (configurable via `vm_keep_alive`). With keep-alive enabled, the VM also starts automatically at login via Lima; `docker` against the calf context is ready once the calf app is running again (typically under 2 seconds when the VM was already up).
- **Cold-start target** — the fair stop→start benchmark target is under 20 seconds (calf measures ~16 s on the reference Mac, ahead of Docker Desktop); keep-alive reopen is documented separately and is not used as that metric.

## [0.9.3] - 2026-07-12

### Changed

- **Settings validation** — CPU, memory, and proxy values are checked on the server before they are saved.
- **Startup port handling** — calf only reclaims the listen port from another calf instance, not unrelated processes.

### Fixed

- **Shutdown** — background migration and Docker Hub sign-in stop cleanly when the app closes.
- **Error messages** — container operations no longer expose low-level runtime output in API responses.

## [0.9.2] - 2026-07-09

### Added

- **Update notifications** — calf checks for updates on launch and in Settings, shows when a newer version is available, and opens the right installer for your platform.
- **macOS menu bar** — Settings, section navigation, Docker Hub sign-in, update checks, and help links are available from the native menu bar.
- **Open at login** — optional setting in Settings to start calf automatically when you sign in.
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

- **Cross-platform support** — calf now runs on Linux, macOS, and Windows.
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
