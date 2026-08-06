#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/pre-teardown.sh"

MOCK_DIR="${REPO_ROOT}/tests/fixtures/mockbin-pre-teardown"
LOG_FILE="${REPO_ROOT}/tests/fixtures/pre-teardown.nomad.calls.log"
JOBS_FILE="${REPO_ROOT}/tests/fixtures/pre-teardown.nomad.jobs"

rm -rf "${MOCK_DIR}"
mkdir -p "${MOCK_DIR}"
rm -f "${LOG_FILE}" "${JOBS_FILE}"

cat > "${JOBS_FILE}" <<'EOF'
custom-job-worker
custom-job-web
custom-job-rserve
custom-job-db
custom-job-redis
custom-job-system-hooks
custom-job-state-backup
custom-job-state-restore
custom-job-batch-verify
custom-job-queue-health-alert
custom-job-test
custom-job-nomad-autoscaler
custom-job-autoscaler
EOF

cat > "${MOCK_DIR}/nomad" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${LOG_FILE:?}"
JOBS_FILE="${JOBS_FILE:?}"

if [[ "${1:-}" != "job" ]]; then
  echo "unsupported mock command: $*" >&2
  exit 1
fi

subcommand="${2:-}"

case "${subcommand}" in
  status)
    job_name="${*: -1}"
    if grep -Fxq "${job_name}" "${JOBS_FILE}"; then
      exit 0
    fi
    exit 1
    ;;
  stop)
    echo "$*" >> "${LOG_FILE}"
    exit 0
    ;;
  *)
    echo "unsupported mock job subcommand: ${subcommand}" >&2
    exit 1
    ;;
esac
EOF

chmod +x "${MOCK_DIR}/nomad"

PATH="${MOCK_DIR}:$PATH" LOG_FILE="${LOG_FILE}" JOBS_FILE="${JOBS_FILE}" NOMAD_NAMESPACE="test-ns" \
  "${SCRIPT}" custom-job >/dev/null

grep -q 'job stop -purge -namespace test-ns custom-job-worker' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-web' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-rserve' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-db' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-redis' "${LOG_FILE}"
grep -q 'job stop -purge -global -namespace test-ns custom-job-system-hooks' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-state-backup' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-state-restore' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-batch-verify' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-queue-health-alert' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-test' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-nomad-autoscaler' "${LOG_FILE}"
grep -q 'job stop -purge -namespace test-ns custom-job-autoscaler' "${LOG_FILE}"

rm -rf "${MOCK_DIR}"
rm -f "${LOG_FILE}" "${JOBS_FILE}"

echo "pre-teardown script tests passed"
