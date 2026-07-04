## Quick start

```bash
make dev-backend   # terminal 1: daemon + runtime on :8765
make dev-ui        # terminal 2: macOS app
```

For containers via the Docker CLI, set:

```bash
export DOCKER_HOST=unix://$HOME/.config/calf/docker.sock
```

## Configuration

On first run the daemon creates `~/.config/calf/config.yaml` with defaults:

```yaml
listen_addr: ":8765"
log_level: info
vm_name: calf
docker_socket: ""
```

## Build

Build the macOS UI from the repository root:

```bash
make build
```

Artifact: `ui/build/macos/Build/Products/Release/ui.app`

## Migrating from Docker Desktop

1. Export images you need:

```bash
docker save my-image:latest -o my-image.tar
```

2. Stop Docker Desktop.

3. Install [Lima](https://github.com/lima-vm/lima) on macOS if needed.

4. Start Calf:

```bash
make dev-backend
```

5. Point your tools at Calf:

```bash
export DOCKER_HOST=unix://$HOME/.config/calf/docker.sock
```

6. Import images:

```bash
docker load -i my-image.tar
```

7. Verify:

```bash
docker run hello-world
```
