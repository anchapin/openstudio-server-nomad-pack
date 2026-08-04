#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK_PATH="${REPO_ROOT}"
PROD_VARS="${REPO_ROOT}/examples/advanced/openstack-production.hcl"
LEGACY_VARS="${REPO_ROOT}/examples/advanced/openstack.hcl"

if [ ! -f "${PROD_VARS}" ] || [ ! -f "${LEGACY_VARS}" ]; then
  echo "ERROR: expected OpenStack var-files are missing."
  exit 1
fi

TMP_RENDER="$(mktemp)"
trap 'rm -f "${TMP_RENDER}"' EXIT

nomad-pack render --name openstudio-server \
  --var-file "${PROD_VARS}" \
  "${PACK_PATH}" > "${TMP_RENDER}"

AUTOSCALER_SPEC="$(mktemp)"
WORKER_SCALING_SPEC="$(mktemp)"
trap 'rm -f "${TMP_RENDER}" "${AUTOSCALER_SPEC}" "${WORKER_SCALING_SPEC}"' EXIT

awk '/^openstudio-server\/nomad-autoscaler\.nomad:/{flag=1;next}/^openstudio-server\/.*\.nomad:/{if(flag)exit}flag' "${TMP_RENDER}" > "${AUTOSCALER_SPEC}"
# Worker task group scaling config now lives in web.nomad (consolidated in #405)
awk '/^openstudio-server\/web\.nomad:/{flag=1;next}/^openstudio-server\/.*\.nomad:/{if(flag)exit}flag' "${TMP_RENDER}" > "${WORKER_SCALING_SPEC}"

if ! grep -q 'health_check      = "task_states"' "${AUTOSCALER_SPEC}"; then
  echo "ERROR: autoscaler job must use update.health_check = \"task_states\"."
  exit 1
fi

if ! grep -q 'affinity {' "${AUTOSCALER_SPEC}" || ! grep -q '\${meta.node_role}' "${AUTOSCALER_SPEC}"; then
  echo "ERROR: autoscaler job should prefer web-role nodes via affinity."
  exit 1
fi

if grep -q 'prometheus_address = "http://127.0.0.1:9090"' "${WORKER_SCALING_SPEC}"; then
  echo "ERROR: worker autoscaling must not default to localhost Prometheus in OpenStack production render."
  exit 1
fi

if ! grep -Fq 'max_over_time(redis_key_size{key=\"resque:queue:requeued\"}[1m])' "${WORKER_SCALING_SPEC}"; then
  echo "ERROR: requeued queue query is not rendered in safe selector form."
  exit 1
fi

if ! grep -Fq 'max_over_time(redis_key_size{key=\"resque:queue:simulations\"}[1m])' "${WORKER_SCALING_SPEC}"; then
  echo "ERROR: simulations queue query is not rendered in safe selector form."
  exit 1
fi

if grep -q 'max_over_time((sum(redis_key_size' "${WORKER_SCALING_SPEC}"; then
  echo "ERROR: invalid nested PromQL form detected: max_over_time((sum(...))[window])."
  exit 1
fi

nomad-pack render --name openstudio-server \
  --var-file "${LEGACY_VARS}" \
  "${PACK_PATH}" > "${TMP_RENDER}"

# Worker scaling config is now in web.nomad post-consolidation (#405)
awk '/^openstudio-server\/web\.nomad:/{flag=1;next}/^openstudio-server\/.*\.nomad:/{if(flag)exit}flag' "${TMP_RENDER}" > "${WORKER_SCALING_SPEC}"

if grep -q 'prometheus_address = "http://127.0.0.1:9090"' "${WORKER_SCALING_SPEC}"; then
  echo "ERROR: legacy OpenStack profile must not hardcode localhost Prometheus."
  exit 1
fi

if grep -q 'max_over_time((sum(redis_key_size' "${WORKER_SCALING_SPEC}"; then
  echo "ERROR: legacy OpenStack profile renders an invalid nested PromQL queue query."
  exit 1
fi

echo "OpenStack autoscaler render checks passed."
