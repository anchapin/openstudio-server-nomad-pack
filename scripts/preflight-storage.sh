#!/usr/bin/env bash
# preflight-storage.sh — Verify (and optionally create/rebind) CSI and host volumes
# before nomad-pack deploy.
#
# Usage:
#   ./scripts/preflight-storage.sh [OPTIONS]
#
# Options:
#   --var-file <path>        Override var-file (repeatable; last value wins per key)
#   --nomad-addr <url>       Nomad API address (default: $NOMAD_ADDR or http://127.0.0.1:4646)
#   --namespace <ns>         Nomad namespace (default: $NOMAD_NAMESPACE or default)
#   --create-missing-csi     Create CSI volume registrations that are absent from Nomad but
#                            needed by the pack.  Requires a healthy CSI plugin.
#   --rebind-stale           Deregister and re-register CSI volumes whose Nomad registration
#                            is stale (wrong plugin ID, no topology, or 0 healthy nodes).
#                            Implies --create-missing-csi.  Safe to run on every deploy.
#   --csi-plugin-id <id>     Default CSI plugin ID (override with env DB_CSI_PLUGIN_ID /
#                            REDIS_CSI_PLUGIN_ID per-volume).
#   --emit-topology-vars     After all checks pass, print shell-eval-safe lines:
#                              db_csi_topology_node_id=<uuid>
#                              redis_csi_topology_node_id=<uuid>
#                            Intended for capture by deploy-openstack.sh via eval.
#   --csi-topology-key <key> Exact topology segment key to look up when resolving a CSI
#                            volume's node UUID (default: "topology.hostpath.csi/node").
#                            Override per-volume via DB_CSI_TOPOLOGY_KEY /
#                            REDIS_CSI_TOPOLOGY_KEY env vars.  If the resolved value is not
#                            a 36-char hyphenated UUID a warning is printed and the pin is
#                            skipped rather than emitting an unsatisfiable constraint.
#
# Exit codes:
#   0  All required volumes are present, correctly registered, and healthy.
#   1  A required volume is missing or unhealthy AND --create-missing-csi / --rebind-stale
#      were not given (or creation/rebind failed).
#   2  Invalid arguments.
#
# Environment:
#   DB_CSI_PLUGIN_ID       CSI plugin ID for the MongoDB volume (overrides --csi-plugin-id)
#   REDIS_CSI_PLUGIN_ID    CSI plugin ID for the Redis volume (overrides --csi-plugin-id)
#   DB_CSI_TOPOLOGY_KEY    Exact topology segment key for MongoDB volume node resolution
#                          (overrides --csi-topology-key; default: topology.hostpath.csi/node)
#   REDIS_CSI_TOPOLOGY_KEY Exact topology segment key for Redis volume node resolution
#                          (overrides --csi-topology-key; default: topology.hostpath.csi/node)
#   DB_CSI_CAPACITY_MIN / DB_CSI_CAPACITY_MAX    Capacity range for auto-created MongoDB volume
#   REDIS_CSI_CAPACITY_MIN / REDIS_CSI_CAPACITY_MAX  Capacity range for auto-created Redis volume
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_VAR_FILE="${REPO_ROOT}/examples/advanced/openstack.hcl"
VAR_FILES=("${DEFAULT_VAR_FILE}")
VAR_FILES_SET=false
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}"
CREATE_MISSING_CSI=false
REBIND_STALE=false
EMIT_TOPOLOGY_VARS=false
CSI_PLUGIN_ID="${CSI_PLUGIN_ID:-nfs}"
DB_CSI_PLUGIN_ID="${DB_CSI_PLUGIN_ID:-}"
REDIS_CSI_PLUGIN_ID="${REDIS_CSI_PLUGIN_ID:-}"
CSI_TOPOLOGY_KEY="${CSI_TOPOLOGY_KEY:-topology.hostpath.csi/node}"
DB_CSI_TOPOLOGY_KEY="${DB_CSI_TOPOLOGY_KEY:-}"
REDIS_CSI_TOPOLOGY_KEY="${REDIS_CSI_TOPOLOGY_KEY:-}"
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
    --rebind-stale)
      REBIND_STALE=true
      CREATE_MISSING_CSI=true   # rebind implies create
      shift
      ;;
    --emit-topology-vars)
      EMIT_TOPOLOGY_VARS=true
      shift
      ;;
    --csi-plugin-id)
      CSI_PLUGIN_ID="$2"
      shift 2
      ;;
    --csi-topology-key)
      CSI_TOPOLOGY_KEY="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      cat >&2 <<'USAGE'
Usage: preflight-storage.sh [--var-file <path> ...] [--nomad-addr <url>] [--namespace <ns>]
                             [--create-missing-csi] [--rebind-stale] [--emit-topology-vars]
                             [--csi-plugin-id <id>] [--csi-topology-key <key>]
USAGE
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

  topology_key_for_volume() {
    local vol="$1"
    if [ "${vol}" = "${db_volume_source}" ]; then
      echo "${DB_CSI_TOPOLOGY_KEY:-${CSI_TOPOLOGY_KEY}}"
    elif [ "${vol}" = "${redis_volume_source}" ]; then
      echo "${REDIS_CSI_TOPOLOGY_KEY:-${CSI_TOPOLOGY_KEY}}"
    else
      echo "${CSI_TOPOLOGY_KEY}"
    fi
  }

  plugin_output="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad plugin status -type csi 2>/dev/null || true)"
  plugin_json="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad plugin status -type csi -json 2>/dev/null || true)"
  plugin_rows="$(echo "${plugin_output}" | awk 'NF && $0 !~ /Container Storage Interface/ && $0 !~ /^No CSI plugins/ && $0 !~ /^ID[[:space:]]+/')"
  if echo "${plugin_output}" | grep -q "No CSI plugins" || [ -z "${plugin_rows}" ]; then
    echo "✗ CSI storage requested but no CSI plugins are registered" >&2
    exit 1
  fi

  # Helper: resolve the Nomad node UUID that owns a CSI volume's topology.
  # Uses the exact topology segment key specified by _TOPO_KEY (env var).
  # Returns empty string if topology is absent or unresolvable.
  # Warns and returns empty string if resolved value does not look like a UUID.
  _csi_volume_topology_node_id() {
    local vol_json="$1"
    python3 - <<'PY'
import json, os, re, sys

raw = os.environ.get("_VOL_JSON", "")
topo_key = os.environ.get("_TOPO_KEY", "topology.hostpath.csi/node")

try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

UUID_RE = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    re.IGNORECASE
)

# Walk Topologies → Segments and look for the exact key
for topo in (data.get("Topologies") or []):
    segs = topo.get("Segments") or {}
    if topo_key not in segs:
        continue
    v = segs[topo_key]
    if not v:
        continue

    # Try to resolve to a Nomad node UUID via the API
    import urllib.request
    addr = os.environ.get("NOMAD_ADDR", "http://127.0.0.1:4646").rstrip("/")
    resolved = v
    try:
        req = urllib.request.Request(f"{addr}/v1/nodes")
        with urllib.request.urlopen(req, timeout=10) as r:
            nodes = json.load(r)
        for n in nodes:
            name = (n.get("Name") or "")
            nid  = (n.get("ID")   or "")
            if name == v or nid.startswith(v) or v.startswith(nid[:8]):
                resolved = nid
                break
    except Exception:
        pass

    # UUID validation: must be 36-char hyphenated hex
    if UUID_RE.match(resolved):
        print(resolved)
        sys.exit(0)
    else:
        print(
            f"warn: topology segment '{topo_key}' resolved to '{resolved}' which is not a "
            f"Nomad UUID — skipping node pin to avoid unsatisfiable constraint",
            file=sys.stderr
        )
        sys.exit(0)
PY
  }

  # Associates emit_vars state
  declare -A _topology_node_ids=()

  _create_csi_volume() {
    local vol="$1"
    local expected_plugin="$2"
    local cap_min="$3"
    local cap_max="$4"

    local tmp_spec
    tmp_spec="$(mktemp)"

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

    local create_output
    create_output="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume create "${tmp_spec}" 2>&1)" || {
      rm -f "${tmp_spec}"
      echo "✗ Failed creating CSI volume: ${vol} (plugin=${expected_plugin})" >&2
      echo "  ${create_output}" >&2
      return 1
    }
    rm -f "${tmp_spec}"
    if NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume status "${vol}" >/dev/null 2>&1; then
      echo "✓ Created CSI volume: ${vol} (plugin=${expected_plugin}, min=${cap_min}, max=${cap_max})"
      return 0
    else
      echo "✗ Failed creating CSI volume: ${vol} (plugin=${expected_plugin})" >&2
      return 1
    fi
  }

  # _is_stale_registration VOL_JSON EXPECTED_PLUGIN
  # Returns 0 (true) if the registration should be replaced; non-zero otherwise.
  _is_stale_registration() {
    local vol_json="$1"
    local expected_plugin="$2"
    EXPECTED_PLUGIN="${expected_plugin}" python3 - <<'PY'
import json, os, sys

raw = os.environ.get("_VOL_JSON", "")
try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)   # can't parse — treat as not stale

expected = os.environ.get("EXPECTED_PLUGIN", "")
actual   = (data.get("PluginID") or "").strip()

# Wrong plugin
if expected and actual and expected != actual:
    print(f"  stale: plugin mismatch (registered={actual}, expected={expected})", file=sys.stderr)
    sys.exit(0)

# No topology at all
topos = data.get("Topologies") or []
if not topos:
    print("  stale: volume has no topology segments", file=sys.stderr)
    sys.exit(0)

# ControllersHealthy == 0 → plugin node detached or volume not attached to any node
healthy = int(data.get("ControllersHealthy") or 0)
nodes_healthy = int(data.get("NodesHealthy") or 0)
if healthy == 0 and nodes_healthy == 0:
    print(f"  stale: ControllersHealthy={healthy}, NodesHealthy={nodes_healthy}", file=sys.stderr)
    sys.exit(0)

sys.exit(1)
PY
  }

  # _check_volume_claims VOL
  # Exits 1 with an actionable error if the volume has active allocation claims.
  # Safe to call before `nomad volume deregister`.
  _check_volume_claims() {
    local vol="$1"
    local status_json
    status_json="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" \
      nomad volume status -json "${vol}" 2>/dev/null || true)"

    local alloc_ids
    alloc_ids="$(echo "${status_json}" | python3 - <<'PY'
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
allocs = data.get("Allocations") or []
ids = [a.get("ID","") for a in allocs if a.get("ID")]
if ids:
    print("\n".join(ids))
PY
)"

    if [ -n "${alloc_ids}" ]; then
      echo "✗ CSI volume '${vol}' cannot be deregistered — active allocation claims:" >&2
      while IFS= read -r alloc_id; do
        echo "    alloc: ${alloc_id}" >&2
      done <<< "${alloc_ids}"
      echo "" >&2
      echo "  Stop the holding jobs first, then retry:" >&2
      echo "    bash scripts/pre-teardown.sh" >&2
      echo "  Then re-run preflight:" >&2
      echo "    bash scripts/preflight-storage.sh --rebind-stale [other flags]" >&2
      exit 1
    fi
  }

  for vol in "${required_csi[@]}"; do
    expected_plugin="$(plugin_for_volume "${vol}")"

    # ── Plugin existence check ────────────────────────────────────────────────
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

      # ── Plugin health check ─────────────────────────────────────────────────
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

    # ── Volume existence + stale-registration handling ────────────────────────
    vol_json=""
    vol_exists=false
    if NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume status "${vol}" >/dev/null 2>&1; then
      vol_exists=true
      vol_json="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume status -json "${vol}" 2>/dev/null || true)"
    fi

    if [ "${vol_exists}" = "true" ]; then
      actual_plugin="$(echo "${vol_json}" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("PluginID") or "").strip())' 2>/dev/null || true)"

      # Plugin mismatch — fail fast (or rebind if requested)
      if [ -n "${expected_plugin}" ] && [ -n "${actual_plugin}" ] && [ "${expected_plugin}" != "${actual_plugin}" ]; then
        if [ "${REBIND_STALE}" = "true" ]; then
          _check_volume_claims "${vol}"
          echo "⚠ CSI volume '${vol}' registered with wrong plugin '${actual_plugin}' (expected '${expected_plugin}') — deregistering for rebind" >&2
          NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume deregister "${vol}" 2>/dev/null || true
          vol_exists=false
          vol_json=""
        else
          echo "✗ CSI volume '${vol}' is bound to plugin '${actual_plugin}' but expected '${expected_plugin}'" >&2
          echo "  Run with --rebind-stale to automatically deregister and re-register the volume." >&2
          exit 1
        fi
      fi

      # Stale check — no topology or 0 healthy nodes (implies csi_hook will fail)
      if [ "${vol_exists}" = "true" ] && [ "${REBIND_STALE}" = "true" ]; then
        if _VOL_JSON="${vol_json}" NOMAD_ADDR="${NOMAD_ADDR}" _is_stale_registration "${vol_json}" "${expected_plugin}" 2>&1; then
          _check_volume_claims "${vol}"
          echo "⚠ CSI volume '${vol}' has a stale registration — deregistering for rebind" >&2
          NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume deregister "${vol}" 2>/dev/null || true
          vol_exists=false
          vol_json=""
        fi
      fi
    fi

    # ── Create if absent (covers first-run and post-deregister rebind) ────────
    if [ "${vol_exists}" = "false" ]; then
      if [ "${CREATE_MISSING_CSI}" = "true" ]; then
        if [ -z "${expected_plugin}" ]; then
          echo "✗ Missing CSI volume '${vol}' and no plugin ID configured. Set DB_CSI_PLUGIN_ID/REDIS_CSI_PLUGIN_ID or CSI_PLUGIN_ID." >&2
          exit 1
        fi

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

        _create_csi_volume "${vol}" "${expected_plugin}" "${cap_min}" "${cap_max}" || exit 1

        # Refresh vol_json after creation
        vol_json="$(NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad volume status -json "${vol}" 2>/dev/null || true)"
      else
        echo "✗ Missing CSI volume: ${vol}" >&2
        echo "  Run with --create-missing-csi to create it automatically." >&2
        exit 1
      fi
    else
      echo "✓ CSI volume present: ${vol}"
    fi

    # ── Topology node ID extraction ────────────────────────────────────────────
    if [ "${EMIT_TOPOLOGY_VARS}" = "true" ] && [ -n "${vol_json}" ]; then
      topo_key="$(topology_key_for_volume "${vol}")"
      topology_node_id=""
      topo_warn=""
      # Capture stdout (UUID or empty) and stderr (warning if non-UUID) in one pass
      topo_out="$(
        _VOL_JSON="${vol_json}" _TOPO_KEY="${topo_key}" \
          NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" \
          _csi_volume_topology_node_id "${vol_json}" 2>/dev/null || true
      )"
      topo_warn="$(
        _VOL_JSON="${vol_json}" _TOPO_KEY="${topo_key}" \
          NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" \
          _csi_volume_topology_node_id "${vol_json}" 2>&1 >/dev/null || true
      )"
      topology_node_id="${topo_out}"
      if [ -n "${topology_node_id}" ]; then
        _topology_node_ids["${vol}"]="${topology_node_id}"
        echo "✓ CSI topology node for '${vol}': ${topology_node_id} (key=${topo_key})"
      else
        [ -n "${topo_warn}" ] && echo "⚠ ${topo_warn}" >&2
        echo "  (no topology node ID resolvable for '${vol}' via key '${topo_key}' — constraint will not be emitted)"
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

# ── Emit topology node IDs for scheduler pinning ──────────────────────────────
# When --emit-topology-vars is set, print shell-eval-safe assignments so the
# caller (deploy-openstack.sh) can pin DB/Redis jobs to their CSI topology node.
if [ "${EMIT_TOPOLOGY_VARS}" = "true" ]; then
  if [ "${db_storage_type}" = "csi" ]; then
    db_topo_node="${_topology_node_ids[${db_volume_source}]:-}"
    echo "db_csi_topology_node_id=${db_topo_node}"
  fi
  if [ "${redis_storage_type}" = "csi" ]; then
    redis_topo_node="${_topology_node_ids[${redis_volume_source}]:-}"
    echo "redis_csi_topology_node_id=${redis_topo_node}"
  fi
fi
