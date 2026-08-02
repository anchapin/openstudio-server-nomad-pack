#!/usr/bin/env bash
set -euo pipefail

DOC_PATH="${1:-docs/infrastructure/migration-k8s-to-nomad.md}"

if [ ! -f "${DOC_PATH}" ]; then
  echo "ERROR: ${DOC_PATH} not found."
  exit 1
fi

if grep -qE 'worker_autoscaling_(min|max)' "${DOC_PATH}"; then
  echo "ERROR: ${DOC_PATH} references nonexistent variables worker_autoscaling_min/max."
  exit 1
fi

if ! grep -qF 'worker_min_replicas' "${DOC_PATH}"; then
  echo "ERROR: ${DOC_PATH} is missing worker_min_replicas in Helm mapping."
  exit 1
fi

if ! grep -qF 'worker_max_replicas' "${DOC_PATH}"; then
  echo "ERROR: ${DOC_PATH} is missing worker_max_replicas in Helm mapping."
  exit 1
fi

if ! grep -qF 'worker_autoscaling_enabled = true' "${DOC_PATH}"; then
  echo "ERROR: ${DOC_PATH} must note worker_autoscaling_enabled = true for autoscaling bounds."
  exit 1
fi

echo "Migration doc autoscaling variable mapping checks passed."
