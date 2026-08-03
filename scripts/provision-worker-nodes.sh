#!/usr/bin/env bash
#
# provision-worker-nodes.sh
#
# Provisions new azimuth.compute1-179d-250disk worker nodes in OpenStack,
# then bootstraps each into the Nomad cluster via SSH.
#
# Usage:
#   ./scripts/provision-worker-nodes.sh [OPTIONS]
#
# Options:
#   --count N          Number of new nodes to provision (default: 1)
#   --start-index N    Node number to start from (auto-detected if omitted)
#   --dry-run          Print what would be done without creating anything
#   --bootstrap-only   Skip instance creation; re-bootstrap nodes by IP list
#   --ips IP1,IP2,...  Comma-separated IP list for --bootstrap-only mode
#   --help             Show this message
#
# Prerequisites:
#   - openstack CLI installed and authenticated (source your openrc or set OS_* env vars)
#   - SSH key configured at SSH_KEY (default: ~/.ssh/id_rsa)
#   - Jump host set via SSH_JUMP_HOST if your workstation lacks direct cluster access
#
# Environment overrides (all have working defaults):
#   FLAVOR              OpenStack flavor name  (default: azimuth.compute1-179d-250disk)
#   IMAGE               OpenStack image name   (default: ubuntu-jammy-20260320)
#   NETWORK             OpenStack network name (default: nomad-net)
#   SECURITY_GROUP      OpenStack security group (default: nomad-sg)
#   KEY_NAME            OpenStack key-pair name (default: id_rsa)
#   NODE_PREFIX         Name prefix for new nodes (default: nomad-client-)
#   SSH_USER            SSH login user (default: ubuntu)
#   SSH_KEY             Path to private key   (default: ~/.ssh/id_rsa)
#   SSH_JUMP_HOST       Optional jump host
#   NOMAD_SERVER_IP     Nomad server RPC address (default: 192.168.100.87)
#   CONSUL_SERVER_IP    Consul server address    (default: 192.168.100.87)
#   PULP_REGISTRY_HOST  Registry hostname        (default: pulp-dev.hpc.nlr.gov)
#   PULP_REGISTRY_IP    Registry IP              (default: 10.60.127.127)
#   BOOT_TIMEOUT        Seconds to wait for SSH readiness after boot (default: 300)
#   IP_LOOKUP_TIMEOUT   Seconds to wait for OpenStack to report node IP (default: 180)
#
# Capacity reference (as of 2025):
#   Flavor azimuth.compute1-179d-250disk: 62 vCPU, 80 GB RAM, 250 GB disk
#   Workers per node:  45  (limited by 80 GB RAM / 1,750 MB per worker)
#   Current cluster:   ~119 nodes → ~5,355 workers
#   Quota headroom:    ~7,296 vCPUs → ~117 more nodes → ~10,620 workers total
#
set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────
FLAVOR="${FLAVOR:-azimuth.compute1-179d-250disk}"
IMAGE="${IMAGE:-ubuntu-jammy-20260320}"
NETWORK="${NETWORK:-nomad-net}"
SECURITY_GROUP="${SECURITY_GROUP:-nomad-sg}"
KEY_NAME="${KEY_NAME:-id_rsa}"
NODE_PREFIX="${NODE_PREFIX:-nomad-client-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
NOMAD_SERVER_IP="${NOMAD_SERVER_IP:-192.168.100.87}"
CONSUL_SERVER_IP="${CONSUL_SERVER_IP:-192.168.100.87}"
PULP_REGISTRY_HOST="${PULP_REGISTRY_HOST:-pulp-dev.hpc.nlr.gov}"
PULP_REGISTRY_IP="${PULP_REGISTRY_IP:-10.60.127.127}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
IP_LOOKUP_TIMEOUT="${IP_LOOKUP_TIMEOUT:-180}"

COUNT=1
START_INDEX=""
DRY_RUN=false
BOOTSTRAP_ONLY=false
EXTRA_IPS=""

# ── argument parsing ──────────────────────────────────────────────────────────
usage() {
  sed -n '/^# Usage/,/^[^#]/p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)       COUNT="$2";       shift 2 ;;
    --start-index) START_INDEX="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true;     shift   ;;
    --bootstrap-only) BOOTSTRAP_ONLY=true; shift ;;
    --ips)         EXTRA_IPS="$2";   shift 2 ;;
    --help|-h)     usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
error()   { echo "[ERROR] $*" >&2; exit 1; }

run() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

ssh_opts() {
  local opts=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
              -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=30)
  if [[ -n "${SSH_JUMP_HOST:-}" ]]; then
    opts+=(-J "${SSH_JUMP_HOST}")
  fi
  printf '%s\n' "${opts[@]}"
}

wait_for_ssh() {
  local ip="$1" name="$2"
  local deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  info "Waiting for SSH on ${name} (${ip}) — timeout ${BOOT_TIMEOUT}s ..."
  while (( $(date +%s) < deadline )); do
    if ssh $(ssh_opts | tr '\n' ' ') "${SSH_USER}@${ip}" true 2>/dev/null; then
      success "SSH ready: ${name} (${ip})"
      return 0
    fi
    sleep 10
  done
  warn "SSH timeout on ${name} (${ip}) — node may still be booting; bootstrap it manually later"
  return 1
}

extract_server_ip() {
  local server_json="$1"
  SERVER_JSON="${server_json}" python3 - <<'PY'
import json, os, re, ipaddress

raw = os.environ.get("SERVER_JSON", "")
try:
    s = json.loads(raw)
except Exception:
    raise SystemExit(1)

addresses = s.get("addresses")
candidates = []

if isinstance(addresses, dict):
    for _, entries in addresses.items():
        if isinstance(entries, list):
            for entry in entries:
                if isinstance(entry, str):
                    candidates.append(entry)
                elif isinstance(entry, dict):
                    ip = entry.get("addr")
                    if ip:
                        candidates.append(ip)
        elif isinstance(entries, str):
            candidates.append(entries)
elif isinstance(addresses, str):
    candidates.append(addresses)

ips = []
for item in candidates:
    for token in re.findall(r'(?:\d{1,3}\.){3}\d{1,3}', item):
        try:
            ipaddress.ip_address(token)
            ips.append(token)
        except ValueError:
            pass

preferred = [ip for ip in ips if ip.startswith("192.168.")]
if preferred:
    print(preferred[0])
elif ips:
    print(ips[0])
PY
}

get_server_ip_with_retry() {
  local name="$1"
  local deadline server_json status ip
  deadline=$(( $(date +%s) + IP_LOOKUP_TIMEOUT ))

  while (( $(date +%s) < deadline )); do
    if ! server_json="$(openstack server show "${name}" -f json 2>/dev/null)"; then
      sleep 3
      continue
    fi

    status="$(SERVER_JSON="${server_json}" python3 - <<'PY'
import json, os
try:
    print((json.loads(os.environ["SERVER_JSON"]).get("status") or "").strip().upper())
except Exception:
    print("")
PY
)"
    ip="$(extract_server_ip "${server_json}" || true)"
    if [[ -n "${ip}" ]]; then
      echo "${ip}"
      return 0
    fi
    if [[ "${status}" == "ERROR" ]]; then
      warn "OpenStack reports ${name} in ERROR state before an IP was assigned."
      return 1
    fi
    sleep 5
  done

  warn "Timed out waiting for IP on ${name} after ${IP_LOOKUP_TIMEOUT}s."
  return 1
}

get_next_index() {
  # Determine highest current nomad-client-N index and add 1
  openstack server list -f json 2>/dev/null \
    | python3 -c "
import sys,json
servers=json.load(sys.stdin)
nums=[]
for s in servers:
    name=s.get('Name','')
    try:
        n=int(name.split('-')[-1])
        nums.append(n)
    except: pass
print(max(nums)+1 if nums else 316)
"
}

check_quota() {
  local need_vcpus=$(( COUNT * 62 ))
  local avail
  avail=$(openstack limits show --absolute -f json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
m={i['Name']:i['Value'] for i in d}
print(int(m.get('total_cores',0)) - int(m.get('total_cores_used',0)))
")
  info "Quota: ${avail} vCPUs available, requesting ${need_vcpus} (${COUNT} × 62)"
  if (( need_vcpus > avail )); then
    error "Not enough vCPU quota: need ${need_vcpus}, only ${avail} available. Reduce --count or request a quota increase."
  fi
}

# ── bootstrap-only mode ───────────────────────────────────────────────────────
if $BOOTSTRAP_ONLY; then
  if [[ -z "$EXTRA_IPS" ]]; then
    error "--bootstrap-only requires --ips IP1,IP2,..."
  fi
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  IFS=',' read -ra IP_LIST <<< "$EXTRA_IPS"
  for ip in "${IP_LIST[@]}"; do
    ip="${ip// /}"
    info "Bootstrapping ${ip} ..."
    run ssh $(ssh_opts | tr '\n' ' ') "${SSH_USER}@${ip}" "sudo bash -s" <<BOOTSTRAP
export NOMAD_SERVER_IP="${NOMAD_SERVER_IP}"
export CONSUL_SERVER_IP="${CONSUL_SERVER_IP}"
export PULP_REGISTRY_HOST="${PULP_REGISTRY_HOST}"
export PULP_REGISTRY_IP="${PULP_REGISTRY_IP}"
export ROLE=worker
$(cat "${SCRIPT_DIR}/bootstrap-179d-node.sh")
BOOTSTRAP
    success "Bootstrap complete: ${ip}"
  done
  exit 0
fi

# ── pre-flight checks ─────────────────────────────────────────────────────────
if ! command -v openstack &>/dev/null; then
  error "openstack CLI not found. Install python-openstackclient and source your openrc."
fi
if ! openstack token issue -f value -c id &>/dev/null; then
  error "openstack CLI not authenticated. Source your openrc or set OS_* env vars."
fi

check_quota

# ── resolve start index ───────────────────────────────────────────────────────
if [[ -z "$START_INDEX" ]]; then
  START_INDEX=$(get_next_index)
  info "Auto-detected start index: ${START_INDEX}"
fi

# ── provision loop ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provisioned=()

for (( i=0; i<COUNT; i++ )); do
  idx=$(( START_INDEX + i ))
  name="${NODE_PREFIX}${idx}"
  info "Creating instance ${name} (flavor: ${FLAVOR}) ..."

  if $DRY_RUN; then
    echo "[DRY-RUN] openstack server create --flavor ${FLAVOR} --image ${IMAGE} \\"
    echo "            --network ${NETWORK} --security-group ${SECURITY_GROUP} \\"
    echo "            --key-name ${KEY_NAME} --wait ${name}"
    provisioned+=("192.0.2.${idx}")  # placeholder IP for dry-run
    continue
  fi

  openstack server create \
    --flavor "${FLAVOR}" \
    --image "${IMAGE}" \
    --network "${NETWORK}" \
    --security-group "${SECURITY_GROUP}" \
    --key-name "${KEY_NAME}" \
    --wait \
    "${name}"

  # Retrieve the assigned IP (OpenStack returns addresses as list[str] on this cloud).
  local_ip="$(get_server_ip_with_retry "${name}" || true)"

  if [[ -z "$local_ip" ]]; then
    warn "Could not determine IP for ${name}; check OpenStack and bootstrap manually."
    continue
  fi

  success "Instance ${name} created at ${local_ip}"
  provisioned+=("${local_ip}")

  # Wait for SSH and bootstrap
  if wait_for_ssh "${local_ip}" "${name}"; then
    info "Bootstrapping ${name} (${local_ip}) ..."
    ssh $(ssh_opts | tr '\n' ' ') "${SSH_USER}@${local_ip}" "sudo bash -s" <<BOOTSTRAP
export NOMAD_SERVER_IP="${NOMAD_SERVER_IP}"
export CONSUL_SERVER_IP="${CONSUL_SERVER_IP}"
export PULP_REGISTRY_HOST="${PULP_REGISTRY_HOST}"
export PULP_REGISTRY_IP="${PULP_REGISTRY_IP}"
export ROLE=worker
$(cat "${SCRIPT_DIR}/bootstrap-179d-node.sh")
BOOTSTRAP
    success "Bootstrap complete: ${name} (${local_ip})"
  fi
done

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "Provisioning complete"
echo "  New nodes:     ${#provisioned[@]} / ${COUNT}"
echo "  Node range:    ${NODE_PREFIX}${START_INDEX} – ${NODE_PREFIX}$(( START_INDEX + COUNT - 1 ))"
echo "  IPs:           ${provisioned[*]:-none}"
echo ""
echo "Next steps:"
echo "  1. Confirm nodes appear in Nomad:"
echo "     nomad node status  (or check http://10.60.126.125:4646/ui/clients)"
echo "  2. system-hooks (image pre-pull) will run automatically on new nodes."
echo "     Monitor: nomad job status openstudio-server-system-hooks"
echo "  3. Once pre-pull succeeds, autoscaler will place workers on new nodes."
echo "  4. Each new node adds up to 45 workers (memory-bound at 80 GB / 1,750 MB)."
echo "  5. Cluster capacity after full scale-out:"
local new_total=$(( 119 + ${#provisioned[@]} ))
echo "     ~${new_total} nodes × 45 = $((new_total * 45)) workers maximum"
echo "══════════════════════════════════════════════════════════════"
