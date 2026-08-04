#!/usr/bin/env bash
#
# drain-workers.sh
#
# Stop old worker allocations in controlled batches after a rollback or image fix.

set -euo pipefail

DEFAULT_NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
NOMAD_ADDR="${DEFAULT_NOMAD_ADDR}"
NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}"
JOB_NAME="${JOB_NAME:-openstudio-server-worker}"
TARGET_VERSION=""
BATCH_SIZE=100
SLEEP_SECONDS=20
MAX_ROUNDS=0
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: scripts/drain-workers.sh [options]
  --job NAME         Nomad job name (default: openstudio-server-worker)
  --target-version N Stop only running allocations older than this version
  --batch N          Allocations to stop per round (default: 100)
  --sleep N          Seconds between rounds (default: 20)
  --rounds N         Max rounds (default: unlimited until done)
  --dry-run          Print what would be stopped without stopping
  --nomad-addr URL   Nomad address (default: $NOMAD_ADDR or http://127.0.0.1:4646)
  --help             Show this help text

Compatibility aliases:
  --job-name, --batch-size, --delay-seconds
EOF
}

is_non_negative_integer() {
  [[ "${1}" =~ ^[0-9]+$ ]]
}

require_option_value() {
  if [[ $# -lt 2 || -z "${2}" || "${2}" == --* ]]; then
    echo "ERROR: missing value for ${1}" >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job|--job-name)
      require_option_value "$@"
      JOB_NAME="$2"
      shift 2
      ;;
    --target-version)
      require_option_value "$@"
      TARGET_VERSION="$2"
      shift 2
      ;;
    --batch|--batch-size)
      require_option_value "$@"
      BATCH_SIZE="$2"
      shift 2
      ;;
    --sleep|--delay-seconds)
      require_option_value "$@"
      SLEEP_SECONDS="$2"
      shift 2
      ;;
    --rounds)
      require_option_value "$@"
      MAX_ROUNDS="$2"
      shift 2
      ;;
    --nomad-addr)
      require_option_value "$@"
      NOMAD_ADDR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${TARGET_VERSION}" ]]; then
  echo "ERROR: --target-version is required" >&2
  usage >&2
  exit 1
fi

for numeric_arg in TARGET_VERSION BATCH_SIZE SLEEP_SECONDS MAX_ROUNDS; do
  value="${!numeric_arg}"
  if ! is_non_negative_integer "${value}"; then
    echo "ERROR: ${numeric_arg} must be a non-negative integer (got '${value}')" >&2
    exit 1
  fi
done

if (( BATCH_SIZE == 0 )); then
  echo "ERROR: --batch must be greater than 0" >&2
  exit 1
fi

NOMAD_ADDR="${NOMAD_ADDR%/}"

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

curl_nomad() {
  local curl_args=(
    -fsS
    --max-time 30
    -H "X-Nomad-Namespace: ${NOMAD_NAMESPACE}"
  )
  if [[ -n "${NOMAD_TOKEN:-}" ]]; then
    curl_args+=(-H "X-Nomad-Token: ${NOMAD_TOKEN}")
  fi
  curl "${curl_args[@]}" "$@"
}

fetch_allocations_json() {
  local encoded_job
  encoded_job="$(urlencode "${JOB_NAME}")"
  curl_nomad "${NOMAD_ADDR}/v1/job/${encoded_job}/allocations"
}

candidate_lines_from_json() {
  python3 -c 'import json
import sys

target = int(sys.argv[1])
allocs = json.load(sys.stdin)
candidates = []

for alloc in allocs:
    version = alloc.get("JobVersion", alloc.get("Version"))
    if version is None:
        continue
    try:
        version = int(version)
    except (TypeError, ValueError):
        continue
    if alloc.get("ClientStatus") != "running":
        continue
    if version >= target:
        continue
    candidates.append(
        (
            version,
            alloc.get("ID", ""),
            alloc.get("NodeName", ""),
            alloc.get("DesiredStatus", ""),
        )
    )

for version, alloc_id, node_name, desired_status in sorted(
    candidates,
    key=lambda item: (item[0], item[2], item[1]),
):
    print(f"{version}\t{alloc_id}\t{node_name}\t{desired_status}")' \
    "${TARGET_VERSION}"
}

version_breakdown_from_json() {
  python3 -c 'import collections
import json
import sys

target = int(sys.argv[1])
allocs = json.load(sys.stdin)
running = collections.Counter()
old_running = collections.Counter()

for alloc in allocs:
    version = alloc.get("JobVersion", alloc.get("Version"))
    if version is None:
        continue
    try:
        version = int(version)
    except (TypeError, ValueError):
        continue
    if alloc.get("ClientStatus") != "running":
        continue
    running[version] += 1
    if version < target:
        old_running[version] += 1

if not running:
    print("version=none running=0 old_running=0")
    raise SystemExit(0)

for version in sorted(running):
    print(
        f"version={version} running={running[version]} old_running={old_running.get(version, 0)}"
    )' \
    "${TARGET_VERSION}"
}

count_lines() {
  awk 'NF { count++ } END { print count + 0 }' <<<"${1}"
}

print_candidates() {
  local candidates="$1"
  while IFS=$'\t' read -r version alloc_id node_name desired_status; do
    [[ -n "${alloc_id}" ]] || continue
    printf 'dry_run alloc=%s version=%s node=%s desired=%s\n' \
      "${alloc_id}" "${version}" "${node_name:-unknown}" "${desired_status:-unknown}"
  done <<<"${candidates}"
}

stop_allocation() {
  local alloc_id="$1"
  local version="$2"
  local response
  local body
  local status
  local eval_id
  local curl_args=(
    -sS
    --max-time 30
    -H "X-Nomad-Namespace: ${NOMAD_NAMESPACE}"
    -X POST
  )

  if [[ -n "${NOMAD_TOKEN:-}" ]]; then
    curl_args+=(-H "X-Nomad-Token: ${NOMAD_TOKEN}")
  fi

  response="$(
    curl "${curl_args[@]}" \
      "${NOMAD_ADDR}/v1/allocation/${alloc_id}/stop" \
      -w $'\n%{http_code}'
  )"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
    eval_id="$(
      python3 -c 'import json,sys
body = sys.stdin.read().strip()
if not body:
    print("")
    raise SystemExit(0)
try:
    payload = json.loads(body)
except json.JSONDecodeError:
    print("")
    raise SystemExit(0)
print(payload.get("EvalID", ""))' <<<"${body}"
    )"
    printf 'stopped alloc=%s version=%s eval=%s\n' \
      "${alloc_id}" "${version}" "${eval_id}"
    return 0
  fi

  printf 'stop_failed alloc=%s version=%s http=%s body=%s\n' \
    "${alloc_id}" "${version}" "${status}" "${body}" >&2
  return 1
}

echo "job=${JOB_NAME} target_version=${TARGET_VERSION} batch=${BATCH_SIZE} sleep=${SLEEP_SECONDS} rounds=${MAX_ROUNDS:-0} dry_run=${DRY_RUN} nomad_addr=${NOMAD_ADDR}"

initial_allocations_json="$(fetch_allocations_json)"
initial_candidates="$(candidate_lines_from_json <<<"${initial_allocations_json}")"
initial_old_running="$(count_lines "${initial_candidates}")"

if [[ "${DRY_RUN}" == "true" ]]; then
  print_candidates "${initial_candidates}"
  echo "round=1 old_running=${initial_old_running} stopped=0"
  echo "final_version_breakdown_begin"
  version_breakdown_from_json <<<"${initial_allocations_json}"
  echo "final_version_breakdown_end"
  if (( initial_old_running == 0 )); then
    echo "summary rounds_completed=0 stopped_total=0 remaining_old_running=0 dry_run=true"
  else
    echo "summary rounds_completed=1 stopped_total=0 remaining_old_running=${initial_old_running} dry_run=true"
  fi
  exit 0
fi

round=0
stopped_total=0
last_old_running="${initial_old_running}"

while :; do
  allocations_json="$(fetch_allocations_json)"
  candidates="$(candidate_lines_from_json <<<"${allocations_json}")"
  old_running="$(count_lines "${candidates}")"
  last_old_running="${old_running}"

  if (( old_running == 0 )); then
    break
  fi

  if (( MAX_ROUNDS > 0 && round >= MAX_ROUNDS )); then
    break
  fi

  round=$(( round + 1 ))
  round_stopped=0
  round_failed=0

  while IFS=$'\t' read -r version alloc_id node_name desired_status; do
    [[ -n "${alloc_id}" ]] || continue
    if stop_allocation "${alloc_id}" "${version}"; then
      round_stopped=$(( round_stopped + 1 ))
      stopped_total=$(( stopped_total + 1 ))
    else
      round_failed=$(( round_failed + 1 ))
    fi
  done < <(printf '%s\n' "${candidates}" | head -n "${BATCH_SIZE}")

  echo "round=${round} old_running=${old_running} stopped=${round_stopped}"

  if (( round_failed > 0 )); then
    echo "round_failed=${round} failed=${round_failed}" >&2
  fi

  if (( round_stopped == 0 && round_failed > 0 )); then
    break
  fi

  if (( MAX_ROUNDS > 0 && round >= MAX_ROUNDS )); then
    break
  fi

  if (( old_running > round_stopped )); then
    sleep "${SLEEP_SECONDS}"
  fi
done

final_allocations_json="$(fetch_allocations_json)"
final_candidates="$(candidate_lines_from_json <<<"${final_allocations_json}")"
remaining_old_running="$(count_lines "${final_candidates}")"

echo "final_version_breakdown_begin"
version_breakdown_from_json <<<"${final_allocations_json}"
echo "final_version_breakdown_end"
echo "summary rounds_completed=${round} stopped_total=${stopped_total} remaining_old_running=${remaining_old_running} dry_run=false"

if (( remaining_old_running > 0 )); then
  if (( MAX_ROUNDS > 0 && round >= MAX_ROUNDS )); then
    echo "ERROR: reached --rounds limit with ${remaining_old_running} old running allocations still present" >&2
  else
    echo "ERROR: ${remaining_old_running} old running allocations remain after drain attempt" >&2
  fi
  exit 1
fi
