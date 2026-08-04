#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATE_SCRIPT="${REPO_ROOT}/scripts/validate-traefik-consul-endpoint.sh"

JUMP_HOST="${JUMP_HOST:-ubuntu@10.60.105.39}"
TRAEFIK_HOST="${TRAEFIK_HOST:-ubuntu@10.60.126.125}"
INGRESS_HOST="${INGRESS_HOST:-10.60.126.125}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
EXPECTED_ROUTER="${EXPECTED_ROUTER:-openstudio-server@consulcatalog}"
TRAEFIK_CONFIG_PATH="${TRAEFIK_CONFIG_PATH:-/etc/traefik/traefik.yml}"
METRICS_PORT="${METRICS_PORT:-8082}"

while [ $# -gt 0 ]; do
  case "$1" in
    --jump-host)
      JUMP_HOST="$2"; shift 2;;
    --traefik-host)
      TRAEFIK_HOST="$2"; shift 2;;
    --ingress-host)
      INGRESS_HOST="$2"; shift 2;;
    --ssh-key)
      SSH_KEY="$2"; shift 2;;
    --expected-router)
      EXPECTED_ROUTER="$2"; shift 2;;
    --config-path)
      TRAEFIK_CONFIG_PATH="$2"; shift 2;;
    --metrics-port)
      METRICS_PORT="$2"; shift 2;;
    --help|-h)
      cat <<EOF
Usage: $0 [options]
  --jump-host <user@host>       SSH jump host (default: ${JUMP_HOST})
  --traefik-host <user@host>    Host running Traefik (default: ${TRAEFIK_HOST})
  --ingress-host <host>         Ingress host used for Host header and URL checks (default: ${INGRESS_HOST})
  --ssh-key <path>              SSH private key path (default: ${SSH_KEY})
  --expected-router <name>      Router name expected in Traefik API (default: ${EXPECTED_ROUTER})
  --config-path <path>          Traefik config path on remote host (default: ${TRAEFIK_CONFIG_PATH})
  --metrics-port <port>         Traefik metrics port on remote host (default: ${METRICS_PORT})
EOF
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ ! -x "${VALIDATE_SCRIPT}" ]; then
  echo "ERROR: Missing executable validator: ${VALIDATE_SCRIPT}" >&2
  exit 1
fi

if [ ! -f "${SSH_KEY}" ]; then
  echo "ERROR: SSH key not found: ${SSH_KEY}" >&2
  exit 1
fi

SSH_OPTS=(
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=no
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
)

remote_ssh() {
  ssh "${SSH_OPTS[@]}" -J "${JUMP_HOST}" "${TRAEFIK_HOST}" "$@"
}

echo "Checking Traefik config on ${TRAEFIK_HOST}..."
TMP_CONFIG="$(mktemp)"
cleanup() { rm -f "${TMP_CONFIG}"; }
trap cleanup EXIT

remote_ssh "sudo cat '${TRAEFIK_CONFIG_PATH}'" > "${TMP_CONFIG}"
"${VALIDATE_SCRIPT}" "${TMP_CONFIG}"

echo "Checking Traefik router API..."
ROUTERS_JSON="$(
  remote_ssh "curl -fsS --max-time 10 http://127.0.0.1:8080/api/http/routers"
)"

printf '%s' "${ROUTERS_JSON}" | python3 -c '
import json
import sys

expected = sys.argv[1]
routers = json.loads(sys.stdin.read())
for router in routers:
    if router.get("name") == expected and router.get("status") == "enabled":
        print(f"OK: Router present and enabled: {expected}")
        raise SystemExit(0)

print(f"ERROR: Router missing or not enabled: {expected}", file=sys.stderr)
raise SystemExit(1)
' "${EXPECTED_ROUTER}"

echo "Checking Traefik metrics endpoint..."
remote_ssh "curl -fsS --max-time 10 http://127.0.0.1:${METRICS_PORT}/metrics >/dev/null"
echo "OK: Traefik metrics endpoint is reachable on :${METRICS_PORT}"

echo "Checking local Traefik path with explicit Host header..."
LOCAL_HTTP_CODE="$(
  remote_ssh "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: ${INGRESS_HOST}' http://127.0.0.1/"
)"
if [[ ! "${LOCAL_HTTP_CODE}" =~ ^[23] ]]; then
  echo "ERROR: Local Traefik request failed, HTTP ${LOCAL_HTTP_CODE}" >&2
  exit 1
fi
echo "OK: Local Traefik request returned HTTP ${LOCAL_HTTP_CODE}"

echo "Checking external ingress URL..."
EXTERNAL_HTTP_CODE="$(
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://${INGRESS_HOST}/"
)"
if [[ ! "${EXTERNAL_HTTP_CODE}" =~ ^[23] ]]; then
  echo "ERROR: External ingress request failed, HTTP ${EXTERNAL_HTTP_CODE}" >&2
  exit 1
fi
echo "OK: External ingress request returned HTTP ${EXTERNAL_HTTP_CODE}"

echo "Ingress smoke check passed."
