#!/usr/bin/env bash
# DEPRECATED: This shell integration test script has been migrated to Terratest Go tests
# in tests/terratest/integration_test.go.
# This script remains as a lightweight wrapper calling `go test` for backwards compatibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Running Terratest integration suite..."
cd "${REPO_ROOT}/tests/terratest"
go test -v ./...

echo "Nomad pack integration scenarios completed successfully."
