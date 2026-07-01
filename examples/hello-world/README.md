# Hello World example

```bash
export DOCKER_HOST=unix://$HOME/.config/calf/docker.sock
docker build -t calf-hello .
docker run --rm calf-hello
```

Expected output:

```
hello from calf
```
