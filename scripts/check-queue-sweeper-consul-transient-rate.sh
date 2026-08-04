#!/usr/bin/env bash
set -euo pipefail

# Counts recent queue-sweeper/watchdog transient Consul signals in alloc logs.
# Exits non-zero when count exceeds threshold.

JOB_NAME="${OS_JOB_NAME:-openstudio-server}"
JOB_SUFFIX="queue-sweeper"
NAMESPACE="${NOMAD_NAMESPACE:-default}"
MAX_ALLOCS=10
THRESHOLD=5

usage() {
  cat <<'EOF'
Usage: scripts/check-queue-sweeper-consul-transient-rate.sh [options]

Options:
  --job-name <name>     Base pack job name (default: openstudio-server)
  --job-suffix <name>   Periodic job suffix (default: queue-sweeper)
  --namespace <ns>      Nomad namespace (default: NOMAD_NAMESPACE or "default")
  --max-allocs <n>      Number of newest allocs to inspect (default: 10)
  --threshold <n>       Fail when transient_count > threshold (default: 5)
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)
      JOB_NAME="$2"
      shift 2
      ;;
    --job-suffix)
      JOB_SUFFIX="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --max-allocs)
      MAX_ALLOCS="$2"
      shift 2
      ;;
    --threshold)
      THRESHOLD="$2"
      shift 2
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

JOB_ID="${JOB_NAME}-${JOB_SUFFIX}"
if ! nomad job status -namespace "${NAMESPACE}" "${JOB_ID}" >/dev/null 2>&1; then
  echo "Job not found: ${JOB_ID} (namespace: ${NAMESPACE})" >&2
  exit 1
fi

allocs_json="$(mktemp)"
trap 'rm -f "$allocs_json"' EXIT
nomad job allocs -namespace "${NAMESPACE}" -json "${JOB_ID}" > "${allocs_json}"

mapfile -t alloc_ids < <(python3 - "${allocs_json}" "${MAX_ALLOCS}" <<'PY'
import json,sys
path=sys.argv[1]
limit=int(sys.argv[2])
data=json.load(open(path,"r",encoding="utf-8"))
data=sorted(data,key=lambda a: a.get("CreateTime") or 0, reverse=True)[:limit]
for a in data:
    aid=a.get("ID")
    if aid:
        print(aid)
PY
)

if [[ ${#alloc_ids[@]} -eq 0 ]]; then
  echo "No allocations found for ${JOB_ID}"
  exit 0
fi

transient_count=0
skip_cycle_count=0

for aid in "${alloc_ids[@]}"; do
  stderr="$(nomad alloc logs -namespace "${NAMESPACE}" -stderr "${aid}" 2>/dev/null || true)"
  stdout="$(nomad alloc logs -namespace "${NAMESPACE}" "${aid}" 2>/dev/null || true)"
  block="${stderr}
${stdout}"

  c1=$(printf '%s' "${block}" | grep -cE 'queue_sweeper_warn msg=consul_transient|stall_watchdog_warn msg=consul_transient' || true)
  c2=$(printf '%s' "${block}" | grep -c 'action=skip_cycle' || true)
  transient_count=$((transient_count + c1))
  skip_cycle_count=$((skip_cycle_count + c2))
done

echo "job=${JOB_ID} namespace=${NAMESPACE} allocs_checked=${#alloc_ids[@]} transient_count=${transient_count} skip_cycle_count=${skip_cycle_count} threshold=${THRESHOLD}"

if [[ "${transient_count}" -gt "${THRESHOLD}" ]]; then
  echo "Transient Consul warning count exceeded threshold." >&2
  exit 2
fi

exit 0
