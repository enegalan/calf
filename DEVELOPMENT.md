## Quick start

**1. Start Calf** (runtime + API):

```bash
make backend
./bin/calf start
export DOCKER_HOST=unix://$HOME/.config/calf/docker.sock
```

**2. Start the UI** (in another terminal):

```bash
cd ui
flutter pub get
flutter run
```

Pick a device when prompted (`chrome`, `macos`, etc.). The UI calls the API on startup and shows daemon status.

For development without the full runtime:

```bash
cd backend
go run ./cmd/calf serve
```

## Configuration

On first run the daemon creates `~/.config/calf/config.yaml` with defaults:

```yaml
listen_addr: ":8080"
log_level: info
vm_name: calf
docker_socket: ""
```

## Build

Build the daemon and macOS UI from the repository root:

```bash
make build
```

Artifacts:

- `bin/calf` — CLI and daemon binary
- `ui/build/macos/Build/Products/Release/ui.app` — macOS app bundle

Build individually:

```bash
make backend
make ui
```

## CLI

```bash
calf start    # start Lima VM/runtime and daemon
calf stop     # stop daemon and runtime
calf status   # show runtime and daemon state
calf serve    # run API daemon only
```

## Migrating from Docker Desktop

1. Export images you need:

```bash
docker save my-image:latest -o my-image.tar
```

2. Stop Docker Desktop.

3. Install [Lima](https://github.com/lima-vm/lima) on macOS if needed.

4. Start Calf:

```bash
calf start
export DOCKER_HOST=unix://$HOME/.config/calf/docker.sock
```

5. Import images:

```bash
docker load -i my-image.tar
```

6. Point your tools at Calf:

```bash
export DOCKER_HOST=unix://$HOME/.config/calf/docker.sock
```

7. Verify:

```bash
docker run hello-world
```

## Examples

See [`examples/hello-world/`](examples/hello-world/).
