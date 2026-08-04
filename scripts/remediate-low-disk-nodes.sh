#!/usr/bin/env bash
set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:-http://10.60.126.125:4646}"
JUMP_HOST="${JUMP_HOST:-ubuntu@10.60.105.39}"
NOMAD_SERVER_HOST="${NOMAD_SERVER_HOST:-ubuntu@10.60.126.125}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
THRESHOLD_MB="${THRESHOLD_MB:-20480}"
ALLOW_WEB_ROLE_QUARANTINE="${ALLOW_WEB_ROLE_QUARANTINE:-false}"
APPLY=false
DRAIN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --drain) DRAIN=true; shift ;;
    --threshold-mb) THRESHOLD_MB="$2"; shift 2 ;;
    --allow-web-role-quarantine) ALLOW_WEB_ROLE_QUARANTINE=true; shift ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--apply] [--drain] [--threshold-mb N]
  --apply          Set low-disk nodes to ineligible in Nomad
  --drain          Also enable drain on low-disk nodes (requires --apply)
  --threshold-mb   Free-disk threshold in MB (default: ${THRESHOLD_MB})
  --allow-web-role-quarantine
                   Allow quarantine of node_role=web nodes (default: false)
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ "${DRAIN}" = "true" ] && [ "${APPLY}" != "true" ]; then
  echo "ERROR: --drain requires --apply" >&2
  exit 1
fi

if [ ! -f "${SSH_KEY}" ]; then
  echo "ERROR: SSH key not found: ${SSH_KEY}" >&2
  exit 1
fi

TMP_NODES="$(mktemp)"
cleanup() { rm -f "${TMP_NODES}"; }
trap cleanup EXIT

curl -fsS --max-time 20 "${NOMAD_ADDR}/v1/nodes" > "${TMP_NODES}"

python3 - "${TMP_NODES}" <<'PY' | while IFS=$'\t' read -r NODE_ID NODE_NAME; do
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    nodes = json.load(f)
for n in nodes:
    if n.get("Status") != "ready":
        continue
    if n.get("SchedulingEligibility") != "eligible":
        continue
    print(f"{n.get('ID')}\t{n.get('Name')}")
PY
  NODE_DETAIL="$(curl -fsS --max-time 15 "${NOMAD_ADDR}/v1/node/${NODE_ID}")"
  NODE_IP="$(printf '%s' "${NODE_DETAIL}" | python3 -c 'import json,sys; d=json.load(sys.stdin); a=d.get("Attributes",{}); print(a.get("unique.network.ip-address",""))')"
  NODE_ROLE="$(printf '%s' "${NODE_DETAIL}" | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d.get("Meta",{}); print(m.get("node_role",""))')"
  if [ -z "${NODE_IP}" ]; then
    echo "WARN: ${NODE_NAME} (${NODE_ID:0:8}) has no unique.network.ip-address"
    continue
  fi

  FREE_MB="$(
    ssh -i "${SSH_KEY}" \
      -n \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -J "${JUMP_HOST},${NOMAD_SERVER_HOST}" \
      "${SSH_USER}@${NODE_IP}" \
      "df -Pm / | awk 'NR==2 {print \$4}'" 2>/dev/null || echo ""
  )"

  if [ -z "${FREE_MB}" ]; then
    echo "WARN: ${NODE_NAME} (${NODE_ID:0:8}) unreachable for disk check"
    continue
  fi

  if [ "${FREE_MB}" -lt "${THRESHOLD_MB}" ]; then
    echo "LOW_DISK: ${NODE_NAME} (${NODE_ID:0:8}) role=${NODE_ROLE:-unknown} free=${FREE_MB}MB threshold=${THRESHOLD_MB}MB"
    if [ "${NODE_ROLE}" = "web" ] && [ "${ALLOW_WEB_ROLE_QUARANTINE}" != "true" ]; then
      echo "  -> skip quarantine (web-role safety guard). Use --allow-web-role-quarantine to override."
      continue
    fi
    if [ "${APPLY}" = "true" ]; then
      NOMAD_ADDR="${NOMAD_ADDR}" nomad node eligibility -disable "${NODE_ID}" >/dev/null
      echo "  -> set ineligible"
      if [ "${DRAIN}" = "true" ]; then
        NOMAD_ADDR="${NOMAD_ADDR}" nomad node drain -enable -yes -deadline=1h "${NODE_ID}" >/dev/null
        echo "  -> drain enabled"
      fi
    fi
  else
    echo "OK: ${NODE_NAME} (${NODE_ID:0:8}) free=${FREE_MB}MB"
  fi
done
