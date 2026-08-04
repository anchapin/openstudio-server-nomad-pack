#!/usr/bin/env bash
# check-csi-topology.sh — Detect CSI topology pin drift for DB/Redis Nomad jobs.
#
# Reads the current db_csi_topology_node_id / redis_csi_topology_node_id
# constraints from the running Nomad job spec and compares them against the
# actual CSI volume topology reported by `nomad volume status -json`.
# If they diverge (e.g. the volume was re-provisioned on a replacement node),
# emits a structured warning and exits non-zero.
#
# Usage:
#   ./scripts/check-csi-topology.sh [OPTIONS]
#
# Options:
#   --job-name <name>         Nomad pack job name prefix (default: openstudio-server)
#   --nomad-addr <url>        Nomad API address (default: $NOMAD_ADDR or http://127.0.0.1:4646)
#   --namespace <ns>          Nomad namespace (default: $NOMAD_NAMESPACE or default)
#   --db-volume <vol>         CSI volume ID for MongoDB (default: openstudio-mongodb)
#   --redis-volume <vol>      CSI volume ID for Redis (default: openstudio-redis)
#   --csi-topology-key <key>  Topology segment key to resolve node UUID
#                             (default: topology.hostpath.csi/node)
#   --auto-remediate          Re-run preflight-storage.sh --rebind-stale --emit-topology-vars
#                             and print the updated var overrides when drift is detected.
#                             Does NOT automatically redeploy — operator must apply the output.
#   --quiet                   Suppress informational output; only print warnings/errors.
#
# Exit codes:
#   0  No drift detected (or storage_type != csi — nothing to check).
#   1  Drift detected (pinned node IDs do not match the current CSI volume topology).
#   2  Invalid arguments or required tools missing.
#   3  Unable to inspect job or volume (Nomad unreachable or job not found).
#
# Environment:
#   NOMAD_ADDR          Nomad API address
#   NOMAD_NAMESPACE     Nomad namespace
#   NOMAD_TOKEN         Nomad ACL token (if ACLs are enabled)
#
# Examples:
#   # Daily cron — alert on drift
#   ./scripts/check-csi-topology.sh --job-name openstudio-server
#
#   # Detect and print remediation vars (operator applies them manually)
#   ./scripts/check-csi-topology.sh --auto-remediate
#
#   # CI pre-deploy gate
#   ./scripts/check-csi-topology.sh --quiet && echo "Topology OK" || echo "Topology DRIFTED — redeploy required"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
JOB_NAME="openstudio-server"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}"
DB_VOLUME="openstudio-mongodb"
REDIS_VOLUME="openstudio-redis"
CSI_TOPOLOGY_KEY="topology.hostpath.csi/node"
AUTO_REMEDIATE=false
QUIET=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --job-name)         JOB_NAME="$2";         shift 2 ;;
    --nomad-addr)       NOMAD_ADDR="$2";        shift 2 ;;
    --namespace)        NOMAD_NAMESPACE="$2";   shift 2 ;;
    --db-volume)        DB_VOLUME="$2";         shift 2 ;;
    --redis-volume)     REDIS_VOLUME="$2";      shift 2 ;;
    --csi-topology-key) CSI_TOPOLOGY_KEY="$2";  shift 2 ;;
    --auto-remediate)   AUTO_REMEDIATE=true;    shift ;;
    --quiet)            QUIET=true;             shift ;;
    --help|-h)
      sed -n '2,/^set -euo/{ /^set -euo/d; s/^# \{0,1\}//; p }' "$0"
      exit 0
      ;;
    *)
      echo "check-csi-topology: unknown argument: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { [ "${QUIET}" = "true" ] || echo "  $*"; }
warn()  { echo "⚠ [check-csi-topology] $*" >&2; }
error() { echo "✗ [check-csi-topology] $*" >&2; }

_require() {
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      error "Required tool not found: ${cmd}"
      exit 2
    fi
  done
}

_require nomad jq

# ── Extract pinned node ID from a running Nomad job spec ─────────────────────
# Returns the value of the `unique.id` node constraint from the named task group,
# or empty string if no such constraint is present.
_pinned_node_from_job() {
  local job_id="$1"
  local group_name="$2"   # "db" or "redis"

  local job_json
  job_json="$(
    NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" \
      nomad job inspect "${job_id}" 2>/dev/null
  )" || { echo ""; return 0; }

  # Find the task group, then locate a Constraint with LTarget == "${node.unique.id}"
  echo "${job_json}" | jq -r --arg grp "${group_name}" '
    .Job.TaskGroups[]?
    | select(.Name == $grp)
    | .Constraints[]?
    | select(.LTarget == "${node.unique.id}")
    | .RTarget
  ' 2>/dev/null | head -1 || echo ""
}

# ── Extract current CSI volume topology node ID ───────────────────────────────
# Returns the node UUID from the volume's Topologies list, or empty string.
_volume_topology_node_id() {
  local volume_id="$1"
  local topo_key="$2"

  local vol_json
  vol_json="$(
    NOMAD_ADDR="${NOMAD_ADDR}" NOMAD_NAMESPACE="${NOMAD_NAMESPACE}" \
      nomad volume status -json "${volume_id}" 2>/dev/null
  )" || { echo ""; return 0; }

  # Topologies is a list of segment maps: [{"Segments": {"key": "value"}}]
  # Pick the first entry matching the topology key.
  local node_id
  node_id="$(echo "${vol_json}" | jq -r --arg key "${topo_key}" '
    .Topologies[]?
    | .Segments[$key]?
    | select(. != null and . != "")
  ' 2>/dev/null | head -1 || echo "")"

  # Validate: must look like a 36-char UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
  if [[ "${node_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    echo "${node_id}"
  else
    echo ""
  fi
}

# ── Per-volume drift check ────────────────────────────────────────────────────
# Returns 0 (no drift) or 1 (drift detected).
_check_volume() {
  local label="$1"         # "db" or "redis"
  local job_id="$2"        # e.g. "openstudio-server-db"
  local group_name="$3"    # task group name inside the job
  local volume_id="$4"     # CSI volume ID

  info "Checking ${label} topology pin (job=${job_id}, volume=${volume_id}) ..."

  local pinned_node volume_node

  pinned_node="$(_pinned_node_from_job "${job_id}" "${group_name}")"
  volume_node="$(_volume_topology_node_id "${volume_id}" "${CSI_TOPOLOGY_KEY}")"

  if [ -z "${pinned_node}" ] && [ -z "${volume_node}" ]; then
    info "  No CSI topology pin found for ${label} — skipping (not a pinned CSI deployment)."
    return 0
  fi

  if [ -z "${pinned_node}" ]; then
    info "  No topology constraint found in job ${job_id} for group '${group_name}'."
    info "  CSI volume topology node: ${volume_node}"
    info "  (Not pinned — no drift to detect.)"
    return 0
  fi

  if [ -z "${volume_node}" ]; then
    warn "${label} job is pinned to node ${pinned_node} but CSI volume '${volume_id}' has no topology information."
    warn "  The volume may not yet be accessible or the topology key '${CSI_TOPOLOGY_KEY}' is wrong."
    warn "  Run: nomad volume status -json ${volume_id} | jq '.Topologies'"
    return 1
  fi

  if [ "${pinned_node}" = "${volume_node}" ]; then
    info "  ✓ ${label} topology pin matches CSI volume topology: ${pinned_node}"
    return 0
  fi

  # Drift detected
  warn "CSI topology DRIFT detected for ${label}:"
  warn "  Job constraint (${job_id} / ${group_name}): node.unique.id = ${pinned_node}"
  warn "  Actual CSI volume topology (${volume_id}):  node.unique.id = ${volume_node}"
  warn "  The node hosting the CSI volume has changed since the last deploy."
  warn "  The ${label} job cannot be scheduled until the constraint is updated."
  warn ""
  warn "  Remediation:"
  warn "    1. Re-run: scripts/preflight-storage.sh --rebind-stale --emit-topology-vars"
  warn "    2. Apply the emitted var overrides to your next nomad-pack deploy."
  warn "  OR: run this script with --auto-remediate to emit the updated vars automatically."
  return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────
[ "${QUIET}" = "true" ] || echo "==> check-csi-topology: checking CSI topology pin alignment ..."
[ "${QUIET}" = "true" ] || echo "    NOMAD_ADDR=${NOMAD_ADDR}  namespace=${NOMAD_NAMESPACE}"
[ "${QUIET}" = "true" ] || echo "    Job prefix: ${JOB_NAME}  topology-key: ${CSI_TOPOLOGY_KEY}"
[ "${QUIET}" = "true" ] || echo ""

DB_JOB="${JOB_NAME}-db"
REDIS_JOB="${JOB_NAME}-redis"

drift_detected=false

# Check DB
if ! _check_volume "db" "${DB_JOB}" "db" "${DB_VOLUME}"; then
  drift_detected=true
fi

# Check Redis
if ! _check_volume "redis" "${REDIS_JOB}" "redis" "${REDIS_VOLUME}"; then
  drift_detected=true
fi

if [ "${drift_detected}" = "true" ]; then
  echo ""
  error "CSI topology drift detected — one or more jobs are pinned to a stale node."

  if [ "${AUTO_REMEDIATE}" = "true" ]; then
    echo ""
    echo "==> --auto-remediate: running preflight-storage.sh --rebind-stale --emit-topology-vars ..."
    echo ""
    # Determine var-file path (use openstack.hcl if it exists, else skip)
    PREFLIGHT_SCRIPT="${SCRIPT_DIR}/preflight-storage.sh"
    if [ ! -x "${PREFLIGHT_SCRIPT}" ]; then
      error "preflight-storage.sh not found or not executable at ${PREFLIGHT_SCRIPT}"
      exit 2
    fi
    OPENSTACK_VAR_FILE="${SCRIPT_DIR}/../examples/advanced/openstack.hcl"
    PREFLIGHT_ARGS=(--rebind-stale --emit-topology-vars
      --nomad-addr "${NOMAD_ADDR}"
      --namespace "${NOMAD_NAMESPACE}"
      --csi-topology-key "${CSI_TOPOLOGY_KEY}")
    if [ -f "${OPENSTACK_VAR_FILE}" ]; then
      PREFLIGHT_ARGS+=(--var-file "${OPENSTACK_VAR_FILE}")
    fi
    echo "--- Updated topology vars (add to your next deploy's -var overrides) ---"
    "${PREFLIGHT_SCRIPT}" "${PREFLIGHT_ARGS[@]}" | grep -E '^(db|redis)_csi_topology_node_id=' || true
    echo "------------------------------------------------------------------------"
    echo ""
    echo "Apply these as -var overrides to your next nomad-pack deploy, for example:"
    echo "  nomad-pack run -var 'db_csi_topology_node_id=<new-uuid>' \\"
    echo "                 -var 'redis_csi_topology_node_id=<new-uuid>' ."
  fi

  exit 1
fi

echo ""
echo "✓ check-csi-topology: all CSI topology pins are aligned."
exit 0
