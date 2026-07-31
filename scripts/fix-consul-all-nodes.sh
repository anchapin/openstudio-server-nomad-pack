#!/usr/bin/env bash
#
# fix-consul-all-nodes.sh
#
# Ensures every nomad-client node uses the local Consul agent for
# service registration. This is the main Consul-side correction that
# eliminates stale remote-registration failures.
#
# Usage:
#   ./scripts/fix-consul-all-nodes.sh
#
set -euo pipefail

CONSUL_SERVER_IP="${CONSUL_SERVER_IP:-192.168.100.87}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
if [ -n "${SSH_JUMP_HOST:-}" ]; then
  SSH_OPTS+=(-J "${SSH_JUMP_HOST}")
fi

if ! command -v openstack >/dev/null 2>&1; then
  echo "openstack CLI is required." >&2
  exit 1
fi

nodes="$(openstack server list -f json | jq -r '.[] | select(.Status == "ACTIVE" and (.Name | test("^(nomad-client-|nomad-web-bake-179d$)"))) | [.Name, (.Networks["nomad-net"][0] // "")] | @tsv')"

if [ -z "${nodes}" ]; then
  echo "No active nomad-client servers found."
  exit 0
fi

printf '%s\n' "${nodes}" | while IFS=$'\t' read -r name ip; do
  [ -n "${ip}" ] || continue
  echo "-> ${name} (${ip})"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "sudo bash -s" <<EOF
set -euo pipefail
  mkdir -p /etc/nomad.d
  cat >/etc/nomad.d/consul.hcl <<HCL
  consul {
    address = "127.0.0.1:8500"
  }
HCL
systemctl restart nomad
EOF
done

echo "Consul registration fix complete."
