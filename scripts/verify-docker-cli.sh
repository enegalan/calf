#!/usr/bin/env bash
# Smoke-test docker CLI commands against a running Calf daemon.
# Prerequisites: make dev-backend (or calf daemon) and DOCKER_HOST pointing at Calf.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="${ROOT_DIR}/examples/hello-world"

DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.config/calf/docker.sock}"
export DOCKER_HOST

CALF_WAIT_SECONDS="${CALF_WAIT_SECONDS:-180}"
RUN_ID="calf-verify-$$"
CONTAINER="${RUN_ID}-web"
VOLUME="${RUN_ID}-vol"
NETWORK="${RUN_ID}-net"
BUILD_TAG="${RUN_ID}:test"
COMPOSE_PROJECT="${RUN_ID}"

PASS=0
FAIL=0
FAILED_STEPS=()

log() {
  printf '==> %s\n' "$*"
}

pass() {
  PASS=$((PASS + 1))
  printf 'OK: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILED_STEPS+=("$1")
  printf 'FAIL: %s\n' "$1" >&2
}

run_step() {
  local name="$1"
  shift
  log "$name"
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "required command not found: $1" >&2
    exit 1
  fi
}

output_contains() {
  local pattern="$1"
  shift
  grep -qx "$pattern" < <("$@")
}

wait_for_docker() {
  local start=$SECONDS
  while (( SECONDS - start < CALF_WAIT_SECONDS )); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    printf 'waiting for Calf Docker socket (%s)...\n' "$DOCKER_HOST"
    sleep 3
  done
  echo "timed out after ${CALF_WAIT_SECONDS}s waiting for docker socket" >&2
  echo "start the daemon first: make dev-backend" >&2
  if curl -sf "${CALF_API:-http://127.0.0.1:8765}/v1/status" >/dev/null 2>&1; then
    echo "calf API is up; last docker error:" >&2
    docker info 2>&1 | tail -n 3 >&2 || true
  fi
  return 1
}

cleanup() {
  log "cleaning up test resources"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  docker rmi "$BUILD_TAG" >/dev/null 2>&1 || true
  if [[ -d "$EXAMPLE_DIR" ]]; then
    (
      cd "$EXAMPLE_DIR"
      docker compose -p "$COMPOSE_PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
    )
  fi
}

trap cleanup EXIT

require_command docker

if [[ ! -d "$EXAMPLE_DIR" ]]; then
  echo "missing example project: $EXAMPLE_DIR" >&2
  exit 1
fi

log "using DOCKER_HOST=$DOCKER_HOST"
log "preflight: docker info"
if ! wait_for_docker; then
  exit 1
fi
pass "preflight: docker info"

run_step "docker pull hello-world" docker pull hello-world
run_step "docker images" output_contains 'hello-world' docker images --format '{{.Repository}}'
run_step "docker run hello-world" docker run --rm hello-world

run_step "docker run -d (alpine)" docker run -d --name "$CONTAINER" alpine:3.20 sleep 300
run_step "docker ps" output_contains "$CONTAINER" docker ps --format '{{.Names}}'
run_step "docker inspect container" output_contains 'true' docker inspect "$CONTAINER" --format '{{.State.Running}}'
run_step "docker logs" docker logs "$CONTAINER" >/dev/null
run_step "docker exec" output_contains 'ok' docker exec "$CONTAINER" sh -c 'echo ok'
run_step "docker stop" docker stop "$CONTAINER"
run_step "docker rm" docker rm "$CONTAINER"
CONTAINER="${RUN_ID}-removed"

run_step "docker volume create" docker volume create "$VOLUME"
run_step "docker volume ls" output_contains "$VOLUME" docker volume ls --format '{{.Name}}'
run_step "docker volume rm" docker volume rm "$VOLUME"
VOLUME="${RUN_ID}-removed"

run_step "docker network create" docker network create "$NETWORK"
run_step "docker network ls" output_contains "$NETWORK" docker network ls --format '{{.Name}}'
run_step "docker network rm" docker network rm "$NETWORK"
NETWORK="${RUN_ID}-removed"

run_step "docker build" docker build -t "$BUILD_TAG" "$EXAMPLE_DIR"
run_step "docker rmi built image" docker rmi "$BUILD_TAG"
BUILD_TAG="${RUN_ID}-removed"

(
  cd "$EXAMPLE_DIR"
  run_step "docker compose up" docker compose -p "$COMPOSE_PROJECT" up -d --build
  run_step "docker compose ps" output_contains 'app' docker compose -p "$COMPOSE_PROJECT" ps --services
  run_step "docker compose down" docker compose -p "$COMPOSE_PROJECT" down -v --remove-orphans
)

run_step "docker rmi hello-world" docker rmi hello-world

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'Failed steps:\n' >&2
  for step in "${FAILED_STEPS[@]}"; do
    printf '  - %s\n' "$step" >&2
  done
  exit 1
fi
