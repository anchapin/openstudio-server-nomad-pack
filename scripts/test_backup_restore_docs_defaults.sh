#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIABLES_FILE="${REPO_ROOT}/variables.hcl"

backup_default="$(
  awk '
    /variable "backup_enabled"/ { in_block=1; next }
    in_block && /default/ { print $3; exit }
  ' "${VARIABLES_FILE}"
)"

restore_default="$(
  awk '
    /variable "restore_enabled"/ { in_block=1; next }
    in_block && /default/ { print $3; exit }
  ' "${VARIABLES_FILE}"
)"

if [[ -z "${backup_default}" || -z "${restore_default}" ]]; then
  echo "ERROR: could not parse backup/restore defaults from variables.hcl"
  exit 1
fi

if [[ "${backup_default}" == "true" ]]; then
  backup_inverse="false"
else
  backup_inverse="true"
fi

if [[ "${restore_default}" == "true" ]]; then
  restore_inverse="false"
else
  restore_inverse="true"
fi

DOC_FILES=(
  "${REPO_ROOT}/README.md"
  "${REPO_ROOT}/AGENTS.md"
  "${REPO_ROOT}/.github/copilot-instructions.md"
)

for doc in "${DOC_FILES[@]}"; do
  if ! grep -q "backup_enabled = ${backup_default}" "${doc}"; then
    echo "ERROR: ${doc} is missing backup_enabled = ${backup_default}"
    exit 1
  fi
  if awk -v inverse="${backup_inverse}" '
    BEGIN { found=0 }
    {
      line=tolower($0)
      if (line ~ "backup_enabled = " inverse && line ~ /default/ && line !~ /enable/) {
        found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${doc}"; then
    echo "ERROR: ${doc} contains stale backup_enabled default value (${backup_inverse})"
    exit 1
  fi

  if ! grep -q "restore_enabled = ${restore_default}" "${doc}"; then
    echo "ERROR: ${doc} is missing restore_enabled = ${restore_default}"
    exit 1
  fi
  if awk -v inverse="${restore_inverse}" '
    BEGIN { found=0 }
    {
      line=tolower($0)
      if (line ~ "restore_enabled = " inverse && line ~ /default/ && line !~ /enable/) {
        found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${doc}"; then
    echo "ERROR: ${doc} contains stale restore_enabled default value (${restore_inverse})"
    exit 1
  fi
done

echo "backup/restore default docs check passed"
