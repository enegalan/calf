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
vm_keep_alive: true
rootless: true
```

`vm_keep_alive` (default `true` on macOS/Windows) leaves the Lima VM running when Calf quits so the next launch is a warm start, and registers the instance with `limactl start-at-login` so the VM also boots at host login after a reboot. The host Docker socket is torn down on quit and restored when the Calf daemon starts again — Lima login autostart alone does not make `docker` work. Set `vm_keep_alive` to `false` to stop the VM on quit and disable login autostart.

`rootless` (default `true`) applies on **Linux** only. When enabled, Calf prefers a user-owned Docker socket (`$XDG_RUNTIME_DIR/docker.sock`, then `~/.docker/run/docker.sock`) and points `nerdctl` at it via `DOCKER_HOST`. If no user socket exists, it falls back to `/var/run/docker.sock`. Set `rootless: false` to always use the system socket. On macOS and Windows the container engine runs inside Lima (rootful guest Docker); the host Calf process stays user-level either way. Restart the daemon after changing `rootless`.

## Image and build cache

Images, volumes, and BuildKit layers live on the Lima VM disk. They survive:

- Quitting and reopening the Calf app
- Stopping and starting the Lima VM (`limactl stop` / `limactl start`)

They are wiped if the VM instance is deleted (for example `limactl delete calf`, or a disk-size change that recreates the instance). To inspect or free space, use the Docker CLI (`docker system df`, `docker builder prune`, `docker image prune`).

## Build

Build the macOS UI from the repository root:

```bash
make build
```

Artifact: `ui/build/macos/Build/Products/Release/ui.app`

Linux UI builds need Flutter’s usual GTK toolchain plus AppIndicator (used by the system tray):

```bash
sudo apt-get install -y clang cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev libayatana-appindicator3-dev
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

Or run the full P0 smoke test (daemon must already be running):

```bash
make verify-docker-cli
```
