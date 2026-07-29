#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/release-version-bump.yml"

grep -qE 'name:[[:space:]]+Sync registry metadata' "${WORKFLOW_FILE}"
grep -qE 'cp[[:space:]]+metadata\.hcl[[:space:]]+packs/openstudio-server/metadata\.hcl' "${WORKFLOW_FILE}"
grep -qE 'git add[[:space:]]+metadata\.hcl[[:space:]]+packs/openstudio-server/metadata\.hcl' "${WORKFLOW_FILE}"

echo "Release version bump workflow sync checks passed"
