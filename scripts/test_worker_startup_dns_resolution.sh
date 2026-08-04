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

assert_contains "${worker_spec}" 'http://${CONSUL_ADDR}/v1/catalog/service/${service}' "worker runtime aliasing uses the Consul catalog API"
assert_contains "${worker_spec}" 'resolve_alias "openstudio-db" "db"' "worker runtime aliasing resolves openstudio-db"
assert_contains "${worker_spec}" 'resolve_alias "openstudio-redis" "queue"' "worker runtime aliasing resolves openstudio-redis"
assert_contains "${worker_spec}" 'resolve_alias "openstudio-rserve" "rserve"' "worker runtime aliasing resolves openstudio-rserve"

assert_not_contains "${worker_spec}" 'getent hosts' "worker runtime aliasing does not fall back to system-resolver-only getent hosts"
assert_not_contains "${worker_spec}" '.service.consul' "worker runtime aliasing does not depend on direct Consul DNS host lookups"

echo "Worker startup DNS/service resolution checks passed."
