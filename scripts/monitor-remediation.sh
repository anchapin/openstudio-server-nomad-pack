#!/usr/bin/env bash
# monitor-remediation.sh — 15-minute monitoring loop for datapoint remediation
#
# Monitors the recovery progress until all stuck datapoints are processed.
# Reports status every 15 minutes and exits when queue is cleared.

set -euo pipefail

WEB_URL="http://10.60.126.125"
NOMAD_ADDR="http://10.60.126.125:4646"
INTERVAL_SECONDS=900  # 15 minutes
MAX_ITERATIONS=0      # 0 = infinite

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-url)       WEB_URL="$2"; shift 2 ;;
    --nomad-addr)    NOMAD_ADDR="$2"; shift 2 ;;
    --interval)      INTERVAL_SECONDS="$2"; shift 2 ;;
    --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--web-url URL] [--nomad-addr ADDR] [--interval SECONDS] [--max-iterations N]"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
warn() { echo "[$(date -u +%H:%M:%S)] WARN $*" >&2; }

iteration=0
last_queued=-1
last_completed=-1
last_started=-1

log "Starting remediation monitor (interval: ${INTERVAL_SECONDS}s, max_iterations: ${MAX_ITERATIONS:-infinite})"
log "Web URL: $WEB_URL"
log "Nomad: $NOMAD_ADDR"
echo ""

while true; do
  iteration=$((iteration + 1))
  
  if [[ "$MAX_ITERATIONS" -gt 0 && "$iteration" -gt "$MAX_ITERATIONS" ]]; then
    log "Max iterations reached ($MAX_ITERATIONS). Exiting."
    break
  fi

  # Fetch status
  STATUS=$(curl -sf --max-time 10 "${WEB_URL}/status.json" 2>/dev/null) || {
    warn "Could not fetch status from ${WEB_URL}/status.json"
    sleep "$INTERVAL_SECONDS"
    continue
  }

  DP_COUNT=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['count'])")
  DP_QUEUED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['queued'])")
  DP_STARTED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['started'])")
  DP_COMPLETED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_points']['completed'])")
  ANALYSES_COMPLETED=$(echo "$STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['analyses']['completed'])")

  # Calculate deltas
  if [[ "$last_queued" -ge 0 ]]; then
    QUEUED_DELTA=$((last_queued - DP_QUEUED))
    COMPLETED_DELTA=$((DP_COMPLETED - last_completed))
    STARTED_DELTA=$((DP_STARTED - last_started))
  else
    QUEUED_DELTA=0
    COMPLETED_DELTA=0
    STARTED_DELTA=0
  fi

  # Fetch Resque workers
  WORKING_HTML=$(curl -sf --max-time 10 "${WEB_URL}/resque/working" 2>/dev/null) || WORKING_HTML=""
  WORKER_COUNT=$(echo "$WORKING_HTML" | grep -c "ResqueJobs::RunSimulateDataPoint" || echo "0")

  # Fetch Nomad worker allocations
  WORKER_ALLOCS=$(curl -sf --max-time 10 "${NOMAD_ADDR}/v1/job/openstudio-server-worker/allocations" 2>/dev/null | \
    python3 -c "import sys,json; a=json.load(sys.stdin); print(len([x for x in a if x.get('ClientStatus')=='running']))" 2>/dev/null || echo "?")

  # Progress bar for queued
  if [[ "$DP_COUNT" -gt 0 ]]; then
    PCT=$(( (DP_COMPLETED * 100) / DP_COUNT ))
    BAR_LEN=40
    FILLED=$(( (PCT * BAR_LEN) / 100 ))
    BAR=$(printf "%${FILLED}s" | tr ' ' '█')
    BAR+=$(printf "%$((BAR_LEN - FILLED))s" | tr ' ' '░')
  else
    PCT=0
    BAR="$(printf "%40s" | tr ' ' '░')"
  fi

  # Status line
  echo "================================================================================"
  log "ITERATION $iteration — $(date -u)"
  echo "================================================================================"
  printf "  Datapoints:    %6d total | %6d queued | %6d started | %6d completed (%d%%)\n" \
    "$DP_COUNT" "$DP_QUEUED" "$DP_STARTED" "$DP_COMPLETED" "$PCT"
  printf "  Progress:      [%s]\n" "$BAR"
  printf "  Delta (15m):   queued: %+6d | started: %+6d | completed: %+6d\n" \
    "$QUEUED_DELTA" "$STARTED_DELTA" "$COMPLETED_DELTA"
  printf "  Workers:       %d Resque workers | %s Nomad worker allocs\n" \
    "$WORKER_COUNT" "$WORKER_ALLOCS"
  printf "  Analyses:      %d completed (showing 'completed' but waiting for DPs)\n" "$ANALYSES_COMPLETED"

  # Check queue-sweeper
  SWEEPER_STATUS=$(curl -sf --max-time 10 "${NOMAD_ADDR}/v1/job/openstudio-server-queue-sweeper/allocations" 2>/dev/null | \
    python3 -c "import sys,json; a=json.load(sys.stdin); running=[x for x in a if x.get('ClientStatus')=='running']; print('running' if running else 'idle')" 2>/dev/null || echo "?")
  log "  Queue-sweeper: $SWEEPER_STATUS"

  # Check if done
  if [[ "$DP_QUEUED" -eq 0 && "$DP_STARTED" -eq 0 ]]; then
    log "✅ ALL DATAPOINTS PROCESSED! Remediation complete."
    break
  fi

  # Warning if no progress
  if [[ "$last_queued" -ge 0 && "$QUEUED_DELTA" -eq 0 && "$COMPLETED_DELTA" -eq 0 ]]; then
    warn "No progress detected in last interval. Check workers/queue-sweeper."
  fi

  # Update last values
  last_queued=$DP_QUEUED
  last_completed=$DP_COMPLETED
  last_started=$DP_STARTED

  # Estimate time remaining
  if [[ "$COMPLETED_DELTA" -gt 0 ]]; then
    RATE_PER_MIN=$(( COMPLETED_DELTA * 60 / INTERVAL_SECONDS ))
    if [[ "$RATE_PER_MIN" -gt 0 ]]; then
      REMAINING=$(( (DP_QUEUED + DP_STARTED) / RATE_PER_MIN ))
      if [[ "$REMAINING" -gt 0 ]]; then
        HRS=$(( REMAINING / 60 ))
        MINS=$(( REMAINING % 60 ))
        log "  Est. remaining: ~${HRS}h ${MINS}m (at ${RATE_PER_MIN} DPs/min)"
      fi
    fi
  fi

  echo ""
  log "Next check in ${INTERVAL_SECONDS}s... (Ctrl+C to stop)"
  sleep "$INTERVAL_SECONDS"
done

log "Monitor stopped. Final status:"
curl -sf --max-time 10 "${WEB_URL}/status.json" 2>/dev/null | python3 -m json.tool