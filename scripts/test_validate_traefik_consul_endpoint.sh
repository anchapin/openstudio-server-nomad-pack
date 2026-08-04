#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/validate-traefik-consul-endpoint.sh"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

cat > "${TMP_DIR}/valid.yml" <<'EOF'
providers:
  consulCatalog:
    endpoint:
      address: "127.0.0.1:8500"
    exposedByDefault: false
EOF

cat > "${TMP_DIR}/invalid-scheme.yml" <<'EOF'
providers:
  consulCatalog:
    endpoint:
      address: "http://127.0.0.1:8500"
EOF

cat > "${TMP_DIR}/invalid-format.yml" <<'EOF'
providers:
  consulCatalog:
    endpoint:
      address: "consul.service.consul"
EOF

"${SCRIPT}" "${TMP_DIR}/valid.yml" >/dev/null

if "${SCRIPT}" "${TMP_DIR}/invalid-scheme.yml" >/dev/null 2>&1; then
  echo "Expected invalid-scheme.yml to fail"
  exit 1
fi

if "${SCRIPT}" "${TMP_DIR}/invalid-format.yml" >/dev/null 2>&1; then
  echo "Expected invalid-format.yml to fail"
  exit 1
fi

echo "validate-traefik-consul-endpoint tests passed"
