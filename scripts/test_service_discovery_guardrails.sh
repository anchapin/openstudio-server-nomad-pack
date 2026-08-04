#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACK_PATH="${REPO_ROOT}/packs/openstudio-server"
WEB_TEMPLATE="${PACK_PATH}/templates/web.nomad.tpl"
WORKER_TEMPLATE="${PACK_PATH}/templates/worker.nomad.tpl"
HELPERS_TEMPLATE="${PACK_PATH}/templates/_helpers.tpl"
TEST_TEMPLATE="${PACK_PATH}/templates/openstudio_test.nomad.tpl"

for template in "${WEB_TEMPLATE}" "${WORKER_TEMPLATE}"; do
  if grep -nE '\{\{\s*range service\s+' "${template}" >/dev/null; then
    echo "ERROR: disallowed Consul-template service watch aliasing found in ${template}."
    exit 1
  fi
done

if grep -nE 'left_delimiter\s*=\s*"\{\{"|right_delimiter\s*=\s*"\}\}"' "${WEB_TEMPLATE}" "${WORKER_TEMPLATE}" >/dev/null; then
  echo "ERROR: legacy template delimiter overrides found in web/worker runtime host patch stanzas."
  exit 1
fi

if grep -nE '\$\{[^}]*@P\}|\$\{![^}]+\}' "${HELPERS_TEMPLATE}" "${WEB_TEMPLATE}" "${WORKER_TEMPLATE}" "${TEST_TEMPLATE}" >/dev/null; then
  echo "ERROR: unsafe shell interpolation pattern detected in startup helper scripts."
  exit 1
fi

TMP_RENDER="$(mktemp)"
TMP_RENDER_CANARY="$(mktemp)"
WEB_SPEC="$(mktemp)"
WORKER_SPEC="$(mktemp)"
TEST_SPEC="$(mktemp)"
trap 'rm -f "${TMP_RENDER}" "${TMP_RENDER_CANARY}" "${WEB_SPEC}" "${WORKER_SPEC}" "${TEST_SPEC}"' EXIT

nomad-pack render "${PACK_PATH}" > "${TMP_RENDER}"

awk '/^openstudio-server\/web\.nomad:/{flag=1;next}/^openstudio-server\/.*\.nomad:/{if(flag)exit}flag' "${TMP_RENDER}" > "${WEB_SPEC}"
awk '/^openstudio-server\/worker\.nomad:/{flag=1;next}/^openstudio-server\/.*\.nomad:/{if(flag)exit}flag' "${TMP_RENDER}" > "${WORKER_SPEC}"

for spec in "${WEB_SPEC}" "${WORKER_SPEC}"; do
  if ! grep -q 'wait_for_deps_timeout' "${spec}"; then
    echo "ERROR: rendered spec is missing bounded wait_for_deps timeout logging: ${spec}"
    exit 1
  fi
  if ! grep -q 'MAX_ATTEMPTS=' "${spec}"; then
    echo "ERROR: rendered spec is missing bounded retry budget for startup scripts: ${spec}"
    exit 1
  fi
done

if ! grep -q 'runtime_resolution_disabled legacy_template_watch_mode_removed=true' "${WEB_SPEC}"; then
  echo "ERROR: web runtime resolver guardrail marker is missing."
  exit 1
fi

if ! grep -q 'runtime_resolution_disabled legacy_template_watch_mode_removed=true' "${WORKER_SPEC}"; then
  echo "ERROR: worker runtime resolver guardrail marker is missing."
  exit 1
fi

nomad-pack render --var "enable_runtime_discovery_canary_test=true" "${PACK_PATH}" > "${TMP_RENDER_CANARY}"
awk '/^openstudio-server\/openstudio_test\.nomad:/{flag=1;next}/^openstudio-server\/.*\.nomad:/{if(flag)exit}flag' "${TMP_RENDER_CANARY}" > "${TEST_SPEC}"

if ! grep -q 'task "runtime-discovery-canary"' "${TEST_SPEC}"; then
  echo "ERROR: runtime discovery canary task did not render when enabled."
  exit 1
fi

if ! grep -q 'runtime_discovery_canary_alias_failed' "${TEST_SPEC}"; then
  echo "ERROR: runtime discovery canary script is missing explicit failure marker."
  exit 1
fi

echo "Service discovery guardrail checks passed."
