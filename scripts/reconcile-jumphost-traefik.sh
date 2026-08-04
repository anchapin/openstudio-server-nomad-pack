#!/usr/bin/env bash
set -euo pipefail

JUMP_HOST="${JUMP_HOST:-ubuntu@10.60.105.39}"
NOMAD_SERVER_HOST="${NOMAD_SERVER_HOST:-ubuntu@10.60.126.125}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
INGRESS_HOST="${INGRESS_HOST:-10.60.126.125}"
CONSUL_ENDPOINT="${CONSUL_ENDPOINT:-127.0.0.1:8500}"
TRAEFIK_CONFIG_PATH="${TRAEFIK_CONFIG_PATH:-/etc/traefik/traefik.yml}"

if [ ! -f "${SSH_KEY}" ]; then
  echo "ERROR: SSH key not found: ${SSH_KEY}" >&2
  exit 1
fi

cat <<'EOF' | ssh -i "${SSH_KEY}" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -J "${JUMP_HOST}" \
  "${NOMAD_SERVER_HOST}" "TRAEFIK_CONFIG_PATH='${TRAEFIK_CONFIG_PATH}' CONSUL_ENDPOINT='${CONSUL_ENDPOINT}' bash -s"
set -euo pipefail

sudo tee "${TRAEFIK_CONFIG_PATH}" >/dev/null <<YAML
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
  metrics:
    address: ":8082"

api:
  dashboard: true
  insecure: true

ping: {}

providers:
  consulCatalog:
    endpoint:
      address: "${CONSUL_ENDPOINT}"
      scheme: "http"
    prefix: "traefik"
    exposedByDefault: false
    refreshInterval: "10s"

metrics:
  prometheus:
    entryPoint: metrics
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
YAML

sudo systemctl restart traefik
sudo systemctl is-active --quiet traefik

for _ in $(seq 1 15); do
  if curl -fsS --max-time 10 http://127.0.0.1:8080/api/http/routers >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS --max-time 10 http://127.0.0.1:8080/api/http/routers >/dev/null

for _ in $(seq 1 15); do
  if curl -fsS --max-time 10 http://127.0.0.1:8082/metrics >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS --max-time 10 http://127.0.0.1:8082/metrics >/dev/null
EOF

"$(dirname "$0")/check-openstack-ingress.sh" --ingress-host "${INGRESS_HOST}"
echo "Traefik reconciliation complete."
