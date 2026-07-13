#!/usr/bin/env bash
# Run Calf public benchmarks against Docker Desktop and OrbStack on macOS.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

RUN_ID="${BENCHMARK_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
PRODUCTS=()
METRICS=(vm_boot compose_up bind_mount_write bind_mount_read idle_ram cold_start)
SKIP_METRICS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --products LIST     Comma-separated: calf,docker_desktop,orbstack (default: auto-detect)
  --metrics LIST      Comma-separated metric names (default: all)
  --skip-metrics LIST Comma-separated metrics to skip
  --run-id ID         Results file suffix (default: timestamp)
  -h, --help          Show this help

Metrics:
  vm_boot             VM/engine restart until docker info succeeds
  compose_up          docker compose up -d --build (examples/hello-world)
  bind_mount_write    Sequential write throughput on a bind mount (256 MiB)
  bind_mount_read     Sequential read throughput on a bind mount (256 MiB)
  idle_ram            Approximate idle RSS for product-related processes (MB)
  cold_start          Full app stop to first successful docker run hello-world
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --products)
      IFS=',' read -ra PRODUCTS <<<"$2"
      shift 2
      ;;
    --metrics)
      IFS=',' read -ra METRICS <<<"$2"
      shift 2
      ;;
    --skip-metrics)
      IFS=',' read -ra SKIP_METRICS <<<"$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

metric_enabled() {
  local metric=$1
  if [[ ${#SKIP_METRICS[@]} -gt 0 ]]; then
    local skip
    for skip in "${SKIP_METRICS[@]}"; do
      if [[ "$skip" == "$metric" ]]; then
        return 1
      fi
    done
  fi
  local enabled
  for enabled in "${METRICS[@]}"; do
    if [[ "$enabled" == "$metric" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ ${#PRODUCTS[@]} -eq 0 ]]; then
  for candidate in calf docker_desktop orbstack; do
    if product_installed "$candidate"; then
      PRODUCTS+=("$candidate")
    fi
  done
fi

require_command docker
require_command python3
ensure_results_dir

hardware_file="${RESULTS_DIR}/hardware-${RUN_ID}.env"
detect_hardware >"$hardware_file"
log "hardware profile written to $hardware_file"
cat "$hardware_file" >&2

should_skip_product() {
  local product=$1
  if ! product_installed "$product"; then
    warn "$(product_label "$product") not installed; skipping"
    write_result_row "$RUN_ID" "$product" "availability" "skipped" "status" "not installed"
    return 0
  fi
  return 1
}

benchmark_vm_boot() {
  local product=$1
  local docker_host
  docker_host=$(product_docker_host "$product")

  stop_other_products "$product"
  stop_product "$product"

  case "$product" in
    calf)
      if ! curl -sf "${CALF_API}/v1/health" >/dev/null 2>&1; then
        start_calf_daemon >/dev/null || {
          write_result_row "$RUN_ID" "$product" "vm_boot" "skipped" "seconds" "daemon not running"
          return 0
        }
      fi
      limactl stop "$CALF_VM_NAME" >/dev/null 2>&1 || true
      wait_for_docker_host_down "$docker_host" 120 || true
      ;;
    docker_desktop | orbstack)
      wait_for_docker_host_down "$docker_host" 120 || true
      ;;
  esac

  local start_ms
  start_ms=$(now_epoch_ms)
  case "$product" in
    calf)
      limactl start "$CALF_VM_NAME" >/dev/null 2>&1 || true
      ;;
    *)
      start_product "$product"
      ;;
  esac

  if wait_for_docker_host "$docker_host" "$BENCHMARK_TIMEOUT"; then
    local seconds
    seconds=$(elapsed_seconds "$start_ms")
    log "$(product_label "$product") vm_boot=${seconds}s"
    write_result_row "$RUN_ID" "$product" "vm_boot" "$seconds" "seconds" ""
  else
    warn "$(product_label "$product") vm_boot timed out"
    write_result_row "$RUN_ID" "$product" "vm_boot" "timeout" "seconds" "exceeded ${BENCHMARK_TIMEOUT}s"
  fi
}

benchmark_compose_up() {
  local product=$1
  local docker_host
  local project="${BENCHMARK_RUN_ID}-compose-${product}"
  docker_host=$(product_docker_host "$product")
  cleanup_compose_project "$product" "$project"
  docker_cmd "$product" image rm "${project}-app" >/dev/null 2>&1 || true

  local start_ms
  start_ms=$(now_epoch_ms)
  if (
    cd "$EXAMPLE_DIR"
    docker_cmd "$product" compose -p "$project" up -d --build
  ); then
    local seconds
    seconds=$(elapsed_seconds "$start_ms")
    log "$(product_label "$product") compose_up=${seconds}s"
    write_result_row "$RUN_ID" "$product" "compose_up" "$seconds" "seconds" "examples/hello-world"
    cleanup_compose_project "$product" "$project"
  else
    write_result_row "$RUN_ID" "$product" "compose_up" "failed" "seconds" "compose command failed"
  fi
}

benchmark_bind_mount_io() {
  local product=$1
  local direction=$2
  local bench_dir="${BENCHMARK_MOUNT_DIR}/${product}"
  local container_name="${BENCHMARK_RUN_ID}-io-${product}-${direction}"
  mkdir -p "$bench_dir"
  rm -f "${bench_dir}/out" "${bench_dir}/dd.log"

  local start_ms
  start_ms=$(now_epoch_ms)
  local container_id=""
  if [[ "$direction" == "bind_mount_write" ]]; then
    container_id=$(docker_cmd "$product" run -d --name "$container_name" \
      -v "${bench_dir}:/bench" \
      alpine:3.20 \
      sh -c 'dd if=/dev/zero of=/bench/out bs=1M count=256 conv=fsync 2>/bench/dd.log')
  else
    docker_cmd "$product" run -d --name "${container_name}-seed" \
      -v "${bench_dir}:/bench" \
      alpine:3.20 \
      sh -c 'dd if=/dev/zero of=/bench/out bs=1M count=256 conv=fsync 2>/dev/null' >/dev/null 2>&1 || true
    docker_cmd "$product" wait "${container_name}-seed" >/dev/null 2>&1 || true
    docker_cmd "$product" rm -f "${container_name}-seed" >/dev/null 2>&1 || true
    container_id=$(docker_cmd "$product" run -d --name "$container_name" \
      -v "${bench_dir}:/bench" \
      alpine:3.20 \
      sh -c 'dd if=/bench/out of=/dev/null bs=1M 2>/bench/dd.log')
  fi

  docker_cmd "$product" wait "$container_id" >/dev/null 2>&1 || true
  local dd_output=""
  local tmp_log="${RESULTS_DIR}/dd-${product}-${direction}.log"
  if docker_cmd "$product" cp "${container_id}:/bench/dd.log" "$tmp_log" >/dev/null 2>&1; then
    dd_output=$(tail -1 "$tmp_log")
  fi
  docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
  rm -f "$tmp_log"
  local mbps=""
  if [[ -z "$dd_output" ]]; then
    local elapsed
    elapsed=$(elapsed_seconds "$start_ms")
    if python3 - <<PY
elapsed = float("${elapsed}")
import sys
sys.exit(0 if elapsed > 0 else 1)
PY
    then
      mbps=$(python3 - <<PY
elapsed = float("${elapsed}")
print(f"{256 / elapsed:.1f}")
PY
)
      write_result_row "$RUN_ID" "$product" "$direction" "$mbps" "MB/s" "256 MiB sequential; wall-clock fallback"
      rm -f "${bench_dir}/out"
      return 0
    fi
    write_result_row "$RUN_ID" "$product" "$direction" "failed" "MB/s" "empty dd output"
    return 0
  fi
  mbps=$(parse_dd_mbps "$dd_output")
  if [[ "$mbps" == "0" || -z "$mbps" ]]; then
    local elapsed
    elapsed=$(elapsed_seconds "$start_ms")
    mbps=$(python3 - <<PY
elapsed = float("${elapsed}")
print(f"{256 / elapsed:.1f}" if elapsed > 0 else "0")
PY
)
  fi
  log "$(product_label "$product") ${direction}=${mbps} MB/s"
  write_result_row "$RUN_ID" "$product" "$direction" "$mbps" "MB/s" "256 MiB sequential; ~/.config/calf/mounts/benchmarks"
  rm -f "${bench_dir}/out"
}

benchmark_idle_ram() {
  local product=$1
  local docker_host
  docker_host=$(product_docker_host "$product")

  local ps_file="${RESULTS_DIR}/.${product}-ps.ids"
  docker_ps_ids "$product" "$ps_file" || true
  local container_id
  while IFS= read -r container_id; do
    [[ -z "$container_id" ]] && continue
    docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
  done <"$ps_file"
  rm -f "$ps_file"
  sleep 5

  local ram_mb
  ram_mb=$(measure_idle_ram_mb "$product")
  log "$(product_label "$product") idle_ram=${ram_mb} MB"
  write_result_row "$RUN_ID" "$product" "idle_ram" "$ram_mb" "MB" "sum RSS of product processes"
}

benchmark_cold_start() {
  local product=$1
  local docker_host
  docker_host=$(product_docker_host "$product")
  local started_daemon_pid=""

  stop_other_products "$product"
  stop_product "$product"

  case "$product" in
    calf)
      wait_for_docker_host_down "$docker_host" 120 || true
      ;;
    docker_desktop | orbstack)
      wait_for_docker_host_down "$docker_host" 120 || true
      ;;
  esac

  local start_ms
  start_ms=$(now_epoch_ms)

  case "$product" in
    calf)
      if ! started_daemon_pid=$(start_calf_daemon); then
        write_result_row "$RUN_ID" "$product" "cold_start" "skipped" "seconds" "could not start daemon"
        return 0
      fi
      ;;
    *)
      start_product "$product"
      ;;
  esac

  if ! wait_for_docker_host "$docker_host" "$BENCHMARK_TIMEOUT"; then
    write_result_row "$RUN_ID" "$product" "cold_start" "timeout" "seconds" "docker socket unavailable"
    [[ -n "$started_daemon_pid" ]] && kill "$started_daemon_pid" >/dev/null 2>&1 || true
    return 0
  fi

  if docker_cmd "$product" run --rm hello-world >/dev/null 2>&1; then
    local seconds
    seconds=$(elapsed_seconds "$start_ms")
    log "$(product_label "$product") cold_start=${seconds}s"
    write_result_row "$RUN_ID" "$product" "cold_start" "$seconds" "seconds" "through first hello-world"
    docker_cmd "$product" rmi hello-world >/dev/null 2>&1 || true
  else
    write_result_row "$RUN_ID" "$product" "cold_start" "failed" "seconds" "hello-world failed"
  fi
}

for product in "${PRODUCTS[@]}"; do
  if should_skip_product "$product"; then
    continue
  fi
  log "benchmarking $(product_label "$product")"
  if metric_enabled vm_boot; then
    benchmark_vm_boot "$product"
  fi

  needs_engine=false
  if metric_enabled compose_up || metric_enabled bind_mount_write || metric_enabled bind_mount_read || metric_enabled idle_ram; then
    needs_engine=true
  fi

  if [[ "$needs_engine" == "true" ]]; then
    if ! ensure_product_ready "$product"; then
      for metric in compose_up bind_mount_write bind_mount_read idle_ram; do
        if metric_enabled "$metric"; then
          write_result_row "$RUN_ID" "$product" "$metric" "skipped" "n/a" "engine unavailable"
        fi
      done
    else
      if metric_enabled compose_up; then
        benchmark_compose_up "$product"
      fi
      if metric_enabled bind_mount_write; then
        benchmark_bind_mount_io "$product" bind_mount_write
      fi
      if metric_enabled bind_mount_read; then
        benchmark_bind_mount_io "$product" bind_mount_read
      fi
      if metric_enabled idle_ram; then
        benchmark_idle_ram "$product"
      fi
    fi
  fi

  if metric_enabled cold_start; then
    benchmark_cold_start "$product"
  fi
done

results_file="${RESULTS_DIR}/results-${RUN_ID}.tsv"
log "results written to ${results_file}"
printf '%s\n' "$results_file"
