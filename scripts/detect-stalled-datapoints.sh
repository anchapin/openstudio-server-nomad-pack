#!/usr/bin/env bash
# detect-stalled-datapoints.sh
#
# Detect data points stuck in "started" status with no updated_at progress
# for longer than MAX_STALL_SECONDS. These indicate hung EnergyPlus processes
# that are holding Resque worker slots without making progress.
#
# When stalled DPs are found, optionally restarts the worker Nomad allocations
# to free the slots and allow the analysis coordinators to re-queue the work.
#
# Usage:
#   ./scripts/detect-stalled-datapoints.sh [--dry-run] [--max-stall <seconds>]
#     [--nomad-addr <addr>] [--web-url <url>] [--restart-allocs]
#
# Options:
#   --dry-run              Report stalled DPs but take no action (default: report only)
#   --restart-allocs       If stalled DPs found, restart worker allocations
#   --max-stall <seconds>  Seconds of no updated_at progress before DP is stalled
#                          (default: 3600 — 60 min, safe above longest normal sim)
#   --nomad-addr <addr>    Nomad API (default: http://localhost:4646)
#   --web-url <url>        OpenStudio Server web URL (default: http://localhost)
#
# Exit codes:
#   0  No stalled DPs
#   1  Error
#   2  Stalled DPs found (useful as alert gate in CI/cron)

set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:-http://localhost:4646}"
WEB_URL="${WEB_URL:-http://localhost}"
MAX_STALL_SECONDS=3600
DRY_RUN=true
RESTART_ALLOCS=false
JOB_NAME="openstudio-server-worker"

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)        DRY_RUN=true; shift ;;
    --restart-allocs) RESTART_ALLOCS=true; shift ;;
    --max-stall)      MAX_STALL_SECONDS="$2"; shift 2 ;;
    --nomad-addr)     NOMAD_ADDR="$2"; shift 2 ;;
    --web-url)        WEB_URL="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "==> Checking for stalled data points"
echo "    Web URL:        ${WEB_URL}"
echo "    Nomad addr:     ${NOMAD_ADDR}"
echo "    Max stall age:  ${MAX_STALL_SECONDS}s ($(( MAX_STALL_SECONDS / 60 )) min)"
echo "    Dry run:        ${DRY_RUN}"
echo "    Restart allocs: ${RESTART_ALLOCS}"
echo ""

# Fetch server status
STATUS=$(curl -sf --max-time 10 "${WEB_URL}/status.json" 2>/dev/null) || {
  echo "ERROR: Could not reach ${WEB_URL}/status.json"
  exit 1
}

STARTED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['started'])")
COMPLETED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['completed'])")
TOTAL=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['count'])")

echo "  DataPoints: completed=${COMPLETED}  started=${STARTED}  total=${TOTAL}"

if [[ "$STARTED" -eq 0 ]]; then
  echo ""
  echo "  No data points currently started — nothing to check."
  exit 0
fi

# Sample up to 10 started DPs across analyses to check their updated_at age
echo "  Sampling started DP ages via analysis status API..."

NOW_EPOCH=$(date +%s)
STALLED_COUNT=0
SAMPLE_IDS=""

# Get list of started analyses
ANALYSES_STARTED=$(echo "$STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['analyses']['started'])
")

if [[ "$ANALYSES_STARTED" -gt 0 ]]; then
  # Check a sample of active analyses for stalled DPs
  # Use the working Resque page to get analysis IDs in flight
  RESQUE_WORKING=$(curl -sf --max-time 15 "${WEB_URL}/resque/working" 2>/dev/null) || ""
  SAMPLE_IDS=$(echo "$RESQUE_WORKING" | python3 -c "
import sys, re
html = sys.stdin.read()
import re
uuids = list(dict.fromkeys(re.findall(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', html)))
# Print first 5 unique UUIDs (DP IDs from RunSimulateDataPoint args)
print('\n'.join(uuids[:5]))
  " 2>/dev/null) || ""

  for DP_ID in $SAMPLE_IDS; do
    DP_JSON=$(curl -sf --max-time 5 "${WEB_URL}/data_points/${DP_ID}.json" 2>/dev/null) || continue
    UPDATED_AT=$(echo "$DP_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
dp = d.get('data_point', d)
print(dp.get('updated_at','') or '')
" 2>/dev/null) || continue

    if [[ -z "$UPDATED_AT" ]]; then continue; fi

    # Parse updated_at (UTC ISO format) to epoch
    UPDATED_EPOCH=$(python3 -c "
from datetime import datetime, timezone
import sys
ts = '${UPDATED_AT}'.replace('Z','').split('+')[0].split('.')[0]
try:
    dt = datetime.fromisoformat(ts).replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except: print(0)
")

    if [[ "$UPDATED_EPOCH" -eq 0 ]]; then continue; fi

    IDLE_SECS=$(( NOW_EPOCH - UPDATED_EPOCH ))
    if [[ "$IDLE_SECS" -gt "$MAX_STALL_SECONDS" ]]; then
      STALLED_COUNT=$(( STALLED_COUNT + 1 ))
      echo "  STALLED DP: ${DP_ID} — idle ${IDLE_SECS}s ($(( IDLE_SECS / 60 )) min) since ${UPDATED_AT}"
    fi
  done
fi

echo ""
if [[ "$STALLED_COUNT" -eq 0 ]]; then
  echo "  No stalled data points detected (sampled ${#SAMPLE_IDS} DPs, max idle < ${MAX_STALL_SECONDS}s)."
  exit 0
fi

echo "  ⚠️  ${STALLED_COUNT} stalled DP(s) detected (idle > $(( MAX_STALL_SECONDS / 60 )) min)"

if [[ "$DRY_RUN" == "true" ]] && [[ "$RESTART_ALLOCS" == "false" ]]; then
  echo "  Dry run — no action taken. Re-run with --restart-allocs to recover."
  exit 2
fi

if [[ "$RESTART_ALLOCS" == "true" ]]; then
  echo ""
  echo "==> Restarting worker allocations to free stalled Resque slots..."
  ALLOCS=$(curl -sf --max-time 10 "${NOMAD_ADDR}/v1/job/${JOB_NAME}/allocations" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
running = [a['ID'] for a in d if a['ClientStatus'] == 'running']
print('\n'.join(running))
")

  for ALLOC_ID in $ALLOCS; do
    echo "  Stopping alloc ${ALLOC_ID:0:8}..."
    RESULT=$(curl -sf --max-time 15 -X POST \
      "${NOMAD_ADDR}/v1/allocation/${ALLOC_ID}/stop" 2>/dev/null) || {
      echo "  WARNING: failed to stop ${ALLOC_ID:0:8}"
      continue
    }
    EVAL_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('EvalID','?')[:8])")
    echo "  Stopped ${ALLOC_ID:0:8} → eval ${EVAL_ID}"
  done
  echo ""
  echo "  Nomad will reschedule fresh worker allocations automatically."
  echo "  The analysis coordinators will re-queue the stalled DPs once new workers register."
fi

exit 2
