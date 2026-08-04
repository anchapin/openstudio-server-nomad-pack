#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/release-version-bump.yml"

grep -qE 'bump_metadata_version\.sh[[:space:]]+packs/openstudio-server/metadata\.hcl[[:space:]]+patch' "${WORKFLOW_FILE}"
grep -qE 'git add[[:space:]]+packs/openstudio-server/metadata\.hcl' "${WORKFLOW_FILE}"

echo "Release version bump workflow sync checks passed"
