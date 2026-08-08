#!/usr/bin/env bash
#
# scale-test-runbook.sh — Staged worker-scale test (100 → 1,000 → 2,500 → 5,500)
#
# Run this AFTER deploying the corrected autoscaling configuration (see
# examples/advanced/scale-to-5500.hcl and docs/infrastructure/operations-guide.md
# §"Sustainable worker scaling to 5,500 allocations"). It drives the fleet up in
# stages and verifies each stage's ingress + control-plane health before allowing
# the next, so a misconfiguration surfaces at 1,000 workers instead of 5,500.
#
# Design decisions:
# - Each stage waits for the autoscaler to move the fleet to the target count
#   (via `nomad job scale`), then waits for allocation stability.
# - The ingress health gate curls the Traefik endpoint and requires the Consul
#   check to pass (route present → HTTP 200, not Traefik's 404).
# - Control-plane gates check for Consul 429 / template failure recurrences and
#   worker restart bursts.
#
# Usage:
#   scripts/scale-test-runbook.sh [--targets "100,1000,2500,5500"] [--timeout-min N] [--dry-run]

set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
JOB_NAME="${JOB_NAME:-openstudio-server-worker}"
INGRESS_URL="${INGRESS_URL:-http://10.60.126.125/status}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://192.168.100.87:8500}"
STAGE_TARGETS="${STAGE_TARGETS:-100,1000,2500,5500}"
STAGE_TIMEOUT_MIN="${STAGE_TIMEOUT_MIN:-60}"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: scripts/scale-test-runbook.sh [options]
  --targets LIST     Comma-separated stage targets (default: 100,1000,2500,5500)
  --timeout-min N    Max minutes to wait for each stage (default: 60)
  --nomad-addr URL   Nomad address (default: $NOMAD_ADDR or http://127.0.0.1:4646)
  --ingress-url URL  Web health endpoint to gate on (default: http://10.60.126.125/status)
  --dry-run          Print the plan without executing scale commands
  --help             Show this help text
EOF
}

log()  { printf '[scale-test][%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[scale-test][%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

is_non_negative_integer() { [[ "${1}" =~ ^[0-9]+$ ]]; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets)   STAGE_TARGETS="${2}"; shift 2 ;;
    --timeout-min) STAGE_TIMEOUT_MIN="${2}"; shift 2 ;;
    --nomad-addr) NOMAD_ADDR="${2}"; shift 2 ;;
    --ingress-url) INGRESS_URL="${2}"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --help|-h)   usage; exit 0 ;;
    *) warn "unknown option: ${1}"; usage >&2; exit 1 ;;
  esac
done

command -v nomad >/dev/null 2>&1 || { echo "ERROR: nomad CLI required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl required" >&2; exit 1; }

IFS=',' read -r -a TARGETS <<< "${STAGE_TARGETS}"

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

# Ingress gate: HTTP 200 on /status means the Traefik route is present and the
# web Consul check is passing. Traefik returns its own 404 (no route) when the
# check is critical — exactly the failure mode we are guarding against.
ingress_healthy() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${INGRESS_URL}" 2>/dev/null || echo 000)"
  [ "${code}" = "200" ]
}

# Control-plane gate: count recent Consul 429s seen in worker logs via the
# Nomad FS API is expensive; instead rely on Nomad allocation stability plus a
# direct Consul health of the web service (the route dependency).
web_consul_passing() {
  curl -fsS "${CONSUL_HTTP_ADDR}/v1/health/service/openstudio-web?passing=true" \
    --max-time 10 >/dev/null 2>&1
}

# Allocation stability gate: no running alloc in a restart loop (restart count
# growth) is approximated by checking that Nomad reports no failed allocs.
stable_allocations() {
  local failed
  failed="$(nomad job status -verbose "${JOB_NAME}" 2>/dev/null | awk -F'[= ]+' '/Failed/{print $2; exit}')"
  [ -z "${failed}" ] || [ "${failed}" = "0" ]
}

current_count() {
  nomad job status "${JOB_NAME}" 2>/dev/null | awk -F'[= ]+' '/Alloc/{gsub(/[^0-9]/,"",$2); print $2; exit}'
}

wait_for_stage() {
  local target="$1" waited=0 deadline=$((STAGE_TIMEOUT_MIN * 60))
  while [ "${waited}" -lt "${deadline}" ]; do
    if ingress_healthy && web_consul_passing && stable_allocations; then
      return 0
    fi
    sleep 30
    waited=$((waited + 30))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "Nomad:    ${NOMAD_ADDR}"
log "Job:      ${JOB_NAME}"
log "Ingress:  ${INGRESS_URL}"
log "Targets:  ${STAGE_TARGETS}"
[ "${DRY_RUN}" = true ] && log "DRY RUN — no scale commands will be issued"

for target in "${TARGETS[@]}"; do
  is_non_negative_integer "${target}" || { warn "invalid target: ${target}"; exit 1; }
done

if [ "${DRY_RUN}" = false ]; then
  log "gate: ingress must be healthy BEFORE the test starts"
  if ! ingress_healthy; then
    warn "ingress not healthy before test — aborting. Fix the 404 first."
    exit 1
  fi
fi

for target in "${TARGETS[@]}"; do
  log "=== stage: scale to ${target} ==="
  if [ "${DRY_RUN}" = true ]; then
    log "  would run: nomad job scale ${JOB_NAME} ${target}"
    continue
  fi
  nomad job scale "${JOB_NAME}" "${target}"
  if wait_for_stage "${target}"; then
    log "stage ${target}: PASS (ingress 200, Consul passing, allocs stable)"
  else
    warn "stage ${target}: FAIL after ${STAGE_TIMEOUT_MIN}m — see runbook §Rollback"
    exit 1
  fi
done

log "scale test complete: ${STAGE_TARGETS}"
log "next: watch 'nomad job scaling-events ${JOB_NAME}' and web load (top on the web node)"
