#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DOCKER_HOST:-}" ]]; then
  export DOCKER_HOST="unix://${HOME}/.config/calf/docker.sock"
fi

commands=(
  "docker ps"
  "docker images"
  "docker run --rm hello-world"
  "docker pull alpine:3.20"
  "docker build -t calf-verify examples/hello-world"
  "docker run --rm calf-verify"
)

for command in "${commands[@]}"; do
  echo "==> ${command}"
  eval "${command}"
done

echo "All P0 Docker CLI checks passed."
