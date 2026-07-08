# Calf

A fast, lightweight alternative to Docker Desktop for running and managing containers on your machine, without the overhead of a full desktop stack.

## Quick start

```bash
make help          # list commands
make dev-backend   # terminal 1: API on :8765
make dev-ui        # terminal 2: macOS app
```

See [DEVELOPMENT.md](DEVELOPMENT.md) for configuration and migration from Docker Desktop.

## Installation

### macOS

The `.dmg` and `.pkg` installers are unsigned during the development phase. To install Calf on macOS without security warnings, use our Homebrew Tap with the `--no-quarantine` flag:

```bash
brew tap enegalan/calf-homebrew https://github.com/enegalan/calf-homebrew
brew install --cask --no-quarantine calf
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
  chmod +x Calf-<version>-x86_64.AppImage
  ./Calf-<version>-x86_64.AppImage
  ```

## License

MIT — see [LICENSE](LICENSE).
