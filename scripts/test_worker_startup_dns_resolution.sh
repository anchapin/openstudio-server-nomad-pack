#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACK_PATH="${REPO_ROOT}/packs/openstudio-server"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if ! grep -Fq "$needle" <<<"${haystack}"; then
    fail "${message}"
  fi
  echo "OK: ${message}"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if grep -Fq "$needle" <<<"${haystack}"; then
    fail "${message}"
  fi
  echo "OK: ${message}"
}

rendered="$(nomad-pack render "${PACK_PATH}")" || fail "nomad-pack render failed for ${PACK_PATH}"

worker_spec="$(
  printf '%s\n' "${rendered}" | awk '
    /^openstudio-server\/worker\.nomad:/ { flag=1; next }
    /^openstudio-server\/.*\.nomad:/ { if (flag) exit }
    flag { print }
  '
)"

[ -n "${worker_spec}" ] || fail "Rendered worker.nomad output was empty or missing."

assert_contains "${worker_spec}" 'task "wait-for-deps"' "worker renders the wait-for-deps prestart task"
assert_contains "${worker_spec}" 'http://$CONSUL_ADDR/v1/health/service/$service?passing=true' "worker prestart polls the Consul health API"
assert_contains "${worker_spec}" 'check_service "openstudio-db"' "worker prestart checks openstudio-db health"
assert_contains "${worker_spec}" 'check_service "openstudio-redis"' "worker prestart checks openstudio-redis health"

assert_contains "${worker_spec}" '{{ range $svc := service "openstudio-db" }}{{ $svc.Address }} db' "worker runtime aliasing renders openstudio-db from Consul"
assert_contains "${worker_spec}" '{{ range $svc := service "openstudio-redis" }}{{ $svc.Address }} queue' "worker runtime aliasing renders openstudio-redis from Consul"
assert_contains "${worker_spec}" '{{ range $svc := service "openstudio-rserve" }}{{ $svc.Address }} rserve' "worker runtime aliasing renders openstudio-rserve from Consul"
assert_contains "${worker_spec}" 'worker_runtime_service_hosts_applied source=consul_template' "worker runtime aliasing applies rendered Consul aliases"

assert_not_contains "${worker_spec}" "command -v getent" "worker runtime aliasing does not probe the system resolver with getent"
assert_not_contains "${worker_spec}" '$(getent hosts' "worker runtime aliasing does not shell out to getent hosts"
assert_not_contains "${worker_spec}" 'http://${CONSUL_ADDR}/v1/catalog/service/${service}' "worker runtime aliasing no longer shells out to the Consul catalog API"

echo "Worker startup DNS/service resolution checks passed."
