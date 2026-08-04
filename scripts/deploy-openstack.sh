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
#   bash scripts/deploy-openstack.sh --ingress-check # Validate Traefik router + ingress path
#   bash scripts/deploy-openstack.sh --traefik-reconcile # Reconcile Traefik config and validate ingress
#   bash scripts/deploy-openstack.sh --conformance-audit # Audit role/constraint conformance
#   bash scripts/deploy-openstack.sh --disk-audit   # Audit root-disk pressure across clients
#   bash scripts/deploy-openstack.sh --logs [job]   # Tail logs (default: web)
#   bash scripts/deploy-openstack.sh --ui           # Tunnel + open Nomad UI
#   bash scripts/deploy-openstack.sh --teardown     # Stop pack + infra-setup
#   bash scripts/deploy-openstack.sh --tunnel       # Open tunnel only (foreground)
#
# Environment overrides:
#   NOMAD_ADDR       Override Nomad API address (default: http://localhost:4646)
#   OS_VAR_FILE      Override var-file (default: examples/advanced/openstack.hcl)
#   OS_JOB_NAME      Override job name  (default: openstudio-server)
#   OS_WORKER_COUNT  Override initial worker count (default: from var-file)
#   OS_CREATE_MISSING_CSI  Auto-create missing CSI volumes before deploy (default: true)
#   OS_BOOTSTRAP_WORKER_MAX_REPLICAS  Temporary max replicas during initial ramp (default: 200)
#   OS_BOOTSTRAP_AUTOSCALER_COOLDOWN  Temporary cooldown during initial ramp (default: 10m)
#   OS_PREPULL_WAIT_TIMEOUT_SECONDS   Timeout for pre-pull readiness gate (default: 900)
#   OS_PREPULL_MIN_READY_PERCENT      Minimum worker pre-pull readiness percent required to proceed (default: 10)
#   OS_PREPULL_REQUIRE_ALL            Require all eligible worker nodes to pass pre-pull before scheduling workers (default: false)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK_PATH="${REPO_ROOT}/packs/openstudio-server"

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

VAR_FILE="${OS_VAR_FILE:-${REPO_ROOT}/examples/advanced/openstack.hcl}"
JOB_NAME="${OS_JOB_NAME:-openstudio-server}"
INFRA_JOB_TPL="${PACK_PATH}/templates/infra-setup.nomad.tpl"
PREFLIGHT_SCRIPT="${REPO_ROOT}/scripts/preflight-storage.sh"
INGRESS_CHECK_SCRIPT="${REPO_ROOT}/scripts/check-openstack-ingress.sh"
TRAEFIK_RECONCILE_SCRIPT="${REPO_ROOT}/scripts/reconcile-jumphost-traefik.sh"
CONFORMANCE_AUDIT_SCRIPT="${REPO_ROOT}/scripts/audit-openstack-role-conformance.sh"
DISK_REMEDIATION_SCRIPT="${REPO_ROOT}/scripts/remediate-low-disk-nodes.sh"
CREATE_MISSING_CSI="${OS_CREATE_MISSING_CSI:-true}"
BOOTSTRAP_WORKER_MAX_REPLICAS="${OS_BOOTSTRAP_WORKER_MAX_REPLICAS:-200}"
BOOTSTRAP_AUTOSCALER_COOLDOWN="${OS_BOOTSTRAP_AUTOSCALER_COOLDOWN:-10m}"
PREPULL_WAIT_TIMEOUT_SECONDS="${OS_PREPULL_WAIT_TIMEOUT_SECONDS:-900}"
PREPULL_MIN_READY_PERCENT="${OS_PREPULL_MIN_READY_PERCENT:-10}"
PREPULL_REQUIRE_ALL="${OS_PREPULL_REQUIRE_ALL:-false}"

PREPULL_READY_NODE_IDS=""
PREPULL_NOT_READY_NODE_IDS=""

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
  [ -f "${INFRA_JOB_TPL}" ] || { err "Infra job template not found: ${INFRA_JOB_TPL}"; ok=false; }
  [ -f "${PREFLIGHT_SCRIPT}" ] || { err "Preflight script not found: ${PREFLIGHT_SCRIPT}"; ok=false; }
  [ -x "${INGRESS_CHECK_SCRIPT}" ] || { err "Ingress check script not found or not executable: ${INGRESS_CHECK_SCRIPT}"; ok=false; }
  [ -x "${TRAEFIK_RECONCILE_SCRIPT}" ] || { err "Traefik reconcile script not found or not executable: ${TRAEFIK_RECONCILE_SCRIPT}"; ok=false; }
  [ -x "${CONFORMANCE_AUDIT_SCRIPT}" ] || { err "Conformance audit script not found or not executable: ${CONFORMANCE_AUDIT_SCRIPT}"; ok=false; }
  [ -x "${DISK_REMEDIATION_SCRIPT}" ] || { err "Disk remediation script not found or not executable: ${DISK_REMEDIATION_SCRIPT}"; ok=false; }

  $ok || exit 1

  ok "nomad-pack: $(nomad-pack --version 2>&1 | head -1)"
  ok "nomad:      $(nomad version 2>&1 | head -1)"
  ok "var-file:   ${VAR_FILE}"
  ok "infra-job:  ${INFRA_JOB_TPL}"

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
  RUNNING=$(nomad_api "/v1/job/openstudio-server-infra-setup/allocations" 2>/dev/null | \
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
  local spec
  spec="$(mktemp)"
  nomad-pack render --var-file "${VAR_FILE}" --var "enable_infra_setup=true" --var "job_name=${JOB_NAME}" "${PACK_PATH}" > "${spec}"
  NOMAD_ADDR="${NOMAD_API}" nomad job run "${spec}"
  rm -f "${spec}"
  ok "infra-setup submitted"

  info "Waiting for all client nodes to complete setup (up to 5 min)..."
  local NODE_COUNT
  NODE_COUNT=$(nomad_api "/v1/nodes" 2>/dev/null | python3 -c \
    "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null) || NODE_COUNT=34

  for i in $(seq 1 60); do
    RUNNING=$(nomad_api "/v1/job/${JOB_NAME}-infra-setup/allocations" 2>/dev/null | \
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
      warn "Some allocations failed. Check: ${NOMAD_API}/ui/jobs/${JOB_NAME}-infra-setup"
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
csi_volume_topology_nodes() {
  local volume_name="$1"
  NOMAD_ADDR="${NOMAD_API}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}" nomad volume status -json "${volume_name}" 2>/dev/null | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

seen = set()
for topo in data.get("Topologies") or []:
    if not isinstance(topo, dict):
        continue
    segments = topo.get("Segments") or {}
    for key, value in segments.items():
        if not value:
            continue
        if key.endswith("/node") or "node" in key:
            if value not in seen:
                seen.add(value)
                print(value)
'
}

job_running_node_ids() {
  local job_id="$1"
  NOMAD_ADDR="${NOMAD_API}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}" nomad job allocs -json "${job_id}" 2>/dev/null | python3 -c '
import json, sys
try:
    allocs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
seen = set()
for alloc in allocs:
    if (alloc.get("DesiredStatus") or "").lower() != "run":
        continue
    if (alloc.get("ClientStatus") or "").lower() not in ("running", "starting", "pending"):
        continue
    node_id = alloc.get("NodeID") or ""
    if node_id and node_id not in seen:
        seen.add(node_id)
        print(node_id)
'
}

build_worker_exclusion_var() {
  local nodes=("$@")
  if [ ${#nodes[@]} -eq 0 ]; then
    return 0
  fi
  printf "%s\n" "${nodes[@]}" | awk 'NF && !seen[$0]++' | python3 -c '
import json, sys
items = [line.strip() for line in sys.stdin if line.strip()]
if items:
    print(json.dumps(items))
'
}

extract_simple_var() {
  local key="$1"
  local default="${2:-}"
  local line value
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${VAR_FILE}" | tail -n 1 || true)"
  if [ -z "${line}" ]; then
    echo "${default}"
    return
  fi
  value="${line#*=}"
  value="$(echo "${value}" | sed -E 's/[[:space:]]*#.*$//' | xargs)"
  value="${value%\"}"
  value="${value#\"}"
  echo "${value}"
}

enforce_removed_var_guardrails() {
  if grep -Eq '^[[:space:]]*web_background_(count|autoscaling_enabled|min_replicas|max_replicas|autoscaling_cpu_enabled|cpu_target_utilization)[[:space:]]*=' "${VAR_FILE}"; then
    err "Removed web-background scaling variables detected in ${VAR_FILE}."
    err "web-background is a fixed singleton task group; tune throughput with web_background_worker_count instead."
    exit 1
  fi

  if grep -Eq '^[[:space:]]*autoscaler_cooldown[[:space:]]*=' "${VAR_FILE}"; then
    err "Removed variable autoscaler_cooldown detected in ${VAR_FILE}."
    err "Use worker_autoscaling_scale_up_cooldown and worker_autoscaling_scale_down_cooldown instead."
    exit 1
  fi
}

run_pack_with_guard() {
  purge_known_legacy_jobs_for_pack() {
    local legacy_job
    local -a known_legacy_jobs=(
      "${JOB_NAME}-stall-watchdog"
    )

    for legacy_job in "${known_legacy_jobs[@]}"; do
      if NOMAD_ADDR="${NOMAD_API}" nomad job status -namespace "${NOMAD_NAMESPACE:-default}" "${legacy_job}" >/dev/null 2>&1; then
        warn "Purging legacy standalone job '${legacy_job}' to enforce consolidated watchdog scheduler source."
        NOMAD_ADDR="${NOMAD_API}" nomad job stop -purge -namespace "${NOMAD_NAMESPACE:-default}" "${legacy_job}" >/dev/null
      fi
    done
  }

  local run_log
  local -a run_args=("$@")
  local metadata_retry=false
  local run_succeeded=false
  run_log="$(mktemp)"
  if NOMAD_ADDR="${NOMAD_API}" nomad-pack run "${run_args[@]}" "${PACK_PATH}" 2>&1 | tee "${run_log}"; then
    run_succeeded=true
  else
    if grep -Eq 'Failed To Query For Previously Deployed Jobs|pack\.deployment_name' "${run_log}"; then
      purge_known_legacy_jobs_for_pack
      metadata_retry=true
    fi
  fi

  if [[ "${metadata_retry}" == "true" && "${run_succeeded}" != "true" ]]; then
    if NOMAD_ADDR="${NOMAD_API}" nomad-pack run "${run_args[@]}" "${PACK_PATH}" 2>&1 | tee "${run_log}"; then
      rm -f "${run_log}"
      return 0
    fi
  fi

  if grep -Eq 'Failed To Query For Previously Deployed Jobs|pack\.deployment_name' "${run_log}"; then
      core_jobs_ready=false
      for _ in $(seq 1 30); do
        if NOMAD_ADDR="${NOMAD_API}" nomad job status -namespace "${NOMAD_NAMESPACE:-default}" "${JOB_NAME}-web" >/dev/null 2>&1 && \
           NOMAD_ADDR="${NOMAD_API}" nomad job status -namespace "${NOMAD_NAMESPACE:-default}" "${JOB_NAME}-worker" >/dev/null 2>&1 && \
           NOMAD_ADDR="${NOMAD_API}" nomad job status -namespace "${NOMAD_NAMESPACE:-default}" "${JOB_NAME}-db" >/dev/null 2>&1 && \
           NOMAD_ADDR="${NOMAD_API}" nomad job status -namespace "${NOMAD_NAMESPACE:-default}" "${JOB_NAME}-redis" >/dev/null 2>&1 && \
           NOMAD_ADDR="${NOMAD_API}" nomad job status -namespace "${NOMAD_NAMESPACE:-default}" "${JOB_NAME}-rserve" >/dev/null 2>&1; then
          core_jobs_ready=true
          break
        fi
        sleep 1
      done
      if [ "${core_jobs_ready}" != "true" ]; then
        rm -f "${run_log}"
        exit 1
      fi
      warn "nomad-pack reported a deployment metadata query error, but core jobs were registered."
  elif [[ "${run_succeeded}" != "true" ]]; then
    rm -f "${run_log}"
    exit 1
  fi
  rm -f "${run_log}"
}

run_system_hooks_phase() {
  local enable_image_prepull worker_instance_type rendered spec
  local total_count deadline now ready_count ready_nodes required_by_percent required_ready_count
  enable_image_prepull="$(extract_simple_var enable_image_prepull false)"
  [ "${enable_image_prepull}" = "true" ] || return 0

  worker_instance_type="$(extract_simple_var worker_instance_type "")"
  rendered="$(mktemp)"
  spec="$(mktemp)"
  nomad-pack render --var-file "${VAR_FILE}" --var "job_name=${JOB_NAME}" "${PACK_PATH}" > "${rendered}"
  awk '
    /^openstudio-server\/system-hooks\.nomad:$/ { in_section=1; next }
    /^openstudio-server\/.*\.nomad:$/ { if (in_section) exit }
    in_section { print }
  ' "${rendered}" > "${spec}"
  rm -f "${rendered}"

  if [ ! -s "${spec}" ]; then
    rm -f "${spec}"
    err "Failed to render system-hooks job spec for pre-pull phase."
    exit 1
  fi

  section "Phase 1/3 — warm image cache (system-hooks)"
  NOMAD_ADDR="${NOMAD_API}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}" nomad job run "${spec}" >/dev/null
  rm -f "${spec}"

  target_nodes="$(
    NOMAD_ADDR="${NOMAD_API}" WORKER_INSTANCE_TYPE="${worker_instance_type}" python3 - <<'PY'
import json, os, urllib.request
addr = os.environ["NOMAD_ADDR"].rstrip("/")
instance_type = os.environ.get("WORKER_INSTANCE_TYPE", "").strip()
with urllib.request.urlopen(f"{addr}/v1/nodes", timeout=20) as r:
    nodes = json.load(r)
targets = []
for n in nodes:
    if n.get("Status") != "ready" or n.get("SchedulingEligibility") != "eligible":
        continue
    nid = n.get("ID")
    if not nid:
        continue
    with urllib.request.urlopen(f"{addr}/v1/node/{nid}", timeout=20) as r:
        detail = json.load(r)
    meta = detail.get("Meta") or {}
    attrs = detail.get("Attributes") or {}
    if meta.get("node_role") != "worker":
        continue
    if attrs.get("driver.docker") != "1":
        continue
    if instance_type and attrs.get("platform.aws.instance-type") != instance_type:
        continue
    targets.append(nid)
for nid in targets:
    print(nid)
PY
  )"

  if [ -z "${target_nodes}" ]; then
    err "No target worker nodes found for pre-pull readiness checks."
    exit 1
  fi

  total_count="$(printf "%s\n" "${target_nodes}" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "${PREPULL_REQUIRE_ALL}" = "true" ]; then
    required_ready_count="${total_count}"
    info "Pre-pull gate requires ${required_ready_count}/${total_count} worker nodes (OS_PREPULL_REQUIRE_ALL=true)."
  else
    required_by_percent=$(( (total_count * PREPULL_MIN_READY_PERCENT + 99) / 100 ))
    if [ "${required_by_percent}" -lt 1 ]; then
      required_by_percent=1
    fi
    required_ready_count="${required_by_percent}"
    if [ "${required_ready_count}" -lt "${worker_count}" ]; then
      required_ready_count="${worker_count}"
    fi
    if [ "${required_ready_count}" -gt "${total_count}" ]; then
      required_ready_count="${total_count}"
    fi
    info "Pre-pull gate requires ${required_ready_count}/${total_count} worker nodes (min ${PREPULL_MIN_READY_PERCENT}%, worker_count=${worker_count})."
  fi
  deadline=$(( $(date +%s) + PREPULL_WAIT_TIMEOUT_SECONDS ))
  ready_nodes=""

  while true; do
    now="$(date +%s)"
    if [ "${now}" -gt "${deadline}" ]; then
      err "Timed out waiting for system-hooks pre-pull readiness on target worker nodes."
      exit 1
    fi

    ready_nodes="$(
      TARGET_NODE_IDS="${target_nodes}" NOMAD_ADDR="${NOMAD_API}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}" JOB_ID="${JOB_NAME}-system-hooks" python3 - <<'PY'
import json, os, subprocess
targets = {x.strip() for x in os.environ.get("TARGET_NODE_IDS", "").splitlines() if x.strip()}
if not targets:
    raise SystemExit(0)
proc = subprocess.run(["nomad", "job", "allocs", "-json", os.environ["JOB_ID"]], capture_output=True, text=True, env=os.environ.copy())
if proc.returncode != 0:
    raise SystemExit(0)
allocs = json.loads(proc.stdout)
ready = set()
for alloc in allocs:
    if alloc.get("DesiredStatus") != "run":
        continue
    if alloc.get("ClientStatus") != "running":
        continue
    node = alloc.get("NodeID")
    if node not in targets:
        continue
    task = (alloc.get("TaskStates") or {}).get("image-cache-ready") or {}
    if task.get("State") == "running":
        ready.add(node)
for node_id in sorted(ready):
    print(node_id)
PY
    )"
    ready_count="$(printf "%s\n" "${ready_nodes}" | awk 'NF' | wc -l | tr -d ' ')"
    printf "\r  pre-pull readiness: %s/%s worker nodes ready (required: %s)" "${ready_count}" "${total_count}" "${required_ready_count}"
    if [ "${ready_count}" -ge "${required_ready_count}" ]; then
      echo ""
      ok "Pre-pull readiness threshold met."
      break
    fi
    sleep 5
  done

  PREPULL_READY_NODE_IDS="${ready_nodes}"
  PREPULL_NOT_READY_NODE_IDS="$(
    TARGET_NODE_IDS="${target_nodes}" READY_NODE_IDS="${ready_nodes}" python3 - <<'PY'
import os
targets = {x.strip() for x in (os.environ.get("TARGET_NODE_IDS", "").splitlines()) if x.strip()}
ready = {x.strip() for x in (os.environ.get("READY_NODE_IDS", "").splitlines()) if x.strip()}
for node_id in sorted(targets - ready):
    print(node_id)
PY
  )"
}

wait_for_core_services() {
  section "Phase 2/3 — waiting for core services"
  local all_ready=false

  for i in $(seq 1 120); do
    status_line="$(
      NOMAD_ADDR="${NOMAD_API}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}" JOB_PREFIX="${JOB_NAME}" python3 - <<'PY'
import json, os, urllib.request
core = [f"{os.environ['JOB_PREFIX']}-db", f"{os.environ['JOB_PREFIX']}-redis", f"{os.environ['JOB_PREFIX']}-rserve", f"{os.environ['JOB_PREFIX']}-web"]
addr = os.environ["NOMAD_ADDR"].rstrip("/")
ns = os.environ.get("NOMAD_NAMESPACE", "default")
with urllib.request.urlopen(f"{addr}/v1/jobs?namespace={ns}", timeout=20) as r:
    jobs = json.load(r)
status = {j.get("ID"): j.get("Status") for j in jobs}
ready = 0
for job_id in core:
    if status.get(job_id) != "running":
        continue
    dep_status = ""
    try:
        with urllib.request.urlopen(f"{addr}/v1/job/{job_id}/deployments?namespace={ns}", timeout=20) as r:
            deps = json.load(r)
        if deps:
            dep_status = (deps[0].get("Status") or "").lower()
    except Exception:
        dep_status = ""
    if dep_status == "successful":
        ready += 1
print(f"{ready}/4")
PY
    )"
    printf "\r  core readiness (deployment healthy): %s" "${status_line}"
    if [ "${status_line}" = "4/4" ]; then
      all_ready=true
      break
    fi
    sleep 5
  done
  echo ""

  if [ "${all_ready}" != "true" ]; then
    err "Core services did not reach running state in time."
    exit 1
  fi
  ok "Core services are running."
}

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

  info "Running storage preflight..."
  enforce_removed_var_guardrails
  PREFLIGHT_ARGS=(
    --var-file "${VAR_FILE}"
    --nomad-addr "${NOMAD_API}"
    --namespace "${NOMAD_NAMESPACE:-default}"
    --emit-topology-vars
  )
  if [ "${CREATE_MISSING_CSI}" = "true" ]; then
    PREFLIGHT_ARGS+=(--rebind-stale)   # --rebind-stale implies --create-missing-csi
  fi
  # Capture topology var output (lines like "db_csi_topology_node_id=<uuid>") from preflight.
  # The preflight script emits these on stdout after "✓ Storage preflight passed" when
  # --emit-topology-vars is set; all other lines go to stderr or are interleaved on stdout.
  # We tee to stderr so the operator sees the full preflight output, then filter the
  # assignment lines for eval.
  preflight_output="$("${PREFLIGHT_SCRIPT}" "${PREFLIGHT_ARGS[@]}" 2>&1)" || {
    echo "${preflight_output}" >&2
    exit 1
  }
  echo "${preflight_output}" >&2 || true
  db_csi_topology_node_id=""
  redis_csi_topology_node_id=""
  while IFS= read -r line; do
    case "${line}" in
      db_csi_topology_node_id=*)    db_csi_topology_node_id="${line#*=}" ;;
      redis_csi_topology_node_id=*) redis_csi_topology_node_id="${line#*=}" ;;
    esac
  done <<< "${preflight_output}"
  if [ -n "${db_csi_topology_node_id}" ]; then
    ok "DB CSI topology node pinned to: ${db_csi_topology_node_id}"
  fi
  if [ -n "${redis_csi_topology_node_id}" ]; then
    ok "Redis CSI topology node pinned to: ${redis_csi_topology_node_id}"
  fi

  db_storage_type="$(extract_simple_var db_storage_type host_volume)"
  db_volume_source="$(extract_simple_var db_volume_source openstudio-mongodb)"
  redis_storage_type="$(extract_simple_var redis_storage_type host_volume)"
  redis_volume_source="$(extract_simple_var redis_volume_source openstudio-redis)"
  worker_count="$(extract_simple_var worker_count 1)"
  worker_max_replicas="$(extract_simple_var worker_max_replicas 10)"
  worker_autoscaling_scale_up_cooldown="$(extract_simple_var worker_autoscaling_scale_up_cooldown 10m)"

  # ── Derive topology nodes for worker exclusion ─────────────────────────────
  # Prefer the topology node IDs emitted by preflight (authoritative, post-rebind).
  # Fall back to querying Nomad volume status / running alloc node IDs as before.
  topology_nodes=()
  db_nodes=()
  redis_nodes=()
  if [ "${db_storage_type}" = "csi" ]; then
    if [ -n "${db_csi_topology_node_id:-}" ]; then
      db_nodes+=("${db_csi_topology_node_id}")
    else
      while IFS= read -r node_id; do
        [ -n "${node_id}" ] && db_nodes+=("${node_id}")
      done < <(csi_volume_topology_nodes "${db_volume_source}")
      if [ ${#db_nodes[@]} -eq 0 ]; then
        while IFS= read -r node_id; do
          [ -n "${node_id}" ] && db_nodes+=("${node_id}")
        done < <(job_running_node_ids "${JOB_NAME}-db")
      fi
    fi
    topology_nodes+=("${db_nodes[@]}")
  fi
  if [ "${redis_storage_type}" = "csi" ]; then
    if [ -n "${redis_csi_topology_node_id:-}" ]; then
      redis_nodes+=("${redis_csi_topology_node_id}")
    else
      while IFS= read -r node_id; do
        [ -n "${node_id}" ] && redis_nodes+=("${node_id}")
      done < <(csi_volume_topology_nodes "${redis_volume_source}")
      if [ ${#redis_nodes[@]} -eq 0 ]; then
        while IFS= read -r node_id; do
          [ -n "${node_id}" ] && redis_nodes+=("${node_id}")
        done < <(job_running_node_ids "${JOB_NAME}-redis")
      fi
    fi
    topology_nodes+=("${redis_nodes[@]}")
  fi

  run_system_hooks_phase

  # Build two exclusion lists:
  #   worker_excluded_node_ids_json  — Phase 2 only: CSI topology nodes + pre-pull not-ready
  #                                    nodes. Keeps workers on already-cached nodes during the
  #                                    bootstrap ramp so first simulations start quickly.
  #   topology_only_exclusion_json   — Phase 3 and beyond: CSI topology nodes only.
  #                                    Pre-pull exclusions are a temporary bootstrap gate; once
  #                                    the Phase 2 ramp succeeds they must be dropped or they
  #                                    permanently block workers from 99%+ of the cluster.
  combined_worker_exclusions=()
  combined_worker_exclusions+=("${topology_nodes[@]}")
  while IFS= read -r node_id; do
    [ -n "${node_id}" ] && combined_worker_exclusions+=("${node_id}")
  done <<< "${PREPULL_NOT_READY_NODE_IDS}"

  worker_excluded_node_ids_json="$(build_worker_exclusion_var "${combined_worker_exclusions[@]}" || true)"
  topology_only_exclusion_json="$(build_worker_exclusion_var "${topology_nodes[@]}" || true)"

  if [ "${db_storage_type}" = "csi" ] || [ "${redis_storage_type}" = "csi" ]; then
    if [ -z "${worker_excluded_node_ids_json}" ]; then
      err "Could not derive worker exclusion node IDs from CSI topology/allocation state; aborting to avoid DB/Redis starvation."
      exit 1
    fi
  fi

  section "Phase 2/3 — deploy stack with conservative worker ramp"
  bootstrap_worker_max_replicas="${BOOTSTRAP_WORKER_MAX_REPLICAS}"
  if [ "${bootstrap_worker_max_replicas}" -gt "${worker_max_replicas}" ] 2>/dev/null; then
    bootstrap_worker_max_replicas="${worker_max_replicas}"
  fi

  PHASE2_ARGS=(
    --var-file "${VAR_FILE}"
    --name "${JOB_NAME}"
    --var "enable_image_prepull=false"
    --var "worker_count=${worker_count}"
    --var "worker_max_replicas=${bootstrap_worker_max_replicas}"
    --var "worker_autoscaling_scale_up_cooldown=${BOOTSTRAP_AUTOSCALER_COOLDOWN}"
  )
  # Inject CSI topology node pin variables so the DB/Redis jobs are constrained to
  # the node that owns their CSI volume.  This prevents the scheduler from placing
  # the alloc on a node where the CSI plugin cannot attach the volume, which is
  # the root cause of: "pre-run hook csi_hook failed ... does not exist in volumes list"
  if [ -n "${db_csi_topology_node_id:-}" ]; then
    PHASE2_ARGS+=(--var "db_csi_topology_node_id=${db_csi_topology_node_id}")
  fi
  if [ -n "${redis_csi_topology_node_id:-}" ]; then
    PHASE2_ARGS+=(--var "redis_csi_topology_node_id=${redis_csi_topology_node_id}")
  fi
  if [ -n "${worker_excluded_node_ids_json}" ]; then
    PHASE2_ARGS+=(--var "worker_excluded_node_ids=${worker_excluded_node_ids_json}")
    info "Phase 2: restricting workers to pre-pulled nodes and protecting CSI topology node(s) (temporary bootstrap gate): ${worker_excluded_node_ids_json}"
  fi

  run_pack_with_guard "${PHASE2_ARGS[@]}"
  wait_for_core_services

  # Phase 3 runs if:
  #   (a) bootstrap replicas/cooldown differ from production values (original condition), OR
  #   (b) the Phase 2 exclusion list contains pre-pull not-ready nodes that must be dropped.
  #       Without this check, equal bootstrap/production bounds skip Phase 3 entirely and the
  #       pre-pull exclusions stay permanently baked into the job.
  local needs_phase3=false
  [ "${bootstrap_worker_max_replicas}" != "${worker_max_replicas}" ] && needs_phase3=true
  [ "${BOOTSTRAP_AUTOSCALER_COOLDOWN}" != "${worker_autoscaling_scale_up_cooldown}" ] && needs_phase3=true
  [ "${worker_excluded_node_ids_json}" != "${topology_only_exclusion_json}" ] && needs_phase3=true

  if [ "${needs_phase3}" = "true" ]; then
    section "Phase 3/3 — restore full worker autoscaling bounds"
    PHASE3_ARGS=(
      --var-file "${VAR_FILE}"
      --name "${JOB_NAME}"
      --var "enable_image_prepull=false"
      --var "worker_count=${worker_count}"
      --var "worker_max_replicas=${worker_max_replicas}"
      --var "worker_autoscaling_scale_up_cooldown=${worker_autoscaling_scale_up_cooldown}"
    )
    # Carry CSI topology pins forward so they remain active for the lifetime of the jobs.
    if [ -n "${db_csi_topology_node_id:-}" ]; then
      PHASE3_ARGS+=(--var "db_csi_topology_node_id=${db_csi_topology_node_id}")
    fi
    if [ -n "${redis_csi_topology_node_id:-}" ]; then
      PHASE3_ARGS+=(--var "redis_csi_topology_node_id=${redis_csi_topology_node_id}")
    fi
    # Phase 3 drops the pre-pull not-ready exclusions; only CSI topology nodes stay excluded.
    # Passing the full Phase 2 list here would permanently lock workers off the majority of
    # the cluster whenever nodes hadn't finished pre-pulling at Phase 2 submit time.
    if [ -n "${topology_only_exclusion_json}" ]; then
      PHASE3_ARGS+=(--var "worker_excluded_node_ids=${topology_only_exclusion_json}")
      info "Phase 3: retaining CSI topology exclusion only: ${topology_only_exclusion_json}"
    else
      PHASE3_ARGS+=(--var "worker_excluded_node_ids=[]")
      info "Phase 3: clearing pre-pull bootstrap exclusions; workers can spread to all eligible nodes"
    fi
    run_pack_with_guard "${PHASE3_ARGS[@]}"
  fi

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
    "${PACK_PATH}" || true
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
  NOMAD_ADDR="${NOMAD_API}" nomad job stop -purge "${JOB_NAME}-infra-setup" 2>/dev/null \
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
  --ingress-check)
    check_prereqs
    "${INGRESS_CHECK_SCRIPT}" \
      --jump-host "${JUMP_HOST}" \
      --traefik-host "${NOMAD_SERVER}" \
      --ingress-host "${NOMAD_SERVER_IP}" \
      --ssh-key "${SSH_KEY}" \
      --expected-router "${JOB_NAME}@consulcatalog"
    ;;
  --traefik-reconcile)
    check_prereqs
    JUMP_HOST="${JUMP_HOST}" \
    NOMAD_SERVER_HOST="${NOMAD_SERVER}" \
    INGRESS_HOST="${NOMAD_SERVER_IP}" \
    SSH_KEY="${SSH_KEY}" \
    "${TRAEFIK_RECONCILE_SCRIPT}"
    ;;
  --conformance-audit)
    check_prereqs
    start_tunnel
    NOMAD_ADDR="${NOMAD_API}" "${CONFORMANCE_AUDIT_SCRIPT}"
    ;;
  --disk-audit)
    check_prereqs
    start_tunnel
    NOMAD_ADDR="${NOMAD_API}" \
      JUMP_HOST="${JUMP_HOST}" \
      NOMAD_SERVER_HOST="${NOMAD_SERVER}" \
      SSH_KEY="${SSH_KEY}" \
      "${DISK_REMEDIATION_SCRIPT}" --threshold-mb 20480
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
    echo "Usage: $0 [--run|--bootstrap|--deploy|--redeploy|--stop|--teardown|--status|--ingress-check|--traefik-reconcile|--conformance-audit|--disk-audit|--logs [job]|--ui|--tunnel|--tunnel-stop]"
    exit 1
    ;;
esac
