#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_ROOT="${REPO_ROOT}/packs/openstudio-server/templates"
PATTERN='\$\{[^}]*:[^}]*\}'

echo "Scanning Nomad templates for shell parameter expansions that can conflict with HCL heredocs..."

if matches=$(grep -RInE "${PATTERN}" "${TEMPLATE_ROOT}"); then
  echo "::warning::Possible HCL/shell interpolation conflict detected. Review any \${...:...} usage inside template heredocs before merge."
  printf '%s\n' "${matches}"
else
  echo "OK: No likely HCL heredoc interpolation conflicts found in ${TEMPLATE_ROOT}."
fi
