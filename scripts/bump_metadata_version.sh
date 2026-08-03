#!/usr/bin/env bash
# bump_metadata_version.sh — bump or set the pack version in a metadata.hcl file
#
# Usage:
#   scripts/bump_metadata_version.sh [metadata_file] [patch|minor|major]
#   scripts/bump_metadata_version.sh [metadata_file] <x.y.z>
#
# Arguments:
#   metadata_file   Path to the HCL file containing the version field (default: metadata.hcl)
#   patch|minor|major   Increment the corresponding version component
#   x.y.z           Set the version to an explicit semver string (e.g. 0.3.0)
#
# Examples:
#   scripts/bump_metadata_version.sh                        # patch-bump metadata.hcl
#   scripts/bump_metadata_version.sh metadata.hcl minor     # minor-bump metadata.hcl
#   scripts/bump_metadata_version.sh metadata.hcl 0.3.0     # set to explicit version
set -euo pipefail

METADATA_FILE="${1:-metadata.hcl}"
BUMP_TYPE="${2:-patch}"

CURRENT_VERSION="$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$METADATA_FILE" | head -n 1)"

if [[ -z "${CURRENT_VERSION}" ]]; then
  echo "Unable to find semantic version in ${METADATA_FILE}" >&2
  exit 1
fi

# Support explicit semver argument (e.g. "0.3.0") in addition to patch/minor/major keywords
if [[ "${BUMP_TYPE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  NEW_VERSION="${BUMP_TYPE}"
else
  IFS='.' read -r MAJOR MINOR PATCH <<< "${CURRENT_VERSION}"

  case "${BUMP_TYPE}" in
    patch)
      PATCH=$((PATCH + 1))
      ;;
    minor)
      MINOR=$((MINOR + 1))
      PATCH=0
      ;;
    major)
      MAJOR=$((MAJOR + 1))
      MINOR=0
      PATCH=0
      ;;
    *)
      echo "Unsupported bump type: ${BUMP_TYPE}. Use patch, minor, major, or an explicit x.y.z version." >&2
      exit 1
      ;;
  esac

  NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

trap 'rm -f "${METADATA_FILE}.bak"' EXIT
sed -E -i.bak 's/^([[:space:]]*version[[:space:]]*=[[:space:]]*")[0-9]+\.[0-9]+\.[0-9]+(".*)$/\1'"${NEW_VERSION}"'\2/' "${METADATA_FILE}"
rm -f "${METADATA_FILE}.bak"

echo "${NEW_VERSION}"
