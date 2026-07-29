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
# NOTE: no `|| true` here — callers handle failure (in `if` conditions
# or via their own `|| true`). Without the exit code, readiness loops
# never detect failure.
nomad_api() {
  local path="$1"
  shift
  curl -sf "${NOMAD_API}${path}" "$@"
}

# Call the Consul HTTP API and return JSON.
consul_api() {
  local path="$1"
  shift
  curl -sf "${CONSUL_API}${path}" "$@"
}

# Check if any Nomad jobs with our prefix exist.
# The pack renders multiple jobs (web, worker, db, redis, rserve, ...).
job_exists() {
  nomad_api "/v1/jobs?prefix=${JOB_NAME}" -o /dev/null 2>/dev/null
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

  # Wait for at least one job to appear in API
  for i in $(seq 1 15); do
    if job_exists; then
      break
    fi
    sleep 2
  done

  info "Waiting for all services to reach 'running' (up to 3 min)..."
  echo ""

  # Poll the Nomad jobs API for all rendered jobs with our prefix.
  # The pack renders: -web, -worker, -db, -redis, -rserve (always),
  # plus optionally -system-hooks, -batch-verify, -state-backup,
  # -state-restore, -test, -nomad-autoscaler.  We check for at
  # least the 5 core services.
  ALL_RUNNING=false
  for i in $(seq 1 36); do
    local jobs_json
    jobs_json=$(nomad_api "/v1/jobs?prefix=${JOB_NAME}") || jobs_json="[]"

    # Parse job statuses — each entry has ID and Status fields
    local jobs_status
    jobs_status=$(echo "$jobs_json" | python3 -c "
import sys, json
try:
    jobs = json.load(sys.stdin)
    core = ['-web', '-worker', '-db', '-redis', '-rserve']
    results = []
    for j in jobs:
        jid = j.get('ID', '')
        status = j.get('Status', '')
        for suffix in core:
            if jid.endswith(suffix):
                results.append(f'{jid}={status}')
                break
    print('|'.join(results) if results else '')
except Exception:
    print('')
" 2>/dev/null) || jobs_status=""

    local running_count=0
    local total_count=0
    for entry in $(echo "$jobs_status" | tr '|' ' '); do
      total_count=$((total_count + 1))
      local name="${entry%%=*}"
      local status="${entry#*=}"
      [ "$status" = "running" ] && running_count=$((running_count + 1))
    done

    printf "\r  Waiting... ${running_count}/${total_count} core jobs running"

    if [ "$running_count" -ge 5 ] 2>/dev/null; then
      ALL_RUNNING=true
      printf "\r  Waiting... ${running_count}/${total_count} core jobs running\n"
      break
    fi

    # Check for failed jobs
    local failed
    failed=$(echo "$jobs_status" | python3 -c "
import sys, json
try:
    jobs = json.load(sys.stdin)
    for j in jobs:
        if j.get('Status') == 'failed':
            print(j.get('ID', ''))
except Exception:
    pass
" 2>/dev/null) || true
    if [ -n "$failed" ]; then
      echo ""
      warn "Job '$failed' has failed. Check: ${NOMAD_API}/ui/jobs/${JOB_NAME}"
      break
    fi

    sleep 5
  done
  echo ""

  if [ "$ALL_RUNNING" = true ]; then
    ok "All 5 core services (web, worker, db, redis, rserve) are running!"
  else
    warn "Not all services reached 'running' within the timeout."
    warn "Check UI: ${NOMAD_API}/ui/jobs"
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
  info "Stopping all OpenStudio Server jobs..."
  # The pack renders multiple jobs (-web, -worker, -db, -redis, -rserve, ...).
  # Enumerate them via the prefix API and deregister each.
  local job_ids
  job_ids=$(nomad_api "/v1/jobs?prefix=${JOB_NAME}" 2>/dev/null | python3 -c "
import sys, json
try:
    for j in json.load(sys.stdin):
        print(j.get('ID', ''))
except Exception:
    pass
" 2>/dev/null || true)

  if [ -n "$job_ids" ]; then
    for id in $job_ids; do
      info "  Stopping ${id}..."
      curl -sf -X PUT "${NOMAD_API}/v1/job/${id}/deregister" >/dev/null 2>&1 || true
    done
    ok "All jobs stopped."
  else
    warn "No jobs found with prefix '${JOB_NAME}'."
  fi

  info "Stopping Docker Compose infrastructure..."
  docker compose -f "$COMPOSE_FILE" down -v
  ok "Infrastructure stopped and volumes cleaned."
  echo ""
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  echo "=== Nomad Jobs (prefix: ${JOB_NAME}) ==="
  local job_json
  job_json=$(nomad_api "/v1/jobs?prefix=${JOB_NAME}") || true
  if [ -n "$job_json" ] && [ "$job_json" != "[]" ] && [ "$job_json" != "null" ]; then
    echo "$job_json" | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
for j in jobs:
    print(f\"  {j['ID']:40s} Status: {j.get('Status', '?'):10s} Type: {j.get('Type', '?'):10s} Priority: {j.get('Priority', '?')}\")
" 2>/dev/null || echo "  (none)"
  else
    echo "  (no jobs found)"
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
