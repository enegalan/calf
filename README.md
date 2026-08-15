<p align="left">
  <img src="ui/assets/brand/calf_logo_art.png" width="140" alt="calf" />
</p>

A fast, lightweight alternative to Docker Desktop for running and managing containers on your machine, without the overhead of a full desktop stack.

## Quick start

```bash
make help          # list commands
make dev-backend   # terminal 1: API on 127.0.0.1:8765
make dev-ui        # terminal 2: macOS app
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for configuration and migration from Docker Desktop.

## Performance

Public macOS benchmarks comparing calf with Docker Desktop and OrbStack (VM boot, Compose startup, bind-mount I/O, idle RAM) are in **[BENCHMARKS.md](BENCHMARKS.md)**. Reproduce them with `make benchmarks`.

## Installation

### macOS

On macOS, calf runs containers in its own VM. Install the **Docker CLI** and its plugins on the host (calf does not ship them):

```bash
brew install docker docker-compose docker-buildx
brew install --cask enegalan/calf/calf
```

Then open calf and leave **Use calf for Docker CLI** enabled in Settings so `docker` / `docker compose` talk to calf.

**Leaving Docker Desktop:** trashing Docker Desktop often leaves broken symlinks under `~/.docker/cli-plugins/` (for `docker-buildx` and `docker-compose`). calf detects that on startup and relinks working plugins from Homebrew, OrbStack, or PATH when it can. If Settings still shows a plugins warning, run the `brew install` line above.

The `.dmg` and `.pkg` installers are unsigned during the development phase.

### Windows

Download the `.exe` installer from the [Releases](https://github.com/enegalan/calf/releases) page and run it. The installer will guide you through the setup process and register the application.

### Linux

Download the package for your distribution from the [Releases](https://github.com/enegalan/calf/releases) page. We provide three distribution formats for Linux:

- **Debian/Ubuntu (`.deb`)**:
  ```bash
  sudo dpkg -i calf-<version>-amd64.deb
  ```
- **RedHat/Fedora (`.rpm`)**:
  ```bash
  sudo rpm -i calf-<version>-amd64.rpm
  ```
- **AppImage**:
  Make the file executable and run it:
  ```bash
  chmod +x calf-<version>-x86_64.AppImage
  ./calf-<version>-x86_64.AppImage
  ```

## License

MIT — see [LICENSE](LICENSE).
