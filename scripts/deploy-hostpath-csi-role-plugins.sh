#!/usr/bin/env bash
set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}"
DATACENTERS="${DATACENTERS:-dc1}"
HOSTPATH_IMAGE="${HOSTPATH_IMAGE:-pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/sig-storage/hostpathplugin:v1.9.0}"

WEB_JOB_NAME="${WEB_JOB_NAME:-csi-plugin-hostpath-web}"
WORKER_JOB_NAME="${WORKER_JOB_NAME:-csi-plugin-hostpath-worker}"
STATEFUL_JOB_NAME="${STATEFUL_JOB_NAME:-csi-plugin-hostpath-stateful}"

WEB_PLUGIN_ID="${WEB_PLUGIN_ID:-hostpath-web-plugin0}"
WORKER_PLUGIN_ID="${WORKER_PLUGIN_ID:-hostpath-worker-plugin0}"
STATEFUL_PLUGIN_ID="${STATEFUL_PLUGIN_ID:-}"

WEB_NODE_ROLE="${WEB_NODE_ROLE:-web}"
WORKER_NODE_ROLE="${WORKER_NODE_ROLE:-worker}"
STATEFUL_NODE_ROLE="${STATEFUL_NODE_ROLE:-stateful}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Deploys role-scoped hostpath CSI plugin system jobs:
  - ${WEB_JOB_NAME}     -> plugin ID ${WEB_PLUGIN_ID} (node_role=${WEB_NODE_ROLE})
  - ${WORKER_JOB_NAME}  -> plugin ID ${WORKER_PLUGIN_ID} (node_role=${WORKER_NODE_ROLE})
  - ${STATEFUL_JOB_NAME} -> plugin ID ${STATEFUL_PLUGIN_ID} (node_role=${STATEFUL_NODE_ROLE}) [optional]

Environment overrides:
  NOMAD_ADDR, NOMAD_NAMESPACE, DATACENTERS
  HOSTPATH_IMAGE
  WEB_JOB_NAME, WORKER_JOB_NAME, STATEFUL_JOB_NAME
  WEB_PLUGIN_ID, WORKER_PLUGIN_ID, STATEFUL_PLUGIN_ID
  WEB_NODE_ROLE, WORKER_NODE_ROLE, STATEFUL_NODE_ROLE
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

render_and_run() {
  local job_name="$1"
  local plugin_id="$2"
  local node_role="$3"
  local spec
  spec="$(mktemp)"

  cat > "${spec}" <<EOF
job "${job_name}" {
  region      = "global"
  datacenters = ["${DATACENTERS}"]
  namespace   = "${NOMAD_NAMESPACE}"
  type        = "system"
  priority    = 70

  group "csi" {
    constraint {
      attribute = "\${meta.node_role}"
      operator  = "="
      value     = "${node_role}"
    }

    constraint {
      attribute = "\${attr.driver.docker}"
      operator  = "="
      value     = "1"
    }

    restart {
      attempts = 2
      interval = "30m"
      delay    = "15s"
      mode     = "fail"
    }

    task "plugin" {
      driver = "docker"

      csi_plugin {
        id        = "${plugin_id}"
        type      = "monolith"
        mount_dir = "/csi"
      }

      config {
        image      = "${HOSTPATH_IMAGE}"
        privileged = true
        args = [
          "--drivername=csi-hostpath",
          "--v=5",
          "--endpoint=\${CSI_ENDPOINT}",
          "--nodeid=\${node.unique.id}"
        ]
      }

      resources {
        cpu    = 256
        memory = 256
      }
    }
  }
}
EOF

  # System jobs may report exit 2 ("failed to place all allocations") when some
  # nodes no longer match the constraint (e.g. a node was re-labeled).  This is
  # expected and harmless — wait_for_csi_plugin_ready validates actual health.
  NOMAD_ADDR="${NOMAD_ADDR}" nomad job run "${spec}" >/dev/null || true
  rm -f "${spec}"
}

echo "==> Deploying role-scoped hostpath CSI plugins"
echo "  Nomad:   ${NOMAD_ADDR} (ns=${NOMAD_NAMESPACE})"
echo "  Web:     ${WEB_JOB_NAME} -> ${WEB_PLUGIN_ID} (node_role=${WEB_NODE_ROLE})"
echo "  Worker:  ${WORKER_JOB_NAME} -> ${WORKER_PLUGIN_ID} (node_role=${WORKER_NODE_ROLE})"
if [[ -n "${STATEFUL_PLUGIN_ID}" ]]; then
  echo "  Stateful:${STATEFUL_JOB_NAME} -> ${STATEFUL_PLUGIN_ID} (node_role=${STATEFUL_NODE_ROLE})"
fi

render_and_run "${WEB_JOB_NAME}" "${WEB_PLUGIN_ID}" "${WEB_NODE_ROLE}"
render_and_run "${WORKER_JOB_NAME}" "${WORKER_PLUGIN_ID}" "${WORKER_NODE_ROLE}"
if [[ -n "${STATEFUL_PLUGIN_ID}" ]]; then
  render_and_run "${STATEFUL_JOB_NAME}" "${STATEFUL_PLUGIN_ID}" "${STATEFUL_NODE_ROLE}"
fi

echo ""
echo "==> CSI plugin status"
NOMAD_ADDR="${NOMAD_ADDR}" nomad plugin status -type csi
