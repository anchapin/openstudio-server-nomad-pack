# infra-setup.nomad
#
# One-time system job that configures all Nomad clients for openstudio-server-nomad-pack testing:
#   1. Adds consul stanza to Nomad client config so services are registered with the central Consul server
#   2. Configures Docker data-root on local storage for reliable layer extraction
#   3. Reloads Nomad client and Docker to pick up the changes
#
# Deploy:
#   export NOMAD_ADDR=http://localhost:4646
#   nomad run infra-setup.nomad
#
# Teardown when done testing:
#   nomad stop -purge infra-setup

[[ if var "enable_infra_setup" . ]]
job "[[ var "job_name" . ]]-infra-setup" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "system"

  group "configure-client" {
    restart {
      attempts = 0
      mode     = "fail"
    }

    task "setup" {
      driver = "raw_exec"

      config {
        command = "/bin/bash"
        args    = ["-c", "${NOMAD_TASK_DIR}/setup.sh"]
      }

      template {
        destination = "${NOMAD_TASK_DIR}/setup.sh"
        perms       = "755"
        data        = <<SCRIPT
#!/bin/bash
set -e

CONSUL_SERVER_IP="192.168.100.87"  # nomad-server nomad-net IP
LOCAL_DOCKER_DIR="/var/lib/docker-local"
NFS_OPENSTUDIO_DIR="/nfs/openstudio/batch/openstudio"
NFS_DOCKER_TGZ="/nfs/openstudio/batch/docker.tgz"
DOCKER_MAX_CONCURRENT_DOWNLOADS="2"
PULP_REGISTRY_HOST="pulp-dev.hpc.nlr.gov"
PULP_REGISTRY_IP="10.60.127.127"

log() { echo "[$(hostname)] $*"; }

pin_registry_host() {
  local host="$1"
  local ip="$2"
  local hosts_file="/etc/hosts"
  [ -n "$host" ] && [ -n "$ip" ] || return 0

  if grep -qE "( |^)$host( |$)" "$hosts_file"; then
    sed -i.bak -E "/( |^)$host( |$)/d" "$hosts_file"
  fi
  echo "$ip $host" >> "$hosts_file"
  log "Pinned registry host $host -> $ip in $hosts_file"
}

NOMAD_RESTART_REQUIRED=false

# ── Step 1: Install Docker from NFS static binary (no internet access) ───────
if ! command -v docker &>/dev/null; then
  if [ -f "$NFS_DOCKER_TGZ" ]; then
    log "Installing Docker from $NFS_DOCKER_TGZ"
    tar -xzf "$NFS_DOCKER_TGZ" -C /usr/local/bin --strip-components=1
    chmod +x /usr/local/bin/docker /usr/local/bin/dockerd /usr/local/bin/containerd \
              /usr/local/bin/docker-init /usr/local/bin/docker-proxy 2>/dev/null || true

    # Create dockerd systemd unit if missing
    if [ ! -f /etc/systemd/system/docker.service ]; then
      cat > /etc/systemd/system/docker.service <<UNIT
[Unit]
Description=Docker Application Container Engine
After=network.target

[Service]
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=always
RestartSec=2
StartLimitIntervalSec=60
StartLimitBurst=3
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
UNIT
    fi

    mkdir -p /etc/docker
    systemctl daemon-reload
    systemctl enable docker
    log "Docker installed from static binary"
  else
    log "ERROR: $NFS_DOCKER_TGZ not found — cannot install Docker"
    exit 1
  fi
else
  log "Docker already installed: $(docker --version 2>/dev/null)"
fi

# ── Step 2: Configure Docker data-root on local storage ──────────────────────
DOCKER_DATA_DIR="${LOCAL_DOCKER_DIR}"
mkdir -p "$DOCKER_DATA_DIR"

# Rebuild daemon.json ensuring data-root, dns, and max-concurrent-downloads are all set.
# Using Python to merge safely; only sets DOCKER_RESTART_REQUIRED if the file changed.
DOCKER_CHANGED=$(python3 - <<PY
import json
from pathlib import Path

path = Path("/etc/docker/daemon.json")
cfg = {}
if path.exists():
    try:
        cfg = json.loads(path.read_text())
    except Exception:
        cfg = {}

desired = dict(cfg)
desired["data-root"]                = "${DOCKER_DATA_DIR}"
desired["max-concurrent-downloads"] = ${DOCKER_MAX_CONCURRENT_DOWNLOADS}
desired["log-driver"]               = "json-file"
desired["log-opts"]                 = {"max-size": "50m", "max-file": "3"}
# Pin Pulp registry IP as Docker's primary DNS so the daemon never relies on
# systemd-resolved (127.0.0.53), which times out under registry pull load.
desired["dns"] = ["${PULP_REGISTRY_IP}", "8.8.8.8", "8.8.4.4"]

if cfg == desired:
    print("unchanged")
else:
    path.write_text(json.dumps(desired, indent=2) + "\n")
    print("changed")
PY
)
if [ "$DOCKER_CHANGED" = "changed" ]; then
  log "Docker daemon.json updated (data-root, dns, max-concurrent-downloads)"
  if ! systemctl is-active --quiet docker; then
    systemctl start docker
    log "Docker started"
  else
    systemctl restart docker
    log "Docker restarted with data-root=$DOCKER_DATA_DIR"
  fi
  # Wait briefly for Docker socket
  for i in $(seq 1 10); do
    docker info &>/dev/null && break
    sleep 2
  done
  docker info --format '{{.DockerRootDir}}' 2>/dev/null && log "Docker root dir confirmed" || log "WARNING: docker info failed"
else
  log "Docker daemon.json unchanged — skipping restart"
  systemctl is-active --quiet docker || { systemctl start docker; log "Docker started (was stopped)"; }
fi
pin_registry_host "$PULP_REGISTRY_HOST" "$PULP_REGISTRY_IP"

# ── Step 2b: Ensure nomad user is in the docker group ────────────────────────
# raw_exec tasks run as the nomad user; without docker group membership
# 'docker pull' fails with "permission denied" on /var/run/docker.sock.
if ! id -nG nomad 2>/dev/null | grep -qw docker; then
  usermod -aG docker nomad
  log "Added nomad user to docker group — Nomad restart required to apply group"
  NOMAD_RESTART_REQUIRED=true
else
  log "nomad user already in docker group"
fi

# ── Step 3: Create shared openstudio data dir on NFS ─────────────────────────
mkdir -p "$NFS_OPENSTUDIO_DIR"
chmod 777 "$NFS_OPENSTUDIO_DIR"
log "NFS openstudio dir ready: $NFS_OPENSTUDIO_DIR"

# ── Step 4: Ensure Nomad uses the active primary NIC (avoid stale eth0) ─────
NOMAD_MAIN_CONF="/etc/nomad.d/nomad.hcl"
PRIMARY_IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
if [ -z "$PRIMARY_IFACE" ]; then
  if ip link show ens3 >/dev/null 2>&1; then
    PRIMARY_IFACE="ens3"
  elif ip link show eth0 >/dev/null 2>&1; then
    PRIMARY_IFACE="eth0"
  else
    log "ERROR: could not determine primary network interface for Nomad"
    exit 1
  fi
fi

if [ -f "$NOMAD_MAIN_CONF" ]; then
  if grep -q 'nomad-server:4646' "$NOMAD_MAIN_CONF"; then
    log "Updating Nomad client RPC port to nomad-server:4647"
    sed -i.bak -E 's/nomad-server:4646/nomad-server:4647/g' "$NOMAD_MAIN_CONF"
    NOMAD_RESTART_REQUIRED=true
  fi

  if grep -q 'network_interface' "$NOMAD_MAIN_CONF"; then
    current_iface="$(sed -n 's/^[ 	]*network_interface[ 	]*=[ 	]*"\([^"]*\)".*/\1/p' "$NOMAD_MAIN_CONF" | head -n1)"
    if [ "$current_iface" != "$PRIMARY_IFACE" ]; then
      current_iface_safe="$current_iface"
      [ -z "$current_iface_safe" ] &&       current_iface_safe="<unset>"
      log "Updating Nomad network_interface: $current_iface_safe -> $PRIMARY_IFACE"
      sed -i.bak -E "s|^[ 	]*network_interface[ 	]*=.*$|  network_interface = \"$PRIMARY_IFACE\"|" "$NOMAD_MAIN_CONF"
      NOMAD_RESTART_REQUIRED=true
    else
      log "Nomad network_interface already set to $PRIMARY_IFACE"
    fi
  else
    log "WARNING: network_interface not found in $NOMAD_MAIN_CONF; leaving file unchanged"
  fi
else
  log "WARNING: $NOMAD_MAIN_CONF not found; skipping network_interface enforcement"
fi

# ── Step 5: Enable host-path mounts for Nomad Docker tasks ───────────────────
NOMAD_DOCKER_CONF="/etc/nomad.d/docker.hcl"
DOCKER_HCL_DESIRED='plugin "docker" {
  config {
    volumes {
      enabled = true
    }
  }
}'
if [ ! -f "$NOMAD_DOCKER_CONF" ] || ! grep -q "enabled = true" "$NOMAD_DOCKER_CONF" 2>/dev/null; then
  cat > "$NOMAD_DOCKER_CONF" <<HCL
plugin "docker" {
  config {
    volumes {
      enabled = true
    }
  }
}
HCL
  log "Wrote Nomad Docker plugin config with volumes.enabled=true"
  NOMAD_RESTART_REQUIRED=true
else
  log "Nomad Docker plugin config already present, skipping"
fi

# ── Step 6: Add Consul address to Nomad client config ────────────────────────
CONSUL_CONF="/etc/nomad.d/consul.hcl"
# Nomad must register services with the LOCAL Consul agent (127.0.0.1), not
# the remote Consul server. The local agent propagates registrations cluster-wide.
if [ ! -f "$CONSUL_CONF" ] || ! grep -q "127.0.0.1:8500" "$CONSUL_CONF" 2>/dev/null; then
  log "Adding Consul config → $CONSUL_CONF"
  cat > "$CONSUL_CONF" <<HCL
consul {
  address = "127.0.0.1:8500"
}
HCL
  NOMAD_RESTART_REQUIRED=true
else
  log "Consul config already present, skipping"
fi

if [ "$NOMAD_RESTART_REQUIRED" = true ]; then
  log "Restarting Nomad once to apply all config changes"
  systemctl reset-failed nomad || true
  systemctl restart nomad
else
  log "Nomad config already up to date; no restart needed"
fi

log "Setup complete on $(hostname)"
SCRIPT
      }

      resources {
        cpu    = 500
        memory = 256
      }
    }
  }
}
[[ end ]]

