#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_VAR_FILE="${OS_VAR_FILE:-${REPO_ROOT}/examples/advanced/openstack.hcl}"
VAR_FILES=("${DEFAULT_VAR_FILE}")
VAR_FILES_SET=false
PULP_REGISTRY="${PULP_REGISTRY:-}"
PULP_PROJECT="${PULP_PROJECT:-}"
PULP_USERNAME="${PULP_USERNAME:-}"
PULP_PASSWORD="${PULP_PASSWORD:-}"
FORCE_PUSH="${FORCE_PUSH:-false}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"

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
  --var-file <path>      Var-file to read image tags from (repeatable, last wins)
  --force                Push even if destination tag already exists
  -h, --help             Show help

Examples:
  PULP_REGISTRY=pulp-dev.hpc.nlr.gov \\
  PULP_PROJECT=pulp-container-aurora-179d \\
  PULP_USERNAME=... PULP_PASSWORD=... \\
  DOCKER_PLATFORM=linux/amd64 \\
  bash scripts/mirror-images-to-pulp.sh \\
    --var-file examples/advanced/openstack-production.hcl \\
    --var-file examples/advanced/openstack-site-local.hcl
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --var-file)
      if [[ "${VAR_FILES_SET}" != "true" ]]; then
        VAR_FILES=()
        VAR_FILES_SET=true
      fi
      VAR_FILES+=("$2")
      shift 2
      ;;
    --force) FORCE_PUSH=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${PULP_REGISTRY}" || -z "${PULP_PROJECT}" || -z "${PULP_USERNAME}" || -z "${PULP_PASSWORD}" ]]; then
  echo "✗ PULP_REGISTRY, PULP_PROJECT, PULP_USERNAME, and PULP_PASSWORD are required." >&2
  exit 1
fi

for var_file in "${VAR_FILES[@]}"; do
  if [[ ! -f "${var_file}" ]]; then
    echo "✗ var-file not found: ${var_file}" >&2
    exit 1
  fi
done

extract_var() {
  local key="$1"
  local default="${2:-}"
  local line value last_value=""
  for var_file in "${VAR_FILES[@]}"; do
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${var_file}" | tail -n 1 || true)"
    if [[ -z "${line}" ]]; then
      continue
    fi
    value="${line#*=}"
    value="$(echo "${value}" | sed -E 's/[[:space:]]*#.*$//' | xargs)"
    value="${value%\"}"
    value="${value#\"}"
    last_value="${value}"
  done
  if [[ -z "${last_value}" ]]; then
    echo "${default}"
    return
  fi
  echo "${last_value}"
}

images=(
  "$(extract_var web_image "")"
  "$(extract_var web_background_image "")"
  "$(extract_var worker_image "")"
  "$(extract_var db_image "")"
  "$(extract_var redis_image "")"
  "$(extract_var rserve_image "")"
  "$(extract_var verification_image "")"
  "$(extract_var poststop_cleanup_image "")"
  "$(extract_var vector_image "")"
  "$(extract_var prometheus_image "")"
  "$(extract_var redis_exporter_image "")"
  "$(extract_var nomad_autoscaler_image "")"
  "$(extract_var queue_sweeper_image "")"
  "$(extract_var stall_watchdog_image "")"
)

mapfile -t unique_images < <(printf '%s\n' "${images[@]}" | awk 'NF && !seen[$0]++')
if [[ ${#unique_images[@]} -eq 0 ]]; then
  echo "✗ No images found in provided var-file set." >&2
  exit 1
fi

if command -v skopeo >/dev/null 2>&1; then
  copier="skopeo"
  echo "==> Using skopeo copy"
elif command -v docker >/dev/null 2>&1; then
  copier="docker"
  echo "==> skopeo not found, falling back to docker pull/tag/push (platform=${DOCKER_PLATFORM})"
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
  src_normalized="${src}"
  pulp_prefix="${PULP_REGISTRY}/${PULP_PROJECT}/"
  if [[ "${src_normalized}" == "${pulp_prefix}"* ]]; then
    # If the var-file already points at this Pulp prefix, recover the upstream
    # image reference by stripping the prefix so we can mirror from source.
    src_normalized="${src_normalized#${pulp_prefix}}"
  fi

  if [[ "${src_normalized}" == "${PULP_REGISTRY}/"* ]]; then
    echo "  - skipping image hosted in a different Pulp path (cannot infer source): ${src}" >&2
    continue
  fi

  dst="${PULP_REGISTRY}/${PULP_PROJECT}/${src_normalized}"
  if [[ "${copier}" = "skopeo" && "${FORCE_PUSH}" != "true" ]]; then
    if skopeo inspect "docker://${dst}" >/dev/null 2>&1; then
      echo "  - exists, skipping: ${dst}"
      continue
    fi
  fi

  echo "  - mirroring: ${src_normalized} -> ${dst}"
  if [[ "${copier}" = "skopeo" ]]; then
    skopeo copy --all "docker://${src_normalized}" "docker://${dst}"
  else
    docker pull --platform "${DOCKER_PLATFORM}" "${src_normalized}"
    docker tag "${src_normalized}" "${dst}"
    docker push "${dst}"
  fi
done

echo "✓ Image mirror complete"
