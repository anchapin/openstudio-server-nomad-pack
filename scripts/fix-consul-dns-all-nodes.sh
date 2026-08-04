#!/usr/bin/env bash
#
# fix-consul-dns-all-nodes.sh
#
# Rolls out Consul DNS forwarding (systemd-resolved stub zone for .consul)
# to every active Nomad client node in the OpenStack cluster.
#
# After this runs, service discovery names such as
#   nomad.service.consul
#   openstudio-prometheus.service.consul
# resolve on every node without hard-coded IP addresses.
#
# Usage:
#   ./scripts/fix-consul-dns-all-nodes.sh
#
# Environment overrides (all have working defaults):
#   SSH_USER        SSH login user              (default: ubuntu)
#   SSH_KEY         Path to private key         (default: ~/.ssh/id_rsa)
#   SSH_JUMP_HOST   Optional jump/bastion host
#   NOMAD_ADDR      Nomad API for node listing  (default: http://10.60.126.125:4646)
#   DRY_RUN         Set to "true" to print what would run without executing
#
# Prerequisites:
#   - openstack CLI installed and authenticated (or NOMAD_ADDR reachable)
#   - SSH key configured and nodes accepting the key
#   - scripts/setup-consul-dns.sh must exist alongside this script
#
set -euo pipefail

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
# Double-jump: workstation → openstudio-mcp (10.60.105.39) → nomad-server (10.60.126.125) → client nodes (192.168.100.x)
# The jump host cannot reach 192.168.100.x directly; nomad-server bridges the two networks.
SSH_JUMP_HOST="${SSH_JUMP_HOST:-ubuntu@10.60.105.39,ubuntu@10.60.126.125}"
NOMAD_ADDR="${NOMAD_ADDR:-http://10.60.126.125:4646}"
DRY_RUN="${DRY_RUN:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONSUL_DNS_SCRIPT="${SCRIPT_DIR}/setup-consul-dns.sh"

SSH_OPTS=(-i "${SSH_KEY}"
          -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR
          -o ConnectTimeout=10
          -o ServerAliveInterval=30)
if [[ -n "${SSH_JUMP_HOST:-}" ]]; then
  SSH_OPTS+=(-J "${SSH_JUMP_HOST}")
fi

info()    { echo "[fix-consul-dns] $*"; }
success() { echo "[fix-consul-dns] OK: $*"; }
warn()    { echo "[fix-consul-dns] WARN: $*"; }
error()   { echo "[fix-consul-dns] ERROR: $*" >&2; exit 1; }

if [[ ! -f "${CONSUL_DNS_SCRIPT}" ]]; then
  error "setup-consul-dns.sh not found at ${CONSUL_DNS_SCRIPT}"
fi

# ── Discover node IPs ─────────────────────────────────────────────────────────
# Prefer openstack CLI (richer metadata); fall back to Nomad API.
get_node_ips() {
  if command -v openstack >/dev/null 2>&1 && openstack token issue -f value -c id >/dev/null 2>&1; then
    info "Querying OpenStack for active Nomad client nodes ..." >&2
    openstack server list -f json \
      | python3 -c "
import sys, json, re, ipaddress

servers = json.load(sys.stdin)
ips = []
for s in servers:
    name = s.get('Name', '')
    status = s.get('Status', '')
    if status != 'ACTIVE':
        continue
    if not re.search(r'^nomad-client-|^nomad-web-bake-', name):
        continue
    networks = s.get('Networks', {})
    for entries in networks.values():
        if isinstance(entries, list):
            for e in entries:
                addr = e if isinstance(e, str) else e.get('addr', '')
                try:
                    ipaddress.ip_address(addr)
                    ips.append(addr)
                    break
                except ValueError:
                    pass
        elif isinstance(entries, str):
            ips.append(entries)

for ip in ips:
    print(ip)
"
  else
    info "openstack CLI not available — querying Nomad API at ${NOMAD_ADDR} ..." >&2
    curl -fsSL "${NOMAD_ADDR}/v1/nodes?stale=false" \
      | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
for n in nodes:
    if n.get('Status') != 'ready':
        continue
    addr = n.get('Address', '')
    if addr:
        print(addr)
"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
SCRIPT_CONTENT="$(cat "${CONSUL_DNS_SCRIPT}")"

mapfile -t NODE_IPS < <(get_node_ips)

if [[ ${#NODE_IPS[@]} -eq 0 ]]; then
  warn "No active Nomad client nodes found. Check openstack auth or NOMAD_ADDR."
  exit 0
fi

info "Found ${#NODE_IPS[@]} node(s) to configure."

passed=0
failed=0
skipped=0

for ip in "${NODE_IPS[@]}"; do
  [[ -n "${ip}" ]] || continue

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY-RUN] Would configure Consul DNS on ${ip}"
    (( skipped++ )) || true
    continue
  fi

  info "Configuring ${ip} ..."
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "sudo bash -s" <<< "${SCRIPT_CONTENT}" 2>&1 \
       | sed "s/^/  [${ip}] /"; then
    success "${ip} — Consul DNS configured."
    (( passed++ )) || true
  else
    warn "${ip} — configuration failed (check SSH access and Consul status on that node)."
    (( failed++ )) || true
  fi
done

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "Consul DNS rollout complete"
echo "  Configured:  ${passed}"
echo "  Failed:      ${failed}"
if [[ "${DRY_RUN}" == "true" ]]; then
echo "  Dry-run:     ${skipped} (no changes made)"
fi
echo ""
echo "Verify on any node:"
echo "  ssh ${SSH_USER}@<node-ip> 'nslookup nomad.service.consul'"
echo "  ssh ${SSH_USER}@<node-ip> 'wget -qO- http://nomad.service.consul:4646/v1/status/leader'"
echo ""
echo "Once all nodes pass verification, autoscaler var-file overrides"
echo "can be removed — the pack defaults use Consul DNS automatically."
echo "══════════════════════════════════════════════════════════════"

if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi
