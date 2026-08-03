#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DEFAULT_VAR_FILE="${OS_VAR_FILE:-${REPO_ROOT}/examples/advanced/openstack.hcl}"
VAR_FILES=("${DEFAULT_VAR_FILE}")
VAR_FILES_SET=false
JOB_NAME="${OS_JOB_NAME:-openstudio-server}"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}"
CSI_PLUGIN_ID="${CSI_PLUGIN_ID:-}"
DB_CSI_PLUGIN_ID="${DB_CSI_PLUGIN_ID:-}"
REDIS_CSI_PLUGIN_ID="${REDIS_CSI_PLUGIN_ID:-}"
DB_CSI_CAPACITY_MIN="${DB_CSI_CAPACITY_MIN:-10GiB}"
DB_CSI_CAPACITY_MAX="${DB_CSI_CAPACITY_MAX:-50GiB}"
REDIS_CSI_CAPACITY_MIN="${REDIS_CSI_CAPACITY_MIN:-1GiB}"
REDIS_CSI_CAPACITY_MAX="${REDIS_CSI_CAPACITY_MAX:-5GiB}"
REDIS_NODE_CLASS_OVERRIDE="${OS_REDIS_NODE_CLASS:-}"
WIPE_NFS=true
BOOTSTRAP_WORKER_MAX_REPLICAS="${OS_BOOTSTRAP_WORKER_MAX_REPLICAS:-200}"
BOOTSTRAP_AUTOSCALER_COOLDOWN="${OS_BOOTSTRAP_AUTOSCALER_COOLDOWN:-2m}"
PREPULL_WAIT_TIMEOUT_SECONDS="${OS_PREPULL_WAIT_TIMEOUT_SECONDS:-900}"
PREPULL_MIN_READY_PERCENT="${OS_PREPULL_MIN_READY_PERCENT:-10}"
PREPULL_REQUIRE_ALL="${OS_PREPULL_REQUIRE_ALL:-false}"
PREPULL_RECONCILE_INTERVAL_SECONDS="${OS_PREPULL_RECONCILE_INTERVAL_SECONDS:-30}"
DISABLE_VECTOR_COLLECTION="${OS_DISABLE_VECTOR_COLLECTION:-false}"
CSI_WIPE_MAX_ATTEMPTS="${OS_CSI_WIPE_MAX_ATTEMPTS:-3}"
CSI_WIPE_JOB_IMAGE="${OS_CSI_WIPE_JOB_IMAGE:-}"
STATEFUL_CSI_NODE_ROLE="${OS_STATEFUL_CSI_NODE_ROLE:-web}"
CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS="${OS_CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS:-6}"
AUTO_DEPLOY_ROLE_CSI_PLUGINS="${OS_AUTO_DEPLOY_ROLE_CSI_PLUGINS:-true}"
CSI_PLUGIN_READY_TIMEOUT_SECONDS="${OS_CSI_PLUGIN_READY_TIMEOUT_SECONDS:-180}"

PREPULL_READY_NODE_IDS=""
PREPULL_NOT_READY_NODE_IDS=""
PREPULL_JOB_ID=""
PREPULL_TARGET_NODE_IDS=""
PREPULL_TOTAL_TARGET_COUNT=0
PREPULL_EXCLUSION_RECONCILER_PID=""
ROLE_CSI_DEPLOY_SCRIPT="${REPO_ROOT}/scripts/deploy-hostpath-csi-role-plugins.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Performs a full fresh redeploy on Nomad/OpenStack:
1) Stops jobs (teardown-safe)
2) Destroys pack jobs via nomad-pack
3) Deletes and recreates DB/Redis CSI volumes
4) Wipes shared NFS data (when enabled)
5) Re-runs storage preflight
6) Deploys pack via nomad-pack run

Options:
  --var-file <path>      Var-file (repeatable; last wins, defaults from ${DEFAULT_VAR_FILE})
  --job-name <name>      Pack job name (default: ${JOB_NAME})
  --nomad-addr <url>     Nomad API (default: ${NOMAD_ADDR})
  --namespace <ns>       Nomad namespace (default: ${NOMAD_NAMESPACE})
  --csi-plugin-id <id>   CSI plugin ID for volume create (auto-detected by default)
  --redis-node-class <class>  Override redis_node_class for this deploy only
  --disable-vector-collection Temporarily disable vector sidecars for this redeploy
  --skip-nfs-wipe        Skip shared NFS wipe step
  --no-auto-csi-plugin-deploy  Disable auto-deploy of role-scoped CSI plugins when missing
  -h, --help             Show help
EOF
}

count_ready_eligible_nodes_with_class() {
  local desired_class="$1"
  if [[ -z "${desired_class}" ]]; then
    echo "0"
    return 0
  fi
  NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" DESIRED_CLASS="${desired_class}" python3 - <<'PY'
import json, os, urllib.request

addr = os.environ["NOMAD_ADDR"].rstrip("/")
ns = os.environ.get("NOMAD_NAMESPACE", "default")
desired = os.environ["DESIRED_CLASS"]
req = urllib.request.Request(f"{addr}/v1/nodes?namespace={ns}")
with urllib.request.urlopen(req, timeout=20) as r:
    nodes = json.load(r)
count = 0
for n in nodes:
    if n.get("Status") != "ready" or n.get("SchedulingEligibility") != "eligible":
        continue
    if (n.get("NodeClass") or "") == desired:
        count += 1
print(count)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --var-file)
      if [[ "${VAR_FILES_SET}" != "true" ]]; then
        VAR_FILES=()
        VAR_FILES_SET=true
      fi
      VAR_FILES+=("$2")
      shift 2
      ;;
    --job-name) JOB_NAME="$2"; shift 2 ;;
    --nomad-addr) NOMAD_ADDR="$2"; shift 2 ;;
    --namespace) NOMAD_NAMESPACE="$2"; shift 2 ;;
    --csi-plugin-id) CSI_PLUGIN_ID="$2"; shift 2 ;;
    --redis-node-class) REDIS_NODE_CLASS_OVERRIDE="$2"; shift 2 ;;
    --disable-vector-collection) DISABLE_VECTOR_COLLECTION=true; shift ;;
    --skip-nfs-wipe) WIPE_NFS=false; shift ;;
    --no-auto-csi-plugin-deploy) AUTO_DEPLOY_ROLE_CSI_PLUGINS=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

for var_file in "${VAR_FILES[@]}"; do
  if [[ ! -f "${var_file}" ]]; then
    echo "✗ var-file not found: ${var_file}" >&2
    exit 1
  fi
done

VAR_FILE_ARGS=()
for var_file in "${VAR_FILES[@]}"; do
  VAR_FILE_ARGS+=(--var-file "${var_file}")
done

export NOMAD_ADDR NOMAD_NAMESPACE

_extract_var() {
  local key="$1"
  local default="${2:-}"
  local line value last_value=""
  for var_file in "${VAR_FILES[@]}"; do
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${var_file}" | tail -n 1 || true)"
    if [[ -z "${line}" ]]; then
      continue
    fi
    value="${line#*=}"
    value="$(echo "${value}" | sed -E 's/[[:space:]]*#.*$//' | xargs)"
    value="${value%\"}"
    value="${value#\"}"
    last_value="${value}"
  done
  if [[ -z "${last_value}" ]]; then
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
nfs_volume_type="$(_extract_var nfs_volume_type host_volume)"
nfs_volume_source="$(_extract_var nfs_volume_source openstudio-nfs)"
nfs_volume_mount_path="$(_extract_var nfs_volume_mount_path /mnt/openstudio)"
enable_image_prepull="$(_extract_var enable_image_prepull false)"
worker_instance_type="$(_extract_var worker_instance_type "")"
worker_runtime_image="$(_extract_var worker_runtime_image "")"
worker_count="$(_extract_var worker_count 1)"
worker_max_replicas="$(_extract_var worker_max_replicas 10)"
worker_autoscaling_scale_up_cooldown="$(_extract_var worker_autoscaling_scale_up_cooldown 10m)"
prometheus_enabled="$(_extract_var prometheus_enabled false)"
db_image="$(_extract_var db_image mongo:4.2)"
redis_image="$(_extract_var redis_image redis:6.2-alpine)"
redis_node_class="$(_extract_var redis_node_class "")"
if [[ -n "${REDIS_NODE_CLASS_OVERRIDE}" ]]; then
  redis_node_class="${REDIS_NODE_CLASS_OVERRIDE}"
fi
redis_config_maxclients="$(_extract_var redis_config_maxclients 50000)"
redis_config_tcp_backlog="$(_extract_var redis_config_tcp_backlog 511)"
redis_config_timeout_seconds="$(_extract_var redis_config_timeout_seconds 0)"
redis_config_maxmemory="$(_extract_var redis_config_maxmemory 22000000000)"
redis_config_maxmemory_policy="$(_extract_var redis_config_maxmemory_policy noeviction)"
redis_config_appendfsync="$(_extract_var redis_config_appendfsync everysec)"
redis_config_save="$(_extract_var redis_config_save "")"

# Default to role-scoped hostpath plugin IDs when CSI storage is used and no
# explicit plugin ID is provided. This avoids selecting a generic/worker plugin
# that can pin DB/Redis volumes to worker nodes.
if [[ "${db_storage_type}" == "csi" && -z "${db_csi_plugin_id}" ]]; then
  db_csi_plugin_id="hostpath-${STATEFUL_CSI_NODE_ROLE}-plugin0"
fi
if [[ "${redis_storage_type}" == "csi" && -z "${redis_csi_plugin_id}" ]]; then
  redis_csi_plugin_id="hostpath-${STATEFUL_CSI_NODE_ROLE}-plugin0"
fi

echo "==> Fresh redeploy configuration"
echo "  nomad_addr=${NOMAD_ADDR}"
echo "  namespace=${NOMAD_NAMESPACE}"
echo "  var_files:"
for var_file in "${VAR_FILES[@]}"; do
  echo "    - ${var_file}"
done
echo "  job_name=${JOB_NAME}"
echo "  redis_node_class=${redis_node_class:-<unset>}"
echo "  redis_config: maxclients=${redis_config_maxclients} tcp_backlog=${redis_config_tcp_backlog} timeout=${redis_config_timeout_seconds}s maxmemory=${redis_config_maxmemory} policy=${redis_config_maxmemory_policy} appendfsync=${redis_config_appendfsync} save='${redis_config_save}'"
echo "  disable_vector_collection=${DISABLE_VECTOR_COLLECTION}"
if [[ "${db_storage_type}" == "csi" || "${redis_storage_type}" == "csi" ]]; then
  echo "  csi_plugins: db=${db_csi_plugin_id:-<auto>} redis=${redis_csi_plugin_id:-<auto>}"
fi

curl -sf "${NOMAD_ADDR}/v1/status/leader" >/dev/null
if [[ -n "${redis_node_class}" ]]; then
  redis_class_ready_count="$(count_ready_eligible_nodes_with_class "${redis_node_class}")"
  if [[ "${redis_class_ready_count}" == "0" ]]; then
    echo "✗ redis_node_class='${redis_node_class}' but no ready/eligible nodes advertise that Nomad node class." >&2
    echo "  Set redis_node_class in a provided var-file to an existing class, or pass --redis-node-class <class>." >&2
    exit 1
  fi
  echo "  redis_node_class readiness: ${redis_class_ready_count} node(s) ready/eligible"
fi

echo ""
echo "==> Stopping jobs in teardown-safe order"
"${REPO_ROOT}/scripts/pre-teardown.sh" --namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}" || true

echo ""
echo "==> Destroying pack jobs"
if nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-web" >/dev/null 2>&1 || \
   nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-worker" >/dev/null 2>&1 || \
   nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-db" >/dev/null 2>&1 || \
   nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-redis" >/dev/null 2>&1 || \
   nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-rserve" >/dev/null 2>&1; then
  nomad-pack destroy "${VAR_FILE_ARGS[@]}" --name "${JOB_NAME}" "${REPO_ROOT}" || true
else
  echo "  - no deployed ${JOB_NAME} pack jobs found; skipping nomad-pack destroy"
fi

detect_csi_plugin_id_for_volume() {
  local vol="$1"
  local configured=""
  local plugin=""

  if [[ "${vol}" == "${db_volume_source}" ]]; then
    configured="${db_csi_plugin_id}"
  elif [[ "${vol}" == "${redis_volume_source}" ]]; then
    configured="${redis_csi_plugin_id}"
  fi
  if [[ -z "${configured}" ]]; then
    configured="${CSI_PLUGIN_ID}"
  fi
  if [[ -n "${configured}" ]]; then
    echo "${configured}"
    return 0
  fi

  if nomad volume status "${vol}" >/dev/null 2>&1; then
    plugin="$(nomad volume status -json "${vol}" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("PluginID") or "").strip())' 2>/dev/null || true)"
    if [[ -n "${plugin}" ]]; then
      echo "${plugin}"
      return 0
    fi
  fi

  plugin="$(nomad plugin status -type csi -json | python3 -c 'import json,sys; p=json.load(sys.stdin); print((p[0].get("ID") if p else "") or "")' 2>/dev/null || true)"
  if [[ -n "${plugin}" ]]; then
    echo "${plugin}"
    return 0
  fi

  return 1
}

csi_plugin_ready() {
  local plugin_id="$1"
  if [[ -z "${plugin_id}" ]]; then
    return 1
  fi
  NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad plugin status -type csi -json 2>/dev/null | \
    PLUGIN_ID="${plugin_id}" python3 -c 'import json,sys,os
pid=os.environ.get("PLUGIN_ID","")
try:
    plugins=json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for p in plugins:
    if (p.get("ID") or "") != pid:
        continue
    healthy = int(p.get("ControllersHealthy") or 0)
    expected = int(p.get("ControllersExpected") or 0)
    # Require at least one healthy controller before volume create.
    if healthy >= 1 and expected >= 1:
        raise SystemExit(0)
raise SystemExit(1)
'
}

wait_for_csi_plugin_ready() {
  local plugin_id="$1"
  local deadline now
  deadline=$(( $(date +%s) + CSI_PLUGIN_READY_TIMEOUT_SECONDS ))
  while true; do
    if csi_plugin_ready "${plugin_id}"; then
      return 0
    fi
    now="$(date +%s)"
    if (( now > deadline )); then
      return 1
    fi
    sleep 3
  done
}

ensure_role_scoped_csi_plugins() {
  local required_plugins=()
  local missing_plugins=()
  local plugin_id

  if [[ "${db_storage_type}" == "csi" && -n "${db_csi_plugin_id}" ]]; then
    required_plugins+=("${db_csi_plugin_id}")
  fi
  if [[ "${redis_storage_type}" == "csi" && -n "${redis_csi_plugin_id}" ]]; then
    required_plugins+=("${redis_csi_plugin_id}")
  fi
  if [[ ${#required_plugins[@]} -eq 0 ]]; then
    return 0
  fi

  mapfile -t required_plugins < <(printf "%s\n" "${required_plugins[@]}" | awk 'NF && !seen[$0]++')
  for plugin_id in "${required_plugins[@]}"; do
    if ! csi_plugin_ready "${plugin_id}"; then
      missing_plugins+=("${plugin_id}")
    fi
  done

  if [[ ${#missing_plugins[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ "${AUTO_DEPLOY_ROLE_CSI_PLUGINS}" != "true" ]]; then
    echo "✗ Missing required CSI plugin ID(s): ${missing_plugins[*]} (auto-deploy disabled)." >&2
    return 1
  fi

  if [[ ! -f "${ROLE_CSI_DEPLOY_SCRIPT}" ]]; then
    echo "✗ Missing required CSI plugin ID(s): ${missing_plugins[*]} and deploy helper was not found: ${ROLE_CSI_DEPLOY_SCRIPT}" >&2
    return 1
  fi

  echo "==> Missing role-scoped CSI plugin(s): ${missing_plugins[*]}"
  echo "==> Deploying role-scoped CSI plugins via ${ROLE_CSI_DEPLOY_SCRIPT}"
  NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" bash "${ROLE_CSI_DEPLOY_SCRIPT}"

  for plugin_id in "${missing_plugins[@]}"; do
    if ! wait_for_csi_plugin_ready "${plugin_id}"; then
      echo "✗ CSI plugin '${plugin_id}' is still missing after role-scoped deploy." >&2
      NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad plugin status -type csi || true
      return 1
    fi
  done
  echo "✓ Required role-scoped CSI plugins are available"
}

delete_csi_volume_if_present() {
  local vol="$1"
  if nomad volume status "${vol}" >/dev/null 2>&1; then
    echo "  - deleting CSI volume: ${vol}"
    for _ in $(seq 1 20); do
      if nomad volume delete "${vol}" >/dev/null 2>&1; then
        echo "    deleted ${vol}"
        # Wait for the CSI backend to finish its cleanup before returning.
        # Without this, an immediate create races the backend and gets AlreadyExists.
        for _ in $(seq 1 15); do
          if ! nomad volume status "${vol}" >/dev/null 2>&1; then
            return 0
          fi
          sleep 2
        done
        echo "  - warning: volume '${vol}' still visible in Nomad after delete; proceeding anyway"
        return 0
      fi
      sleep 2
    done
    echo "✗ Failed deleting CSI volume '${vol}' after retries (still in use?)" >&2
    return 1
  else
    echo "  - CSI volume not present: ${vol}"
  fi
}

create_csi_volume() {
  local vol="$1"
  local cap_min="$2"
  local cap_max="$3"
  local plugin_id="$4"
  local desired_role="${5:-}"
  local existing_external_id="${6:-}"
  local attempt spec topo_node topo_role
  local saw_already_exists=false
  local backend_name="${vol}"

  for attempt in $(seq 1 "${CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS}"); do
    spec="$(mktemp)"
    cat > "${spec}" <<EOF
id        = "${vol}"
name      = "${backend_name}"
type      = "csi"
plugin_id = "${plugin_id}"

capacity_min = "${cap_min}"
capacity_max = "${cap_max}"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
EOF
    local create_out create_rc
    create_out="$(nomad volume create "${spec}" 2>&1)" && create_rc=0 || create_rc=$?
    rm -f "${spec}"

    if [[ "${create_rc}" -ne 0 ]]; then
      # The CSI backend may still be finishing its previous delete. Retry on AlreadyExists.
      if echo "${create_out}" | grep -qi "alreadyexists\|already exists"; then
        saw_already_exists=true
        if echo "${create_out}" | grep -qi "same name\|different size\|incompatible with these parameters"; then
          backend_name="${vol}-recreate-$(date +%s)-${attempt}"
          echo "  - CSI backend name conflict for '${vol}'; retrying with unique backend name '${backend_name}' (Nomad volume ID stays '${vol}')"
          sleep 2
          continue
        fi
        echo "  - CSI volume '${vol}' still exists in backend (attempt ${attempt}/${CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS}); waiting for delete to propagate..."
        sleep 5
        continue
      fi
      echo "✗ Failed to create CSI volume '${vol}': ${create_out}" >&2
      return 1
    fi

    if [[ -z "${desired_role}" ]]; then
      echo "  - created CSI volume: ${vol} (plugin=${plugin_id})"
      return 0
    fi

    topo_node="$(csi_volume_topology_nodes "${vol}" | head -n 1 || true)"
    if [[ -z "${topo_node}" ]]; then
      echo "  - created CSI volume: ${vol} (plugin=${plugin_id}); topology not yet reported (attempt ${attempt})"
      sleep 2
      continue
    fi

    topo_role="$(
      NOMAD_ADDR="${NOMAD_ADDR}" nomad node status -json "${topo_node}" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print(((d.get("Meta") or {}).get("node_role") or "").strip())
' || true
    )"

    if [[ "${topo_role}" == "${desired_role}" ]]; then
      echo "  - created CSI volume: ${vol} (plugin=${plugin_id}, topology node_role=${topo_role})"
      return 0
    fi

    echo "  - CSI volume ${vol} pinned to node ${topo_node} (node_role=${topo_role:-unknown}), expected node_role=${desired_role}; recreating (attempt ${attempt}/${CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS})"
    nomad volume delete "${vol}" >/dev/null 2>&1 || true
    # Wait for the CSI backend to finish deleting before re-creating
    for _ in $(seq 1 15); do
      if ! nomad volume status "${vol}" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    sleep 2
  done

  if [[ "${saw_already_exists}" == "true" ]]; then
    local register_external_id="${existing_external_id:-${vol}}"
    echo "  - attempting backend recovery by registering existing CSI volume '${vol}' (external_id=${register_external_id})"
    if register_existing_csi_volume "${vol}" "${plugin_id}" "${register_external_id}"; then
      if [[ -n "${desired_role}" ]]; then
        topo_node="$(csi_volume_topology_nodes "${vol}" | head -n 1 || true)"
        if [[ -n "${topo_node}" ]]; then
          topo_role="$(
            NOMAD_ADDR="${NOMAD_ADDR}" nomad node status -json "${topo_node}" 2>/dev/null | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print(((d.get("Meta") or {}).get("node_role") or "").strip())
' || true
          )"
          if [[ -n "${topo_role}" && "${topo_role}" != "${desired_role}" ]]; then
            echo "✗ Recovered volume '${vol}' is pinned to node_role='${topo_role}', expected '${desired_role}'." >&2
            return 1
          fi
        fi
      fi
      return 0
    fi
  fi

  echo "✗ Failed to create CSI volume '${vol}' with topology node_role='${desired_role}' after ${CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS} attempts" >&2
  return 1
}

wipe_csi_volume_data() {
  local vol="$1"
  local preferred_image="${2:-}"
  local attempt wipe_job job_spec state alloc_id
  local wipe_image
  wipe_image="${preferred_image:-${CSI_WIPE_JOB_IMAGE}}"
  if [[ -z "${wipe_image}" ]]; then
    # busybox:1.36 is pre-cached on every node (used by wait-for-deps tasks).
    # Avoids Docker Hub rate-limit errors (429) that occur when pulling alpine
    # on nodes that don't have it cached.
    wipe_image="busybox:1.36"
  fi
  attempt=1
  while (( attempt <= CSI_WIPE_MAX_ATTEMPTS )); do
    wipe_job="${JOB_NAME}-${vol}-wipe-$(date +%s)-a${attempt}"
    job_spec="$(mktemp)"

    cat > "${job_spec}" <<EOF
job "${wipe_job}" {
  region      = "global"
  datacenters = ["dc1"]
  namespace   = "${NOMAD_NAMESPACE}"
  type        = "batch"

  group "wipe" {
    restart {
      attempts = 0
      mode     = "fail"
    }

    volume "target" {
      type            = "csi"
      source          = "${vol}"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    task "wipe" {
      # Use exec driver (no Docker image required) to avoid Docker Hub rate
      # limits (429) on nodes that don't have a cached image. exec is enabled
      # on all Ubuntu 22.04 nodes in this cluster.
      driver = "exec"
      config {
        command = "/bin/sh"
        args = [
          "-ec",
          "rm -rf /data/* /data/.[!.]* /data/..?* || true; chmod 777 /data"
        ]
      }
      volume_mount {
        volume      = "target"
        destination = "/data"
        read_only   = false
      }
      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
EOF

    nomad job run "${job_spec}" >/dev/null
    rm -f "${job_spec}"

    for _ in $(seq 1 120); do
      state="$(
        nomad job allocs -json "${wipe_job}" 2>/dev/null | python3 -c '
import json,sys
j=json.load(sys.stdin)
if not j:
    print("wait")
    sys.exit(0)
statuses=[(a.get("ClientStatus") or "").lower() for a in j]
if any(s == "complete" for s in statuses):
    print("ok")
    sys.exit(0)
if statuses and all(s in ("failed","lost") for s in statuses):
    print("fail")
    sys.exit(0)
print("wait")
' 2>/dev/null || echo "wait"
      )"

      case "${state}" in
        ok)
          nomad job stop -purge "${wipe_job}" >/dev/null 2>&1 || true
          echo "  - wiped CSI data in volume '${vol}'"
          return 0
          ;;
        fail)
          echo "  - CSI wipe attempt ${attempt}/${CSI_WIPE_MAX_ATTEMPTS} failed for '${vol}' (${wipe_job})" >&2
          alloc_id="$(nomad job allocs -json "${wipe_job}" 2>/dev/null | python3 -c 'import json,sys;j=json.load(sys.stdin); print((j[0].get("ID") if j else ""))' 2>/dev/null || true)"
          if [[ -n "${alloc_id}" ]]; then
            nomad alloc status "${alloc_id}" || true
            nomad alloc logs -stderr "${alloc_id}" || true
            nomad alloc logs "${alloc_id}" || true
          fi
          nomad job stop -purge "${wipe_job}" >/dev/null 2>&1 || true
          break
          ;;
        *)
          ;;
      esac
      sleep 2
    done

    if [[ "${state}" == "wait" ]]; then
      echo "  - CSI wipe attempt ${attempt}/${CSI_WIPE_MAX_ATTEMPTS} timed out for '${vol}' (${wipe_job})" >&2
      nomad job status "${wipe_job}" || true
      nomad job allocs "${wipe_job}" || true
      alloc_id="$(nomad job allocs -json "${wipe_job}" 2>/dev/null | python3 -c 'import json,sys;j=json.load(sys.stdin); print((j[0].get("ID") if j else ""))' 2>/dev/null || true)"
      if [[ -n "${alloc_id}" ]]; then
        nomad alloc status "${alloc_id}" || true
        nomad alloc logs -stderr "${alloc_id}" || true
        nomad alloc logs "${alloc_id}" || true
      fi
      nomad job stop -purge "${wipe_job}" >/dev/null 2>&1 || true
    fi

    attempt=$((attempt + 1))
    sleep 2
  done

  echo "✗ CSI wipe failed for volume '${vol}' after ${CSI_WIPE_MAX_ATTEMPTS} attempt(s)" >&2
  return 1
}

csi_volume_topology_nodes() {
  local vol="$1"
  nomad volume status -json "${vol}" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

seen = set()
for topo in data.get("Topologies") or []:
    if not isinstance(topo, dict):
        continue
    segments = topo.get("Segments") or {}
    for key, value in segments.items():
        if not value:
            continue
        if key.endswith("/node") or "node" in key:
            if value not in seen:
                seen.add(value)
                print(value)
'
}

csi_volume_external_id() {
  local vol="$1"
  nomad volume status -json "${vol}" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
print((data.get("ExternalID") or "").strip())
'
}

register_existing_csi_volume() {
  local vol="$1"
  local plugin_id="$2"
  local external_id="$3"
  local spec register_out register_rc

  spec="$(mktemp)"
  cat > "${spec}" <<EOF
id          = "${vol}"
name        = "${vol}"
type        = "csi"
plugin_id   = "${plugin_id}"
external_id = "${external_id}"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
EOF

  register_out="$(nomad volume register "${spec}" 2>&1)" && register_rc=0 || register_rc=$?
  rm -f "${spec}"

  if [[ "${register_rc}" -ne 0 ]]; then
    echo "  - failed registering existing backend volume '${vol}' (external_id=${external_id}): ${register_out}" >&2
    return 1
  fi

  if ! nomad volume status "${vol}" >/dev/null 2>&1; then
    echo "  - register returned success but volume '${vol}' is still not visible in Nomad." >&2
    return 1
  fi

  echo "  - registered existing backend CSI volume: ${vol} (external_id=${external_id})"
  return 0
}

build_worker_exclusion_var() {
  local nodes=("$@")
  if [[ ${#nodes[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${nodes[@]}" | awk 'NF && !seen[$0]++' | python3 -c '
import json, sys
items = [line.strip() for line in sys.stdin if line.strip()]
if items:
    print(json.dumps(items))
'
}

collect_prepull_ready_nodes() {
  local job_id="$1"
  local target_nodes="$2"
  TARGET_NODE_IDS="${target_nodes}" NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" JOB_ID="${job_id}" python3 - <<'PY'
import json, os, subprocess

targets = {x.strip() for x in os.environ.get("TARGET_NODE_IDS", "").splitlines() if x.strip()}
if not targets:
    raise SystemExit(0)

cmd = ["nomad", "job", "allocs", "-json", os.environ["JOB_ID"]]
env = os.environ.copy()
proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
if proc.returncode != 0:
    raise SystemExit(0)

allocs = json.loads(proc.stdout)
ready_nodes = set()
for alloc in allocs:
    if alloc.get("DesiredStatus") != "run":
        continue
    if alloc.get("ClientStatus") != "running":
        continue
    node = alloc.get("NodeID")
    if node not in targets:
        continue
    task = (alloc.get("TaskStates") or {}).get("image-cache-ready") or {}
    if task.get("State") == "running":
        ready_nodes.add(node)

for node_id in sorted(ready_nodes):
    print(node_id)
PY
}

refresh_prepull_not_ready_nodes() {
  local ready_nodes="$1"
  local target_nodes="$2"
  TARGET_NODE_IDS="${target_nodes}" READY_NODE_IDS="${ready_nodes}" python3 - <<'PY'
import os
targets = {x.strip() for x in (os.environ.get("TARGET_NODE_IDS", "").splitlines()) if x.strip()}
ready = {x.strip() for x in (os.environ.get("READY_NODE_IDS", "").splitlines()) if x.strip()}
for node_id in sorted(targets - ready):
    print(node_id)
PY
}

build_combined_worker_exclusions_json() {
  local prepull_not_ready_nodes="$1"
  local combined=()
  while IFS= read -r node_id; do
    [[ -n "${node_id}" ]] && combined+=("${node_id}")
  done <<< "${CSI_EXCLUDED_NODE_IDS}"
  while IFS= read -r node_id; do
    [[ -n "${node_id}" ]] && combined+=("${node_id}")
  done <<< "${prepull_not_ready_nodes}"
  build_worker_exclusion_var "${combined[@]}" || true
}

start_prepull_exclusion_reconciler() {
  local effective_bootstrap_max="$1"
  [[ "${enable_image_prepull}" == "true" ]] || return 0
  [[ -n "${PREPULL_JOB_ID}" ]] || return 0
  [[ -n "${PREPULL_TARGET_NODE_IDS}" ]] || return 0
  (( PREPULL_TOTAL_TARGET_COUNT > 0 )) || return 0

  (
    local deadline now ready_nodes ready_count not_ready_nodes updated_exclusions_json
    local -a args
    local previous_exclusions_json="${WORKER_EXCLUDED_NODE_IDS_JSON:-}"
    deadline=$(( $(date +%s) + PREPULL_WAIT_TIMEOUT_SECONDS ))

    while true; do
      now="$(date +%s)"
      if (( now > deadline )); then
        echo "✗ pre-pull exclusion reconciler timed out before all target worker nodes were pre-pulled." >&2
        exit 1
      fi

      ready_nodes="$(collect_prepull_ready_nodes "${PREPULL_JOB_ID}" "${PREPULL_TARGET_NODE_IDS}")"
      ready_count="$(printf "%s\n" "${ready_nodes}" | awk 'NF' | wc -l | tr -d ' ')"
      not_ready_nodes="$(refresh_prepull_not_ready_nodes "${ready_nodes}" "${PREPULL_TARGET_NODE_IDS}")"
      updated_exclusions_json="$(build_combined_worker_exclusions_json "${not_ready_nodes}")"

      if [[ "${updated_exclusions_json}" != "${previous_exclusions_json}" ]]; then
        echo ""
        echo "==> Reconciling worker exclusions from live pre-pull readiness (${ready_count}/${PREPULL_TOTAL_TARGET_COUNT} ready)"
        if [[ -n "${updated_exclusions_json}" ]]; then
          echo "  - updated worker exclusions: ${updated_exclusions_json}"
        else
          echo "  - updated worker exclusions: []"
        fi

        args=("${VAR_FILE_ARGS[@]}" --name "${JOB_NAME}")
        args+=(--var "enable_image_prepull=false")
        if [[ "${DISABLE_VECTOR_COLLECTION}" == "true" ]]; then
          args+=(--var "enable_vector_collection=false")
        fi
        if [[ -n "${REDIS_NODE_CLASS_OVERRIDE}" ]]; then
          args+=(--var "redis_node_class=${REDIS_NODE_CLASS_OVERRIDE}")
        fi
        if [[ -n "${updated_exclusions_json}" ]]; then
          args+=(--var "worker_excluded_node_ids=${updated_exclusions_json}")
        else
          args+=(--var "worker_excluded_node_ids=[]")
        fi
        args+=(--var "worker_count=${worker_count}")
        args+=(--var "worker_max_replicas=${effective_bootstrap_max}")
        args+=(--var "worker_autoscaling_scale_up_cooldown=${BOOTSTRAP_AUTOSCALER_COOLDOWN}")
        run_pack_with_guard "${args[@]}"
        previous_exclusions_json="${updated_exclusions_json}"
      fi

      if (( ready_count >= PREPULL_TOTAL_TARGET_COUNT )); then
        echo "✓ Pre-pull completed on all target worker nodes; dynamic exclusions are fully reconciled."
        break
      fi

      sleep "${PREPULL_RECONCILE_INTERVAL_SECONDS}"
    done
  ) &

  PREPULL_EXCLUSION_RECONCILER_PID="$!"
}

wait_for_prepull_exclusion_reconciler() {
  if [[ -z "${PREPULL_EXCLUSION_RECONCILER_PID}" ]]; then
    return 0
  fi
  wait "${PREPULL_EXCLUSION_RECONCILER_PID}"
  PREPULL_EXCLUSION_RECONCILER_PID=""
}

stop_prepull_job_if_running() {
  if [[ -n "${PREPULL_JOB_ID}" ]]; then
    nomad job stop -namespace "${NOMAD_NAMESPACE}" -purge "${PREPULL_JOB_ID}" >/dev/null 2>&1 || true
    PREPULL_JOB_ID=""
  fi
}

run_system_hooks_phase() {
  local total_count deadline now ready_count ready_nodes required_by_percent required_ready_count
  local prewarm_job_name prewarm_job_id
  [[ "${enable_image_prepull}" == "true" ]] || return 0

  local rendered spec
  prewarm_job_name="${JOB_NAME}-prewarm"
  prewarm_job_id="${prewarm_job_name}-system-hooks"
  rendered="$(mktemp)"
  spec="$(mktemp)"

  nomad-pack render "${VAR_FILE_ARGS[@]}" --var "job_name=${prewarm_job_name}" "${REPO_ROOT}" > "${rendered}"
  awk '
    /^openstudio-server\/system-hooks\.nomad:$/ { in_section=1; next }
    /^openstudio-server\/.*\.nomad:$/ { if (in_section) exit }
    in_section { print }
  ' "${rendered}" > "${spec}"
  rm -f "${rendered}"

  if [[ ! -s "${spec}" ]]; then
    rm -f "${spec}"
    echo "✗ Failed to render system-hooks job spec for pre-pull phase." >&2
    exit 1
  fi

  echo ""
  echo "==> Phase 1/3: warm image cache (system-hooks)"
  # Use an isolated prewarm job ID so manual `nomad-pack run` won't conflict
  # with an unmanaged lingering system-hooks job from this phase.
  if nomad job status -namespace "${NOMAD_NAMESPACE}" "${prewarm_job_id}" >/dev/null 2>&1; then
    nomad job stop -namespace "${NOMAD_NAMESPACE}" -purge "${prewarm_job_id}" >/dev/null 2>&1 || true
  fi
  NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" nomad job run "${spec}" >/dev/null
  rm -f "${spec}"

  local target_nodes
  target_nodes="$(
    NOMAD_ADDR="${NOMAD_ADDR}" WORKER_INSTANCE_TYPE="${worker_instance_type}" WORKER_RUNTIME_IMAGE="${worker_runtime_image}" python3 - <<'PY'
import json, os, urllib.request
addr = os.environ["NOMAD_ADDR"].rstrip("/")
instance_type = os.environ.get("WORKER_INSTANCE_TYPE", "").strip()
# When worker_runtime_image is set, pull-worker-image uses raw_exec driver.
# Nomad implicitly filters out nodes without driver.raw_exec=1, so match that.
require_raw_exec = bool(os.environ.get("WORKER_RUNTIME_IMAGE", "").strip())

with urllib.request.urlopen(f"{addr}/v1/nodes", timeout=20) as r:
    nodes = json.load(r)

targets = []
for n in nodes:
    if n.get("Status") != "ready" or n.get("SchedulingEligibility") != "eligible":
        continue
    nid = n.get("ID")
    if not nid:
        continue
    with urllib.request.urlopen(f"{addr}/v1/node/{nid}", timeout=20) as r:
        detail = json.load(r)
    meta = detail.get("Meta") or {}
    attrs = detail.get("Attributes") or {}
    if meta.get("node_role") != "worker":
        continue
    if attrs.get("driver.docker") != "1":
        continue
    if instance_type and attrs.get("platform.aws.instance-type") != instance_type:
        continue
    if require_raw_exec and attrs.get("driver.raw_exec") != "1":
        continue
    targets.append(nid)

for nid in targets:
    print(nid)
PY
  )"

  if [[ -z "${target_nodes}" ]]; then
    nomad job stop -namespace "${NOMAD_NAMESPACE}" -purge "${prewarm_job_id}" >/dev/null 2>&1 || true
    echo "✗ No target worker nodes found for pre-pull readiness checks." >&2
    exit 1
  fi

  total_count="$(printf "%s\n" "${target_nodes}" | awk 'NF' | wc -l | tr -d ' ')"
  if [[ "${PREPULL_REQUIRE_ALL}" == "true" ]]; then
    required_ready_count="${total_count}"
    echo "  pre-pull gate requires ${required_ready_count}/${total_count} worker nodes (OS_PREPULL_REQUIRE_ALL=true)"
  else
    required_by_percent=$(( (total_count * PREPULL_MIN_READY_PERCENT + 99) / 100 ))
    if (( required_by_percent < 1 )); then
      required_by_percent=1
    fi
    required_ready_count="${required_by_percent}"
    if (( required_ready_count < worker_count )); then
      required_ready_count="${worker_count}"
    fi
    if (( required_ready_count > total_count )); then
      required_ready_count="${total_count}"
    fi
    echo "  pre-pull gate requires ${required_ready_count}/${total_count} worker nodes (min ${PREPULL_MIN_READY_PERCENT}%, worker_count=${worker_count})"
  fi
  deadline=$(( $(date +%s) + PREPULL_WAIT_TIMEOUT_SECONDS ))

  while true; do
    now="$(date +%s)"
    if (( now > deadline )); then
      nomad job stop -namespace "${NOMAD_NAMESPACE}" -purge "${prewarm_job_id}" >/dev/null 2>&1 || true
      echo "✗ Timed out waiting for system-hooks pre-pull readiness on target worker nodes." >&2
      exit 1
    fi

    ready_nodes="$(collect_prepull_ready_nodes "${prewarm_job_id}" "${target_nodes}")"

    ready_count="$(printf "%s\n" "${ready_nodes}" | awk 'NF' | wc -l | tr -d ' ')"
    printf "\r  pre-pull readiness: %s/%s worker nodes ready (required: %s)" "${ready_count}" "${total_count}" "${required_ready_count}"
    if (( ready_count >= required_ready_count )); then
      echo ""
      echo "✓ Pre-pull readiness threshold met."
      break
    fi
    sleep 5
  done

  PREPULL_READY_NODE_IDS="${ready_nodes}"
  PREPULL_NOT_READY_NODE_IDS="$(refresh_prepull_not_ready_nodes "${ready_nodes}" "${target_nodes}")"
  PREPULL_JOB_ID="${prewarm_job_id}"
  PREPULL_TARGET_NODE_IDS="${target_nodes}"
  PREPULL_TOTAL_TARGET_COUNT="${total_count}"
}

wait_for_core_services() {
  local deadline now status_line all_ready
  deadline=$(( $(date +%s) + 600 ))
  all_ready=false

  echo ""
  echo "==> Phase 2/3: waiting for core services"
  while true; do
    now="$(date +%s)"
    if (( now > deadline )); then
      break
    fi

    status_line="$(
      NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" JOB_PREFIX="${JOB_NAME}" python3 - <<'PY'
import json, os, urllib.request
core = [f"{os.environ['JOB_PREFIX']}-db", f"{os.environ['JOB_PREFIX']}-redis", f"{os.environ['JOB_PREFIX']}-rserve", f"{os.environ['JOB_PREFIX']}-web"]
addr = os.environ["NOMAD_ADDR"].rstrip("/")
ns = os.environ.get("NOMAD_NAMESPACE", "default")
req = urllib.request.Request(f"{addr}/v1/jobs?namespace={ns}")
with urllib.request.urlopen(req, timeout=20) as r:
    jobs = json.load(r)
status = {j.get("ID"): j.get("Status") for j in jobs}
ready = 0
for job_id in core:
    if status.get(job_id) != "running":
        continue
    dep_status = ""
    try:
        with urllib.request.urlopen(f"{addr}/v1/job/{job_id}/deployments?namespace={ns}", timeout=20) as r:
            deps = json.load(r)
        if deps:
            dep_status = (deps[0].get("Status") or "").lower()
    except Exception:
        dep_status = ""
    if dep_status == "successful":
        ready += 1
print(f"{ready}/4")
PY
    )"
    printf "\r  core readiness (deployment healthy): %s" "${status_line}"
    if [[ "${status_line}" == "4/4" ]]; then
      all_ready=true
      break
    fi
    sleep 5
  done
  echo ""

  if [[ "${all_ready}" != "true" ]]; then
    echo "✗ Core services did not reach running state in time." >&2
    exit 1
  fi
}

wait_for_prometheus_if_enabled() {
  local prometheus_enabled_normalized
  prometheus_enabled_normalized="$(echo "${prometheus_enabled}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${prometheus_enabled_normalized}" != "true" ]]; then
    return 0
  fi

  local job_id deadline now status_line all_ready
  job_id="${JOB_NAME}-prometheus"
  deadline=$(( $(date +%s) + 600 ))
  all_ready=false

  echo ""
  echo "==> Final check: waiting for Prometheus"
  while true; do
    now="$(date +%s)"
    if (( now > deadline )); then
      break
    fi

    status_line="$(
      NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" PROM_JOB="${job_id}" python3 - <<'PY'
import json, os, urllib.request
addr = os.environ["NOMAD_ADDR"].rstrip("/")
ns = os.environ.get("NOMAD_NAMESPACE", "default")
job_id = os.environ["PROM_JOB"]

job_status = "unknown"
dep_status = ""
running = 0
queued = 0
ready = False

try:
    with urllib.request.urlopen(f"{addr}/v1/job/{job_id}?namespace={ns}", timeout=20) as r:
        job = json.load(r)
    job_status = (job.get("Status") or "unknown").lower()
except Exception:
    print("job=missing deployment=none running=0 queued=0 ready=false")
    raise SystemExit(0)

try:
    with urllib.request.urlopen(f"{addr}/v1/job/{job_id}/deployments?namespace={ns}", timeout=20) as r:
        deps = json.load(r)
    if deps:
        dep_status = (deps[0].get("Status") or "").lower()
except Exception:
    dep_status = ""

try:
    with urllib.request.urlopen(f"{addr}/v1/job/{job_id}/summary?namespace={ns}", timeout=20) as r:
        summary = json.load(r)
    tg_summary = summary.get("Summary") or {}
    if tg_summary:
        first_group = next(iter(tg_summary.values()))
        running = int(first_group.get("Running") or 0)
        queued = int(first_group.get("Queued") or 0)
except Exception:
    pass

if job_status == "running" and dep_status == "successful" and running >= 1:
    ready = True

print(f"job={job_status} deployment={dep_status or 'none'} running={running} queued={queued} ready={'true' if ready else 'false'}")
PY
    )"
    printf "\r  prometheus readiness: %s" "${status_line}"
    if [[ "${status_line}" == *"ready=true"* ]]; then
      all_ready=true
      break
    fi
    sleep 5
  done
  echo ""

  if [[ "${all_ready}" != "true" ]]; then
    echo "✗ Prometheus did not reach healthy running status in time." >&2
    nomad job status -namespace "${NOMAD_NAMESPACE}" "${job_id}" || true
    exit 1
  fi
}

run_pack_with_guard() {
  local run_log
  run_log="$(mktemp)"
  if ! nomad-pack run "$@" "${REPO_ROOT}" 2>&1 | tee "${run_log}"; then
    if grep -q 'Failed To Query For Previously Deployed Jobs' "${run_log}"; then
      core_jobs_ready=false
      for _ in $(seq 1 30); do
        if nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-web" >/dev/null 2>&1 && \
           nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-worker" >/dev/null 2>&1 && \
           nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-db" >/dev/null 2>&1 && \
           nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-redis" >/dev/null 2>&1 && \
           nomad job status -namespace "${NOMAD_NAMESPACE}" "${JOB_NAME}-rserve" >/dev/null 2>&1; then
          core_jobs_ready=true
          break
        fi
        sleep 1
      done
      if [[ "${core_jobs_ready}" == "true" ]]; then
        echo "⚠ nomad-pack reported a deployment metadata query error, but core jobs are registered."
      else
        rm -f "${run_log}"
        exit 1
      fi
    else
      rm -f "${run_log}"
      exit 1
    fi
  fi
  rm -f "${run_log}"
}

cleanup_background_jobs() {
  if [[ -n "${PREPULL_EXCLUSION_RECONCILER_PID}" ]]; then
    kill "${PREPULL_EXCLUSION_RECONCILER_PID}" >/dev/null 2>&1 || true
    wait "${PREPULL_EXCLUSION_RECONCILER_PID}" >/dev/null 2>&1 || true
    PREPULL_EXCLUSION_RECONCILER_PID=""
  fi
  stop_prepull_job_if_running
}

trap cleanup_background_jobs EXIT

echo ""
echo "==> Recreating data volumes"
ensure_role_scoped_csi_plugins
ACTIVE_DB_CSI_PLUGIN_ID=""
ACTIVE_REDIS_CSI_PLUGIN_ID=""
DB_EXISTING_EXTERNAL_ID=""
REDIS_EXISTING_EXTERNAL_ID=""
if [[ "${db_storage_type}" == "csi" ]]; then
  DB_EXISTING_EXTERNAL_ID="$(csi_volume_external_id "${db_volume_source}" || true)"
  ACTIVE_DB_CSI_PLUGIN_ID="$(detect_csi_plugin_id_for_volume "${db_volume_source}" || true)"
  if [[ -z "${ACTIVE_DB_CSI_PLUGIN_ID}" ]]; then
    echo "✗ Could not determine CSI plugin ID for DB volume '${db_volume_source}'." >&2
    exit 1
  fi
  echo "  - DB CSI plugin: ${ACTIVE_DB_CSI_PLUGIN_ID}"
fi
if [[ "${redis_storage_type}" == "csi" ]]; then
  REDIS_EXISTING_EXTERNAL_ID="$(csi_volume_external_id "${redis_volume_source}" || true)"
  ACTIVE_REDIS_CSI_PLUGIN_ID="$(detect_csi_plugin_id_for_volume "${redis_volume_source}" || true)"
  if [[ -z "${ACTIVE_REDIS_CSI_PLUGIN_ID}" ]]; then
    echo "✗ Could not determine CSI plugin ID for Redis volume '${redis_volume_source}'." >&2
    exit 1
  fi
  echo "  - Redis CSI plugin: ${ACTIVE_REDIS_CSI_PLUGIN_ID}"
fi

if [[ "${db_storage_type}" == "csi" ]]; then
  delete_csi_volume_if_present "${db_volume_source}"
  create_csi_volume "${db_volume_source}" "${DB_CSI_CAPACITY_MIN}" "${DB_CSI_CAPACITY_MAX}" "${ACTIVE_DB_CSI_PLUGIN_ID}" "${STATEFUL_CSI_NODE_ROLE}" "${DB_EXISTING_EXTERNAL_ID}"
  wipe_csi_volume_data "${db_volume_source}"
else
  echo "  - db_storage_type=${db_storage_type}; skipping CSI recreation for DB"
fi

if [[ "${redis_storage_type}" == "csi" ]]; then
  delete_csi_volume_if_present "${redis_volume_source}"
  create_csi_volume "${redis_volume_source}" "${REDIS_CSI_CAPACITY_MIN}" "${REDIS_CSI_CAPACITY_MAX}" "${ACTIVE_REDIS_CSI_PLUGIN_ID}" "${STATEFUL_CSI_NODE_ROLE}" "${REDIS_EXISTING_EXTERNAL_ID}"
  wipe_csi_volume_data "${redis_volume_source}"
else
  echo "  - redis_storage_type=${redis_storage_type}; skipping CSI recreation for Redis"
fi

CSI_EXCLUDED_NODE_IDS=""
if [[ "${db_storage_type}" == "csi" || "${redis_storage_type}" == "csi" ]]; then
  topology_nodes=()
  if [[ "${db_storage_type}" == "csi" ]]; then
    while IFS= read -r node_id; do
      [[ -n "${node_id}" ]] && topology_nodes+=("${node_id}")
    done < <(csi_volume_topology_nodes "${db_volume_source}")
  fi
  if [[ "${redis_storage_type}" == "csi" ]]; then
    while IFS= read -r node_id; do
      [[ -n "${node_id}" ]] && topology_nodes+=("${node_id}")
    done < <(csi_volume_topology_nodes "${redis_volume_source}")
  fi
  CSI_EXCLUDED_NODE_IDS="$(printf '%s\n' "${topology_nodes[@]}" | awk 'NF && !seen[$0]++')"
  if [[ -n "${CSI_EXCLUDED_NODE_IDS}" ]]; then
    echo "  - protected CSI topology node IDs:"
    printf '%s\n' "${CSI_EXCLUDED_NODE_IDS}" | sed 's/^/    - /'
  else
    echo "✗ No CSI topology node IDs detected for worker exclusion; aborting to avoid scheduling workers onto DB/Redis nodes." >&2
    exit 1
  fi
fi

wipe_nfs_data() {
  local wipe_job
  local job_spec
  wipe_job="${JOB_NAME}-nfs-wipe-$(date +%s)"
  job_spec="$(mktemp)"
  cat > "${job_spec}" <<EOF
job "${wipe_job}" {
  region      = "global"
  datacenters = ["dc1"]
  namespace   = "${NOMAD_NAMESPACE}"
  type        = "batch"

  group "wipe" {
    restart {
      attempts = 0
      mode     = "fail"
    }

    volume "nfs-shared" {
      type      = "host"
      source    = "${nfs_volume_source}"
      read_only = false
    }

    task "wipe" {
      # Use exec driver (no Docker image required) to avoid Docker Hub rate
      # limits (429) on nodes that don't have a cached image. exec is enabled
      # on all Nomad clients in this cluster and has no registry dependency.
      driver = "exec"
      config {
        command = "/bin/sh"
        args = [
          "-ec",
          "find /local/nfs -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
        ]
      }
      volume_mount {
        volume      = "nfs-shared"
        destination = "/local/nfs"
        read_only   = false
      }
      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
EOF

  nomad job run "${job_spec}" >/dev/null
  rm -f "${job_spec}"

  for _ in $(seq 1 120); do
    state="$(
      nomad job allocs -json "${wipe_job}" 2>/dev/null | python3 -c '
import json,sys
j=json.load(sys.stdin)
if not j:
    print("wait")
    sys.exit(0)
statuses=[(a.get("ClientStatus") or "").lower() for a in j]
# A complete alloc means success; Nomad may have rescheduled once after an
# initial alloc failure (e.g. exec user lookup on a different node image).
if any(s == "complete" for s in statuses):
    print("ok")
    sys.exit(0)
# All allocs failed/lost with no complete -> genuinely failed
if statuses and all(s in ("failed","lost") for s in statuses):
    print("fail")
    sys.exit(0)
print("wait")
' 2>/dev/null || echo "wait"
    )"

    case "${state}" in
      ok)
        nomad job stop -purge "${wipe_job}" >/dev/null 2>&1 || true
        echo "  - wiped NFS data in ${nfs_volume_source}:${nfs_volume_mount_path}"
        return 0
        ;;
      fail)
        # Capture logs before purging so the failure reason is visible
        alloc_id="$(nomad job allocs -json "${wipe_job}" 2>/dev/null | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j[0]["ID"][:8] if j else "")' 2>/dev/null || true)"
        if [[ -n "${alloc_id}" ]]; then
          echo "  NFS wipe alloc ${alloc_id} stderr:" >&2
          nomad alloc logs -stderr "${alloc_id}" 2>&1 | tail -20 >&2 || true
        fi
        nomad job stop -purge "${wipe_job}" >/dev/null 2>&1 || true
        echo "✗ NFS wipe job failed (${wipe_job})" >&2
        return 1
        ;;
      *)
        ;;
    esac
    sleep 2
  done

  nomad job status "${wipe_job}" || true
  nomad job allocs "${wipe_job}" || true
  nomad job stop -purge "${wipe_job}" >/dev/null 2>&1 || true
  echo "✗ Timed out waiting for NFS wipe job (${wipe_job})" >&2
  return 1
}

if [[ "${WIPE_NFS}" == "true" && "${nfs_shared_volume_enabled}" == "true" && "${nfs_volume_type}" == "host_volume" ]]; then
  echo ""
  echo "==> Wiping shared NFS data"
  wipe_nfs_data
else
  echo ""
  echo "==> Skipping NFS wipe (wipe=${WIPE_NFS}, enabled=${nfs_shared_volume_enabled}, type=${nfs_volume_type})"
fi

echo ""
echo "==> Running storage preflight"
PREFLIGHT_ARGS=(
  --nomad-addr "${NOMAD_ADDR}"
  --namespace "${NOMAD_NAMESPACE}"
  --create-missing-csi
)
for var_file in "${VAR_FILES[@]}"; do
  PREFLIGHT_ARGS+=(--var-file "${var_file}")
done
if [[ -n "${CSI_PLUGIN_ID}" ]]; then
  PREFLIGHT_ARGS+=(--csi-plugin-id "${CSI_PLUGIN_ID}")
fi
DB_CSI_PLUGIN_ID="${ACTIVE_DB_CSI_PLUGIN_ID:-${DB_CSI_PLUGIN_ID}}" \
  REDIS_CSI_PLUGIN_ID="${ACTIVE_REDIS_CSI_PLUGIN_ID:-${REDIS_CSI_PLUGIN_ID}}" \
  "${REPO_ROOT}/scripts/preflight-storage.sh" "${PREFLIGHT_ARGS[@]}"

echo ""
run_system_hooks_phase

WORKER_EXCLUDED_NODE_IDS_JSON="$(build_combined_worker_exclusions_json "${PREPULL_NOT_READY_NODE_IDS}")"
if [[ -n "${WORKER_EXCLUDED_NODE_IDS_JSON}" ]]; then
  echo "  - worker exclusions (CSI + pre-pull not-ready): ${WORKER_EXCLUDED_NODE_IDS_JSON}"
fi

echo "==> Phase 2/3: deploy stack with conservative worker ramp"
RUN_ARGS=("${VAR_FILE_ARGS[@]}" --name "${JOB_NAME}")
RUN_ARGS+=(--var "enable_image_prepull=false")
if [[ "${DISABLE_VECTOR_COLLECTION}" == "true" ]]; then
  RUN_ARGS+=(--var "enable_vector_collection=false")
fi
if [[ -n "${REDIS_NODE_CLASS_OVERRIDE}" ]]; then
  RUN_ARGS+=(--var "redis_node_class=${REDIS_NODE_CLASS_OVERRIDE}")
fi
if [[ -n "${WORKER_EXCLUDED_NODE_IDS_JSON}" ]]; then
  RUN_ARGS+=(--var "worker_excluded_node_ids=${WORKER_EXCLUDED_NODE_IDS_JSON}")
else
  RUN_ARGS+=(--var "worker_excluded_node_ids=[]")
fi
effective_bootstrap_max="${BOOTSTRAP_WORKER_MAX_REPLICAS}"
if (( effective_bootstrap_max > worker_max_replicas )); then
  effective_bootstrap_max="${worker_max_replicas}"
fi
RUN_ARGS+=(--var "worker_count=${worker_count}")
RUN_ARGS+=(--var "worker_max_replicas=${effective_bootstrap_max}")
RUN_ARGS+=(--var "worker_autoscaling_scale_up_cooldown=${BOOTSTRAP_AUTOSCALER_COOLDOWN}")
run_pack_with_guard "${RUN_ARGS[@]}"

# Keep pre-pull running in the background and continuously reconcile
# worker_excluded_node_ids as nodes become image-cache-ready.
start_prepull_exclusion_reconciler "${effective_bootstrap_max}"

wait_for_core_services
wait_for_prepull_exclusion_reconciler

if [[ -n "${PREPULL_JOB_ID}" && -n "${PREPULL_TARGET_NODE_IDS}" ]]; then
  PREPULL_READY_NODE_IDS="$(collect_prepull_ready_nodes "${PREPULL_JOB_ID}" "${PREPULL_TARGET_NODE_IDS}")"
  PREPULL_NOT_READY_NODE_IDS="$(refresh_prepull_not_ready_nodes "${PREPULL_READY_NODE_IDS}" "${PREPULL_TARGET_NODE_IDS}")"
fi
WORKER_EXCLUDED_NODE_IDS_JSON="$(build_combined_worker_exclusions_json "${PREPULL_NOT_READY_NODE_IDS}")"

if [[ "${effective_bootstrap_max}" != "${worker_max_replicas}" || "${BOOTSTRAP_AUTOSCALER_COOLDOWN}" != "${worker_autoscaling_scale_up_cooldown}" || -n "${PREPULL_NOT_READY_NODE_IDS}" ]]; then
  echo ""
  echo "==> Phase 3/3: restore full worker autoscaling bounds"
  FINAL_ARGS=("${VAR_FILE_ARGS[@]}" --name "${JOB_NAME}")
  FINAL_ARGS+=(--var "enable_image_prepull=false")
  if [[ "${DISABLE_VECTOR_COLLECTION}" == "true" ]]; then
    FINAL_ARGS+=(--var "enable_vector_collection=false")
  fi
  if [[ -n "${REDIS_NODE_CLASS_OVERRIDE}" ]]; then
    FINAL_ARGS+=(--var "redis_node_class=${REDIS_NODE_CLASS_OVERRIDE}")
  fi
  if [[ -n "${WORKER_EXCLUDED_NODE_IDS_JSON}" ]]; then
    FINAL_ARGS+=(--var "worker_excluded_node_ids=${WORKER_EXCLUDED_NODE_IDS_JSON}")
  else
    FINAL_ARGS+=(--var "worker_excluded_node_ids=[]")
  fi
  FINAL_ARGS+=(--var "worker_count=${worker_count}")
  FINAL_ARGS+=(--var "worker_max_replicas=${worker_max_replicas}")
  FINAL_ARGS+=(--var "worker_autoscaling_scale_up_cooldown=${worker_autoscaling_scale_up_cooldown}")
  run_pack_with_guard "${FINAL_ARGS[@]}"
fi

stop_prepull_job_if_running

wait_for_prometheus_if_enabled

echo ""
echo "✓ Fresh redeploy complete"
