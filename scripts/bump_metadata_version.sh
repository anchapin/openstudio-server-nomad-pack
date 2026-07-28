#!/usr/bin/env bash
set -euo pipefail

METADATA_FILE="${1:-metadata.hcl}"
BUMP_TYPE="${2:-patch}"

CURRENT_VERSION="$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$METADATA_FILE" | head -n 1)"

if [[ -z "${CURRENT_VERSION}" ]]; then
  echo "Unable to find semantic version in ${METADATA_FILE}" >&2
  exit 1
fi

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
    echo "Unsupported bump type: ${BUMP_TYPE}. Use patch, minor, or major." >&2
    exit 1
    ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
sed -E -i.bak 's/^([[:space:]]*version[[:space:]]*=[[:space:]]*")[0-9]+\.[0-9]+\.[0-9]+(".*)$/\1'"${NEW_VERSION}"'\2/' "${METADATA_FILE}"
rm -f "${METADATA_FILE}.bak"

echo "${NEW_VERSION}"
