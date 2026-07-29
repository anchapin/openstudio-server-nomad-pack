#!/usr/bin/env bash
# scripts/pre-teardown.sh
#
# Pre-teardown helper for OpenStudio Server on Nomad.
#
# PURPOSE
# -------
# Stop Nomad jobs in teardown-safe order before running
# `nomad-pack destroy .` to ensure all allocations are fully dead before
# any downstream cleanup (e.g., NFS unmount, volume deletion).
#
# WHY NO SLEEP?
# -------------
# The Helm chart's hooks/pre-delete-hook.yaml runs:
#
#   kubectl delete deployment web web-background rserve && sleep 60
#
# The `sleep 60` is a workaround for Kubernetes' non-deterministic pod
# drain timing — there is no built-in blocking primitive that guarantees
# all pods are dead before the hook exits.
#
# `nomad job stop` is deterministic: it blocks until every allocation
# belonging to the job reaches a terminal state (dead/failed/complete).
# No sleep is needed; this script is safe to run immediately before
# NFS teardown or volume cleanup.
#
# USAGE
# -----
#   ./scripts/pre-teardown.sh [--namespace <ns>] [-n <ns>] [JOB_NAME]
#
#   --namespace, -n  Nomad namespace containing the jobs (default: "default").
#                    Falls back to the NOMAD_NAMESPACE environment variable
#                    when the flag is not provided.
#
#   JOB_NAME         Base job name prefix (default: openstudio-server).
#                    The script stops:
#                      - <JOB_NAME>-worker
#                      - <JOB_NAME>-web
#                      - <JOB_NAME>-rserve
#                      - <JOB_NAME>-db
#                      - <JOB_NAME>-redis
#                      - <JOB_NAME>-system-hooks (global system job)
#                    It also stops optional jobs when present:
#                      - <JOB_NAME>-state-backup
#                      - <JOB_NAME>-nomad-autoscaler
#                      - <JOB_NAME>-autoscaler (legacy name)
#
# ENVIRONMENT
# -----------
#   NOMAD_NAMESPACE  Nomad namespace to use when --namespace is not passed.
#                    Defaults to "default" if neither the flag nor this
#                    variable is set.
#
# EXAMPLE
# -------
#   # Default namespace
#   ./scripts/pre-teardown.sh
#
#   # Custom namespace via flag
#   ./scripts/pre-teardown.sh --namespace openstudio
#
#   # Custom namespace via environment variable
#   NOMAD_NAMESPACE=openstudio ./scripts/pre-teardown.sh
#
#   # Custom job name and namespace
#   ./scripts/pre-teardown.sh --namespace openstudio my-custom-job-name
#
# After this script completes successfully, run:
#   nomad-pack destroy .

set -euo pipefail

usage() {
  sed -n '/^# USAGE/,/^# After this script/p' "$0" | sed 's/^# \?//'
  exit 0
}

# Parse arguments
NAMESPACE="${NOMAD_NAMESPACE:-default}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace|-n)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --namespace requires a value." >&2
        exit 1
      fi
      NAMESPACE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    -*)
      echo "ERROR: Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

JOB_NAME="${1:-openstudio-server}"

echo "==> Stopping Nomad jobs for pack '${JOB_NAME}' in namespace '${NAMESPACE}' ..."
echo "    (nomad job stop blocks until all allocations are dead — no sleep required)"
echo ""

stop_required_job() {
  local job_name="$1"
  shift
  local stop_args=("$@")

  echo "--> Stopping ${job_name} ..."
  if ! nomad job stop "${stop_args[@]}" -namespace "${NAMESPACE}" "${job_name}"; then
    echo "ERROR: Failed to stop job '${job_name}'. Aborting." >&2
    exit 1
  fi
  echo "    ${job_name}: all allocations dead."
}

stop_optional_job() {
  local job_name="$1"
  shift
  local stop_args=("$@")

  if ! nomad job status -namespace "${NAMESPACE}" "${job_name}" >/dev/null 2>&1; then
    echo "--> Skipping ${job_name} (not found in namespace '${NAMESPACE}')."
    return 0
  fi

  echo "--> Stopping optional job ${job_name} ..."
  if ! nomad job stop "${stop_args[@]}" -namespace "${NAMESPACE}" "${job_name}"; then
    echo "ERROR: Failed to stop optional job '${job_name}'." >&2
    exit 1
  fi
  echo "    ${job_name}: all allocations dead."
}

echo "--> Stopping ${JOB_NAME}-worker ..."
echo "    Note: this may take up to worker_kill_timeout seconds for in-flight simulations to drain."
if ! nomad job stop -namespace "${NAMESPACE}" "${JOB_NAME}-worker"; then
  echo "ERROR: Failed to stop job '${JOB_NAME}-worker'. Aborting." >&2
  exit 1
fi
echo "    ${JOB_NAME}-worker: all allocations dead."

echo ""
stop_required_job "${JOB_NAME}-web"

echo ""
stop_required_job "${JOB_NAME}-rserve"

echo ""
stop_required_job "${JOB_NAME}-db"

echo ""
stop_required_job "${JOB_NAME}-redis"

echo ""
stop_required_job "${JOB_NAME}-system-hooks" -global

echo ""
stop_optional_job "${JOB_NAME}-state-backup"

echo ""
# Stop both the current and legacy autoscaler job names.
stop_optional_job "${JOB_NAME}-nomad-autoscaler"
stop_optional_job "${JOB_NAME}-autoscaler"

echo ""
echo "==> All target jobs stopped successfully."
echo ""
echo "Next step — destroy the full pack (removes remaining jobs and Nomad state):"
echo ""
echo "    nomad-pack destroy ."
echo ""
