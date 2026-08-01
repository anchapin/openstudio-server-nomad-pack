#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VAR_FILE="${OS_VAR_FILE:-${REPO_ROOT}/examples/openstack.hcl}"
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
CSI_WIPE_MAX_ATTEMPTS="${OS_CSI_WIPE_MAX_ATTEMPTS:-3}"
CSI_WIPE_JOB_IMAGE="${OS_CSI_WIPE_JOB_IMAGE:-}"
STATEFUL_CSI_NODE_ROLE="${OS_STATEFUL_CSI_NODE_ROLE:-web}"
CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS="${OS_CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS:-6}"
AUTO_DEPLOY_ROLE_CSI_PLUGINS="${OS_AUTO_DEPLOY_ROLE_CSI_PLUGINS:-true}"
CSI_PLUGIN_READY_TIMEOUT_SECONDS="${OS_CSI_PLUGIN_READY_TIMEOUT_SECONDS:-180}"

PREPULL_READY_NODE_IDS=""
PREPULL_NOT_READY_NODE_IDS=""
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
  --var-file <path>      Var-file (default: ${VAR_FILE})
  --job-name <name>      Pack job name (default: ${JOB_NAME})
  --nomad-addr <url>     Nomad API (default: ${NOMAD_ADDR})
  --namespace <ns>       Nomad namespace (default: ${NOMAD_NAMESPACE})
  --csi-plugin-id <id>   CSI plugin ID for volume create (auto-detected by default)
  --redis-node-class <class>  Override redis_node_class for this deploy only
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
    --var-file) VAR_FILE="$2"; shift 2 ;;
    --job-name) JOB_NAME="$2"; shift 2 ;;
    --nomad-addr) NOMAD_ADDR="$2"; shift 2 ;;
    --namespace) NOMAD_NAMESPACE="$2"; shift 2 ;;
    --csi-plugin-id) CSI_PLUGIN_ID="$2"; shift 2 ;;
    --redis-node-class) REDIS_NODE_CLASS_OVERRIDE="$2"; shift 2 ;;
    --skip-nfs-wipe) WIPE_NFS=false; shift ;;
    --no-auto-csi-plugin-deploy) AUTO_DEPLOY_ROLE_CSI_PLUGINS=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -f "${VAR_FILE}" ]]; then
  echo "✗ var-file not found: ${VAR_FILE}" >&2
  exit 1
fi

export NOMAD_ADDR NOMAD_NAMESPACE

_extract_var() {
  local key="$1"
  local default="${2:-}"
  local line value
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${VAR_FILE}" | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    echo "${default}"
    return
  fi
  value="${line#*=}"
  value="$(echo "${value}" | sed -E 's/[[:space:]]*#.*$//' | xargs)"
  value="${value%\"}"
  value="${value#\"}"
  echo "${value}"
}

db_storage_type="$(_extract_var db_storage_type host_volume)"
db_volume_source="$(_extract_var db_volume_source openstudio-mongodb)"
redis_storage_type="$(_extract_var redis_storage_type host_volume)"
redis_volume_source="$(_extract_var redis_volume_source openstudio-redis)"
db_csi_plugin_id="$(_extract_var db_csi_plugin_id "${DB_CSI_PLUGIN_ID:-${CSI_PLUGIN_ID}}")"
redis_csi_plugin_id="$(_extract_var redis_csi_plugin_id "${REDIS_CSI_PLUGIN_ID:-${CSI_PLUGIN_ID}}")"
nfs_shared_volume_enabled="$(_extract_var nfs_shared_volume_enabled false)"
nfs_volume_type="$(_extract_var nfs_volume_type host_volume)"
nfs_volume_source="$(_extract_var nfs_volume_source openstudio-nfs)"
nfs_volume_mount_path="$(_extract_var nfs_volume_mount_path /mnt/openstudio)"
enable_image_prepull="$(_extract_var enable_image_prepull false)"
worker_instance_type="$(_extract_var worker_instance_type "")"
worker_runtime_image="$(_extract_var worker_runtime_image "")"
worker_count="$(_extract_var worker_count 1)"
worker_max_replicas="$(_extract_var worker_max_replicas 10)"
autoscaler_cooldown="$(_extract_var autoscaler_cooldown 60m)"
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

echo "==> Fresh redeploy configuration"
echo "  nomad_addr=${NOMAD_ADDR}"
echo "  namespace=${NOMAD_NAMESPACE}"
echo "  var_file=${VAR_FILE}"
echo "  job_name=${JOB_NAME}"
echo "  redis_node_class=${redis_node_class:-<unset>}"
echo "  redis_config: maxclients=${redis_config_maxclients} tcp_backlog=${redis_config_tcp_backlog} timeout=${redis_config_timeout_seconds}s maxmemory=${redis_config_maxmemory} policy=${redis_config_maxmemory_policy} appendfsync=${redis_config_appendfsync} save='${redis_config_save}'"

curl -sf "${NOMAD_ADDR}/v1/status/leader" >/dev/null
if [[ -n "${redis_node_class}" ]]; then
  redis_class_ready_count="$(count_ready_eligible_nodes_with_class "${redis_node_class}")"
  if [[ "${redis_class_ready_count}" == "0" ]]; then
    echo "✗ redis_node_class='${redis_node_class}' but no ready/eligible nodes advertise that Nomad node class." >&2
    echo "  Set redis_node_class in ${VAR_FILE} to an existing class, or pass --redis-node-class <class>." >&2
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
  nomad-pack destroy --var-file "${VAR_FILE}" --name "${JOB_NAME}" "${REPO_ROOT}" || true
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
  local attempt spec topo_node topo_role

  for attempt in $(seq 1 "${CSI_TOPOLOGY_RECREATE_MAX_ATTEMPTS}"); do
    spec="$(mktemp)"
    cat > "${spec}" <<EOF
id        = "${vol}"
name      = "${vol}"
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
    wipe_image="alpine:3.20"
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
      driver = "docker"
      config {
        image   = "${wipe_image}"
        command = "sh"
        args = [
          "-ec",
          "mkdir -p /data && rm -rf /data/* /data/.[!.]* /data/..?* || true"
        ]
      }
      volume_mount {
        volume      = "target"
        destination = "/data"
        read_only   = false
      }
      resources {
        cpu    = 100
        memory = 128
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
if any(s == "failed" for s in statuses):
    print("fail")
    sys.exit(0)
if all(s in ("complete","failed","lost") for s in statuses) and any(s == "complete" for s in statuses):
    print("ok")
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

run_system_hooks_phase() {
  local total_count deadline now ready_count ready_nodes required_by_percent required_ready_count
  [[ "${enable_image_prepull}" == "true" ]] || return 0

  local rendered spec
  rendered="$(mktemp)"
  spec="$(mktemp)"

  nomad-pack render --var-file "${VAR_FILE}" --var "job_name=${JOB_NAME}" "${REPO_ROOT}" > "${rendered}"
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
      echo "✗ Timed out waiting for system-hooks pre-pull readiness on target worker nodes." >&2
      exit 1
    fi

    ready_nodes="$(
      TARGET_NODE_IDS="${target_nodes}" NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" JOB_ID="${JOB_NAME}-system-hooks" python3 - <<'PY'
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
    )"

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
  PREPULL_NOT_READY_NODE_IDS="$(
    TARGET_NODE_IDS="${target_nodes}" READY_NODE_IDS="${ready_nodes}" python3 - <<'PY'
import os
targets = {x.strip() for x in (os.environ.get("TARGET_NODE_IDS", "").splitlines()) if x.strip()}
ready = {x.strip() for x in (os.environ.get("READY_NODE_IDS", "").splitlines()) if x.strip()}
for node_id in sorted(targets - ready):
    print(node_id)
PY
  )"
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

echo ""
echo "==> Recreating data volumes"
ensure_role_scoped_csi_plugins
ACTIVE_DB_CSI_PLUGIN_ID=""
ACTIVE_REDIS_CSI_PLUGIN_ID=""
if [[ "${db_storage_type}" == "csi" ]]; then
  ACTIVE_DB_CSI_PLUGIN_ID="$(detect_csi_plugin_id_for_volume "${db_volume_source}" || true)"
  if [[ -z "${ACTIVE_DB_CSI_PLUGIN_ID}" ]]; then
    echo "✗ Could not determine CSI plugin ID for DB volume '${db_volume_source}'." >&2
    exit 1
  fi
  echo "  - DB CSI plugin: ${ACTIVE_DB_CSI_PLUGIN_ID}"
fi
if [[ "${redis_storage_type}" == "csi" ]]; then
  ACTIVE_REDIS_CSI_PLUGIN_ID="$(detect_csi_plugin_id_for_volume "${redis_volume_source}" || true)"
  if [[ -z "${ACTIVE_REDIS_CSI_PLUGIN_ID}" ]]; then
    echo "✗ Could not determine CSI plugin ID for Redis volume '${redis_volume_source}'." >&2
    exit 1
  fi
  echo "  - Redis CSI plugin: ${ACTIVE_REDIS_CSI_PLUGIN_ID}"
fi

if [[ "${db_storage_type}" == "csi" ]]; then
  delete_csi_volume_if_present "${db_volume_source}"
  create_csi_volume "${db_volume_source}" "${DB_CSI_CAPACITY_MIN}" "${DB_CSI_CAPACITY_MAX}" "${ACTIVE_DB_CSI_PLUGIN_ID}" "${STATEFUL_CSI_NODE_ROLE}"
  wipe_csi_volume_data "${db_volume_source}" "${db_image}"
else
  echo "  - db_storage_type=${db_storage_type}; skipping CSI recreation for DB"
fi

if [[ "${redis_storage_type}" == "csi" ]]; then
  delete_csi_volume_if_present "${redis_volume_source}"
  create_csi_volume "${redis_volume_source}" "${REDIS_CSI_CAPACITY_MIN}" "${REDIS_CSI_CAPACITY_MAX}" "${ACTIVE_REDIS_CSI_PLUGIN_ID}" "${STATEFUL_CSI_NODE_ROLE}"
  wipe_csi_volume_data "${redis_volume_source}" "${redis_image}"
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
      driver = "docker"
      config {
        image   = "alpine:3.20"
        command = "sh"
        args = [
          "-ec",
          "mkdir -p ${nfs_volume_mount_path} && find ${nfs_volume_mount_path} -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
        ]
      }
      volume_mount {
        volume      = "nfs-shared"
        destination = "${nfs_volume_mount_path}"
        read_only   = false
      }
      resources {
        cpu    = 100
        memory = 128
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
if any(s == "failed" for s in statuses):
    print("fail")
    sys.exit(0)
if all(s in ("complete","failed","lost") for s in statuses) and any(s == "complete" for s in statuses):
    print("ok")
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
  --var-file "${VAR_FILE}"
  --nomad-addr "${NOMAD_ADDR}"
  --namespace "${NOMAD_NAMESPACE}"
  --create-missing-csi
)
if [[ -n "${CSI_PLUGIN_ID}" ]]; then
  PREFLIGHT_ARGS+=(--csi-plugin-id "${CSI_PLUGIN_ID}")
fi
"${REPO_ROOT}/scripts/preflight-storage.sh" "${PREFLIGHT_ARGS[@]}"

echo ""
run_system_hooks_phase

WORKER_EXCLUDED_NODE_IDS_JSON=""
combined_worker_exclusions=()
while IFS= read -r node_id; do
  [[ -n "${node_id}" ]] && combined_worker_exclusions+=("${node_id}")
done <<< "${CSI_EXCLUDED_NODE_IDS}"
while IFS= read -r node_id; do
  [[ -n "${node_id}" ]] && combined_worker_exclusions+=("${node_id}")
done <<< "${PREPULL_NOT_READY_NODE_IDS}"
WORKER_EXCLUDED_NODE_IDS_JSON="$(build_worker_exclusion_var "${combined_worker_exclusions[@]}" || true)"
if [[ -n "${WORKER_EXCLUDED_NODE_IDS_JSON}" ]]; then
  echo "  - worker exclusions (CSI + pre-pull not-ready): ${WORKER_EXCLUDED_NODE_IDS_JSON}"
fi

echo "==> Phase 2/3: deploy stack with conservative worker ramp"
RUN_ARGS=(--var-file "${VAR_FILE}" --name "${JOB_NAME}")
RUN_ARGS+=(--var "enable_image_prepull=false")
if [[ -n "${REDIS_NODE_CLASS_OVERRIDE}" ]]; then
  RUN_ARGS+=(--var "redis_node_class=${REDIS_NODE_CLASS_OVERRIDE}")
fi
if [[ -n "${WORKER_EXCLUDED_NODE_IDS_JSON}" ]]; then
  RUN_ARGS+=(--var "worker_excluded_node_ids=${WORKER_EXCLUDED_NODE_IDS_JSON}")
fi
effective_bootstrap_max="${BOOTSTRAP_WORKER_MAX_REPLICAS}"
if (( effective_bootstrap_max > worker_max_replicas )); then
  effective_bootstrap_max="${worker_max_replicas}"
fi
RUN_ARGS+=(--var "worker_count=${worker_count}")
RUN_ARGS+=(--var "worker_max_replicas=${effective_bootstrap_max}")
RUN_ARGS+=(--var "autoscaler_cooldown=${BOOTSTRAP_AUTOSCALER_COOLDOWN}")
run_pack_with_guard "${RUN_ARGS[@]}"

wait_for_core_services

if [[ "${effective_bootstrap_max}" != "${worker_max_replicas}" || "${BOOTSTRAP_AUTOSCALER_COOLDOWN}" != "${autoscaler_cooldown}" ]]; then
  echo ""
  echo "==> Phase 3/3: restore full worker autoscaling bounds"
  FINAL_ARGS=(--var-file "${VAR_FILE}" --name "${JOB_NAME}")
  FINAL_ARGS+=(--var "enable_image_prepull=false")
  if [[ -n "${REDIS_NODE_CLASS_OVERRIDE}" ]]; then
    FINAL_ARGS+=(--var "redis_node_class=${REDIS_NODE_CLASS_OVERRIDE}")
  fi
  if [[ -n "${WORKER_EXCLUDED_NODE_IDS_JSON}" ]]; then
    FINAL_ARGS+=(--var "worker_excluded_node_ids=${WORKER_EXCLUDED_NODE_IDS_JSON}")
  fi
  FINAL_ARGS+=(--var "worker_count=${worker_count}")
  FINAL_ARGS+=(--var "worker_max_replicas=${worker_max_replicas}")
  FINAL_ARGS+=(--var "autoscaler_cooldown=${autoscaler_cooldown}")
  run_pack_with_guard "${FINAL_ARGS[@]}"
fi

echo ""
echo "✓ Fresh redeploy complete"
