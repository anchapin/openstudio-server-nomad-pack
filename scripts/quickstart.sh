#!/usr/bin/env bash
#
# quickstart.sh — One-command OpenStudio Server dev environment
#
# Starts Consul + Nomad via Docker Compose, deploys the OpenStudio Server
# Nomad Pack, and waits for services to come online.
#
# Prerequisites: Docker + nomad-pack only (no native Nomad/Consul needed)
#
# Usage:
#   bash scripts/quickstart.sh              # Start + deploy everything
#   bash scripts/quickstart.sh --teardown   # Stop and clean up
#   bash scripts/quickstart.sh --status     # Check current state
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker/docker-compose.yaml"
VAR_FILE="${REPO_ROOT}/examples/minimal-dev.hcl"
JOB_NAME="openstudio-server-dev"
NOMAD_API="http://127.0.0.1:4646"
CONSUL_API="http://127.0.0.1:8500"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}==>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Call the Nomad HTTP API and return JSON.
nomad_api() {
  local path="$1"
  shift
  curl -sf "${NOMAD_API}${path}" "$@" 2>/dev/null || true
}

# Call the Consul HTTP API and return JSON.
consul_api() {
  local path="$1"
  shift
  curl -sf "${CONSUL_API}${path}" "$@" 2>/dev/null || true
}

# Check if the Nomad job exists.
job_exists() {
  nomad_api "/v1/job/${JOB_NAME}" -o /dev/null 2>/dev/null
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prereqs() {
  info "Checking prerequisites..."

  command -v docker >/dev/null 2>&1 || {
    err "docker not found. Install Docker Desktop: https://docs.docker.com/get-docker/"
    exit 1
  }
  ok "docker: $(docker --version)"

  docker info >/dev/null 2>&1 || {
    err "Docker daemon not running."
    exit 1
  }

  command -v nomad-pack >/dev/null 2>&1 || {
    err "nomad-pack not found."
    echo "  Install: brew install hashicorp/tap/nomad-pack"
    echo "  Or: https://developer.hashicorp.com/nomad/tools/nomad-pack"
    exit 1
  }
  ok "nomad-pack: $(nomad-pack --version 2>&1 | head -1)"

  docker compose version >/dev/null 2>&1 || {
    err "Docker Compose v2 not available (docker compose)."
    exit 1
  }

  echo ""
}

# ── Infrastructure ────────────────────────────────────────────────────────────
start_infra() {
  info "Starting Consul and Nomad via Docker Compose..."
  docker compose -f "$COMPOSE_FILE" up -d
  ok "Containers started."

  info "Waiting for Nomad API to be ready..."
  for i in $(seq 1 30); do
    if nomad_api "/v1/agent/self" -o /dev/null >/dev/null 2>&1; then
      ok "Nomad ready."
      break
    fi
    if [ "$i" -eq 30 ]; then
      err "Nomad did not become ready within 60s."
      err "Check: docker compose -f ${COMPOSE_FILE} logs nomad"
      exit 1
    fi
    sleep 2
  done

  # Quick wait for Consul too
  for i in $(seq 1 15); do
    if consul_api "/v1/status/leader" -o /dev/null >/dev/null 2>&1; then
      ok "Consul ready."
      break
    fi
    sleep 1
  done

  echo ""
  info "Nomad:  ${NOMAD_API}"
  info "Consul: ${CONSUL_API}"
  echo ""
}

# ── Deployment ────────────────────────────────────────────────────────────────
deploy_pack() {
  # Check if already deployed
  if job_exists; then
    warn "Job '${JOB_NAME}' already exists. Skipping deploy."
    warn "Run 'make redeploy' to re-deploy, or 'make stop' first."
    return 0
  fi

  info "Deploying OpenStudio Server (nomad-pack run)..."
  nomad-pack run -var-file "$VAR_FILE" "$REPO_ROOT"
  ok "Pack submitted."

  echo ""

  # Wait for job to appear in API
  for i in $(seq 1 15); do
    if job_exists; then
      break
    fi
    sleep 2
  done

  info "Waiting for all task groups to reach 'running' (up to 3 min)..."
  echo ""

  # Poll the Nomad job API for task group status
  ALL_RUNNING=false
  for i in $(seq 1 36); do
    local job_json
    job_json=$(nomad_api "/v1/job/${JOB_NAME}") || true

    if [ -z "$job_json" ] || [ "$job_json" = "null" ]; then
      sleep 5
      continue
    fi

    # Parse task group statuses from the API
    # TaskGroups is an array of objects with Name and Status
    local groups_json
    groups_json=$(echo "$job_json" | python3 -c "
import sys, json
try:
    job = json.load(sys.stdin)
    groups = job.get('TaskGroups', [])
    results = []
    for g in groups:
        status = g.get('Status', '')
        results.append(f\"{g['Name']}={status}\")
    print('|'.join(results) if results else '')
except Exception:
    print('')
" 2>/dev/null) || groups_json=""

    # Print progress
    local running_count=0
    local total_count=0
    for entry in $(echo "$groups_json" | tr '|' ' '); do
      total_count=$((total_count + 1))
      local name="${entry%%=*}"
      local status="${entry#*=}"
      [ "$status" = "running" ] && running_count=$((running_count + 1))
    done

    printf "\r  Waiting... ${running_count}/${total_count} groups running"

    if [ "$running_count" -ge 6 ] 2>/dev/null; then
      ALL_RUNNING=true
      printf "\r  Waiting... ${running_count}/${total_count} groups running\n"
      break
    fi

    # Check for failed groups
    local failed
    failed=$(echo "$job_json" | python3 -c "
import sys, json
try:
    job = json.load(sys.stdin)
    for g in job.get('TaskGroups', []):
        if g.get('Status') == 'failed':
            print(g['Name'])
except Exception:
    pass
" 2>/dev/null) || true
    if [ -n "$failed" ]; then
      echo ""
      warn "Task group '$failed' has failed. Check: ${NOMAD_API}/ui/jobs/${JOB_NAME}"
      break
    fi

    sleep 5
  done
  echo ""

  if [ "$ALL_RUNNING" = true ]; then
    ok "All 6 task groups are running!"
  else
    warn "Not all groups reached 'running' within the timeout."
    warn "Check UI: ${NOMAD_API}/ui/jobs/${JOB_NAME}"
  fi

  echo ""
}

# ── Verification ──────────────────────────────────────────────────────────────
verify_services() {
  info "Checking Consul service registrations..."
  local services_json
  services_json=$(consul_api "/v1/catalog/services") || services_json="{}"

  for svc in "openstudio-db" "openstudio-redis" "openstudio-rserve" "openstudio-web"; do
    if echo "$services_json" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if '$svc' in d else 1)" 2>/dev/null; then
      ok "Consul: ${svc} registered"
    else
      warn "Consul: ${svc} NOT YET registered"
    fi
  done

  echo ""

  # Check web HTTP endpoint
  info "Checking web UI..."
  for i in $(seq 1 12); do
    if curl -sf http://localhost:8080/up >/dev/null 2>&1; then
      ok "Web UI is responding at http://localhost:8080"
      break
    fi
    if [ "$i" -eq 12 ]; then
      warn "Web UI not yet responding. It may still be starting."
    fi
    sleep 5
  done

  echo ""
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  OpenStudio Server is ready!"
  echo ""
  echo "  Web UI:  http://localhost:8080"
  echo "  Nomad:   ${NOMAD_API}"
  echo "  Consul:  ${CONSUL_API}"
  echo ""
  echo "  Commands:"
  echo "    make status     — Check job/node/service status"
  echo "    make logs       — Tail Nomad agent logs"
  echo "    make web        — Tail web task logs"
  echo "    make open       — Open web UI in browser"
  echo "    make down       — Stop everything and clean up"
  echo "══════════════════════════════════════════════════════════════"
  echo ""
}

# ── Teardown ──────────────────────────────────────────────────────────────────
teardown() {
  info "Stopping OpenStudio Server job..."
  curl -sf -X PUT "${NOMAD_API}/v1/job/${JOB_NAME}/deregister" >/dev/null 2>&1 || true
  ok "Job stopped."

  info "Stopping Docker Compose infrastructure..."
  docker compose -f "$COMPOSE_FILE" down -v
  ok "Infrastructure stopped and volumes cleaned."
  echo ""
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  echo "=== Nomad Job ==="
  local job_json
  job_json=$(nomad_api "/v1/job/${JOB_NAME}") || true
  if [ -n "$job_json" ] && [ "$job_json" != "null" ]; then
    echo "$job_json" | python3 -c "
import sys, json
job = json.load(sys.stdin)
tg = job.get('TaskGroups', [])
print(f\"  Name: {job.get('Name', '?')}\")
for g in tg:
    s = g.get('Status', '?')
    c = g.get('Count', '?')
    print(f\"  Group: {g['Name']}  Status: {s}  Count: {c}\")
" 2>/dev/null || echo "  (parse error)"
  else
    echo "  (none)"
  fi

  echo ""
  echo "=== Nomad Nodes ==="
  local nodes_json
  nodes_json=$(nomad_api "/v1/nodes") || true
  if [ -n "$nodes_json" ]; then
    echo "$nodes_json" | python3 -c "
import sys, json
for n in json.load(sys.stdin):
    print(f\"  {n['ID'][:8]}  {n['Datacenter']}  {n['Name']}  Status:{n['Status']}  Eligible:{n.get('SchedulingEligibility','?')}\")
" 2>/dev/null
  fi

  echo ""
  echo "=== Consul Services ==="
  local svc_json
  svc_json=$(consul_api "/v1/catalog/services") || true
  if [ -n "$svc_json" ]; then
    echo "$svc_json" | python3 -c "
import sys, json
for s in sorted(json.load(sys.stdin).keys()):
    if 'openstudio' in s:
        print(f'  {s}')
" 2>/dev/null || echo "  (none)"
  fi

  echo ""
  echo "=== Web UI Health ==="
  curl -sf http://localhost:8080/up >/dev/null 2>&1 && echo "  UP at http://localhost:8080" || echo "  NOT RESPONDING"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local cmd="${1:-up}"

  case "${cmd}" in
    --teardown|-t|down)
      teardown
      ;;
    --status|-s|status)
      show_status
      ;;
    --help|-h)
      echo "Usage: bash scripts/quickstart.sh [OPTION]"
      echo ""
      echo "Options:"
      echo "  (no args)    Start infra, deploy pack, verify (default)"
      echo "  --teardown   Stop job, stop Docker, clean volumes"
      echo "  --status     Show current deployment status"
      echo "  --help       Show this help"
      echo ""
      echo "Prerequisites: Docker + nomad-pack"
      ;;
    *)
      check_prereqs
      start_infra
      deploy_pack
      verify_services
      print_summary
      ;;
  esac
}

main "$@"
