#!/usr/bin/env bash
# verify-prepull.sh — confirm openstudio-worker image is pre-pulled and cached on all
# eligible Nomad worker nodes before starting a simulation run.
#
# Usage:
#   ./scripts/verify-prepull.sh [options]
#
# Options:
#   --job-name NAME          Base job name prefix (default: openstudio-server)
#   --namespace NS           Nomad namespace (default: $NOMAD_NAMESPACE or "default")
#   --worker-image IMAGE     Local image alias to verify (default: openstudio-worker:local)
#   --hooks-task TASK        Sentinel task name in system-hooks (default: image-cache-ready)
#   --timeout SECONDS        Seconds to wait for allocs to become healthy (default: 0, no wait)
#   --quiet                  Only print failures and summary
#
# Requirements:
#   - NOMAD_ADDR set (or defaults to http://127.0.0.1:4646)
#   - nomad CLI available
#   - jq available
#
# Exit codes:
#   0  All nodes have pre-pulled image and sentinel is running
#   1  One or more nodes are missing the image or sentinel task is unhealthy
#   2  system-hooks job not found
#   3  Dependency missing (nomad, jq)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- defaults ---
JOB_NAME="openstudio-server"
NAMESPACE="${NOMAD_NAMESPACE:-default}"
WORKER_IMAGE="openstudio-worker:local"
HOOKS_TASK="image-cache-ready"
TIMEOUT=0
QUIET=false

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)    JOB_NAME="$2";    shift 2 ;;
    --namespace)   NAMESPACE="$2";   shift 2 ;;
    --worker-image) WORKER_IMAGE="$2"; shift 2 ;;
    --hooks-task)  HOOKS_TASK="$2";  shift 2 ;;
    --timeout)     TIMEOUT="$2";     shift 2 ;;
    --quiet)       QUIET=true;       shift   ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

HOOKS_JOB="${JOB_NAME}-system-hooks"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"

log() { [[ "$QUIET" == "true" ]] || echo "$*"; }
info() { log "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
fail() { echo "[FAIL]  $*" >&2; }

# --- check dependencies ---
for dep in nomad jq; do
  if ! command -v "$dep" &>/dev/null; then
    echo "ERROR: '$dep' not found in PATH — install it before running this script" >&2
    exit 3
  fi
done

info "verify-prepull.sh"
info "  Nomad addr  : ${NOMAD_ADDR}"
info "  Job prefix  : ${JOB_NAME}"
info "  Namespace   : ${NAMESPACE}"
info "  Worker image: ${WORKER_IMAGE}"
info "  Sentinel    : ${HOOKS_JOB} / task=${HOOKS_TASK}"
echo ""

# --- wait loop (optional) ---
deadline=$(( $(date +%s) + TIMEOUT ))

check_allocs() {
  # Returns 0 if all conditions pass, 1 otherwise.
  local failed=0 healthy=0 total=0

  # Get all allocations for the system-hooks job
  allocs_json=$(nomad job allocs \
    -namespace "$NAMESPACE" \
    -json "$HOOKS_JOB" 2>/dev/null) || true

  if [[ -z "$allocs_json" || "$allocs_json" == "null" || "$allocs_json" == "[]" ]]; then
    warn "No allocations found for job '$HOOKS_JOB' in namespace '$NAMESPACE'."
    warn "Is enable_image_prepull = true and was 'nomad-pack run' executed?"
    return 1
  fi

  # Check each allocation
  while IFS= read -r alloc_id; do
    [[ -z "$alloc_id" ]] && continue
    total=$(( total + 1 ))

    alloc_json=$(nomad alloc status -json "$alloc_id" 2>/dev/null) || {
      warn "Could not fetch alloc status for $alloc_id"
      failed=$(( failed + 1 ))
      continue
    }

    node_id=$(echo "$alloc_json" | jq -r '.NodeID // "unknown"')
    node_name=$(echo "$alloc_json" | jq -r '.NodeName // "unknown"')
    client_status=$(echo "$alloc_json" | jq -r '.ClientStatus // "unknown"')

    # Check sentinel task state
    task_state=$(echo "$alloc_json" | jq -r \
      --arg task "$HOOKS_TASK" \
      '.TaskStates[$task].State // "missing"')

    if [[ "$task_state" == "running" ]]; then
      info "  ✅ node=${node_name} (${node_id:0:8}) alloc=${alloc_id:0:8} sentinel=running"
      healthy=$(( healthy + 1 ))
    else
      fail "  ❌ node=${node_name} (${node_id:0:8}) alloc=${alloc_id:0:8} sentinel=${task_state} (client=${client_status})"
      failed=$(( failed + 1 ))
    fi
  done < <(echo "$allocs_json" | jq -r '.[].ID')

  echo ""
  info "verify_prepull_summary total=${total} healthy=${healthy} failed=${failed}"
  [[ "$failed" -eq 0 ]]
}

# Check that the system-hooks job exists
if ! nomad job status -namespace "$NAMESPACE" "$HOOKS_JOB" &>/dev/null; then
  echo "ERROR: Job '$HOOKS_JOB' not found in namespace '$NAMESPACE'." >&2
  echo "       Is enable_image_prepull = true? Has the pack been deployed?" >&2
  exit 2
fi

# Run once (or loop until timeout)
if [[ "$TIMEOUT" -eq 0 ]]; then
  check_allocs
  exit $?
fi

info "Waiting up to ${TIMEOUT}s for all sentinel tasks to reach 'running'..."
while true; do
  if check_allocs; then
    info "All nodes verified. Safe to start simulation run."
    exit 0
  fi
  now=$(date +%s)
  if [[ "$now" -ge "$deadline" ]]; then
    fail "Timed out after ${TIMEOUT}s. Some nodes still unhealthy."
    exit 1
  fi
  remaining=$(( deadline - now ))
  info "Retrying... (${remaining}s remaining)"
  sleep 10
done
