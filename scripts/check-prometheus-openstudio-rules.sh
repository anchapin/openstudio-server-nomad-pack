#!/usr/bin/env bash
set -euo pipefail

PROM_URL="${PROMETHEUS_URL:-http://localhost:9090}"

usage() {
  cat <<'EOF'
Usage: scripts/check-prometheus-openstudio-rules.sh [--prometheus-url <url>]

Verifies that required OpenStudio alert rules are loaded in Prometheus.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prometheus-url)
      PROM_URL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

tmp_json="$(mktemp)"
trap 'rm -f "$tmp_json"' EXIT
curl -sf "${PROM_URL}/api/v1/rules" > "${tmp_json}"

required_rules=(
  TraefikRouterMissing
  TraefikIngressHighErrorRate
  TraefikBackendUnhealthy
  OpenStudioQueueSweeperFailedAllocs
  OpenStudioQueueSweeperPlacementBlocked
)

missing=()
for rule in "${required_rules[@]}"; do
  if ! python3 - "${tmp_json}" "${rule}" <<'PY'
import json,sys
path,rule=sys.argv[1],sys.argv[2]
data=json.load(open(path,"r",encoding="utf-8"))
groups=((data.get("data") or {}).get("groups") or [])
for g in groups:
    for r in (g.get("rules") or []):
        if (r.get("name") or "") == rule:
            raise SystemExit(0)
raise SystemExit(1)
PY
  then
    missing+=("${rule}")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "Missing required Prometheus rules at ${PROM_URL}:"
  printf '  - %s\n' "${missing[@]}"
  exit 1
fi

echo "Required OpenStudio alert rules are loaded at ${PROM_URL}."
