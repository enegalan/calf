## Quick start

**1. Start the API** (port `8080`):

```bash
cd backend
go run ./cmd/calf
```

**2. Start the UI** (in another terminal):

```bash
cd ui
flutter pub get
flutter run
```

Pick a device when prompted (`chrome`, `macos`, etc.). The UI calls the API on startup and shows daemon status.

## Configuration

On first run the daemon creates `~/.config/calf/config.yaml` with defaults:

```yaml
listen_addr: ":8080"
log_level: info
```
