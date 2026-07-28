#!/usr/bin/env bash
set -euo pipefail

PACK_PATH="${1:-.}"

supports_pack_run_dry_run() {
  nomad-pack run --help | grep -q -- "--dry-run"
}

run_integration_case() {
  local scenario="$1"
  shift
  local args=("$@")

  echo "==> Running scenario: ${scenario}"
  nomad-pack render "${PACK_PATH}" "${args[@]}"

  if supports_pack_run_dry_run; then
    nomad-pack run --dry-run "${PACK_PATH}" "${args[@]}"
  else
    nomad-pack plan "${PACK_PATH}" --diff=false --exit-code-makes-changes=0 "${args[@]}"
  fi
}

run_integration_case "default"
run_integration_case "vector-disabled" --var "enable_vector_collection=false"
run_integration_case "custom-images" \
  --var "web_image=nrel/openstudio-server:3.7.0" \
  --var "worker_image=nrel/openstudio-server:3.7.0" \
  --var "rserve_image=nrel/rserve:3.7.0"

echo "Nomad pack integration scenarios completed successfully."
