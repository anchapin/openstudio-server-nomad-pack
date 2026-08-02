#!/usr/bin/env bash
#
# cleanup-repo.sh — repository hygiene helper
#
# Removes transient files and consolidates generated variable documentation
# from variables.hcl.
#
# Usage:
#   ./scripts/cleanup-repo.sh            # dry-run (default)
#   ./scripts/cleanup-repo.sh --apply    # perform cleanup changes
#   ./scripts/cleanup-repo.sh --no-docs  # skip docs regeneration step
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DRY_RUN=true
REFRESH_DOCS=true

usage() {
  cat <<'EOF'
Usage: ./scripts/cleanup-repo.sh [--apply] [--no-docs] [--help]

Options:
  --apply    Perform deletions and docs refresh. Default is dry-run.
  --no-docs  Skip regenerating docs/variables.md and docs/variables.generated.md.
  --help     Show this message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) DRY_RUN=false; shift ;;
    --no-docs) REFRESH_DOCS=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

run_or_echo() {
  local cmd="$1"
  if $DRY_RUN; then
    echo "DRY-RUN: $cmd"
  else
    eval "$cmd"
  fi
}

log "Scanning for transient files..."
mapfile -t transient_files < <(
  find "$REPO_ROOT" -type f \
    \( -name '.DS_Store' -o -name '*.swp' -o -name '*.swo' -o -name '*~' -o -name '*.tmp' -o -name '*.temp' -o -name '*.bak' -o -name '*.orig' -o -name '*.rej' \) \
    -not -path "$REPO_ROOT/.git/*" \
    -not -path "$REPO_ROOT/.vagrant/*"
)

if [[ ${#transient_files[@]} -eq 0 ]]; then
  log "No transient files found."
else
  log "Found ${#transient_files[@]} transient file(s)."
  for f in "${transient_files[@]}"; do
    run_or_echo "rm -f \"${f}\""
  done
fi

log "Scanning benchmark-results for non-summary artifacts..."
mapfile -t benchmark_raw_files < <(
  find "$REPO_ROOT/benchmark-results" -type f ! -name 'summary.json' 2>/dev/null || true
)

if [[ ${#benchmark_raw_files[@]} -eq 0 ]]; then
  log "No benchmark raw artifacts found."
else
  log "Found ${#benchmark_raw_files[@]} benchmark raw artifact(s)."
  for f in "${benchmark_raw_files[@]}"; do
    run_or_echo "rm -f \"${f}\""
  done
  run_or_echo "find \"$REPO_ROOT/benchmark-results\" -type d -empty -delete"
fi

if $REFRESH_DOCS; then
  log "Refreshing variable docs from variables.hcl..."
  if $DRY_RUN; then
    echo "DRY-RUN: ./scripts/generate-vars-doc.sh docs/variables.md"
    echo "DRY-RUN: ./scripts/generate-vars-doc.sh docs/variables.generated.md"
  else
    "$REPO_ROOT/scripts/generate-vars-doc.sh" "$REPO_ROOT/docs/variables.md"
    "$REPO_ROOT/scripts/generate-vars-doc.sh" "$REPO_ROOT/docs/variables.generated.md"
  fi
else
  log "Skipping docs regeneration (--no-docs)."
fi

log "Cleanup completed."
