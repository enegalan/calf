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

The `.dmg` and `.pkg` installers are unsigned during the development phase. To install calf on macOS, run this single command to install the application:

```bash
brew install --cask enegalan/calf/calf
```

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
