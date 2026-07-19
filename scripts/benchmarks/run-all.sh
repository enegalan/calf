#!/usr/bin/env bash
# Run Calf public benchmarks against Docker Desktop and OrbStack on macOS.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

RUN_ID="${BENCHMARK_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
PRODUCTS=()
METRICS=(cold_start vm_boot compose_up bind_mount_write bind_mount_read idle_ram)
SKIP_METRICS=()

if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
  disable_lima_autostart_calf
  trap 'enable_lima_autostart_calf' EXIT
fi

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

  stop_other_products "$product"

  case "$product" in
    calf)
      if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
        # Daemon stays up; only the guest must be cold (mirrors limactl stop/start).
        if ! curl -sf "${CALF_API}/v1/health" >/dev/null 2>&1; then
          start_calf_daemon >/dev/null || {
            write_result_row "$RUN_ID" "$product" "vm_boot" "skipped" "seconds" "daemon not running"
            return 0
          }
        fi
        disable_lima_autostart_calf
        pkill -9 -x limactl >/dev/null 2>&1 || true
        if [[ -f "${HOME}/.config/calf/vfkit/${CALF_VM_NAME}/vfkit.pid" ]]; then
          kill -9 "$(cat "${HOME}/.config/calf/vfkit/${CALF_VM_NAME}/vfkit.pid" 2>/dev/null)" >/dev/null 2>&1 || true
        fi
        pkill -9 -x vfkit >/dev/null 2>&1 || true
        rm -f "${HOME}/.config/calf/docker.sock"
        wait_for_vfkit_gone 30 || true
        sleep 1
        wait_for_docker_host_down "$product" 120 || true
      else
        stop_product "$product"
        if ! curl -sf "${CALF_API}/v1/health" >/dev/null 2>&1; then
          start_calf_daemon >/dev/null || {
            write_result_row "$RUN_ID" "$product" "vm_boot" "skipped" "seconds" "daemon not running"
            return 0
          }
        fi
        env -u LIMA_HOME limactl stop "$CALF_VM_NAME" >/dev/null 2>&1 || true
        wait_for_docker_host_down "$product" 120 || true
      fi
      ;;
    docker_desktop | orbstack)
      stop_product "$product"
      wait_for_docker_host_down "$product" 120 || true
      ;;
  esac

  local start_ms
  start_ms=$(now_epoch_ms)
  case "$product" in
    calf)
      if [[ "${CALF_RUNTIME:-}" == "vfkit" ]]; then
        # Daemon stays up (same as limactl start with daemon already running).
        curl -sf -X POST "${CALF_API}/v1/runtime/start" >/dev/null 2>&1 || true
      else
        env -u LIMA_HOME limactl start "$CALF_VM_NAME" >/dev/null 2>&1 || true
      fi
      ;;
    *)
      start_product "$product"
      ;;
  esac

  if wait_for_docker_host "$product" "$BENCHMARK_TIMEOUT"; then
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
  else
    write_result_row "$RUN_ID" "$product" "compose_up" "failed" "seconds" "compose command failed"
  fi
  cleanup_compose_project "$product" "$project"
}

benchmark_bind_mount_io() {
  local product=$1
  local direction=$2
  local bench_dir="${BENCHMARK_MOUNT_DIR}/${product}"
  local container_name="${BENCHMARK_RUN_ID}-io-${product}-${direction}"
  mkdir -p "$bench_dir"
  mkdir -p "$RESULTS_DIR"
  rm -f "${bench_dir}/out" "${bench_dir}/dd.log"

  local container_id=""
  if [[ "$direction" == "bind_mount_write" ]]; then
    container_id=$(docker_cmd "$product" run -d --name "$container_name" \
      -v "${bench_dir}:/bench" \
      alpine:3.20 \
      sh -c 'dd if=/dev/zero of=/bench/out bs=1M count=256 conv=fsync 2>/bench/dd.log')
  else
    local seed_id
    seed_id=$(docker_cmd "$product" run -d --name "${container_name}-seed" \
      -v "${bench_dir}:/bench" \
      alpine:3.20 \
      sh -c 'dd if=/dev/zero of=/bench/out bs=1M count=256 conv=fsync 2>/dev/null')
    local seed_status
    seed_status=$(docker_cmd "$product" wait "$seed_id" | tr -d '[:space:]')
    docker_cmd "$product" rm -f "$seed_id" >/dev/null 2>&1 || true
    if [[ "$seed_status" != "0" ]]; then
      write_result_row "$RUN_ID" "$product" "$direction" "failed" "MiB/s" "seed container exited ${seed_status}"
      rm -f "${bench_dir}/out"
      return 0
    fi
    container_id=$(docker_cmd "$product" run -d --name "$container_name" \
      -v "${bench_dir}:/bench" \
      alpine:3.20 \
      sh -c 'dd if=/bench/out of=/dev/null bs=1M 2>/bench/dd.log')
  fi

  local wait_status
  wait_status=$(docker_cmd "$product" wait "$container_id" | tr -d '[:space:]')
  if [[ "$wait_status" != "0" ]]; then
    docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
    write_result_row "$RUN_ID" "$product" "$direction" "failed" "MiB/s" "transfer container exited ${wait_status}"
    rm -f "${bench_dir}/out"
    return 0
  fi

  local dd_output=""
  local tmp_log="${RESULTS_DIR}/dd-${product}-${direction}.log"
  if ! docker_cmd "$product" cp "${container_id}:/bench/dd.log" "$tmp_log" >/dev/null 2>&1; then
    docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
    write_result_row "$RUN_ID" "$product" "$direction" "failed" "MiB/s" "dd log missing"
    rm -f "${bench_dir}/out"
    return 0
  fi
  dd_output=$(tail -1 "$tmp_log")
  docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
  rm -f "$tmp_log"

  if [[ -z "$dd_output" ]]; then
    write_result_row "$RUN_ID" "$product" "$direction" "failed" "MiB/s" "empty dd output"
    rm -f "${bench_dir}/out"
    return 0
  fi
  local mbps
  mbps=$(parse_dd_mbps "$dd_output")
  if [[ "$mbps" == "0" || -z "$mbps" ]]; then
    write_result_row "$RUN_ID" "$product" "$direction" "failed" "MiB/s" "unparseable dd output"
    rm -f "${bench_dir}/out"
    return 0
  fi
  log "$(product_label "$product") ${direction}=${mbps} MiB/s"
  write_result_row "$RUN_ID" "$product" "$direction" "$mbps" "MiB/s" "256 MiB sequential"
  rm -f "${bench_dir}/out"
}

benchmark_idle_ram() {
  local product=$1
  local docker_host
  docker_host=$(product_docker_host "$product")

  local ps_file="${RESULTS_DIR}/.${product}-ps.ids"
  if ! docker_ps_ids "$product" "$ps_file"; then
    write_result_row "$RUN_ID" "$product" "idle_ram" "failed" "MB" "container enumeration failed"
    return 0
  fi
  local container_id
  local other_workloads=0
  while IFS= read -r container_id; do
    [[ -z "$container_id" ]] && continue
    local name
    name=$(docker_cmd "$product" inspect --format '{{.Name}}' "$container_id" 2>/dev/null || true)
    name="${name#/}"
    if [[ "$name" == "${BENCHMARK_RUN_ID}"* ]]; then
      docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
    else
      other_workloads=1
    fi
  done <"$ps_file"
  rm -f "$ps_file"
  if (( other_workloads )); then
    log "$(product_label "$product") idle_ram skipped (other workloads remain)"
    write_result_row "$RUN_ID" "$product" "idle_ram" "skipped" "MB" "other workloads remain"
    return 0
  fi
  sleep 5

  if [[ "$product" == "calf" && "${CALF_RUNTIME:-}" == "vfkit" ]]; then
    # Drop any resurrected Lima VM before summing Virtualization RSS.
    disable_lima_autostart_calf
    pkill -9 -x limactl >/dev/null 2>&1 || true
    sleep 1
  fi

  local ram_mb
  ram_mb=$(measure_idle_ram_mb "$product")
  log "$(product_label "$product") idle_ram=${ram_mb} MB"
  write_result_row "$RUN_ID" "$product" "idle_ram" "$ram_mb" "MB" "sum RSS of product processes"
}

benchmark_cold_start() {
  local product=$1
  local started_daemon_pid=""

  stop_other_products "$product"

  # Bring the engine up once so hello-world can be cached before the timed stop/start.
  case "$product" in
    calf)
      if ! start_calf_daemon; then
        write_result_row "$RUN_ID" "$product" "cold_start" "skipped" "seconds" "could not start daemon"
        return 0
      fi
      ;;
    *)
      start_product "$product"
      ;;
  esac

  if ! wait_for_docker_host "$product" "$BENCHMARK_TIMEOUT"; then
    write_result_row "$RUN_ID" "$product" "cold_start" "skipped" "seconds" "could not pre-pull hello-world"
    stop_product "$product"
    return 0
  fi

  docker_cmd "$product" pull hello-world >/dev/null 2>&1 || true
  stop_product "$product"
  wait_for_docker_host_down "$product" 120 || true

  local start_ms
  start_ms=$(now_epoch_ms)

  case "$product" in
    calf)
      if ! start_calf_daemon; then
        write_result_row "$RUN_ID" "$product" "cold_start" "skipped" "seconds" "could not start daemon"
        return 0
      fi
      started_daemon_pid="$CALF_BENCHMARK_DAEMON_PID"
      ;;
    *)
      start_product "$product"
      ;;
  esac

  if ! wait_for_docker_host "$product" "$BENCHMARK_TIMEOUT"; then
    write_result_row "$RUN_ID" "$product" "cold_start" "timeout" "seconds" "docker socket unavailable"
    [[ -n "$started_daemon_pid" ]] && kill "$started_daemon_pid" >/dev/null 2>&1 || true
    return 0
  fi

  if run_hello_world_cached "$product"; then
    local seconds
    seconds=$(elapsed_seconds "$start_ms")
    log "$(product_label "$product") cold_start=${seconds}s"
    write_result_row "$RUN_ID" "$product" "cold_start" "$seconds" "seconds" "stop to first hello-world (image cached)"
  else
    local err_log="${RESULTS_DIR}/cold-start-${product}.log"
    docker_cmd "$product" run --rm hello-world >"$err_log" 2>&1 || true
    write_result_row "$RUN_ID" "$product" "cold_start" "failed" "seconds" "hello-world failed; see ${err_log}"
    warn "$(product_label "$product") cold_start failed; details in ${err_log}"
  fi
}

for product in "${PRODUCTS[@]}"; do
  if should_skip_product "$product"; then
    continue
  fi
  log "benchmarking $(product_label "$product")"
  if metric_enabled cold_start; then
    benchmark_cold_start "$product"
  fi

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
done

results_file="${RESULTS_DIR}/results-${RUN_ID}.tsv"
log "results written to ${results_file}"
printf '%s\n' "$results_file"
