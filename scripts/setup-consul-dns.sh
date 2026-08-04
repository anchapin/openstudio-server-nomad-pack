#!/usr/bin/env bash
#
# setup-consul-dns.sh
#
# Configures the OS DNS resolver on a Nomad client node to forward all
# .consul queries to the local Consul agent (127.0.0.1:8600).
#
# After this script runs, service discovery names such as
#   nomad.service.consul
#   openstudio-prometheus.service.consul
# resolve without hard-coded IP addresses.
#
# Supports:
#   - systemd-resolved (Ubuntu 18.04+, Debian 10+)  — preferred
#   - dnsmasq fallback for older distros without systemd-resolved
#
# Usage (run as root on each Nomad client node):
#   sudo bash scripts/setup-consul-dns.sh
#
# To roll out across all OpenStack cluster nodes at once, use:
#   ./scripts/fix-consul-dns-all-nodes.sh
#
set -euo pipefail

log()     { echo "[consul-dns] $*"; }
success() { echo "[consul-dns] OK: $*"; }
warn()    { echo "[consul-dns] WARN: $*"; }

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# ── Step 1: verify Consul agent is reachable on port 8600 ─────────────────────
log "Checking that Consul DNS is listening on 127.0.0.1:8600 ..."
if ! consul_ver="$(consul version 2>/dev/null | head -1)"; then
  warn "consul binary not found — is Consul installed?"
  exit 1
fi
log "Consul installed: ${consul_ver}"

if ! systemctl is-active --quiet consul.service 2>/dev/null; then
  warn "consul.service is not running. Start it first: systemctl start consul.service"
  exit 1
fi

# Quick DNS sanity check against Consul's own port
if command -v dig >/dev/null 2>&1; then
  if dig @127.0.0.1 -p 8600 consul.service.consul SRV +time=3 +tries=1 +short >/dev/null 2>&1; then
    log "Consul DNS port 8600 is responding."
  else
    warn "Consul DNS port 8600 did not respond. Consul may still be bootstrapping — proceeding anyway."
  fi
fi

# ── Step 2: configure OS resolver ─────────────────────────────────────────────
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  log "Detected systemd-resolved — configuring stub resolver for .consul domain ..."

  mkdir -p /etc/systemd/resolved.conf.d
  cat >/etc/systemd/resolved.conf.d/consul.conf <<'EOF'
[Resolve]
# Forward all .consul queries to the local Consul agent DNS port.
# This allows service discovery names like nomad.service.consul to resolve
# without hard-coded IP addresses anywhere in the pack configuration.
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
EOF

  systemctl restart systemd-resolved
  success "systemd-resolved restarted with .consul stub zone."

elif command -v dnsmasq >/dev/null 2>&1 || apt-cache show dnsmasq >/dev/null 2>&1; then
  log "systemd-resolved not active — using dnsmasq fallback ..."

  if ! command -v dnsmasq >/dev/null 2>&1; then
    log "Installing dnsmasq ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
  fi

  mkdir -p /etc/dnsmasq.d
  cat >/etc/dnsmasq.d/consul.conf <<'EOF'
# Forward .consul queries to the local Consul agent DNS port.
server=/consul/127.0.0.1#8600
EOF

  systemctl enable --now dnsmasq
  systemctl restart dnsmasq
  success "dnsmasq configured with .consul forwarding."

else
  echo "[consul-dns] ERROR: Neither systemd-resolved nor dnsmasq is available." >&2
  echo "  Install one of them, then re-run this script." >&2
  exit 1
fi

# ── Step 3: verify end-to-end resolution ──────────────────────────────────────
log "Verifying .consul name resolution ..."
sleep 2  # give the resolver a moment to come up

if command -v nslookup >/dev/null 2>&1; then
  if nslookup consul.service.consul >/dev/null 2>&1; then
    success "consul.service.consul resolves via OS resolver."
  else
    warn "consul.service.consul did not resolve yet."
    warn "This is normal if no services are registered. Test with:"
    warn "  nslookup nomad.service.consul"
    warn "  dig nomad.service.consul"
  fi
elif command -v dig >/dev/null 2>&1; then
  if dig consul.service.consul +time=3 +tries=1 +short >/dev/null 2>&1; then
    success "consul.service.consul resolves via OS resolver."
  else
    warn "consul.service.consul did not resolve yet (may need services to register first)."
  fi
else
  warn "nslookup/dig unavailable; skipping OS-resolver verification for consul.service.consul."
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Consul DNS forwarding configured."
echo ""
echo "Test resolution:"
echo "  nslookup nomad.service.consul"
echo "  nslookup openstudio-prometheus.service.consul"
echo "  wget -qO- http://nomad.service.consul:4646/v1/status/leader"
echo ""
echo "Hard-coded IP overrides can now be removed from var-files."
echo "The pack defaults resolve correctly via Consul DNS:"
echo "  autoscaler_nomad_address      = http://nomad.service.consul:4646"
echo "  autoscaler_prometheus_address = http://openstudio-prometheus.service.consul:9090"
echo "═══════════════════════════════════════════════════════════════"
