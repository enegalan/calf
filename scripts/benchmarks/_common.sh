#!/usr/bin/env bash
# Shared helpers for Calf benchmark scripts.
set -euo pipefail

# Spike LIMA_HOME overrides must not leak into fair product benches.
unset LIMA_HOME || true

BENCHMARKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${BENCHMARKS_DIR}/../.." && pwd)"
EXAMPLE_DIR="${ROOT_DIR}/examples/hello-world"

BENCHMARK_TIMEOUT="${BENCHMARK_TIMEOUT:-300}"
BENCHMARK_RUN_ID="${BENCHMARK_RUN_ID:-calf-bench-$$}"
RESULTS_DIR="${RESULTS_DIR:-${BENCHMARKS_DIR}/results}"

# Product socket paths (macOS defaults).
CALF_DOCKER_HOST="unix://${HOME}/.config/calf/docker.sock"
DOCKER_DESKTOP_HOST="unix://${HOME}/.docker/run/docker.sock"
ORBSTACK_HOST="unix://${HOME}/.orbstack/run/docker.sock"

CALF_VM_NAME="${CALF_VM_NAME:-calf}"
CALF_API="${CALF_API:-http://127.0.0.1:8765}"
BENCHMARK_MOUNT_DIR="${BENCHMARK_MOUNT_DIR:-${HOME}/.config/calf/mounts/benchmarks}"

log() {
  printf '[benchmark] %s\n' "$*" >&2
}

warn() {
  printf '[benchmark] warning: %s\n' "$*" >&2
}

require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command '$cmd' not found" >&2
    exit 1
  fi
}

now_epoch_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

elapsed_seconds() {
  local start_ms=$1
  local end_ms
  end_ms=$(now_epoch_ms)
  python3 - <<PY
start = int("${start_ms}")
end = int("${end_ms}")
print(f"{(end - start) / 1000:.2f}")
PY
}

docker_engine_ready() {
  local product=$1
  docker_cmd "$product" info 2>/dev/null | grep -q 'Server Version:'
}

wait_for_docker_host() {
  local product=$1
  local timeout=${2:-$BENCHMARK_TIMEOUT}
  local start=$SECONDS
  local retried=false
  local poll=1
  if [[ "$product" == "calf" && "${CALF_RUNTIME:-}" == "vfkit" ]]; then
    poll=0.2
  fi
  while (( SECONDS - start < timeout )); do
    if docker_engine_ready "$product"; then
      return 0
    fi
    if [[ "$retried" == "false" && $(( SECONDS - start )) -gt 60 ]]; then
      case "$product" in
        docker_desktop | orbstack)
          warn "$(product_label "$product") engine slow; retrying app launch"
          restart_product "$product"
          retried=true
          ;;
      esac
    fi
    sleep "$poll"
  done
  return 1
}

wait_for_docker_host_down() {
  local product=$1
  local timeout=${2:-120}
  local start=$SECONDS
  while (( SECONDS - start < timeout )); do
    if ! docker_engine_ready "$product"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_docker_context() {
  wait_for_docker_host "$@"
}

product_docker_host() {
  local product=$1
  case "$product" in
    calf) echo "$CALF_DOCKER_HOST" ;;
    docker_desktop) echo "$DOCKER_DESKTOP_HOST" ;;
    orbstack) echo "$ORBSTACK_HOST" ;;
    *) return 1 ;;
  esac
}

product_installed() {
  local product=$1
  case "$product" in
    calf)
      [[ -S "${HOME}/.config/calf/docker.sock" ]] || command -v limactl >/dev/null 2>&1
      ;;
    docker_desktop)
      [[ -d "/Applications/Docker.app" ]]
      ;;
    orbstack)
      [[ -d "/Applications/OrbStack.app" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

product_docker_context() {
  local product=$1
  case "$product" in
    calf) echo "calf" ;;
    docker_desktop) echo "desktop-linux" ;;
    orbstack) echo "orbstack" ;;
    *) return 1 ;;
  esac
}

docker_cmd() {
  local product=$1
  shift
  docker --context "$(product_docker_context "$product")" "$@"
}

product_label() {
  local product=$1
  case "$product" in
    calf) echo "Calf" ;;
    docker_desktop) echo "Docker Desktop" ;;
    orbstack) echo "OrbStack" ;;
    *) echo "$product" ;;
  esac
}

detect_hardware() {
  local cpu_model ram_bytes ram_gb macos_version macos_build arch
  cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
  ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
  ram_gb=$(python3 - <<PY
ram = int("${ram_bytes}")
print(f"{ram / (1024 ** 3):.0f}")
PY
)
  macos_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  macos_build=$(sw_vers -buildVersion 2>/dev/null || echo "unknown")
  arch=$(uname -m)
  printf 'cpu_model=%s\nram_gb=%s\nmacos_version=%s\nmacos_build=%s\narch=%s\n' \
    "$cpu_model" "$ram_gb" "$macos_version" "$macos_build" "$arch"
}

ensure_results_dir() {
  mkdir -p "$RESULTS_DIR"
}

write_result_row() {
  local run_id=$1
  local product=$2
  local metric=$3
  local value=$4
  local unit=$5
  local notes=${6:-}
  local outfile="${RESULTS_DIR}/results-${run_id}.tsv"
  if [[ ! -f "$outfile" ]]; then
    printf 'timestamp\tproduct\tmetric\tvalue\tunit\tnotes\n' >"$outfile"
  elif ! head -1 "$outfile" | grep -q '^timestamp'; then
    printf 'timestamp\tproduct\tmetric\tvalue\tunit\tnotes\n' | cat - "$outfile" >"${outfile}.tmp" && mv "${outfile}.tmp" "$outfile"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "$product" "$metric" "$value" "$unit" "$notes" >>"$outfile"
  echo "$outfile"
}

preflight_docker() {
  local product=$1
  docker_cmd "$product" run -d --name "${BENCHMARK_RUN_ID}-preflight" alpine:3.20 sleep 1 >/dev/null 2>&1 \
    && docker_cmd "$product" wait "${BENCHMARK_RUN_ID}-preflight" >/dev/null 2>&1 \
    && docker_cmd "$product" rm -f "${BENCHMARK_RUN_ID}-preflight" >/dev/null 2>&1
}

stop_other_products() {
  local keep=$1
  local product
  for product in calf docker_desktop orbstack; do
    if [[ "$product" != "$keep" ]]; then
      stop_product "$product" || true
    fi
  done
}

stop_product() {
  local product=$1
  log "stopping $(product_label "$product")"
  case "$product" in
    calf)
      if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
        # Lima start-at-login fights vfkit benches (second Virtualization RSS + CPU).
        disable_lima_autostart_calf
        # Avoid `limactl stop -f` here: it can hang when the hostagent is wedged.
        pkill -9 -x limactl >/dev/null 2>&1 || true
        if [[ -f "${HOME}/.config/calf/vfkit/${CALF_VM_NAME}/vfkit.pid" ]]; then
          kill -9 "$(cat "${HOME}/.config/calf/vfkit/${CALF_VM_NAME}/vfkit.pid" 2>/dev/null)" >/dev/null 2>&1 || true
        fi
        pkill -9 -x vfkit >/dev/null 2>&1 || true
        wait_for_vfkit_gone 30 || true
        sleep 1
      elif command -v limactl >/dev/null 2>&1; then
        env -u LIMA_HOME limactl stop "$CALF_VM_NAME" >/dev/null 2>&1 || true
      fi
      stop_calf_daemon
      ;;
    docker_desktop)
      osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
      wait_for_docker_host_down docker_desktop 120 || true
      ;;
    orbstack)
      osascript -e 'quit app "OrbStack"' >/dev/null 2>&1 || true
      wait_for_docker_host_down orbstack 120 || true
      ;;
  esac
}

# wait_for_vfkit_gone waits until the vfkit process has exited, then drains briefly.
wait_for_vfkit_gone() {
  local timeout=${1:-30}
  local start=$SECONDS
  while (( SECONDS - start < timeout )); do
    if ! pgrep -x vfkit >/dev/null 2>&1; then
      sleep 0.5
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# disable_lima_autostart_calf unloads the Lima start-at-login agent for the Calf VM.
disable_lima_autostart_calf() {
  local plist="${HOME}/Library/LaunchAgents/io.lima-vm.autostart.${CALF_VM_NAME}.plist"
  if [[ -f "$plist" ]]; then
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  fi
}

# enable_lima_autostart_calf restores the Lima start-at-login agent if the plist exists.
enable_lima_autostart_calf() {
  local plist="${HOME}/Library/LaunchAgents/io.lima-vm.autostart.${CALF_VM_NAME}.plist"
  if [[ -f "$plist" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  fi
}


# enable_lima_autostart_calf restores the Lima start-at-login agent if the plist exists.
enable_lima_autostart_calf() {
  local plist="${HOME}/Library/LaunchAgents/io.lima-vm.autostart.${CALF_VM_NAME}.plist"
  if [[ -f "$plist" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  fi
}

start_product() {
  local product=$1
  case "$product" in
    calf)
      if ! curl -sf "${CALF_API}/v1/health" >/dev/null 2>&1; then
        start_calf_daemon >/dev/null || return 1
      fi
      if command -v limactl >/dev/null 2>&1; then
        limactl start "$CALF_VM_NAME" >/dev/null 2>&1 || true
      fi
      ;;
    docker_desktop)
      open -ga Docker
      ;;
    orbstack)
      open -ga OrbStack
      ;;
  esac
}

# restart_product issues another open after a failed engine wait (Docker Desktop can ignore a rapid relaunch).
restart_product() {
  local product=$1
  case "$product" in
    docker_desktop | orbstack)
      stop_product "$product"
      sleep 3
      start_product "$product"
      ;;
    *)
      start_product "$product"
      ;;
  esac
}

ensure_calf_daemon() {
  if curl -sf "${CALF_API}/v1/health" >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  start_calf_daemon
}

resolve_calf_daemon_bin() {
  if [[ -n "${CALF_DAEMON_BIN:-}" && -x "${CALF_DAEMON_BIN}" ]]; then
    echo "${CALF_DAEMON_BIN}"
    return 0
  fi
  local candidates=(
    "${ROOT_DIR}/backend/calf-daemon"
    "${ROOT_DIR}/ui/build/macos/Build/Products/Release/Calf.app/Contents/MacOS/calf-daemon"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

CALF_BENCHMARK_DAEMON_PID=""

start_calf_daemon() {
  local daemon_bin=""
  CALF_BENCHMARK_DAEMON_PID=""
  if daemon_bin=$(resolve_calf_daemon_bin); then
    log "starting Calf daemon for benchmarks (${daemon_bin})"
    if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
      env CALF_RUNTIME=vfkit CALF_VFKIT_MEMORY_GB="${CALF_VFKIT_MEMORY_GB:-2}" CALF_BENCHMARK=1 \
        "$daemon_bin" >>"${RESULTS_DIR}/calf-daemon.log" 2>&1 &
    else
      "$daemon_bin" >>"${RESULTS_DIR}/calf-daemon.log" 2>&1 &
    fi
  else
    warn "calf-daemon binary not found; falling back to go run (slower, may skew cold-start)"
    (
      cd "${ROOT_DIR}/backend"
      if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
        CALF_RUNTIME=vfkit CALF_VFKIT_MEMORY_GB="${CALF_VFKIT_MEMORY_GB:-2}" CALF_BENCHMARK=1 CGO_ENABLED=0 go run ./cmd/calf
      else
        CGO_ENABLED=0 go run ./cmd/calf
      fi
    ) >>"${RESULTS_DIR}/calf-daemon.log" 2>&1 &
  fi
  CALF_BENCHMARK_DAEMON_PID=$!
  local start=$SECONDS
  local ready_timeout=60
  if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
    ready_timeout=120
  fi
  while (( SECONDS - start < ready_timeout )); do
    if curl -sf "${CALF_API}/v1/health" >/dev/null 2>&1; then
      # For vfkit, also wait until Docker API answers (daemon health is not enough).
      if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
        if curl -sf --unix-socket "${HOME}/.config/calf/docker.sock" http://localhost/_ping >/dev/null 2>&1; then
          return 0
        fi
        sleep 0.2
        continue
      else
        return 0
      fi
    fi
    sleep 0.2
  done
  kill "$CALF_BENCHMARK_DAEMON_PID" >/dev/null 2>&1 || true
  CALF_BENCHMARK_DAEMON_PID=""
  return 1
}

run_hello_world() {
  local product=$1
  local attempt
  for attempt in 1 2 3; do
    if docker_cmd "$product" run --rm hello-world >/dev/null 2>&1; then
      return 0
    fi
    if (( attempt < 3 )); then
      docker_cmd "$product" pull hello-world >/dev/null 2>&1 || true
      sleep 2
    fi
  done
  return 1
}

# run_hello_world_cached runs hello-world without pulling (for timed cold starts).
run_hello_world_cached() {
  local product=$1
  docker_cmd "$product" run --rm hello-world >/dev/null 2>&1
}

stop_calf_daemon() {
  local pid="${CALF_BENCHMARK_DAEMON_PID:-}"
  local pid_file="${HOME}/.config/calf/calf.pid"
  if [[ -z "$pid" && -f "$pid_file" ]]; then
    pid=$(tr -d '[:space:]' <"$pid_file")
  fi
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    # Only terminate a tracked, still-living PID we started (or the recorded calf.pid).
    local cmdline=""
    if [[ -r "/proc/${pid}/cmdline" ]]; then
      cmdline=$(tr '\0' ' ' <"/proc/${pid}/cmdline")
    elif command -v ps >/dev/null 2>&1; then
      cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
    fi
    if [[ -n "$cmdline" && "$cmdline" != *calf* ]]; then
      warn "refusing to kill non-calf pid ${pid}: ${cmdline}"
      CALF_BENCHMARK_DAEMON_PID=""
      return 0
    fi
    kill "$pid" >/dev/null 2>&1 || true
    local start=$SECONDS
    while (( SECONDS - start < 30 )); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi
  CALF_BENCHMARK_DAEMON_PID=""
  rm -f "$pid_file"
  rm -f "${HOME}/.config/calf/docker.sock"
}

measure_idle_ram_mb() {
  local product=$1
  local pattern
  case "$product" in
    calf)
      if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
        # Exclude limactl: vfkit path must not count a leftover Lima VM.
        pattern='/exe/calf|calf-daemon|vfkit$|Virtualization\.VirtualMachine'
      else
        pattern='/exe/calf|calf-daemon|vfkit$|/limactl$|Virtualization\.VirtualMachine'
      fi
      ;;
    docker_desktop)
      pattern='com\.docker\.|Docker Desktop|docker-desktop|Virtualization\.VirtualMachine'
      ;;
    orbstack)
      pattern='OrbStack|orbstack|macvirt|Virtualization\.VirtualMachine'
      ;;
    *)
      return 1
      ;;
  esac
  # Pipe ps via stdin — putting the full process table in an env var truncates on macOS.
  ps -axo rss,comm | PATTERN="$pattern" python3 -c '
import os, re, sys
pattern = re.compile(os.environ["PATTERN"], re.I)
total_kb = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) != 2 or not parts[0].isdigit():
        continue
    if pattern.search(parts[1]):
        total_kb += int(parts[0])
print(f"{total_kb / 1024:.0f}")
'
}

parse_dd_mbps() {
  local line
  if [[ $# -gt 0 ]]; then
    line=$1
  else
    line=$(cat)
  fi
  DD_LINE="$line" python3 - <<'PY'
import os
import re

line = os.environ.get("DD_LINE", "").strip()
# Prefer bytes + seconds (most accurate); report MiB/s.
match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*seconds", line)
bytes_match = re.search(r"([0-9]+)\s*bytes", line)
if match and bytes_match:
    seconds = float(match.group(1))
    num_bytes = int(bytes_match.group(1))
    if seconds > 0:
        print(f"{(num_bytes / seconds) / (1024 * 1024):.1f}")
        raise SystemExit(0)
# Decimal MB/s and GB/s from dd → MiB/s.
match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*MB/s", line)
if match:
    print(f"{float(match.group(1)) * 1_000_000 / (1024 * 1024):.1f}")
    raise SystemExit(0)
match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*GB/s", line)
if match:
    print(f"{float(match.group(1)) * 1_000_000_000 / (1024 * 1024):.1f}")
    raise SystemExit(0)
print("0")
PY
}

docker_ps_ids() {
  local product=$1
  local outfile=$2
  docker_cmd "$product" ps -q >"$outfile" 2>/dev/null &
  local pid=$!
  local waited=0
  while (( waited < 15 )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  : >"$outfile"
  return 1
}

ensure_product_ready() {
  local product=$1

  stop_other_products "$product"
  stop_product "$product"
  start_product "$product"
  if ! wait_for_docker_context "$product" "$BENCHMARK_TIMEOUT"; then
    warn "$(product_label "$product") docker socket unavailable"
    return 1
  fi
  if ! preflight_docker "$product"; then
    warn "$(product_label "$product") docker run preflight failed"
    return 1
  fi
  sleep 2
  return 0
}

cleanup_compose_project() {
  local product=$1
  local project=$2
  if [[ -d "$EXAMPLE_DIR" ]]; then
    (
      cd "$EXAMPLE_DIR"
      docker_cmd "$product" compose -p "$project" down -v --remove-orphans >/dev/null 2>&1 || true
    )
  fi
}
