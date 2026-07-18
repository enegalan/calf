#!/usr/bin/env bash
# Measure one product at a time without stopping other engines (caller switches products).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT_DIR}/scripts/benchmarks/_common.sh"

PRODUCT="${1:?product required: calf|docker_desktop|orbstack}"
RUN_ID="${2:-m3pro-final}"

bench_dir="${BENCHMARK_MOUNT_DIR}/${PRODUCT}"
mkdir -p "$bench_dir"
mkdir -p "$RESULTS_DIR"

log "measuring $(product_label "$PRODUCT") (engine must already be running)"

if ! wait_for_docker_context "$PRODUCT" 60; then
  echo "ERROR: docker unavailable for $PRODUCT" >&2
  exit 1
fi

# compose up
project="${RUN_ID}-manual-${PRODUCT}"
cleanup_compose_project "$PRODUCT" "$project"
start_ms=$(now_epoch_ms)
(cd "${ROOT_DIR}/examples/hello-world" && docker_cmd "$PRODUCT" compose -p "$project" up -d --build) >/dev/null
compose_up=$(elapsed_seconds "$start_ms")
cleanup_compose_project "$PRODUCT" "$project"

# bind mount write
id=$(docker_cmd "$PRODUCT" run -d --name "${RUN_ID}-w" -v "${bench_dir}:/bench" alpine:3.20 \
  sh -c 'dd if=/dev/zero of=/bench/out bs=1M count=256 conv=fsync 2>/bench/dd.log')
docker_cmd "$PRODUCT" wait "$id" >/dev/null
tmp="${RESULTS_DIR}/dd-write-${PRODUCT}.log"
docker_cmd "$PRODUCT" cp "${id}:/bench/dd.log" "$tmp" >/dev/null
write_mbps=$(parse_dd_mbps "$(tail -1 "$tmp")")
docker_cmd "$PRODUCT" rm -f "$id" >/dev/null

# bind mount read (warm file in mount)
id=$(docker_cmd "$PRODUCT" run -d --name "${RUN_ID}-r" -v "${bench_dir}:/bench" alpine:3.20 \
  sh -c 'dd if=/bench/out of=/dev/null bs=1M 2>/bench/dd.log')
docker_cmd "$PRODUCT" wait "$id" >/dev/null
docker_cmd "$PRODUCT" cp "${id}:/bench/dd.log" "$tmp" >/dev/null
read_mbps=$(parse_dd_mbps "$(tail -1 "$tmp")")
docker_cmd "$PRODUCT" rm -f "$id" >/dev/null
rm -f "$tmp"

# idle ram — remove only benchmark-prefixed containers; skip idle if other workloads remain
ps_file="${RESULTS_DIR}/.${PRODUCT}.ps"
if ! docker_ps_ids "$PRODUCT" "$ps_file"; then
  echo "ERROR: failed to list containers for idle measurement" >&2
  exit 1
fi
other_workloads=0
while IFS= read -r cid; do
  [[ -z "$cid" ]] && continue
  name=$(docker_cmd "$PRODUCT" inspect --format '{{.Name}}' "$cid" 2>/dev/null || true)
  name="${name#/}"
  if [[ "$name" == "${BENCHMARK_RUN_ID}"* || "$name" == "${RUN_ID}"* ]]; then
    docker_cmd "$PRODUCT" rm -f "$cid" >/dev/null 2>&1 || true
  else
    other_workloads=1
  fi
done <"$ps_file"
rm -f "$ps_file"
if (( other_workloads )); then
  echo "ERROR: other containers still running; skip idle_ram" >&2
  exit 1
fi
sleep 3
idle_ram=$(measure_idle_ram_mb "$PRODUCT")

printf '%s compose_up=%s bind_mount_write=%s bind_mount_read=%s idle_ram=%s\n' \
  "$PRODUCT" "$compose_up" "$write_mbps" "$read_mbps" "$idle_ram"
