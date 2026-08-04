#!/usr/bin/env bash
#
# drain-workers.sh
#
# Safely stop old worker allocations in batches after a worker rollback or image fix.
#
# Usage:
#   ./scripts/drain-workers.sh --target-version <job-version> [options]
#   JOB_NAME=openstudio-server-worker ./scripts/drain-workers.sh --target-version 41
#
# Options:
#   --target-version <n>   Required Nomad job version that should remain running
#   --job-name <name>      Worker job name (default: $JOB_NAME or openstudio-server-worker)
#   --batch-size <n>       Number of allocation stop requests per batch (default: 25)
#   --delay-seconds <n>    Delay between batches (default: 10)
#   --retry-delay <n>      Delay after HTTP 429 before retrying (default: 15)
#   --max-retries <n>      Maximum retries for one stop request (default: 5)
#   --dry-run              Print matching allocations without stopping them
#   --help                 Show this help text

set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}"
JOB_NAME="${JOB_NAME:-openstudio-server-worker}"
TARGET_VERSION=""
BATCH_SIZE=25
DELAY_SECONDS=10
RETRY_DELAY=15
MAX_RETRIES=5
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage:
  ./scripts/drain-workers.sh --target-version <job-version> [options]
  JOB_NAME=openstudio-server-worker ./scripts/drain-workers.sh --target-version 41

Options:
  --target-version <n>   Required Nomad job version that should remain running
  --job-name <name>      Worker job name (default: $JOB_NAME or openstudio-server-worker)
  --batch-size <n>       Number of allocation stop requests per batch (default: 25)
  --delay-seconds <n>    Delay between batches (default: 10)
  --retry-delay <n>      Delay after HTTP 429 before retrying (default: 15)
  --max-retries <n>      Maximum retries for one stop request (default: 5)
  --dry-run              Print matching allocations without stopping them
  --help                 Show this help text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-version)
      TARGET_VERSION="${2:-}"
      shift 2
      ;;
    --job-name)
      JOB_NAME="${2:-}"
      shift 2
      ;;
    --batch-size)
      BATCH_SIZE="${2:-}"
      shift 2
      ;;
    --delay-seconds)
      DELAY_SECONDS="${2:-}"
      shift 2
      ;;
    --retry-delay)
      RETRY_DELAY="${2:-}"
      shift 2
      ;;
    --max-retries)
      MAX_RETRIES="${2:-}"
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
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for value_name in TARGET_VERSION BATCH_SIZE DELAY_SECONDS RETRY_DELAY MAX_RETRIES; do
  value="${!value_name}"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${value_name} must be an integer (got '$value')" >&2
    exit 1
  fi
done

if [[ -z "$TARGET_VERSION" ]]; then
  echo "ERROR: --target-version is required" >&2
  usage >&2
  exit 1
fi

export NOMAD_ADDR NOMAD_NAMESPACE

alloc_lines="$(
  nomad job allocs -json "$JOB_NAME" \
    | python3 -c $'
import json
import sys

target = int(sys.argv[1])
allocs = json.load(sys.stdin)

for alloc in sorted(
    allocs,
    key=lambda a: (
        int(a.get("JobVersion", a.get("Version", -1)) or -1),
        a.get("NodeName", ""),
        a.get("ID", ""),
    ),
):
    version = alloc.get("JobVersion", alloc.get("Version"))
    if version is None:
        continue
    try:
        version = int(version)
    except (TypeError, ValueError):
        continue
    if alloc.get("ClientStatus") != "running":
        continue
    if version == target:
        continue
    print(
        "\\t".join(
            [
                str(version),
                alloc.get("ID", ""),
                alloc.get("NodeName", ""),
                alloc.get("DesiredStatus", ""),
            ]
        )
    )
' "$TARGET_VERSION"
)"

if [[ -z "$alloc_lines" ]]; then
  echo "No running allocations need draining for ${JOB_NAME}; all running allocs already match version ${TARGET_VERSION}."
  exit 0
fi

echo "==> Candidate allocations for drain"
echo "    Job:            ${JOB_NAME}"
echo "    Target version: ${TARGET_VERSION}"
echo "    Batch size:     ${BATCH_SIZE}"
echo "    Batch delay:    ${DELAY_SECONDS}s"
echo "    Retry delay:    ${RETRY_DELAY}s"
echo "    Max retries:    ${MAX_RETRIES}"
echo "    Dry run:        ${DRY_RUN}"
echo
printf '%s\n' "$alloc_lines" | while IFS=$'\t' read -r version alloc_id node_name desired_status; do
  printf '  version=%s alloc=%s node=%s desired=%s\n' \
    "$version" "${alloc_id:0:8}" "${node_name:-unknown}" "${desired_status:-unknown}"
done
echo

if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run only; no allocations were stopped."
  exit 0
fi

stop_alloc() {
  local alloc_id="$1"
  local attempt=1

  while (( attempt <= MAX_RETRIES )); do
    local response
    local body
    local status

    response="$(
      curl -sS --max-time 30 \
        -H "X-Nomad-Namespace: ${NOMAD_NAMESPACE}" \
        ${NOMAD_TOKEN:+-H "X-Nomad-Token: ${NOMAD_TOKEN}"} \
        -X POST \
        "${NOMAD_ADDR}/v1/allocation/${alloc_id}/stop" \
        -w $'\n%{http_code}'
    )"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"

    if [[ "$status" == "200" ]]; then
      local eval_id
      eval_id="$(
        python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("EvalID",""))' \
          <<<"$body"
      )"
      printf '  stopped alloc=%s eval=%s\n' "${alloc_id:0:8}" "${eval_id:0:8}"
      return 0
    fi

    if [[ "$status" == "429" ]]; then
      printf '  retrying alloc=%s after HTTP 429 (attempt %s/%s)\n' "${alloc_id:0:8}" "$attempt" "$MAX_RETRIES" >&2
      sleep "$RETRY_DELAY"
      (( attempt++ ))
      continue
    fi

    printf '  failed alloc=%s http=%s body=%s\n' "${alloc_id:0:8}" "$status" "$body" >&2
    return 1
  done

  printf '  failed alloc=%s exhausted retries after repeated HTTP 429 responses\n' "${alloc_id:0:8}" >&2
  return 1
}

stopped=0
failed=0
batch_count=0
total_count="$(printf '%s\n' "$alloc_lines" | wc -l | tr -d ' ')"

while IFS=$'\t' read -r version alloc_id node_name desired_status; do
  if stop_alloc "$alloc_id"; then
    (( stopped++ )) || true
  else
    (( failed++ )) || true
  fi

  (( batch_count++ )) || true

  if (( batch_count == BATCH_SIZE && stopped + failed < total_count )); then
    echo "==> Batch complete; sleeping ${DELAY_SECONDS}s before next batch"
    echo
    sleep "$DELAY_SECONDS"
    batch_count=0
  fi
done <<<"$alloc_lines"

echo
echo "==> Drain summary"
echo "    Stopped: ${stopped}"
echo "    Failed:  ${failed}"
echo "    Total:   ${total_count}"

if (( failed > 0 )); then
  exit 1
fi
