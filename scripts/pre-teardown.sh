#!/usr/bin/env bash
# scripts/pre-teardown.sh
#
# Pre-teardown helper for OpenStudio Server on Nomad.
#
# PURPOSE
# -------
# Stop the stateless Nomad jobs (web and rserve) before running
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
#   ./scripts/pre-teardown.sh [JOB_NAME]
#
#   JOB_NAME  Base job name prefix (default: openstudio-server).
#             The script stops <JOB_NAME>-web and <JOB_NAME>-rserve.
#
# EXAMPLE
# -------
#   ./scripts/pre-teardown.sh
#   ./scripts/pre-teardown.sh my-custom-job-name
#
# After this script completes successfully, run:
#   nomad-pack destroy .

set -euo pipefail

JOB_NAME="${1:-openstudio-server}"

echo "==> Stopping Nomad jobs for pack '${JOB_NAME}' ..."
echo "    (nomad job stop blocks until all allocations are dead — no sleep required)"
echo ""

echo "--> Stopping ${JOB_NAME}-web ..."
if ! nomad job stop "${JOB_NAME}-web"; then
  echo "ERROR: Failed to stop job '${JOB_NAME}-web'. Aborting." >&2
  exit 1
fi
echo "    ${JOB_NAME}-web: all allocations dead."

echo ""
echo "--> Stopping ${JOB_NAME}-rserve ..."
if ! nomad job stop "${JOB_NAME}-rserve"; then
  echo "ERROR: Failed to stop job '${JOB_NAME}-rserve'. Aborting." >&2
  exit 1
fi
echo "    ${JOB_NAME}-rserve: all allocations dead."

echo ""
echo "==> All target jobs stopped successfully."
echo ""
echo "Next step — destroy the full pack (removes remaining jobs and Nomad state):"
echo ""
echo "    nomad-pack destroy ."
echo ""
