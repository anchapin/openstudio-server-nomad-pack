#!/usr/bin/env bash
#
# deploy-openstack.sh — Deploy OpenStudio Server Nomad Pack to the NREL OpenStack cluster.
#
# Manages the full lifecycle: SSH tunnel, Consul bootstrap, Nomad client infra
# setup, pack deploy, health polling, and teardown.
#
# Prerequisites (local):
#   - nomad-pack (brew install hashicorp/tap/nomad-pack)
#   - nomad      (brew install hashicorp/tap/nomad)
#   - ssh key:   ~/.ssh/id_rsa
#   - openstack credentials in ~/.zshrc (for quota/server queries only)
#
# Usage:
#   bash scripts/deploy-openstack.sh                # Full bootstrap + deploy
#   bash scripts/deploy-openstack.sh --deploy       # Pack deploy only (tunnel must be open)
#   bash scripts/deploy-openstack.sh --bootstrap    # Consul + infra-setup only (no pack deploy)
#   bash scripts/deploy-openstack.sh --status       # Show job/service status
#   bash scripts/deploy-openstack.sh --logs [job]   # Tail logs (default: web)
#   bash scripts/deploy-openstack.sh --ui           # Tunnel + open Nomad UI
#   bash scripts/deploy-openstack.sh --teardown     # Stop pack + infra-setup
#   bash scripts/deploy-openstack.sh --tunnel       # Open tunnel only (foreground)
#
# Environment overrides:
#   NOMAD_ADDR       Override Nomad API address (default: http://localhost:4646)
#   OS_VAR_FILE      Override var-file (default: examples/openstack.hcl)
#   OS_JOB_NAME      Override job name  (default: openstudio-server)
#   OS_WORKER_COUNT  Override initial worker count (default: from var-file)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Config ────────────────────────────────────────────────────────────────────
JUMP_HOST="ubuntu@10.60.105.39"
NOMAD_SERVER="ubuntu@10.60.126.125"
NOMAD_SERVER_IP="10.60.126.125"     # nomad-server's nomad-net IP (used for Consul tunnel)
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30"

TUNNEL_LOCAL_PORT=4646
CONSUL_LOCAL_PORT=8500
CONSUL_VERSION="1.17.3"

NOMAD_API="${NOMAD_ADDR:-http://127.0.0.1:${TUNNEL_LOCAL_PORT}}"
CONSUL_API="http://127.0.0.1:${CONSUL_LOCAL_PORT}"

VAR_FILE="${OS_VAR_FILE:-${REPO_ROOT}/examples/openstack.hcl}"
JOB_NAME="${OS_JOB_NAME:-openstudio-server}"
INFRA_JOB="${REPO_ROOT}/infra-setup.nomad"

TUNNEL_PID_FILE="/tmp/nomad-openstack-tunnel.pid"
CONSUL_TUNNEL_PID_FILE="/tmp/consul-openstack-tunnel.pid"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $*"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
err()     { echo -e "${RED}✗${NC} $*"; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

# ── SSH helpers ───────────────────────────────────────────────────────────────
ssh_nomad_server() {
  ssh ${SSH_OPTS} -J "${JUMP_HOST}" "${NOMAD_SERVER}" "$@"
}

ssh_client() {
  local host="$1"; shift
  ssh ${SSH_OPTS} -J "${JUMP_HOST}" "ubuntu@${host}" "$@"
}

# Kill any process holding a local TCP port (stale tunnels).
_kill_port() {
  local port="$1"
  local pid
  pid=$(lsof -ti "TCP:${port}" 2>/dev/null | head -1 || true)
  if [ -n "${pid}" ]; then
    kill "${pid}" 2>/dev/null || true
    sleep 1
  fi
}

# ── Tunnel management ─────────────────────────────────────────────────────────
tunnel_running() {
  curl -sf --connect-timeout 2 "${NOMAD_API}/v1/status/leader" >/dev/null 2>&1
}

consul_tunnel_running() {
  curl -sf --connect-timeout 2 "${CONSUL_API}/v1/status/leader" >/dev/null 2>&1
}

start_tunnel() {
  if tunnel_running; then
    ok "Nomad tunnel already open (${NOMAD_API})"
    return 0
  fi
  info "Opening SSH tunnel → Nomad API (localhost:${TUNNEL_LOCAL_PORT})..."

  # Kill any stale process holding the port (e.g. a failed previous tunnel)
  _kill_port "${TUNNEL_LOCAL_PORT}"

  # ProxyJump through openstudio-mcp to nomad-server, then forward nomad-server's
  # 127.0.0.1:4646 → local port. Using explicit 127.0.0.1 (not 'localhost') on
  # both sides avoids IPv6/IPv4 ambiguity that causes "Connection reset" errors.
  ssh ${SSH_OPTS} \
    -N -f \
    -J "${JUMP_HOST}" \
    -L "127.0.0.1:${TUNNEL_LOCAL_PORT}:127.0.0.1:4646" \
    "${NOMAD_SERVER}"
  # Capture the background SSH PID
  sleep 1
  lsof -ti "TCP:${TUNNEL_LOCAL_PORT}" 2>/dev/null | head -1 > "${TUNNEL_PID_FILE}" || true
  for i in $(seq 1 15); do
    if tunnel_running; then
      ok "Nomad tunnel open → ${NOMAD_API}"
      return 0
    fi
    sleep 1
  done
  err "Nomad tunnel failed to become ready."
  exit 1
}

start_consul_tunnel() {
  if consul_tunnel_running; then
    ok "Consul tunnel already open (${CONSUL_API})"
    return 0
  fi
  info "Opening SSH tunnel → Consul UI (localhost:${CONSUL_LOCAL_PORT})..."

  _kill_port "${CONSUL_LOCAL_PORT}"

  # Same ProxyJump pattern — Consul binds to 0.0.0.0 on nomad-server after install.
  ssh ${SSH_OPTS} \
    -N -f \
    -J "${JUMP_HOST}" \
    -L "127.0.0.1:${CONSUL_LOCAL_PORT}:127.0.0.1:8500" \
    "${NOMAD_SERVER}"
  sleep 1
  lsof -ti "TCP:${CONSUL_LOCAL_PORT}" 2>/dev/null | head -1 > "${CONSUL_TUNNEL_PID_FILE}" || true
  for i in $(seq 1 10); do
    if consul_tunnel_running; then
      ok "Consul tunnel open → ${CONSUL_API}"
      return 0
    fi
    sleep 1
  done
  warn "Consul tunnel did not become ready (Consul may not be installed yet)."
}

stop_tunnel() {
  for pid_file in "${TUNNEL_PID_FILE}" "${CONSUL_TUNNEL_PID_FILE}"; do
    if [ -f "${pid_file}" ]; then
      PID=$(cat "${pid_file}")
      if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
        kill "${PID}" 2>/dev/null && echo "Closed tunnel (pid ${PID})"
      fi
      rm -f "${pid_file}"
    fi
  done
  # Kill any lingering tunnels on these ports
  for port in "${TUNNEL_LOCAL_PORT}" "${CONSUL_LOCAL_PORT}"; do
    local pid
    pid=$(lsof -ti "TCP:${port}" 2>/dev/null | head -1 || true)
    if [ -n "${pid}" ]; then
      kill "${pid}" 2>/dev/null && echo "Closed tunnel on port ${port} (pid ${pid})" || true
    fi
  done
}

# ── API helpers ───────────────────────────────────────────────────────────────
nomad_api() {
  local path="$1"; shift
  NOMAD_ADDR="${NOMAD_API}" curl -sf "${NOMAD_API}${path}" "$@"
}

consul_api() {
  local path="$1"; shift
  curl -sf "${CONSUL_API}${path}" "$@"
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prereqs() {
  section "Checking prerequisites"
  local ok=true

  command -v nomad-pack >/dev/null 2>&1 || { err "nomad-pack not found. Install: brew install hashicorp/tap/nomad-pack"; ok=false; }
  command -v nomad      >/dev/null 2>&1 || { err "nomad not found. Install: brew install hashicorp/tap/nomad"; ok=false; }
  command -v ssh        >/dev/null 2>&1 || { err "ssh not found."; ok=false; }
  command -v python3    >/dev/null 2>&1 || { err "python3 not found."; ok=false; }

  [ -f "${SSH_KEY}" ] || { err "SSH key not found: ${SSH_KEY}"; ok=false; }
  [ -f "${VAR_FILE}" ] || { err "Var file not found: ${VAR_FILE}"; ok=false; }
  [ -f "${INFRA_JOB}" ] || { err "Infra job not found: ${INFRA_JOB}"; ok=false; }

  $ok || exit 1

  ok "nomad-pack: $(nomad-pack --version 2>&1 | head -1)"
  ok "nomad:      $(nomad version 2>&1 | head -1)"
  ok "var-file:   ${VAR_FILE}"
  ok "infra-job:  ${INFRA_JOB}"

  # Test jump host connectivity
  info "Testing SSH jump host (${JUMP_HOST})..."
  ssh ${SSH_OPTS} -o ConnectTimeout=8 "${JUMP_HOST}" "echo ok" >/dev/null 2>&1 \
    && ok "Jump host reachable" \
    || { err "Cannot reach jump host ${JUMP_HOST}. Check VPN/network."; exit 1; }
}

# ── Consul bootstrap on nomad-server ─────────────────────────────────────────
install_consul_server() {
  section "Consul server on nomad-server"

  # Check if already running
  if ssh_nomad_server "systemctl is-active --quiet consul 2>/dev/null && consul members >/dev/null 2>&1"; then
    ok "Consul server already running on nomad-server"
    return 0
  fi

  info "Installing Consul ${CONSUL_VERSION} on nomad-server..."
  ssh_nomad_server bash -s << ENDSSH
set -e
CONSUL_VERSION="${CONSUL_VERSION}"

# Install binary if missing or wrong version
if ! consul version 2>/dev/null | grep -q "${CONSUL_VERSION}"; then
  curl -fsSL "https://releases.hashicorp.com/consul/\${CONSUL_VERSION}/consul_\${CONSUL_VERSION}_linux_amd64.zip" \
    -o /tmp/consul.zip
  sudo unzip -o /tmp/consul.zip consul -d /usr/local/bin/
  sudo chmod +x /usr/local/bin/consul
  rm -f /tmp/consul.zip
fi

sudo mkdir -p /etc/consul.d /opt/consul/data

SERVER_IP=\$(ip -4 addr show ens3 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
echo "Binding Consul to: \${SERVER_IP}"

sudo tee /etc/consul.d/server.hcl > /dev/null <<HCL
datacenter   = "dc1"
data_dir     = "/opt/consul/data"
server       = true
bootstrap_expect = 1
bind_addr    = "\${SERVER_IP}"
client_addr  = "0.0.0.0"
ui_config { enabled = true }
HCL

sudo tee /etc/systemd/system/consul.service > /dev/null <<SVC
[Unit]
Description=Consul
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
SVC

sudo systemctl daemon-reload
sudo systemctl enable consul
sudo systemctl restart consul
sleep 3
consul members
echo "Consul server ready at \${SERVER_IP}:8500"
ENDSSH
  ok "Consul server installed and running"
}

# ── Infra setup system job ────────────────────────────────────────────────────
deploy_infra_setup() {
  section "Infra setup (Docker data-root + Consul config on all clients)"

  if ! tunnel_running; then
    err "Nomad tunnel not open. Run with --tunnel first or use full bootstrap."
    exit 1
  fi

  # Check if already complete (all allocations in 'running' state)
  RUNNING=$(nomad_api "/v1/job/infra-setup/allocations" 2>/dev/null | \
    python3 -c "
import sys, json
try:
  allocs = json.load(sys.stdin)
  running = sum(1 for a in allocs if a.get('ClientStatus') == 'running')
  total   = len(allocs)
  print(f'{running}/{total}')
except Exception:
  print('0/0')
" 2>/dev/null) || RUNNING="0/0"

  if echo "${RUNNING}" | grep -qv "^0/"; then
    ok "infra-setup already running (${RUNNING} allocations active)"
    return 0
  fi

  info "Deploying infra-setup system job to all Nomad clients..."
  NOMAD_ADDR="${NOMAD_API}" nomad job run "${INFRA_JOB}"
  ok "infra-setup submitted"

  info "Waiting for all client nodes to complete setup (up to 5 min)..."
  local NODE_COUNT
  NODE_COUNT=$(nomad_api "/v1/nodes" 2>/dev/null | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null) || NODE_COUNT=34

  for i in $(seq 1 60); do
    RUNNING=$(nomad_api "/v1/job/infra-setup/allocations" 2>/dev/null | \
      python3 -c "
import sys, json
try:
  allocs = json.load(sys.stdin)
  by_status = {}
  for a in allocs:
    s = a.get('ClientStatus', 'unknown')
    by_status[s] = by_status.get(s, 0) + 1
  total = len(allocs)
  running = by_status.get('running', 0)
  failed  = by_status.get('failed', 0)
  print(f'{running}/{total} running, {failed} failed')
except Exception:
  print('?')
" 2>/dev/null) || RUNNING="?"

    printf "\r  Progress: ${RUNNING} (expected ${NODE_COUNT} nodes)"

    # Check for failures
    if echo "${RUNNING}" | grep -qE "[1-9]+ failed"; then
      echo ""
      warn "Some allocations failed. Check: ${NOMAD_API}/ui/jobs/infra-setup"
    fi

    # Done when running count equals node count
    RUNNING_N=$(echo "${RUNNING}" | grep -oE "^[0-9]+" || echo "0")
    if [ "${RUNNING_N}" -ge "${NODE_COUNT}" ] 2>/dev/null; then
      echo ""
      ok "All ${NODE_COUNT} nodes configured"
      break
    fi

    sleep 5
  done
  echo ""
}

# ── Pack deployment ───────────────────────────────────────────────────────────
deploy_pack() {
  section "Deploying openstudio-server-nomad-pack"

  if ! tunnel_running; then
    err "Nomad tunnel not open."
    exit 1
  fi

  # Check if already deployed
  EXISTING=$(nomad_api "/v1/jobs?prefix=${JOB_NAME}" 2>/dev/null | \
    python3 -c "import sys,json; j=json.load(sys.stdin); print(len(j))" 2>/dev/null) || EXISTING=0
  if [ "${EXISTING}" -gt 0 ] 2>/dev/null; then
    warn "Jobs with prefix '${JOB_NAME}' already exist (${EXISTING} jobs)."
    warn "Run with --redeploy to stop + redeploy, or --teardown first."
    return 0
  fi

  info "Running: nomad-pack run --var-file ${VAR_FILE} --name ${JOB_NAME} ."
  NOMAD_ADDR="${NOMAD_API}" nomad-pack run \
    --var-file "${VAR_FILE}" \
    --name "${JOB_NAME}" \
    "${REPO_ROOT}"
  ok "Pack submitted"

  wait_for_healthy
}

stop_pack() {
  section "Stopping openstudio-server pack"

  if ! tunnel_running; then start_tunnel; fi

  IDS=$(nomad_api "/v1/jobs?prefix=${JOB_NAME}" 2>/dev/null | \
    python3 -c "import sys,json; [print(j['ID']) for j in json.load(sys.stdin)]" 2>/dev/null) || IDS=""

  if [ -z "${IDS}" ]; then
    warn "No jobs found with prefix '${JOB_NAME}'"
    return 0
  fi

  NOMAD_ADDR="${NOMAD_API}" nomad-pack destroy \
    --var-file "${VAR_FILE}" \
    --name "${JOB_NAME}" \
    "${REPO_ROOT}" || true
  ok "Pack jobs stopped"
}

# ── Health polling ────────────────────────────────────────────────────────────
wait_for_healthy() {
  section "Waiting for all core services to reach 'running'"
  echo "  Expected order: db → redis → rserve → web → worker"
  echo "  (web wait-for-deps blocks until db, redis, rserve are healthy in Consul)"
  echo ""

  local CORE=("${JOB_NAME}-db" "${JOB_NAME}-redis" "${JOB_NAME}-rserve" "${JOB_NAME}-web" "${JOB_NAME}-worker")
  local ALL_RUNNING=false

  for i in $(seq 1 72); do  # 6 min timeout
    local JOBS_JSON
    JOBS_JSON=$(nomad_api "/v1/jobs?prefix=${JOB_NAME}" 2>/dev/null) || JOBS_JSON="[]"

    local STATUS_LINE
    STATUS_LINE=$(echo "${JOBS_JSON}" | python3 -c "
import sys, json
try:
  jobs = json.load(sys.stdin)
  job_map = {j['ID']: j.get('Status','?') for j in jobs}
  core = ['${JOB_NAME}-db','${JOB_NAME}-redis','${JOB_NAME}-rserve','${JOB_NAME}-web','${JOB_NAME}-worker']
  parts = []
  running = 0
  for jid in core:
    status = job_map.get(jid, 'pending')
    icon = '✓' if status == 'running' else ('✗' if status == 'failed' else '…')
    name = jid.replace('${JOB_NAME}-','')
    parts.append(f'{icon}{name}')
    if status == 'running':
      running += 1
  print(f'{running}/5  ' + '  '.join(parts))
except Exception as e:
  print(f'? ({e})')
" 2>/dev/null) || STATUS_LINE="?"

    printf "\r  [%3ds] %s" "$((i * 5))" "${STATUS_LINE}"

    # Check for failures
    if echo "${JOBS_JSON}" | python3 -c \
      "import sys,json; jobs=json.load(sys.stdin); sys.exit(1 if any(j.get('Status')=='failed' for j in jobs) else 0)" \
      2>/dev/null; then
      :
    else
      echo ""
      err "One or more jobs failed. Check: ${NOMAD_API}/ui/jobs"
      return 1
    fi

    # Done when all 5 running
    if echo "${STATUS_LINE}" | grep -q "^5/5"; then
      ALL_RUNNING=true
      echo ""
      break
    fi

    sleep 5
  done
  echo ""

  if $ALL_RUNNING; then
    ok "All 5 core services running!"
  else
    warn "Timeout — not all services reached 'running' within 6 min."
    warn "Check: ${NOMAD_API}/ui/jobs"
  fi
}

# ── Status ────────────────────────────────────────────────────────────────────
show_status() {
  section "Nomad jobs (prefix: ${JOB_NAME})"
  nomad_api "/v1/jobs?prefix=${JOB_NAME}" 2>/dev/null | python3 -c "
import sys, json
try:
  jobs = json.load(sys.stdin)
  if not jobs:
    print('  (no jobs found)')
  else:
    for j in sorted(jobs, key=lambda x: x.get('ID','')):
      status = j.get('Status','?')
      color = '\033[32m' if status == 'running' else ('\033[31m' if status == 'failed' else '\033[33m')
      print(f\"  {j['ID']:<45s} {color}{status}\033[0m\")
except Exception as e:
  print(f'  Error: {e}')
" 2>/dev/null || echo "  (Nomad API not reachable — is the tunnel open?)"

  section "Nomad nodes"
  nomad_api "/v1/nodes" 2>/dev/null | python3 -c "
import sys, json
try:
  nodes = json.load(sys.stdin)
  ready = sum(1 for n in nodes if n.get('Status') == 'ready')
  print(f'  {ready}/{len(nodes)} nodes ready')
  for n in sorted(nodes, key=lambda x: x.get('Name','')):
    status = n.get('Status','?')
    elig   = n.get('SchedulingEligibility','?')
    print(f\"  {n['ID'][:8]}  {n['Name']:<20s}  {status}  eligible:{elig}\")
except Exception as e:
  print(f'  Error: {e}')
" 2>/dev/null || echo "  (unreachable)"

  section "Consul services"
  consul_api "/v1/catalog/services" 2>/dev/null | python3 -c "
import sys, json
try:
  svcs = json.load(sys.stdin)
  os_svcs = [s for s in svcs if 'openstudio' in s]
  if not os_svcs:
    print('  (no openstudio services registered yet)')
  else:
    for s in sorted(os_svcs):
      print(f'  {s}')
except Exception as e:
  print(f'  Error (Consul not reachable?): {e}')
" 2>/dev/null || echo "  (Consul tunnel not open — run with --tunnel)"

  # Print web UI access info
  section "Web UI access"
  WEB_ALLOC=$(nomad_api "/v1/job/${JOB_NAME}-web/allocations" 2>/dev/null | \
    python3 -c "
import sys, json
try:
  allocs = json.load(sys.stdin)
  running = [a for a in allocs if a.get('ClientStatus') == 'running']
  if running:
    a = running[0]
    print(a['NodeID'][:8] + ' ' + a['ID'][:8])
except Exception:
  pass
" 2>/dev/null) || WEB_ALLOC=""

  if [ -n "${WEB_ALLOC}" ]; then
    NODE_SHORT=$(echo "${WEB_ALLOC}" | awk '{print $1}')
    ALLOC_SHORT=$(echo "${WEB_ALLOC}" | awk '{print $2}')
    NODE_IP=$(nomad_api "/v1/nodes" 2>/dev/null | python3 -c "
import sys, json
try:
  nodes = json.load(sys.stdin)
  for n in nodes:
    if n['ID'].startswith('${NODE_SHORT}'):
      addr = n.get('Address','')
      print(addr)
      break
except Exception:
  pass
" 2>/dev/null) || NODE_IP=""

    WEB_PORT=$(nomad_api "/v1/job/${JOB_NAME}-web/allocations" 2>/dev/null | python3 -c "
import sys, json
try:
  allocs = json.load(sys.stdin)
  for a in allocs:
    if a.get('ClientStatus') == 'running':
      for res in a.get('AllocatedResources', {}).get('Tasks', {}).get('web', {}).get('Networks', []):
        for dp in res.get('DynamicPorts', []):
          if dp.get('Label') == 'http':
            print(dp.get('Value', ''))
except Exception:
  pass
" 2>/dev/null) || WEB_PORT=""

    if [ -n "${NODE_IP}" ] && [ -n "${WEB_PORT}" ]; then
      echo "  Web is running on ${NODE_IP}:${WEB_PORT}"
      echo ""
      echo "  To open in browser, run:"
      echo "    ssh -i ${SSH_KEY} -N -L 8080:${NODE_IP}:${WEB_PORT} ${JUMP_HOST}"
      echo "  Then open: http://localhost:8080"
    else
      echo "  Web allocation found (node: ${NODE_SHORT}, alloc: ${ALLOC_SHORT})"
      echo "  Run --status again once allocation ports are assigned."
    fi
  else
    echo "  Web not yet running"
  fi

  echo ""
  echo "  Nomad UI: ${NOMAD_API}/ui  (requires tunnel on port ${TUNNEL_LOCAL_PORT})"
  echo "  Consul UI: ${CONSUL_API}/ui (requires tunnel on port ${CONSUL_LOCAL_PORT})"
}

# ── Log tailing ───────────────────────────────────────────────────────────────
tail_logs() {
  local job_suffix="${1:-web}"
  local full_job="${JOB_NAME}-${job_suffix}"
  section "Logs: ${full_job}"
  NOMAD_ADDR="${NOMAD_API}" nomad alloc logs -f -job "${full_job}" "${job_suffix}" 2>/dev/null \
    || { err "Could not tail logs for ${full_job}. Is the job running?"; exit 1; }
}

# ── Teardown ──────────────────────────────────────────────────────────────────
teardown() {
  section "Teardown"
  if ! tunnel_running; then
    info "Opening tunnel for teardown..."
    start_tunnel
  fi

  stop_pack

  info "Stopping infra-setup system job..."
  NOMAD_ADDR="${NOMAD_API}" nomad job stop -purge infra-setup 2>/dev/null \
    && ok "infra-setup stopped" \
    || warn "infra-setup not running (already stopped?)"

  echo ""
  warn "Note: Consul server on nomad-server is still running."
  warn "To stop it: ssh_nomad_server 'sudo systemctl stop consul'"
  echo ""
  ok "Teardown complete."
}

# ── Full bootstrap + deploy ───────────────────────────────────────────────────
full_run() {
  check_prereqs
  start_tunnel
  start_consul_tunnel
  install_consul_server
  deploy_infra_setup
  deploy_pack
  show_status
}

# ── Open Nomad UI ─────────────────────────────────────────────────────────────
open_ui() {
  start_tunnel
  start_consul_tunnel
  echo ""
  ok "Tunnels open:"
  echo "  Nomad UI:  ${NOMAD_API}/ui"
  echo "  Consul UI: ${CONSUL_API}/ui"
  echo ""
  command -v open >/dev/null 2>&1 && open "${NOMAD_API}/ui" || true
  echo "Press Ctrl+C to close tunnels."
  wait
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
MODE="${1:-}"

case "${MODE}" in
  ""|--run|--full)
    full_run
    ;;
  --bootstrap)
    check_prereqs
    start_tunnel
    install_consul_server
    deploy_infra_setup
    ok "Bootstrap complete. Run --deploy to deploy the pack."
    ;;
  --deploy)
    start_tunnel
    start_consul_tunnel
    deploy_pack
    show_status
    ;;
  --redeploy)
    start_tunnel
    stop_pack
    sleep 5
    deploy_pack
    show_status
    ;;
  --stop)
    start_tunnel
    stop_pack
    ;;
  --teardown)
    teardown
    ;;
  --status)
    start_tunnel
    start_consul_tunnel || true
    show_status
    ;;
  --logs)
    start_tunnel
    tail_logs "${2:-web}"
    ;;
  --ui)
    open_ui
    ;;
  --tunnel)
    info "Opening tunnels (Ctrl+C to close)..."
    start_tunnel
    start_consul_tunnel || true
    echo ""
    ok "Nomad API: ${NOMAD_API}"
    ok "Consul UI: ${CONSUL_API}"
    echo ""
    echo "Press Ctrl+C to close tunnels and exit."
    wait
    ;;
  --tunnel-stop)
    stop_tunnel
    ok "Tunnels closed."
    ;;
  --help|-h)
    grep "^#" "$0" | head -30 | sed 's/^# \{0,1\}//'
    ;;
  *)
    err "Unknown option: ${MODE}"
    echo "Usage: $0 [--run|--bootstrap|--deploy|--redeploy|--stop|--teardown|--status|--logs [job]|--ui|--tunnel|--tunnel-stop]"
    exit 1
    ;;
esac
