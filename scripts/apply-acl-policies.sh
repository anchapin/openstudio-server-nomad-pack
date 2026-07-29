#!/usr/bin/env bash
# apply-acl-policies.sh — Apply Nomad ACL policies for the OpenStudio Server pack.
#
# This script substitutes the correct namespace into all policy files and
# applies them to the cluster in one step.
#
# Usage:
#   bash scripts/apply-acl-policies.sh [OPTIONS]
#
# Options:
#   -n, --namespace NS    Nomad namespace to target (default: "default")
#   -r, --roles ROLES     Comma-separated list of roles to apply
#                         (default: "operator,readonly,cicd,teardown")
#   --dry-run             Print the substituted policy HCL without applying
#   -h, --help            Show this help message
#
# Examples:
#   # Apply all policies for the default namespace
#   bash scripts/apply-acl-policies.sh --namespace default
#
#   # Apply all policies for a custom namespace
#   bash scripts/apply-acl-policies.sh --namespace openstudio
#
#   # Apply only the operator and cicd policies
#   bash scripts/apply-acl-policies.sh --namespace default --roles operator,cicd
#
#   # Preview the substituted HCL without applying
#   bash scripts/apply-acl-policies.sh --namespace myns --dry-run

set -euo pipefail

NAMESPACE="default"
ROLES="operator,readonly,cicd,teardown"
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICIES_DIR="$(cd "${SCRIPT_DIR}/../policies" && pwd)"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --namespace requires a value" >&2
        usage 1
      fi
      NAMESPACE="$2"
      shift 2
      ;;
    -r|--roles)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --roles requires a value" >&2
        usage 1
      fi
      ROLES="$2"
      shift 2
      ;;
    --dry-run)      DRY_RUN=true;   shift   ;;
    -h|--help)      usage ;;
    *) echo "Error: Unknown option: $1" >&2; usage 1 ;;
  esac
done

ROLE_DESCRIPTIONS=(
  "operator:OpenStudio Server operator role"
  "readonly:OpenStudio Server read-only role"
  "cicd:OpenStudio Server CI/CD service token role"
  "teardown:OpenStudio Server teardown role"
)

description_for() {
  local role="$1"
  for entry in "${ROLE_DESCRIPTIONS[@]}"; do
    if [[ "${entry%%:*}" == "$role" ]]; then
      echo "${entry#*:}"
      return
    fi
  done
  echo "OpenStudio Server ${role} role"
}

echo "Namespace : ${NAMESPACE}"
echo "Roles     : ${ROLES}"
echo "Dry run   : ${DRY_RUN}"
echo ""

IFS=',' read -ra ROLE_LIST <<< "$ROLES"
FAILED=()

for role in "${ROLE_LIST[@]}"; do
  policy_file="${POLICIES_DIR}/${role}.hcl"
  if [[ ! -f "$policy_file" ]]; then
    echo "WARN: Policy file not found for role '${role}': ${policy_file}" >&2
    FAILED+=("$role")
    continue
  fi

  substituted=$(sed "s/namespace \"default\"/namespace \"${NAMESPACE}\"/g" "$policy_file")

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== DRY RUN: ${role} (namespace: ${NAMESPACE}) ==="
    echo "$substituted"
    echo ""
    continue
  fi

  if ! command -v nomad &>/dev/null; then
    echo "ERROR: 'nomad' CLI not found in PATH. Install it from https://developer.hashicorp.com/nomad/downloads" >&2
    exit 1
  fi

  description="$(description_for "$role")"
  echo "Applying policy: ${role} → namespace '${NAMESPACE}'"
  if echo "$substituted" | nomad acl policy apply \
      -name "${role}" \
      -description "${description}" \
      -; then
    echo "  ✓ ${role} applied"
  else
    echo "  ✗ ${role} FAILED" >&2
    FAILED+=("$role")
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "" >&2
  echo "ERROR: The following roles failed: ${FAILED[*]}" >&2
  exit 1
fi

if [[ "$DRY_RUN" == "false" ]]; then
  echo ""
  echo "All policies applied successfully. Verify with:"
  echo "  nomad acl policy list"
fi
