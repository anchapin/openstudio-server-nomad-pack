#!/usr/bin/env bash
set -euo pipefail

# Captures short-lived periodic allocation evidence before Nomad GC removes it.

JOB_NAME="${OS_JOB_NAME:-openstudio-server}"
JOB_SUFFIX="queue-sweeper"
NAMESPACE="${NOMAD_NAMESPACE:-default}"
OUT_DIR=""
MAX_ALLOCS=5

usage() {
  cat <<'EOF'
Usage: scripts/capture-periodic-forensics.sh [options]

Options:
  --job-name <name>     Base pack job name (default: openstudio-server)
  --job-suffix <name>   Periodic job suffix (default: queue-sweeper)
  --namespace <ns>      Nomad namespace (default: NOMAD_NAMESPACE or "default")
  --out-dir <dir>       Output directory (default: /tmp/<job>-forensics-<timestamp>)
  --max-allocs <n>      Number of newest allocs to capture (default: 5)
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
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --max-allocs)
      MAX_ALLOCS="$2"
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
TS="$(date +%Y%m%d-%H%M%S)"
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="/tmp/${JOB_ID}-forensics-${TS}"
fi
mkdir -p "${OUT_DIR}"

echo "==> Capturing periodic forensics"
echo "  job: ${JOB_ID}"
echo "  namespace: ${NAMESPACE}"
echo "  out_dir: ${OUT_DIR}"

if ! nomad job status -namespace "${NAMESPACE}" "${JOB_ID}" >/dev/null 2>&1; then
  echo "Job not found: ${JOB_ID} (namespace: ${NAMESPACE})" >&2
  exit 1
fi

nomad job status -namespace "${NAMESPACE}" "${JOB_ID}" > "${OUT_DIR}/job-status.txt" || true
nomad job history -namespace "${NAMESPACE}" "${JOB_ID}" > "${OUT_DIR}/job-history.txt" || true
nomad job allocs -namespace "${NAMESPACE}" -json "${JOB_ID}" > "${OUT_DIR}/allocations.json" || true

mapfile -t alloc_ids < <(python3 - "${OUT_DIR}/allocations.json" "${MAX_ALLOCS}" <<'PY'
import json,sys
path=sys.argv[1]
limit=int(sys.argv[2])
try:
    data=json.load(open(path,"r",encoding="utf-8"))
except Exception:
    data=[]
def key(a):
    return a.get("CreateTime") or 0
allocs=sorted(data,key=key,reverse=True)[:limit]
for a in allocs:
    aid=a.get("ID")
    if aid:
        print(aid)
PY
)

if [[ ${#alloc_ids[@]} -eq 0 ]]; then
  echo "No allocations found for ${JOB_ID}."
  exit 0
fi

for alloc_id in "${alloc_ids[@]}"; do
  alloc_dir="${OUT_DIR}/alloc-${alloc_id}"
  mkdir -p "${alloc_dir}"

  nomad alloc status -namespace "${NAMESPACE}" "${alloc_id}" > "${alloc_dir}/status.txt" || true
  nomad alloc status -namespace "${NAMESPACE}" -json "${alloc_id}" > "${alloc_dir}/status.json" || true
  nomad alloc logs -namespace "${NAMESPACE}" "${alloc_id}" > "${alloc_dir}/stdout.log" || true
  nomad alloc logs -namespace "${NAMESPACE}" -stderr "${alloc_id}" > "${alloc_dir}/stderr.log" || true

  mapfile -t tasks < <(python3 - "${alloc_dir}/status.json" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1],"r",encoding="utf-8"))
except Exception:
    data={}
for name in (data.get("TaskStates") or {}).keys():
    print(name)
PY
)

  for task in "${tasks[@]}"; do
    nomad alloc logs -namespace "${NAMESPACE}" "${alloc_id}" "${task}" > "${alloc_dir}/${task}.stdout.log" || true
    nomad alloc logs -namespace "${NAMESPACE}" -stderr "${alloc_id}" "${task}" > "${alloc_dir}/${task}.stderr.log" || true
  done
done

echo "Forensic capture complete: ${OUT_DIR}"
