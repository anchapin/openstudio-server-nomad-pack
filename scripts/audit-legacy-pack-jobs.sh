#!/usr/bin/env bash
set -euo pipefail

# Audits jobs for a pack prefix and identifies known legacy/orphan jobs that can
# interfere with nomad-pack deployment metadata lookups.
#
# Default mode is read-only. Use --apply to purge only known legacy jobs.

JOB_NAME="${OS_JOB_NAME:-openstudio-server}"
NAMESPACE="${NOMAD_NAMESPACE:-default}"
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
APPLY=false

usage() {
  cat <<'EOF'
Usage: scripts/audit-legacy-pack-jobs.sh [options]

Options:
  --job-name <name>     Base pack job name prefix (default: openstudio-server)
  --namespace <ns>      Nomad namespace (default: NOMAD_NAMESPACE or "default")
  --nomad-addr <url>    Nomad API address (default: NOMAD_ADDR or http://127.0.0.1:4646)
  --apply               Purge known legacy jobs (safe subset only)
  -h, --help            Show this help

Known legacy jobs purged with --apply (safe subset):
  - <job_name>-stall-watchdog
  - <job_name>-stall-watchdog/periodic-* (dead only)
  - <job_name>-prewarm-worker-system-hooks (only when <job_name>-system-hooks is running)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)
      JOB_NAME="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --nomad-addr)
      NOMAD_ADDR="$2"
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

export NOMAD_NAMESPACE="${NAMESPACE}" NOMAD_ADDR="${NOMAD_ADDR}"

echo "==> Auditing jobs with prefix '${JOB_NAME}-' in namespace '${NAMESPACE}' at '${NOMAD_ADDR}'"

jobs_json="$(mktemp)"
trap 'rm -f "$jobs_json"' EXIT

if ! curl -sf "${NOMAD_ADDR}/v1/jobs?prefix=${JOB_NAME}-&namespace=${NAMESPACE}" >"${jobs_json}"; then
  echo "Failed to query Nomad jobs API at ${NOMAD_ADDR}." >&2
  exit 1
fi

expected_suffixes=(
  web
  worker
  db
  redis
  rserve
  system-hooks
  traefik
  autoscaler
  nomad-autoscaler
  prometheus
  queue-sweeper
  state-backup
  state-restore
  batch-verify
  test
  infra-setup
  nomad-batch-worker
)

declare -A expected=()
for suffix in "${expected_suffixes[@]}"; do
  expected["${JOB_NAME}-${suffix}"]=1
done

declare -A periodic_allowed_prefixes=(
  ["${JOB_NAME}-queue-sweeper/periodic-"]=1
  ["${JOB_NAME}-state-backup/periodic-"]=1
)

to_purge=()
unknown=()
prewarm_candidate=""
system_hooks_running=false

mapfile -t job_lines < <(python3 - "${jobs_json}" <<'PY'
import json,sys
jobs=json.load(open(sys.argv[1],"r",encoding="utf-8"))
for j in jobs:
    jid=(j or {}).get("ID") or ""
    status=(j or {}).get("Status") or ""
    jtype=(j or {}).get("Type") or ""
    print(f"{jid}\t{status}\t{jtype}")
PY
)

if [[ ${#job_lines[@]} -eq 0 ]]; then
  echo "No jobs found with prefix '${JOB_NAME}-' in namespace '${NAMESPACE}'."
  exit 0
fi

for line in "${job_lines[@]}"; do
  IFS=$'\t' read -r jid status jtype <<<"${line}"
  [[ "$jid" == "${JOB_NAME}-"* ]] || continue

  if [[ "$jid" == "${JOB_NAME}-system-hooks" && "$status" == "running" ]]; then
    system_hooks_running=true
  fi

  if [[ "$jid" == "${JOB_NAME}-stall-watchdog" ]]; then
    to_purge+=("$jid")
    continue
  fi

  if [[ "$jid" == "${JOB_NAME}-prewarm-worker-system-hooks" ]]; then
    prewarm_candidate="$jid"
    continue
  fi

  if [[ "$jid" == "${JOB_NAME}-stall-watchdog/periodic-"* ]]; then
    if [[ "$status" == "dead" ]]; then
      to_purge+=("$jid")
    else
      unknown+=("$jid (non-dead legacy periodic child)")
    fi
    continue
  fi

  if [[ -n "${expected[$jid]+x}" ]]; then
    continue
  fi

  is_allowed_periodic=false
  for pfx in "${!periodic_allowed_prefixes[@]}"; do
    if [[ "$jid" == "${pfx}"* ]]; then
      is_allowed_periodic=true
      break
    fi
  done
  [[ "${is_allowed_periodic}" == "true" ]] && continue

  unknown+=("$jid")
done

if [[ ${#to_purge[@]} -eq 0 ]]; then
  echo "No known legacy jobs found."
else
  echo "Known legacy jobs:"
  printf '  - %s\n' "${to_purge[@]}"
fi

if [[ ${#unknown[@]} -gt 0 ]]; then
  echo "Unrecognized jobs with same prefix (manual review required):"
  printf '  - %s\n' "${unknown[@]}"
fi

if [[ -n "${prewarm_candidate}" ]]; then
  if [[ "${system_hooks_running}" == "true" ]]; then
    echo "Prewarm legacy candidate (safe to purge because main system-hooks is running):"
    echo "  - ${prewarm_candidate}"
    to_purge+=("${prewarm_candidate}")
  else
    echo "Prewarm legacy candidate found but main system-hooks is not running; manual review required:"
    echo "  - ${prewarm_candidate}"
  fi
fi

if [[ "${APPLY}" != "true" ]]; then
  echo "Dry-run only. Re-run with --apply to purge known legacy jobs."
  exit 0
fi

if [[ ${#to_purge[@]} -eq 0 ]]; then
  echo "Nothing to purge."
  exit 0
fi

echo "==> Purging known legacy jobs"
for jid in "${to_purge[@]}"; do
  echo "  - nomad job stop -purge -namespace ${NAMESPACE} ${jid}"
  nomad job stop -purge -namespace "${NAMESPACE}" "${jid}" >/dev/null
done

echo "Legacy cleanup complete."
