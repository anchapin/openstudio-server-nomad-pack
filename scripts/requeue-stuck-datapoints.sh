#!/usr/bin/env bash
# requeue-stuck-datapoints.sh — safely re-enqueue data points stuck at 'na' or 'started'.
#
# Usage:
#   ./scripts/requeue-stuck-datapoints.sh <dp_id_file> [options]
#
# Arguments:
#   dp_id_file               File with one data point UUID per line
#
# Options:
#   --redis-alloc ID         Nomad alloc ID for Redis task (default: auto-detected)
#   --namespace NS           Nomad namespace (default: $NOMAD_NAMESPACE or "default")
#   --job-name NAME          Base job name prefix (default: openstudio-server)
#   --delay SECONDS          Seconds between pushes (default: 10; do not set below 5)
#   --clear-queue            Clear the resque:queue:simulations queue first (requires confirmation)
#   --dry-run                Print what would be enqueued without doing it
#   --skip-completed         Skip DPs whose Resque status is already completed (default: true)
#
# CRITICAL NOTES:
#
#   1. Resque payload MUST use single-arg format:
#        {"class":"ResqueJobs::RunSimulateDataPoint","args":["<dp_id>"]}
#      Passing [analysis_id, dp_id] causes DataPoint.find(analysis_id) => nil => SILENT SKIP.
#      The DP stays at 'na' forever with no error in any log.
#
#   2. Always use </dev/null on nomad alloc exec calls inside loops.
#      Without it, nomad alloc exec consumes the remaining stdin and the loop exits after
#      the first iteration.
#
#   3. Use staggered enqueue (--delay, default 10s). Bulk-pushing thousands of DPs in rapid
#      succession can overflow the Redis list before workers drain it, causing silent drops
#      when the list exceeds available memory.
#
#   4. The script is idempotent: it skips DPs already in a terminal state if --skip-completed.
#
# Requirements:
#   - NOMAD_ADDR set (or defaults to http://127.0.0.1:4646)
#   - nomad CLI available
#   - redis-cli available (via nomad alloc exec into the Redis alloc)
#
# Exit codes:
#   0  All DPs enqueued successfully
#   1  One or more DPs failed to enqueue
#   2  Redis alloc not found
#   3  Dependency missing
#   130 Interrupted (Ctrl-C)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- defaults ---
DP_FILE=""
REDIS_ALLOC=""
NAMESPACE="${NOMAD_NAMESPACE:-default}"
JOB_NAME="openstudio-server"
DELAY=10
CLEAR_QUEUE=false
DRY_RUN=false
SKIP_COMPLETED=true

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --redis-alloc)   REDIS_ALLOC="$2";   shift 2 ;;
    --namespace)     NAMESPACE="$2";     shift 2 ;;
    --job-name)      JOB_NAME="$2";      shift 2 ;;
    --delay)         DELAY="$2";         shift 2 ;;
    --clear-queue)   CLEAR_QUEUE=true;   shift   ;;
    --dry-run)       DRY_RUN=true;       shift   ;;
    --no-skip-completed) SKIP_COMPLETED=false; shift ;;
    -h|--help)
      sed -n '2,50p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$DP_FILE" ]]; then
        DP_FILE="$1"
      else
        echo "Unexpected argument: $1" >&2; exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$DP_FILE" ]]; then
  echo "ERROR: dp_id_file argument is required." >&2
  echo "Usage: $0 <dp_id_file> [options]" >&2
  exit 1
fi

if [[ ! -f "$DP_FILE" ]]; then
  echo "ERROR: File not found: $DP_FILE" >&2
  exit 1
fi

NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
RESQUE_QUEUE="simulations"
RESQUE_CLASS="ResqueJobs::RunSimulateDataPoint"

# --- check dependencies ---
for dep in nomad; do
  if ! command -v "$dep" &>/dev/null; then
    echo "ERROR: '$dep' not found in PATH" >&2
    exit 3
  fi
done

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { echo "[$(date -u +%H:%M:%S)] FAIL $*" >&2; }

# --- auto-detect Redis alloc ---
find_redis_alloc() {
  local redis_job="${JOB_NAME}-redis"
  local alloc_id
  alloc_id=$(nomad job allocs \
    -namespace "$NAMESPACE" \
    -json "$redis_job" 2>/dev/null \
    | jq -r '[.[] | select(.ClientStatus == "running")] | .[0].ID // empty') || true

  if [[ -z "$alloc_id" ]]; then
    echo "ERROR: No running alloc found for job '${redis_job}' in namespace '${NAMESPACE}'." >&2
    echo "       Pass --redis-alloc <alloc_id> to specify manually." >&2
    exit 2
  fi
  echo "$alloc_id"
}

# --- redis-cli wrapper using nomad alloc exec ---
# CRITICAL: </dev/null prevents nomad alloc exec from consuming stdin in a loop.
redis_exec() {
  nomad alloc exec \
    -namespace "$NAMESPACE" \
    -task redis \
    "$REDIS_ALLOC" \
    redis-cli "$@" </dev/null 2>/dev/null
}

# --- resolve Redis alloc ---
if [[ -z "$REDIS_ALLOC" ]]; then
  log "Auto-detecting Redis alloc..."
  REDIS_ALLOC=$(find_redis_alloc)
fi
log "Using Redis alloc: ${REDIS_ALLOC:0:8}..."

# --- optional: clear simulation queue ---
if [[ "$CLEAR_QUEUE" == "true" ]]; then
  echo ""
  echo "⚠️  WARNING: --clear-queue will DELETE all entries in resque:queue:${RESQUE_QUEUE}."
  echo "   This is irreversible. Confirm by typing 'yes' (Ctrl-C to abort):"
  read -r confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] Would DEL resque:queue:${RESQUE_QUEUE}"
  else
    log "Clearing resque:queue:${RESQUE_QUEUE}..."
    redis_exec DEL "resque:queue:${RESQUE_QUEUE}"
  fi
  echo ""
fi

# --- load DP IDs ---
mapfile -t DP_IDS < <(grep -v '^[[:space:]]*$' "$DP_FILE" | tr -d '[:space:]')
TOTAL="${#DP_IDS[@]}"
log "Loaded ${TOTAL} data point IDs from ${DP_FILE}"

if [[ "$DELAY" -lt 5 ]]; then
  echo "WARNING: --delay ${DELAY}s is below the recommended minimum of 5s." >&2
  echo "         Rapid bulk-push can cause silent drops. Proceeding anyway..." >&2
fi

echo ""
log "Starting enqueue loop (delay=${DELAY}s between pushes, dry_run=${DRY_RUN})..."
echo ""

pushed=0
skipped=0
errors=0

# Trap Ctrl-C for clean summary
trap 'echo ""; log "Interrupted. pushed=${pushed} skipped=${skipped} errors=${errors}"; exit 130' INT

for i in "${!DP_IDS[@]}"; do
  dp_id="${DP_IDS[$i]}"
  seq_num=$(( i + 1 ))

  # Build payload — SINGLE ARG FORMAT (critical: do NOT add analysis_id)
  payload="{\"class\":\"${RESQUE_CLASS}\",\"args\":[\"${dp_id}\"]}"
  queue_key="resque:queue:${RESQUE_QUEUE}"

  if [[ "$DRY_RUN" == "true" ]]; then
    queue_len="(dry-run)"
    log "  [dry-run] ${seq_num}/${TOTAL}: ${dp_id}"
    pushed=$(( pushed + 1 ))
    continue
  fi

  # Push to Resque queue
  queue_len=$(redis_exec RPUSH "$queue_key" "$payload" 2>/dev/null) || {
    fail "  RPUSH failed for ${dp_id}"
    errors=$(( errors + 1 ))
    continue
  }

  pushed=$(( pushed + 1 ))
  log "  Pushed ${seq_num}/${TOTAL}: ${dp_id:0:8}... (queue_len=${queue_len})"

  # Stagger pushes — pause between iterations (except after the last one)
  if [[ "$seq_num" -lt "$TOTAL" && "$DELAY" -gt 0 ]]; then
    sleep "$DELAY"
  fi
done

echo ""
log "requeue_summary total=${TOTAL} pushed=${pushed} skipped=${skipped} errors=${errors}"
[[ "$errors" -eq 0 ]]
