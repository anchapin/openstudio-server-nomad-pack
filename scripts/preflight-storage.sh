#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_VAR_FILE="${REPO_ROOT}/examples/advanced/openstack.hcl"
VAR_FILES=("${DEFAULT_VAR_FILE}")
VAR_FILES_SET=false
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}"
CREATE_MISSING_CSI=false
CSI_PLUGIN_ID="${CSI_PLUGIN_ID:-nfs}"
DB_CSI_PLUGIN_ID="${DB_CSI_PLUGIN_ID:-}"
REDIS_CSI_PLUGIN_ID="${REDIS_CSI_PLUGIN_ID:-}"
DB_CSI_CAPACITY_MIN="${DB_CSI_CAPACITY_MIN:-10GiB}"
DB_CSI_CAPACITY_MAX="${DB_CSI_CAPACITY_MAX:-50GiB}"
REDIS_CSI_CAPACITY_MIN="${REDIS_CSI_CAPACITY_MIN:-1GiB}"
REDIS_CSI_CAPACITY_MAX="${REDIS_CSI_CAPACITY_MAX:-5GiB}"

while [ $# -gt 0 ]; do
  case "$1" in
    --var-file)
      if [ "${VAR_FILES_SET}" != "true" ]; then
        VAR_FILES=()
        VAR_FILES_SET=true
      fi
      VAR_FILES+=("$2")
      shift 2
      ;;
    --nomad-addr)
      NOMAD_ADDR="$2"
      shift 2
      ;;
    --namespace)
      NOMAD_NAMESPACE="$2"
      shift 2
      ;;
    --create-missing-csi)
      CREATE_MISSING_CSI=true
      shift
      ;;
    --csi-plugin-id)
      CSI_PLUGIN_ID="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      echo "Usage: $0 [--var-file <path> ...] [--nomad-addr <url>] [--namespace <ns>] [--create-missing-csi] [--csi-plugin-id <id>]" >&2
      exit 2
      ;;
  esac
done

for var_file in "${VAR_FILES[@]}"; do
  if [ ! -f "${var_file}" ]; then
    echo "✗ var-file not found: ${var_file}" >&2
    exit 1
  fi
done

_extract_var() {
  local key="$1"
  local default="${2:-}"
  local line value last_value=""
  for var_file in "${VAR_FILES[@]}"; do
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${var_file}" | tail -n 1 || true)"
    if [ -z "${line}" ]; then
      continue
    fi
    value="${line#*=}"
    value="$(echo "${value}" | sed -E 's/[[:space:]]*#.*$//' | xargs)"
    value="${value%\"}"
    value="${value#\"}"
    last_value="${value}"
  done
  if [ -z "${last_value}" ]; then
    echo "${default}"
    return
  fi
  echo "${last_value}"
}

db_storage_type="$(_extract_var db_storage_type host_volume)"
db_volume_source="$(_extract_var db_volume_source openstudio-mongodb)"
redis_storage_type="$(_extract_var redis_storage_type host_volume)"
redis_volume_source="$(_extract_var redis_volume_source openstudio-redis)"
db_csi_plugin_id="${DB_CSI_PLUGIN_ID:-${CSI_PLUGIN_ID}}"
redis_csi_plugin_id="${REDIS_CSI_PLUGIN_ID:-${CSI_PLUGIN_ID}}"
nfs_shared_volume_enabled="$(_extract_var nfs_shared_volume_enabled false)"
nfs_volume_type="$(_extract_var nfs_volume_type host)"
nfs_volume_source="$(_extract_var nfs_volume_source openstudio-nfs)"

echo "==> Storage preflight"
echo "  nomad_addr=${NOMAD_ADDR}"
echo "  namespace=${NOMAD_NAMESPACE}"
echo "  var_files:"
for var_file in "${VAR_FILES[@]}"; do
  echo "    - ${var_file}"
done

curl -sf "${NOMAD_ADDR}/v1/status/leader" >/dev/null

required_csi=()
required_host=()

if [ "${db_storage_type}" = "csi" ]; then
  required_csi+=("${db_volume_source}")
elif [ "${db_storage_type}" = "host_volume" ]; then
  required_host+=("${db_volume_source}")
fi

if [ "${redis_storage_type}" = "csi" ]; then
  required_csi+=("${redis_volume_source}")
elif [ "${redis_storage_type}" = "host_volume" ]; then
  required_host+=("${redis_volume_source}")
fi

if [ "${nfs_shared_volume_enabled}" = "true" ] && [ "${nfs_volume_type}" = "host" ]; then
  required_host+=("${nfs_volume_source}")
fi

if [ ${#required_csi[@]} -gt 0 ]; then
  plugin_for_volume() {
    local vol="$1"
    if [ "${vol}" = "${db_volume_source}" ]; then
      echo "${db_csi_plugin_id}"
    elif [ "${vol}" = "${redis_volume_source}" ]; then
      echo "${redis_csi_plugin_id}"
    else
      echo "${CSI_PLUGIN_ID}"
    fi
  }

  plugin_output="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad plugin status -type csi 2>/dev/null || true)"
  plugin_json="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad plugin status -type csi -json 2>/dev/null || true)"
  plugin_rows="$(echo "${plugin_output}" | awk 'NF && $0 !~ /Container Storage Interface/ && $0 !~ /^No CSI plugins/ && $0 !~ /^ID[[:space:]]+/')"
  if echo "${plugin_output}" | grep -q "No CSI plugins" || [ -z "${plugin_rows}" ]; then
    echo "✗ CSI storage requested but no CSI plugins are registered" >&2
    exit 1
  fi

  for vol in "${required_csi[@]}"; do
    expected_plugin="$(plugin_for_volume "${vol}")"
    if [ -n "${expected_plugin}" ]; then
      if ! PLUGIN_ID="${expected_plugin}" PLUGIN_JSON="${plugin_json}" python3 - <<'PY'
import json, os, sys
pid = os.environ.get("PLUGIN_ID", "")
raw = os.environ.get("PLUGIN_JSON", "")
if not raw.strip():
    raise SystemExit(1)
plugins = json.loads(raw)
raise SystemExit(0 if any((p.get("ID") or "") == pid for p in plugins) else 1)
PY
      then
        echo "✗ Required CSI plugin ID '${expected_plugin}' not found for volume '${vol}'" >&2
        exit 1
      fi
    fi
    if [ -n "${expected_plugin}" ]; then
      if ! PLUGIN_ID="${expected_plugin}" PLUGIN_JSON="${plugin_json}" python3 - <<'PY'
import json, os, sys
pid = os.environ.get("PLUGIN_ID", "")
raw = os.environ.get("PLUGIN_JSON", "")
if not raw.strip():
    raise SystemExit(1)
plugins = json.loads(raw)
for p in plugins:
    if (p.get("ID") or "") != pid:
        continue
    healthy = int(p.get("ControllersHealthy") or 0)
    expected = int(p.get("ControllersExpected") or 0)
    if healthy >= 1 and expected >= 1:
        raise SystemExit(0)
raise SystemExit(1)
PY
      then
        echo "✗ CSI plugin '${expected_plugin}' is present but has no healthy controller yet" >&2
        exit 1
      fi
    fi

    if NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume status "${vol}" >/dev/null 2>&1; then
      actual_plugin="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume status -json "${vol}" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("PluginID") or "").strip())' 2>/dev/null || true)"
      if [ -n "${expected_plugin}" ] && [ -n "${actual_plugin}" ] && [ "${expected_plugin}" != "${actual_plugin}" ]; then
        echo "✗ CSI volume '${vol}' is bound to plugin '${actual_plugin}' but expected '${expected_plugin}'" >&2
        exit 1
      fi
      echo "✓ CSI volume present: ${vol}"
    else
      if [ "${CREATE_MISSING_CSI}" = "true" ]; then
        if [ -z "${expected_plugin}" ]; then
          echo "✗ Missing CSI volume '${vol}' and no plugin ID configured. Set DB_CSI_PLUGIN_ID/REDIS_CSI_PLUGIN_ID or CSI_PLUGIN_ID." >&2
          exit 1
        fi
        tmp_spec="$(mktemp)"

        if [ "${vol}" = "${db_volume_source}" ]; then
          cap_min="${DB_CSI_CAPACITY_MIN}"
          cap_max="${DB_CSI_CAPACITY_MAX}"
        elif [ "${vol}" = "${redis_volume_source}" ]; then
          cap_min="${REDIS_CSI_CAPACITY_MIN}"
          cap_max="${REDIS_CSI_CAPACITY_MAX}"
        else
          cap_min="${DB_CSI_CAPACITY_MIN}"
          cap_max="${DB_CSI_CAPACITY_MAX}"
        fi

        cat > "${tmp_spec}" <<EOF
id        = "${vol}"
name      = "${vol}"
type      = "csi"
plugin_id = "${expected_plugin}"

capacity_min = "${cap_min}"
capacity_max = "${cap_max}"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
EOF

        create_output="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume create "${tmp_spec}" 2>&1)" || {
          rm -f "${tmp_spec}"
          echo "✗ Failed creating CSI volume: ${vol} (plugin=${expected_plugin})" >&2
          echo "  ${create_output}" >&2
          exit 1
        }
        if NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume status "${vol}" >/dev/null 2>&1; then
          rm -f "${tmp_spec}"
          echo "✓ Created CSI volume: ${vol} (plugin=${expected_plugin}, min=${cap_min}, max=${cap_max})"
        else
          rm -f "${tmp_spec}"
          echo "✗ Failed creating CSI volume: ${vol} (plugin=${expected_plugin})" >&2
          exit 1
        fi
      else
        echo "✗ Missing CSI volume: ${vol}" >&2
        exit 1
      fi
    fi
  done
fi

if [ ${#required_host[@]} -gt 0 ]; then
  names_csv="$(printf "%s\n" "${required_host[@]}" | awk '!seen[$0]++' | paste -sd, -)"
  NOMAD_ADDR="${NOMAD_ADDR}" NAMES_CSV="${names_csv}" python3 - <<'PY'
import json
import os
import sys
import urllib.request

addr = os.environ["NOMAD_ADDR"].rstrip("/")
required = [x for x in os.environ.get("NAMES_CSV", "").split(",") if x]

req = urllib.request.Request(f"{addr}/v1/nodes")
with urllib.request.urlopen(req, timeout=10) as r:
    nodes = json.load(r)

eligible = [n for n in nodes if n.get("Status") == "ready" and n.get("SchedulingEligibility") == "eligible"]
counts = {name: 0 for name in required}

for n in eligible:
    nid = n.get("ID")
    if not nid:
      continue
    with urllib.request.urlopen(f"{addr}/v1/node/{nid}", timeout=10) as r:
        detail = json.load(r)
    host_vols = set((detail.get("HostVolumes") or {}).keys())
    for name in required:
        if name in host_vols:
            counts[name] += 1

for name in required:
    if counts[name] <= 0:
        print(f"✗ Host volume '{name}' not advertised by any ready/eligible node", file=sys.stderr)
        sys.exit(1)
    print(f"✓ Host volume '{name}' advertised by {counts[name]} ready/eligible node(s)")
PY
fi

echo "✓ Storage preflight passed"
