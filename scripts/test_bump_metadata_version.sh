#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/bump_metadata_version.sh"
FIXTURE="${REPO_ROOT}/tests/fixtures/metadata.sample.hcl"
TEST_FILE="${REPO_ROOT}/tests/fixtures/metadata.sample.test.hcl"

cp "${FIXTURE}" "${TEST_FILE}"

PATCH_VERSION="$("${SCRIPT}" "${TEST_FILE}" patch)"
[[ "${PATCH_VERSION}" == "0.1.1" ]]
grep -Eq 'version[[:space:]]*=[[:space:]]*"0.1.1"' "${TEST_FILE}"

MINOR_VERSION="$("${SCRIPT}" "${TEST_FILE}" minor)"
[[ "${MINOR_VERSION}" == "0.2.0" ]]
grep -Eq 'version[[:space:]]*=[[:space:]]*"0.2.0"' "${TEST_FILE}"

MAJOR_VERSION="$("${SCRIPT}" "${TEST_FILE}" major)"
[[ "${MAJOR_VERSION}" == "1.0.0" ]]
grep -Eq 'version[[:space:]]*=[[:space:]]*"1.0.0"' "${TEST_FILE}"

EXPLICIT_VERSION="$("${SCRIPT}" "${TEST_FILE}" 2.5.3)"
[[ "${EXPLICIT_VERSION}" == "2.5.3" ]]
grep -Eq 'version[[:space:]]*=[[:space:]]*"2.5.3"' "${TEST_FILE}"

rm -f "${TEST_FILE}"
echo "Version bump script tests passed"
