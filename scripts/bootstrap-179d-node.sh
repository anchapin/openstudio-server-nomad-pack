#!/usr/bin/env bash
#
# bootstrap-179d-node.sh
#
# Idempotent bootstrap helper for new 179d OpenStack Nomad clients.
# Installs Docker/Nomad/Consul/CNI, writes the client config, and restarts
# services once at the end.
#
# Usage:
#   sudo bash scripts/bootstrap-179d-node.sh --role worker
#   sudo bash scripts/bootstrap-179d-node.sh --role web
#
# Environment overrides:
#   NOMAD_SERVER_IP     Nomad server RPC address (default: 192.168.100.87)
#   CONSUL_SERVER_IP    Consul server address  (default: 192.168.100.87)
#   ROLE                worker|web (default: worker)
#   DISK_TYPE           Nomad meta.disk_type value (default: local-large)
#   DOCKER_MAX_CONCURRENT_DOWNLOADS  Docker image pull concurrency cap (default: 2)
#   PULP_REGISTRY_HOST  Registry hostname to pin in /etc/hosts (default: pulp-dev.hpc.nlr.gov)
#   PULP_REGISTRY_IP    Registry IP to pin in /etc/hosts (default: 10.60.127.127)
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap-179d-node.sh [--role worker|web]

Bootstraps a 179d OpenStack Nomad client in one pass:
  - installs Docker, Nomad, Consul, and CNI plugins
  - configures Consul to register with the local agent
  - configures Nomad as a client (not a server)
  - tags the node with role-specific meta so placement is easier

Defaults:
  ROLE=worker
  NOMAD_SERVER_IP=192.168.100.87
  CONSUL_SERVER_IP=192.168.100.87
  DISK_TYPE=local-large
EOF
}

ROLE="${ROLE:-worker}"
NOMAD_SERVER_IP="${NOMAD_SERVER_IP:-192.168.100.87}"
CONSUL_SERVER_IP="${CONSUL_SERVER_IP:-192.168.100.87}"
DISK_TYPE="${DISK_TYPE:-local-large}"
DOCKER_MAX_CONCURRENT_DOWNLOADS="${DOCKER_MAX_CONCURRENT_DOWNLOADS:-2}"
PULP_REGISTRY_HOST="${PULP_REGISTRY_HOST:-pulp-dev.hpc.nlr.gov}"
PULP_REGISTRY_IP="${PULP_REGISTRY_IP:-10.60.127.127}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      ROLE="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

case "${ROLE}" in
  worker|web) ;;
  *)
    echo "ROLE must be worker or web (got: ${ROLE})" >&2
    exit 1
    ;;
esac

PRIVATE_IP="$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
NOMAD_RESTART=false
NFS_OPENSTUDIO_DIR="/nfs/opensstudio/batch/openstudio"
NFS_DOCKER_TGZ="/nfs/opensstudio/batch/docker.tgz"

log() { echo "[$(hostname)] $*"; }

pin_registry_host() {
  local host="$1"
  local ip="$2"
  local hosts_file="/etc/hosts"
  [[ -n "${host}" && -n "${ip}" ]] || return 0

  if grep -qE "[[:space:]]${host}([[:space:]]|\$)" "${hosts_file}"; then
    sed -i.bak -E "/[[:space:]]${host}([[:space:]]|\$)/d" "${hosts_file}"
  fi
  echo "${ip} ${host}" >> "${hosts_file}"
  log "Pinned registry host ${host} -> ${ip} in ${hosts_file}"
}

install -d -m 0755 /etc/apt/keyrings
if ! command -v consul >/dev/null 2>&1 || ! command -v nomad >/dev/null 2>&1; then
  curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" >/etc/apt/sources.list.d/hashicorp.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y consul nomad
fi

install -d -m 0755 /opt/cni/bin
if ! [ -x /opt/cni/bin/bridge ]; then
  curl -fsSL https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz -o /tmp/cni.tgz
  tar -xzf /tmp/cni.tgz -C /opt/cni/bin
  rm -f /tmp/cni.tgz
fi

install -d -m 0755 /etc/consul.d /opt/consul /etc/nomad.d /opt/nomad

cat >/etc/consul.d/consul.hcl <<EOF
datacenter = "dc1"
data_dir   = "/opt/consul"
bind_addr  = "${PRIVATE_IP}"
client_addr = "0.0.0.0"
retry_join = ["${CONSUL_SERVER_IP}"]
server     = false
ui_config { enabled = false }
EOF
cat >/etc/nomad.d/nomad.hcl <<EOF
datacenter = "dc1"
data_dir   = "/opt/nomad"
bind_addr  = "0.0.0.0"

advertise {
  http = "${PRIVATE_IP}:4646"
  rpc  = "${PRIVATE_IP}:4647"
  serf = "${PRIVATE_IP}:4648"
}

server {
  enabled = false
}

client {
  enabled = true
  servers = ["${NOMAD_SERVER_IP}:4647"]
  cni_path = "/opt/cni/bin"
  meta {
    disk_type = "${DISK_TYPE}"
    node_role = "${ROLE}"
  }

  host_volume "openstudio-nfs" {
    path      = "/nfs/opensstudio/batch/openstudio"
    read_only = false
  }
}

consul {
  address          = "127.0.0.1:8500"
  auto_advertise   = true
  client_auto_join = true
}

plugin "docker" {
  config {
    allow_privileged = true
    volumes {
      enabled = true
    }
  }
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}

# Retain legacy option for older Nomad versions
options = {
  "driver.raw_exec.enable" = "1"
}
EOF

if [ ! -f /etc/systemd/system/consul.service ] && [ ! -f /lib/systemd/system/consul.service ]; then
  cat >/etc/systemd/system/consul.service <<UNIT
[Unit]
Description=Consul Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/consul agent -config-file=/etc/consul.d/consul.hcl
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
fi

if [ ! -f /etc/systemd/system/nomad.service ] && [ ! -f /lib/systemd/system/nomad.service ]; then
  cat >/etc/systemd/system/nomad.service <<UNIT
[Unit]
Description=Nomad
After=network-online.target consul.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/nomad agent -config /etc/nomad.d
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
fi

if ! docker info >/dev/null 2>&1; then
  rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket
  if [ -f "${NFS_DOCKER_TGZ}" ]; then
    tar -xzf "${NFS_DOCKER_TGZ}" -C /usr/local/bin --strip-components=1
    chmod +x /usr/local/bin/docker /usr/local/bin/dockerd /usr/local/bin/containerd \
              /usr/local/bin/docker-init /usr/local/bin/docker-proxy 2>/dev/null || true
  elif [ ! -s "$(command -v dockerd 2>/dev/null || echo /usr/bin/dockerd)" ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  fi

  cat >/etc/systemd/system/docker.service <<UNIT
[Unit]
Description=Docker Application Container Engine
After=network.target

[Service]
ExecStart=/usr/bin/dockerd
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

install -d -m 0755 /etc/docker
python3 - <<PY
import json
from pathlib import Path

path = Path("/etc/docker/daemon.json")
cfg = {}
if path.exists():
    try:
        cfg = json.loads(path.read_text())
    except Exception:
        cfg = {}
cfg["max-concurrent-downloads"] = int("${DOCKER_MAX_CONCURRENT_DOWNLOADS}")
# Pin the Pulp registry IP in Docker's DNS so the daemon does not rely on
# systemd-resolved (127.0.0.53), which can time-out under load.
# Use the registry IP as primary DNS, fall back to public resolvers.
cfg["dns"] = ["${PULP_REGISTRY_IP}", "8.8.8.8", "8.8.4.4"]
path.write_text(json.dumps(cfg, indent=2) + "\n")
PY
log "Docker daemon.json updated (max-concurrent-downloads, dns)"
pin_registry_host "${PULP_REGISTRY_HOST}" "${PULP_REGISTRY_IP}"

mkdir -p "$NFS_OPENSTUDIO_DIR"
chmod 777 "$NFS_OPENSTUDIO_DIR"
log "NFS openstudio dir ready: $NFS_OPENSTUDIO_DIR"

systemctl daemon-reload
systemctl unmask docker.service docker.socket 2>/dev/null || true
systemctl enable docker.service consul.service nomad.service
systemctl restart docker.service
systemctl restart consul.service
systemctl restart nomad.service

echo "Bootstrap complete: $(hostname) (${ROLE}) @ ${PRIVATE_IP}"
