#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR_FILE="${OS_VAR_FILE:-${REPO_ROOT}/examples/openstack.hcl}"
PULP_REGISTRY="${PULP_REGISTRY:-}"
PULP_PROJECT="${PULP_PROJECT:-}"
PULP_USERNAME="${PULP_USERNAME:-}"
PULP_PASSWORD="${PULP_PASSWORD:-}"
FORCE_PUSH="${FORCE_PUSH:-false}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Mirror OpenStudio stack images referenced by a var-file into Pulp.

Required environment:
  PULP_REGISTRY   Registry host (example: pulp-dev.hpc.nlr.gov)
  PULP_PROJECT    Registry path prefix (example: pulp-container-aurora-179d)
  PULP_USERNAME   Registry username
  PULP_PASSWORD   Registry password/token

Options:
  --var-file <path>      Var-file to read image tags from (default: ${VAR_FILE})
  --force                Push even if destination tag already exists
  -h, --help             Show help

Examples:
  PULP_REGISTRY=pulp-dev.hpc.nlr.gov \\
  PULP_PROJECT=pulp-container-aurora-179d \\
  PULP_USERNAME=... PULP_PASSWORD=... \\
  bash scripts/mirror-images-to-pulp.sh --var-file examples/openstack.hcl
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --var-file) VAR_FILE="$2"; shift 2 ;;
    --force) FORCE_PUSH=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${PULP_REGISTRY}" || -z "${PULP_PROJECT}" || -z "${PULP_USERNAME}" || -z "${PULP_PASSWORD}" ]]; then
  echo "✗ PULP_REGISTRY, PULP_PROJECT, PULP_USERNAME, and PULP_PASSWORD are required." >&2
  exit 1
fi

if [[ ! -f "${VAR_FILE}" ]]; then
  echo "✗ var-file not found: ${VAR_FILE}" >&2
  exit 1
fi

extract_var() {
  local key="$1"
  local default="${2:-}"
  local line value
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${VAR_FILE}" | tail -n 1 || true)"
  if [[ -z "${line}" ]]; then
    echo "${default}"
    return
  fi
  value="${line#*=}"
  value="$(echo "${value}" | sed -E 's/[[:space:]]*#.*$//' | xargs)"
  value="${value%\"}"
  value="${value#\"}"
  echo "${value}"
}

images=(
  "$(extract_var web_image "")"
  "$(extract_var web_background_image "")"
  "$(extract_var worker_image "")"
  "$(extract_var db_image "")"
  "$(extract_var redis_image "")"
  "$(extract_var rserve_image "")"
)

mapfile -t unique_images < <(printf '%s\n' "${images[@]}" | awk 'NF && !seen[$0]++')
if [[ ${#unique_images[@]} -eq 0 ]]; then
  echo "✗ No images found in ${VAR_FILE}" >&2
  exit 1
fi

if command -v skopeo >/dev/null 2>&1; then
  copier="skopeo"
  echo "==> Using skopeo copy"
elif command -v docker >/dev/null 2>&1; then
  copier="docker"
  echo "==> skopeo not found, falling back to docker pull/tag/push"
else
  echo "✗ Neither skopeo nor docker is available." >&2
  exit 1
fi

if [[ "${copier}" = "skopeo" ]]; then
  skopeo login --username "${PULP_USERNAME}" --password "${PULP_PASSWORD}" "${PULP_REGISTRY}" >/dev/null
else
  echo "${PULP_PASSWORD}" | docker login "${PULP_REGISTRY}" --username "${PULP_USERNAME}" --password-stdin >/dev/null
fi

echo "==> Mirroring images to ${PULP_REGISTRY}/${PULP_PROJECT}"
for src in "${unique_images[@]}"; do
  dst="${PULP_REGISTRY}/${PULP_PROJECT}/${src}"
  if [[ "${copier}" = "skopeo" && "${FORCE_PUSH}" != "true" ]]; then
    if skopeo inspect "docker://${dst}" >/dev/null 2>&1; then
      echo "  - exists, skipping: ${dst}"
      continue
    fi
  fi

  echo "  - mirroring: ${src} -> ${dst}"
  if [[ "${copier}" = "skopeo" ]]; then
    skopeo copy --all "docker://${src}" "docker://${dst}"
  else
    docker pull "${src}"
    docker tag "${src}" "${dst}"
    docker push "${dst}"
  fi
done

echo "✓ Image mirror complete"
