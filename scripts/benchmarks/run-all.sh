#!/usr/bin/env bash
# Run Calf public benchmarks against Docker Desktop and OrbStack on macOS.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

RUN_ID="${BENCHMARK_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
PRODUCTS=()
METRICS=(cold_start vm_boot bind_mount_write bind_mount_read idle_ram)
SKIP_METRICS=()

disable_lima_autostart_calf
trap 'enable_lima_autostart_calf' EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --products LIST     Comma-separated: calf,docker_desktop,orbstack (default: auto-detect)
  --metrics LIST      Comma-separated metric names (default: all)
  --skip-metrics LIST Comma-separated metrics to skip
  --run-id ID         Results file suffix (default: timestamp)
  --repeats N         Timed samples per metric per product (default: ${BENCHMARK_REPEATS})
  --warmup N          Discarded warm-up samples before timed ones (default: ${BENCHMARK_WARMUP})
  -h, --help          Show this help

Environment:
  BENCHMARK_ALLOW_SUDO=1   Allow interactive sudo

Metrics:
  vm_boot             VM/engine restart until docker info succeeds
  bind_mount_write    Sequential write throughput on a bind mount (256 MiB)
  bind_mount_read     Sequential read after host page-cache drop (256 MiB)
  idle_ram            Approximate idle RSS for product-related processes (MB)
  cold_start          Full app stop to first successful docker run hello-world

Every metric is measured the same way for every product: warmup + N timed runs, then median.
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
    --repeats)
      BENCHMARK_REPEATS="$2"
      shift 2
      ;;
    --warmup)
      BENCHMARK_WARMUP="$2"
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
log "repeats=${BENCHMARK_REPEATS} warmup=${BENCHMARK_WARMUP} (median of timed samples, all products)"
cat "$hardware_file" >&2
log "Priming host page-cache drop (approve macOS admin prompt for purge if shown; 45s timeout)"
drop_host_page_cache || true

should_skip_product() {
  local product=$1
  if ! product_installed "$product"; then
    warn "$(product_label "$product") not installed; skipping"
    write_result_row "$RUN_ID" "$product" "availability" "skipped" "status" "not installed"
    return 0
  fi
  return 1
}

# run_metric_repeats runs warmup+N samples via a once-function that echoes a numeric value.
# Once-function must echo ONLY the value on success (stdout); non-zero exit = failed sample.
run_metric_repeats() {
  local product=$1
  local metric=$2
  local unit=$3
  local once_fn=$4
  local samples=()
  local i total val
  total=$((BENCHMARK_WARMUP + BENCHMARK_REPEATS))
  if (( total < 1 )); then
    write_result_row "$RUN_ID" "$product" "$metric" "failed" "$unit" "repeats+warmup < 1"
    return 0
  fi
  for ((i = 1; i <= total; i++)); do
    if ! val=$("$once_fn" "$product"); then
      write_result_row "$RUN_ID" "$product" "${metric}_sample" "failed" "$unit" "sample ${i}/${total}"
      continue
    fi
    val=$(printf '%s' "$val" | tr -d '[:space:]')
    if [[ -z "$val" || "$val" == "failed" || "$val" == "timeout" || "$val" == "skipped" ]]; then
      write_result_row "$RUN_ID" "$product" "${metric}_sample" "${val:-failed}" "$unit" "sample ${i}/${total}"
      continue
    fi
    if ! [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      write_result_row "$RUN_ID" "$product" "${metric}_sample" "failed" "$unit" "non-numeric sample ${i}/${total}"
      continue
    fi
    if (( i <= BENCHMARK_WARMUP )); then
      log "$(product_label "$product") ${metric} warmup ${i}/${BENCHMARK_WARMUP}=${val}${unit}"
      write_result_row "$RUN_ID" "$product" "${metric}_warmup" "$val" "$unit" "warmup ${i}/${BENCHMARK_WARMUP}"
      continue
    fi
    samples+=("$val")
    log "$(product_label "$product") ${metric} sample ${#samples[@]}/${BENCHMARK_REPEATS}=${val}${unit}"
    write_result_row "$RUN_ID" "$product" "${metric}_sample" "$val" "$unit" "sample ${#samples[@]}/${BENCHMARK_REPEATS}"
    # Fair cooldown for sequential bind-write: same gap for every product (reduces FS starvation noise).
    if [[ "$metric" == "bind_mount_write" ]]; then
      sleep "${BENCHMARK_WRITE_GAP_SEC:-2}"
    fi
  done
  if [[ ${#samples[@]} -eq 0 ]]; then
    write_result_row "$RUN_ID" "$product" "$metric" "failed" "$unit" "no successful timed samples"
    return 0
  fi
  local med
  if ! med=$(median_numbers "${samples[@]}"); then
    write_result_row "$RUN_ID" "$product" "$metric" "failed" "$unit" "median failed"
    return 0
  fi
  log "$(product_label "$product") ${metric}=${med}${unit} (median n=${#samples[@]})"
  write_result_row "$RUN_ID" "$product" "$metric" "$med" "$unit" "median n=${#samples[@]} warmup=${BENCHMARK_WARMUP}"
}

# pause_product_vm / resume_product_vm freeze the other engine during soft-interleaved
# samples so warm guests stay up without fighting for disk/CPU.
pause_product_vm() {
  local product=$1
  case "$product" in
    calf)
      pkill -STOP -x krunkit >/dev/null 2>&1 || true
      ;;
    orbstack)
      pkill -STOP -f 'OrbStack Helper.*vmgr' >/dev/null 2>&1 || true
      ;;
    docker_desktop)
      pkill -STOP -f 'com.docker.backend' >/dev/null 2>&1 || true
      ;;
  esac
}

resume_product_vm() {
  local product=$1
  case "$product" in
    calf)
      pkill -CONT -x krunkit >/dev/null 2>&1 || true
      ;;
    orbstack)
      pkill -CONT -f 'OrbStack Helper.*vmgr' >/dev/null 2>&1 || true
      ;;
    docker_desktop)
      pkill -CONT -f 'com.docker.backend' >/dev/null 2>&1 || true
      ;;
  esac
}

resume_all_vms() {
  local product
  for product in "${PRODUCTS[@]}"; do
    if product_installed "$product"; then
      resume_product_vm "$product"
    fi
  done
}

# pause_other_vms freezes idle engines during a sample. Default ON for soft-interleave
# so warm guests do not fight for APFS (write dips ~1.1 GB/s). Set BENCHMARK_PAUSE_VM=0
# to disable. Always CONT the active VM and verify it is not left stopped.
pause_other_vms() {
  local keep=$1
  if [[ "${BENCHMARK_PAUSE_VM:-1}" != "1" ]]; then
    return 0
  fi
  resume_all_vms
  local product
  for product in "${PRODUCTS[@]}"; do
    if [[ "$product" != "$keep" ]] && product_installed "$product"; then
      pause_product_vm "$product"
    fi
  done
  resume_product_vm "$keep"
  # Belt-and-suspenders: never leave the active Calf VM stopped.
  if [[ "$keep" == "calf" ]]; then
    pkill -CONT -x krunkit >/dev/null 2>&1 || true
  fi
}

# run_bind_io_interleaved soft-interleaves products per sample (BENCHMARK_INTERLEAVE=1).
# Starts every product once, keeps guests warm, and SIGSTOPs the idle VM during each sample.
# Bash 3.2 compatible (temp files, no assoc arrays).
run_bind_io_interleaved() {
  local metric=$1
  local unit=$2
  local once_fn=$3
  local -a products=()
  local product
  for product in "${PRODUCTS[@]}"; do
    if ! should_skip_product "$product"; then
      products+=("$product")
    fi
  done
  if [[ ${#products[@]} -eq 0 ]]; then
    return 0
  fi
  if [[ ${#products[@]} -eq 1 ]]; then
    if ! ensure_product_ready "${products[0]}"; then
      write_result_row "$RUN_ID" "${products[0]}" "$metric" "skipped" "n/a" "engine unavailable"
      return 0
    fi
    run_metric_repeats "${products[0]}" "$metric" "$unit" "$once_fn"
    return 0
  fi

  local sample_dir
  sample_dir=$(mktemp -d "${TMPDIR:-/tmp}/calf-bench-interleave.XXXXXX")
  local -a ready=()
  for product in "${products[@]}"; do
    : >"${sample_dir}/${product}.samples"
    log "starting $(product_label "$product") for soft-interleaved ${metric}"
    if ! start_product "$product"; then
      write_result_row "$RUN_ID" "$product" "$metric" "skipped" "n/a" "engine start failed"
      continue
    fi
    if [[ "$product" == "calf" ]]; then
      curl -sf -X POST "${CALF_API}/v1/runtime/start" >/dev/null 2>&1 || true
    fi
    if ! wait_for_docker_context "$product" "$BENCHMARK_TIMEOUT"; then
      write_result_row "$RUN_ID" "$product" "$metric" "skipped" "n/a" "engine unavailable"
      continue
    fi
    if ! preflight_docker "$product"; then
      write_result_row "$RUN_ID" "$product" "$metric" "skipped" "n/a" "preflight failed"
      continue
    fi
    ready+=("$product")
  done
  if [[ ${#ready[@]} -eq 0 ]]; then
    rm -rf "$sample_dir"
    return 0
  fi
  products=("${ready[@]}")

  if [[ "${BENCHMARK_PAUSE_VM:-1}" == "1" ]]; then
    log "soft-interleaved ${metric}: products=${products[*]} warmup=${BENCHMARK_WARMUP} repeats=${BENCHMARK_REPEATS} (pause idle VM)"
  else
    log "soft-interleaved ${metric}: products=${products[*]} warmup=${BENCHMARK_WARMUP} repeats=${BENCHMARK_REPEATS}"
  fi

  local w s val
  for ((w = 1; w <= BENCHMARK_WARMUP; w++)); do
    for product in "${products[@]}"; do
      pause_other_vms "$product"
      if ! val=$("$once_fn" "$product"); then
        resume_all_vms
        write_result_row "$RUN_ID" "$product" "${metric}_warmup" "failed" "$unit" "warmup ${w}/${BENCHMARK_WARMUP}"
        continue
      fi
      resume_product_vm "$product"
      val=$(printf '%s' "$val" | tr -d '[:space:]')
      log "$(product_label "$product") ${metric} warmup ${w}/${BENCHMARK_WARMUP}=${val}${unit} (soft-interleaved)"
      write_result_row "$RUN_ID" "$product" "${metric}_warmup" "$val" "$unit" "warmup ${w}/${BENCHMARK_WARMUP} soft-interleaved"
      if [[ "$metric" == "bind_mount_write" ]]; then
        sleep "${BENCHMARK_WRITE_GAP_SEC:-2}"
      fi
    done
  done

  for ((s = 1; s <= BENCHMARK_REPEATS; s++)); do
    for product in "${products[@]}"; do
      pause_other_vms "$product"
      if ! val=$("$once_fn" "$product"); then
        resume_all_vms
        write_result_row "$RUN_ID" "$product" "${metric}_sample" "failed" "$unit" "sample ${s}/${BENCHMARK_REPEATS}"
        continue
      fi
      resume_product_vm "$product"
      val=$(printf '%s' "$val" | tr -d '[:space:]')
      if ! [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        write_result_row "$RUN_ID" "$product" "${metric}_sample" "failed" "$unit" "non-numeric sample ${s}"
        continue
      fi
      printf '%s\n' "$val" >>"${sample_dir}/${product}.samples"
      log "$(product_label "$product") ${metric} sample ${s}/${BENCHMARK_REPEATS}=${val}${unit} (soft-interleaved)"
      write_result_row "$RUN_ID" "$product" "${metric}_sample" "$val" "$unit" "sample ${s}/${BENCHMARK_REPEATS} soft-interleaved"
      if [[ "$metric" == "bind_mount_write" ]]; then
        sleep "${BENCHMARK_WRITE_GAP_SEC:-2}"
      fi
    done
  done

  # Resume everyone after the metric.
  resume_all_vms

  for product in "${products[@]}"; do
    local -a samples=()
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && samples+=("$line")
    done <"${sample_dir}/${product}.samples"
    if [[ ${#samples[@]} -eq 0 ]]; then
      write_result_row "$RUN_ID" "$product" "$metric" "failed" "$unit" "no successful timed samples"
      continue
    fi
    local med
    if ! med=$(median_numbers "${samples[@]}"); then
      write_result_row "$RUN_ID" "$product" "$metric" "failed" "$unit" "median failed"
      continue
    fi
    log "$(product_label "$product") ${metric}=${med}${unit} (median n=${#samples[@]} soft-interleaved)"
    write_result_row "$RUN_ID" "$product" "$metric" "$med" "$unit" "median n=${#samples[@]} soft-interleaved"
  done
  rm -rf "$sample_dir"
}

vm_boot_once() {
  local product=$1
  stop_other_products "$product"

  case "$product" in
    calf)
      if ! curl -sf "${CALF_API}/v1/health" >/dev/null 2>&1; then
        start_calf_daemon >/dev/null || return 1
      fi
      disable_lima_autostart_calf
      pkill -9 -x limactl >/dev/null 2>&1 || true
      guest_dir="${HOME}/.config/calf/guest/${CALF_VM_NAME}"
      if [[ -f "${guest_dir}/krunkit.pid" ]]; then
        kill -9 "$(cat "${guest_dir}/krunkit.pid" 2>/dev/null)" >/dev/null 2>&1 || true
      fi
      if [[ -f "${guest_dir}/gvproxy.pid" ]]; then
        kill -9 "$(cat "${guest_dir}/gvproxy.pid" 2>/dev/null)" >/dev/null 2>&1 || true
      fi
      pkill -9 -x krunkit >/dev/null 2>&1 || true
      pkill -9 -x gvproxy >/dev/null 2>&1 || true
      rm -f "${HOME}/.config/calf/docker.sock"
      wait_for_krunkit_gone 30 || true
      sleep 1
      wait_for_docker_host_down "$product" 120 || true
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
      # Ensure daemon is alive after hard guest kill; surface start failures.
      if ! curl -sf "${CALF_API}/v1/health" >/dev/null 2>&1; then
        start_calf_daemon >/dev/null || return 1
        sleep 1
      fi
      if ! curl -sf -X POST "${CALF_API}/v1/runtime/start" >/dev/null 2>&1; then
        # One retry after a brief pause (krunkit teardown races).
        sleep 2
        curl -sf -X POST "${CALF_API}/v1/runtime/start" >/dev/null 2>&1 || return 1
      fi
      ;;
    *)
      start_product "$product"
      ;;
  esac

  if wait_for_docker_host "$product" "$BENCHMARK_TIMEOUT"; then
    elapsed_seconds "$start_ms"
    return 0
  fi
  return 1
}

# bind_mount_write_once / bind_mount_read_once — read drops host page cache first.
bind_mount_write_once() {
  local product=$1
  _bind_mount_io_once "$product" write
}

bind_mount_read_once() {
  local product=$1
  _bind_mount_io_once "$product" read
}

_bind_mount_io_once() {
  local product=$1
  local direction=$2
  local bench_dir
  local volume_src
  bench_dir=$(bench_host_dir "$product")
  volume_src=$(bench_volume_src "$product")
  local container_name="${BENCHMARK_RUN_ID}-io-${product}-${direction}-$$-${RANDOM}"
  local data_file="out-$$-${RANDOM}"
  mkdir -p "$bench_dir"
  mkdir -p "$RESULTS_DIR"
  # Drop leftover containers from a previous failed sample (same product/direction).
  docker_cmd "$product" ps -aq --filter "name=${BENCHMARK_RUN_ID}-io-${product}-${direction}-" 2>/dev/null \
    | while read -r stale; do
        [[ -n "$stale" ]] && docker_cmd "$product" rm -f "$stale" >/dev/null 2>&1 || true
      done

  # Clean data via the engine (not host rm): macOS host deletes on virtiofs break the next create.
  docker_cmd "$product" run -d --rm -v "${volume_src}:/bench" alpine:3.20 \
    sh -c 'rm -f /bench/out /bench/dd.log /bench/out-* /bench/done.txt' >/dev/null 2>&1 || true
  sleep 0.3

  local container_id=""
  if [[ "$direction" == "write" ]]; then
    container_id=$(docker_cmd "$product" run -d --name "$container_name" \
      -v "${volume_src}:/bench" \
      alpine:3.20 \
      sh -c "dd if=/dev/zero of=/bench/${data_file} bs=1M count=256 conv=fsync 2>/bench/dd.log")
  else
    # Host-seeded file: same APFS create path for every product so cold-read
    # does not mix guest-write layout quirks into the read metric.
    local data_path="${bench_dir}/${data_file}"
    if ! dd if=/dev/zero of="$data_path" bs=1m count=256 conv=fsync 2>/dev/null; then
      warn "host seed write failed for ${data_path}"
      return 1
    fi
    # Same guest+host cache drop for every product so read is comparable.
    drop_bind_mount_caches "$product"
    sleep "${BENCHMARK_READ_GAP_SEC:-2}"
    container_id=$(docker_cmd "$product" run -d --name "$container_name" \
      -v "${volume_src}:/bench" \
      alpine:3.20 \
      sh -c "dd if=/bench/${data_file} of=/dev/null bs=1M 2>/bench/dd.log")
  fi

  local wait_status
  wait_status=$(docker_cmd "$product" wait "$container_id" | tr -d '[:space:]')
  if [[ "$wait_status" != "0" ]]; then
    docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
    docker_cmd "$product" run --rm -v "${volume_src}:/bench" alpine:3.20 \
      sh -c "rm -f /bench/${data_file} /bench/dd.log" >/dev/null 2>&1 || true
    return 1
  fi

  if [[ "$direction" == "write" && "$product" == "calf" && ! -f "${bench_dir}/${data_file}" ]]; then
    docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
    warn "calf bind-mount write did not appear on host ${bench_dir} (not virtiofs?)"
    return 1
  fi

  local tmp_log="${RESULTS_DIR}/dd-${product}-${direction}-$$-${RANDOM}.log"
  # Prefer host-side log for Calf: krunkit vsock breaks `docker cp` (unexpected EOF).
  if [[ "$product" == "calf" && -f "${bench_dir}/dd.log" ]]; then
    cp "${bench_dir}/dd.log" "$tmp_log"
  elif ! docker_cmd "$product" cp "${container_id}:/bench/dd.log" "$tmp_log" >/dev/null 2>&1; then
    docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
    docker_cmd "$product" run --rm -d -v "${volume_src}:/bench" alpine:3.20 \
      sh -c "rm -f /bench/${data_file} /bench/dd.log" >/dev/null 2>&1 || true
    return 1
  fi
  local dd_output
  dd_output=$(tail -1 "$tmp_log")
  docker_cmd "$product" rm -f "$container_id" >/dev/null 2>&1 || true
  # Detached cleanup avoids krunkit attach/stdout hangs.
  docker_cmd "$product" run --rm -d -v "${volume_src}:/bench" alpine:3.20 \
    sh -c "rm -f /bench/${data_file} /bench/dd.log /bench/out-*" >/dev/null 2>&1 || true
  rm -f "$tmp_log"

  if [[ -z "$dd_output" ]]; then
    return 1
  fi
  local mbps
  mbps=$(parse_dd_mbps "$dd_output")
  if [[ "$mbps" == "0" || -z "$mbps" ]]; then
    return 1
  fi
  printf '%s\n' "$mbps"
  return 0
}

idle_ram_once() {
  local product=$1
  local ps_file="${RESULTS_DIR}/.${product}-ps.ids.$$"
  if ! docker_ps_ids "$product" "$ps_file"; then
    return 1
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
    return 1
  fi
  sleep 5
  if [[ "$product" == "calf" ]]; then
    disable_lima_autostart_calf
    pkill -9 -x limactl >/dev/null 2>&1 || true
    sleep 1
  fi
  measure_idle_ram_mb "$product"
}

cold_start_once() {
  local product=$1
  local started_daemon_pid=""

  stop_other_products "$product"

  case "$product" in
    calf)
      if ! start_calf_daemon; then
        return 1
      fi
      ;;
    *)
      start_product "$product"
      ;;
  esac

  if ! wait_for_docker_host "$product" "$BENCHMARK_TIMEOUT"; then
    stop_product "$product"
    return 1
  fi

  docker_cmd "$product" pull hello-world >/dev/null 2>&1 || true
  stop_product "$product"
  wait_for_docker_host_down "$product" 120 || true

  local start_ms
  start_ms=$(now_epoch_ms)

  case "$product" in
    calf)
      if ! start_calf_daemon; then
        return 1
      fi
      started_daemon_pid="$CALF_BENCHMARK_DAEMON_PID"
      ;;
    *)
      start_product "$product"
      ;;
  esac

  if ! wait_for_docker_host "$product" "$BENCHMARK_TIMEOUT"; then
    [[ -n "$started_daemon_pid" ]] && kill "$started_daemon_pid" >/dev/null 2>&1 || true
    return 1
  fi

  if run_hello_world_cached "$product"; then
    elapsed_seconds "$start_ms"
    return 0
  fi
  return 1
}

for product in "${PRODUCTS[@]}"; do
  if should_skip_product "$product"; then
    continue
  fi
  log "benchmarking $(product_label "$product")"

  if metric_enabled cold_start; then
    run_metric_repeats "$product" cold_start s cold_start_once
  fi

  if metric_enabled vm_boot; then
    run_metric_repeats "$product" vm_boot s vm_boot_once
  fi
done

# Bind I/O + idle: either per-product (default) or interleaved across products (BENCHMARK_INTERLEAVE=1).
if [[ "${BENCHMARK_INTERLEAVE:-0}" == "1" ]] && { metric_enabled bind_mount_write || metric_enabled bind_mount_read; }; then
  if metric_enabled bind_mount_write; then
    run_bind_io_interleaved bind_mount_write MiB/s bind_mount_write_once
  fi
  if metric_enabled bind_mount_read; then
    run_bind_io_interleaved bind_mount_read MiB/s bind_mount_read_once
  fi
  if metric_enabled idle_ram; then
    for product in "${PRODUCTS[@]}"; do
      if should_skip_product "$product"; then
        continue
      fi
      if ! ensure_product_ready "$product"; then
        write_result_row "$RUN_ID" "$product" idle_ram "skipped" "n/a" "engine unavailable"
      else
        run_metric_repeats "$product" idle_ram MB idle_ram_once
      fi
    done
  fi
else
  for product in "${PRODUCTS[@]}"; do
    if should_skip_product "$product"; then
      continue
    fi
    needs_engine=false
    if metric_enabled bind_mount_write || metric_enabled bind_mount_read || metric_enabled idle_ram; then
      needs_engine=true
    fi

    if [[ "$needs_engine" == "true" ]]; then
      log "benchmarking $(product_label "$product") (steady-state metrics)"
      if ! ensure_product_ready "$product"; then
        for metric in bind_mount_write bind_mount_read idle_ram; do
          if metric_enabled "$metric"; then
            write_result_row "$RUN_ID" "$product" "$metric" "skipped" "n/a" "engine unavailable"
          fi
        done
      else
        if metric_enabled bind_mount_write; then
          run_metric_repeats "$product" bind_mount_write MiB/s bind_mount_write_once
        fi
        if metric_enabled bind_mount_read; then
          run_metric_repeats "$product" bind_mount_read MiB/s bind_mount_read_once
        fi
        if metric_enabled idle_ram; then
          run_metric_repeats "$product" idle_ram MB idle_ram_once
        fi
      fi
    fi
  done
fi

results_file="${RESULTS_DIR}/results-${RUN_ID}.tsv"
log "results written to ${results_file}"
printf '%s\n' "$results_file"
