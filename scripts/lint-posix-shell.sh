#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="${REPO_ROOT}/.scratch-lint-posix-shell-$$"
RENDERED_FILE="${SCRATCH_DIR}/rendered.nomad"
EXTRACTED_DIR="${SCRATCH_DIR}/extracted"

cleanup() {
  rm -rf "${SCRATCH_DIR}"
}
trap cleanup EXIT

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "ERROR: shellcheck is required for POSIX shell linting." >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <nomad-pack render args...>" >&2
  echo "Example: $0 packs/openstudio-server" >&2
  exit 1
fi

mkdir -p "${EXTRACTED_DIR}"

shellcheck_inputs=()

shopt -s nullglob
entrypoint_scripts=("${REPO_ROOT}"/scripts/container-entrypoints/*.sh)
if [ "${#entrypoint_scripts[@]}" -gt 0 ]; then
  echo "Linting scripts/container-entrypoints/*.sh with shellcheck --shell=sh"
  shellcheck_inputs+=("${entrypoint_scripts[@]}")
else
  echo "INFO: No scripts/container-entrypoints/*.sh files found; linting rendered /bin/sh heredocs instead."
fi
shopt -u nullglob

(
  cd "${REPO_ROOT}"
  nomad-pack render "$@"
) > "${RENDERED_FILE}"

extracted_count="$(
  python3 - "${RENDERED_FILE}" "${EXTRACTED_DIR}" <<'PY'
import os
import re
import sys

rendered_path = sys.argv[1]
output_dir = sys.argv[2]

with open(rendered_path, "r", encoding="utf-8") as handle:
    lines = handle.readlines()

heredoc_start = re.compile(r"<<-?([A-Za-z_][A-Za-z0-9_]*)")
count = 0
i = 0

while i < len(lines):
    match = heredoc_start.search(lines[i])
    if not match:
        i += 1
        continue

    terminator = match.group(1)
    content_start = i + 1
    i += 1
    block = []

    while i < len(lines) and lines[i].strip() != terminator:
        block.append(lines[i])
        i += 1

    if block and block[0].startswith("#!/bin/sh"):
        count += 1
        destination = os.path.join(
            output_dir,
            f"rendered-posix-{count:02d}-line-{content_start + 1}.sh",
        )
        with open(destination, "w", encoding="utf-8") as output:
            output.write(block[0])
            output.write(
                f"# extracted from nomad-pack render output at line {content_start + 1}\n"
            )
            output.writelines(block[1:])

    i += 1

print(count)
PY
)"

if [ "${extracted_count}" -gt 0 ]; then
  for extracted_file in "${EXTRACTED_DIR}"/*.sh; do
    shellcheck_inputs+=("${extracted_file}")
  done
  echo "Linting ${extracted_count} rendered /bin/sh heredoc script(s)"
fi

if [ "${#shellcheck_inputs[@]}" -eq 0 ]; then
  echo "INFO: No POSIX shell targets found to lint."
  exit 0
fi

shellcheck --shell=sh "${shellcheck_inputs[@]}"
