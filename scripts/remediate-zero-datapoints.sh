#!/usr/bin/env bash
# remediate-zero-datapoints.sh — Emergency remediation for analyses showing "completed" with 0 datapoints
#
# This script addresses the issue where:
# - Analyses show status "completed" in the API
# - But datapoints are stuck in MongoDB with status "queued" or "started"
# - Resque queue (resque:queue:simulations) is empty
#
# Uses MongoDB directly (bypassing web API which may be slow/unavailable for large queries)
#
# Usage:
#   ./scripts/remediate-zero-datapoints.sh [options]
#
# Options:
#   --web-url URL         OpenStudio Server web URL (default: http://10.60.126.125)
#   --nomad-addr ADDR     Nomad API address (default: http://10.60.126.125:4646)
#   --namespace NS        Nomad namespace (default: default)
#   --job-name NAME       Base job name (default: openstudio-server)
#   --delay SECONDS       Delay between requeue pushes (default: 10)
#   --dry-run             Print what would be done without executing
#   --max-dps N           Maximum datapoints to requeue (default: all)
#   --status-only         Only show current status, don't requeue
#
# Prerequisites:
#   - nomad CLI available and configured
#   - curl available
#   - python3 available
#   - Access to the Nomad cluster

set -euo pipefail

# --- defaults ---
WEB_URL="http://10.60.126.125"
NOMAD_ADDR="http://10.60.126.125:4646"
NAMESPACE="default"
JOB_NAME="openstudio-server"
DELAY=10
DRY_RUN=false
MAX_DPS=0
STATUS_ONLY=false

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-url)       WEB_URL="$2"; shift 2 ;;
    --nomad-addr)    NOMAD_ADDR="$2"; shift 2 ;;
    --namespace)     NAMESPACE="$2"; shift 2 ;;
    --job-name)      JOB_NAME="$2"; shift 2 ;;
    --delay)         DELAY="$2"; shift 2 ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --max-dps)       MAX_DPS="$2"; shift 2 ;;
    --status-only)   STATUS_ONLY=true; shift ;;
    -h|--help)
      sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { echo "[$(date -u +%H:%M:%S)] FAIL $*" >&2; }

# --- check dependencies ---
for dep in nomad curl python3; do
  if ! command -v "$dep" &>/dev/null; then
    fail "ERROR: '$dep' not found in PATH"
    exit 3
  fi
done

export NOMAD_ADDR

# --- Step 1: Get current status from web API (status.json works) ---
log "Fetching current status from ${WEB_URL}/status.json..."
STATUS=$(curl -sf --max-time 10 "${WEB_URL}/status.json" 2>/dev/null) || {
  fail "Could not reach ${WEB_URL}/status.json"
  exit 1
}

ANALYSES_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['analyses']['count'])")
ANALYSES_COMPLETED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['analyses']['completed'])")
DP_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['count'])")
DP_QUEUED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['queued'])")
DP_STARTED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['started'])")
DP_COMPLETED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['completed'])")

log "Current status:"
log "  Analyses: ${ANALYSES_COUNT} total, ${ANALYSES_COMPLETED} completed"
log "  DataPoints: ${DP_COUNT} total, ${DP_QUEUED} queued, ${DP_STARTED} started, ${DP_COMPLETED} completed"

if [[ "$DP_QUEUED" -eq 0 && "$DP_STARTED" -eq 0 ]]; then
  log "No stuck datapoints found. Nothing to do."
  exit 0
fi

if [[ "$STATUS_ONLY" == "true" ]]; then
  exit 0
fi

# --- Step 2: Get stuck datapoint IDs from MongoDB directly ---
log "Fetching stuck datapoint IDs from MongoDB via web task..."

# Find web allocation to run mongo query
WEB_JOB="${JOB_NAME}-web"
WEB_ALLOC=$(nomad job allocs -namespace "$NAMESPACE" -json "$WEB_JOB" 2>/dev/null | \
  jq -r '[.[] | select(.ClientStatus == "running" and .TaskGroup == "web")] | .[0].ID // empty') || true

if [[ -z "$WEB_ALLOC" ]]; then
  fail "No running web allocation found for job '${WEB_JOB}' in namespace '${NAMESPACE}'"
  exit 2
fi
log "Using web alloc: ${WEB_ALLOC:0:8}..."

# MongoDB connection details (from user-overrides.hcl)
MONGO_HOST="192.168.100.122"
MONGO_PORT="27017"
MONGO_DB="os_docker"
MONGO_USER=""
MONGO_PASSWORD=""

# Build MongoDB query to find stuck datapoints
# Query data_points with status "queued" or "started"
MONGO_QUERY='db.data_points.find({status: {$in: ["queued", "started"]}}, {_id: 1}).forEach(function(doc) { print(doc._id); })'

# Execute MongoDB query via nomad alloc exec in web container
log "Querying MongoDB for stuck datapoint IDs..."
DP_IDS=$(nomad alloc exec -namespace "$NAMESPACE" -task web "$WEB_ALLOC" \
  mongosh --quiet --host "$MONGO_HOST" --port "$MONGO_PORT" "$MONGO_DB" --eval "$MONGO_QUERY" 2>/dev/null) || {
  fail "Failed to query MongoDB"
  exit 1
}

if [[ -z "$DP_IDS" ]]; then
  log "No stuck datapoint IDs found in MongoDB"
  exit 0
fi

# Convert to array (filter empty lines)
mapfile -t DP_ID_ARRAY < <(echo "$DP_IDS" | grep -v '^[[:space:]]*$')
TOTAL="${#DP_ID_ARRAY[@]}"

if [[ "$MAX_DPS" -gt 0 && "$MAX_DPS" -lt "$TOTAL" ]]; then
  log "Limiting to $MAX_DPS datapoints (of $TOTAL found)"
  DP_ID_ARRAY=("${DP_ID_ARRAY[@]:0:$MAX_DPS}")
  TOTAL="$MAX_DPS"
fi

log "Found $TOTAL stuck datapoints to requeue"

# --- Step 3: Find Redis allocation ---
REDIS_JOB="${JOB_NAME}-redis"
log "Finding Redis allocation..."
REDIS_ALLOC=$(nomad job allocs -namespace "$NAMESPACE" -json "$REDIS_JOB" 2>/dev/null | \
  jq -r '[.[] | select(.ClientStatus == "running")] | .[0].ID // empty') || true

if [[ -z "$REDIS_ALLOC" ]]; then
  fail "No running Redis allocation found for job '${REDIS_JOB}' in namespace '${NAMESPACE}'"
  exit 2
fi
log "Using Redis alloc: ${REDIS_ALLOC:0:8}..."

# --- Step 4: Redis CLI wrapper ---
redis_exec() {
  nomad alloc exec \
    -namespace "$NAMESPACE" \
    -task redis \
    "$REDIS_ALLOC" \
    redis-cli "$@" </dev/null 2>/dev/null
}

# Test Redis connection
if ! redis_exec PING >/dev/null 2>&1; then
  fail "Cannot connect to Redis via nomad alloc exec"
  exit 2
fi

# --- Step 5: Check current Resque queue depth ---
QUEUE_KEY="resque:queue:simulations"
CURRENT_QUEUE_LEN=$(redis_exec LLEN "$QUEUE_KEY" 2>/dev/null | tr -d '[:space:]')
log "Current resque:queue:simulations depth: ${CURRENT_QUEUE_LEN}"

# --- Step 6: Requeue datapoints ---
RESQUE_CLASS="ResqueJobs::RunSimulateDataPoint"
pushed=0
errors=0

log "Starting requeue loop (delay=${DELAY}s, dry_run=${DRY_RUN})..."

for i in "${!DP_ID_ARRAY[@]}"; do
  dp_id="${DP_ID_ARRAY[$i]}"
  seq_num=$(( i + 1 ))

  # Build payload — SINGLE ARG FORMAT (critical!)
  payload="{\"class\":\"${RESQUE_CLASS}\",\"args\":[\"${dp_id}\"]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "  [dry-run] ${seq_num}/${TOTAL}: ${dp_id}"
    pushed=$(( pushed + 1 ))
    continue
  fi

  # Push to Resque queue
  queue_len=$(redis_exec RPUSH "$QUEUE_KEY" "$payload" 2>/dev/null) || {
    fail "  RPUSH failed for ${dp_id}"
    errors=$(( errors + 1 ))
    continue
  }

  pushed=$(( pushed + 1 ))
  if [[ $(( seq_num % 100 )) -eq 0 || "$seq_num" -eq "$TOTAL" ]]; then
    log "  Pushed ${seq_num}/${TOTAL}: ${dp_id:0:8}... (queue_len=${queue_len})"
  fi

  # Stagger pushes
  if [[ "$seq_num" -lt "$TOTAL" && "$DELAY" -gt 0 ]]; then
    sleep "$DELAY"
  fi
done

# --- Step 7: Verify ---
NEW_QUEUE_LEN=$(redis_exec LLEN "$QUEUE_KEY" 2>/dev/null | tr -d '[:space:]')
log "Requeue complete: pushed=${pushed}, errors=${errors}"
log "Queue depth: ${CURRENT_QUEUE_LEN} -> ${NEW_QUEUE_LEN} (delta: $(( NEW_QUEUE_LEN - CURRENT_QUEUE_LEN )))"

# --- Step 8: Check Resque stats ---
log "Checking Resque stats..."
sleep 2
redis_exec GET "resque:stat:processed" 2>/dev/null | xargs -I{} echo "  Processed: {}"
redis_exec GET "resque:stat:failed" 2>/dev/null | xargs -I{} echo "  Failed: {}"

log "Remediation complete. Monitor ${WEB_URL}/status.json for progress."
[[ "$errors" -eq 0 ]]