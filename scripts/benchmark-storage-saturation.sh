#!/usr/bin/env bash
# benchmark-storage-saturation.sh — Quantify NFS shared-storage saturation at scale.
#
# Usage:
#   ./scripts/benchmark-storage-saturation.sh --tier <250|500|1000|2000> \
#       --nfs-mount /mnt/openstudio [--duration 300] [--output-dir benchmark-results]
#
#   ./scripts/benchmark-storage-saturation.sh --analyze \
#       [--output-dir benchmark-results]
#
# Prerequisites (on the Nomad client node running this script):
#   fio >= 3.x        — I/O load generator
#   sysstat >= 11.x   — iostat, sar
#   nfsstat           — NFS client statistics (nfs-common / nfs-utils)
#   vmstat            — virtual memory / CPU stats (procps)
#
# The script simulates the mixed I/O pattern produced by OpenStudio worker
# allocations: 4 KB random writes (metadata / result fragments) and 1 MB
# sequential reads (model file loading).  It captures NFS client stats,
# iowait, disk utilisation, and network throughput, then writes a structured
# JSON summary to the output directory.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TIER=""
NFS_MOUNT="/mnt/openstudio"
DURATION=300           # seconds each fio phase runs
OUTPUT_DIR="benchmark-results"
ANALYZE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -20
  exit 1
}

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' is required but not found in PATH." >&2
    echo "  Install it:  $2" >&2
    exit 1
  }
}

check_prerequisites() {
  require_cmd fio       "apt-get install fio  / yum install fio"
  require_cmd iostat    "apt-get install sysstat / yum install sysstat"
  require_cmd sar       "apt-get install sysstat / yum install sysstat"
  require_cmd nfsstat   "apt-get install nfs-common / yum install nfs-utils"
  require_cmd vmstat    "apt-get install procps / yum install procps-ng"
  require_cmd jq        "apt-get install jq / yum install jq"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)       TIER="$2";         shift 2 ;;
    --nfs-mount)  NFS_MOUNT="$2";    shift 2 ;;
    --duration)   DURATION="$2";     shift 2 ;;
    --output-dir) OUTPUT_DIR="$2";   shift 2 ;;
    --analyze)    ANALYZE=true;      shift   ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Analyze mode: summarize all tier results and identify saturation point
# ---------------------------------------------------------------------------
if $ANALYZE; then
  echo "=== Storage Saturation Benchmark — Analysis ==="
  echo ""

  if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "ERROR: output directory '$OUTPUT_DIR' not found." >&2
    exit 1
  fi

  # Print header
  printf "%-8s %-12s %-12s %-12s %-12s %-14s %-12s %-10s\n" \
    "Tier" "iowait%" "disk_util%" "net_MB/s" "nfs_ops/s" "nfs_rtt_ms" "retrans" "saturated"
  printf "%-8s %-12s %-12s %-12s %-12s %-14s %-12s %-10s\n" \
    "----" "--------" "----------" "--------" "---------" "----------" "-------" "---------"

  saturation_tier=""

  for summary in "$OUTPUT_DIR"/tier-*/summary.json; do
    [[ -f "$summary" ]] || continue
    tier=$(jq -r '.tier'           "$summary")
    iowait=$(jq -r '.iowait_pct'   "$summary")
    disk_util=$(jq -r '.disk_util_pct' "$summary")
    net=$(jq -r '.net_throughput_MBps' "$summary")
    nfs_ops=$(jq -r '.nfs_ops_per_sec' "$summary")
    nfs_rtt=$(jq -r '.nfs_rtt_ms'  "$summary")
    retrans=$(jq -r '.nfs_retrans' "$summary")

    # Saturation heuristics (see docs/storage-benchmark-methodology.md)
    saturated="no"
    if (( $(echo "$iowait > 40" | bc -l) )) || \
       (( $(echo "$retrans > 0" | bc -l) )) || \
       (( $(echo "$nfs_rtt > 20" | bc -l) )); then
      saturated="YES ⚠"
      [[ -z "$saturation_tier" ]] && saturation_tier="$tier"
    fi

    printf "%-8s %-12s %-12s %-12s %-12s %-14s %-12s %-10s\n" \
      "$tier" "$iowait" "$disk_util" "$net" "$nfs_ops" "$nfs_rtt" "$retrans" "$saturated"
  done

  echo ""
  if [[ -n "$saturation_tier" ]]; then
    echo "Saturation first observed at tier: $saturation_tier workers"
    echo "Recommendation: keep concurrent workers below $saturation_tier for this storage backend."
  else
    echo "No saturation detected across captured tiers."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Benchmark mode: validate args
# ---------------------------------------------------------------------------
if [[ -z "$TIER" ]]; then
  echo "ERROR: --tier is required." >&2
  usage
fi

case "$TIER" in
  250|500|1000|2000) ;;
  *) echo "ERROR: --tier must be one of: 250 500 1000 2000" >&2; exit 1 ;;
esac

check_prerequisites

if [[ ! -d "$NFS_MOUNT" ]]; then
  echo "ERROR: NFS mount point '$NFS_MOUNT' not found." >&2
  exit 1
fi

# Verify the path is actually an NFS mount
if ! mount | grep -q "on $NFS_MOUNT type nfs"; then
  echo "WARNING: '$NFS_MOUNT' does not appear to be an NFS mount. Proceeding anyway." >&2
fi

RESULT_DIR="$OUTPUT_DIR/tier-${TIER}"
mkdir -p "$RESULT_DIR"

# Number of parallel fio jobs ≈ tier / 4 (simulating worker thread concurrency)
FIO_JOBS=$(( TIER / 4 ))
# Clamp to a sane maximum for the client node
(( FIO_JOBS > 64 )) && FIO_JOBS=64
(( FIO_JOBS < 1 )) && FIO_JOBS=1

FIO_DIR="$NFS_MOUNT/.benchmark-${TIER}"
mkdir -p "$FIO_DIR"

log "Starting benchmark for tier=${TIER} workers, fio_jobs=${FIO_JOBS}, duration=${DURATION}s"
log "Results will be written to: $RESULT_DIR"

# ---------------------------------------------------------------------------
# 1. Capture pre-run NFS baseline
# ---------------------------------------------------------------------------
log "Capturing pre-run NFS stats..."
nfsstat -c > "$RESULT_DIR/nfsstat-before.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# 2. Start background metric collectors
# ---------------------------------------------------------------------------
log "Starting background metric collectors..."

# iostat: 5-second intervals
iostat -xz 5 $(( DURATION / 5 + 2 )) > "$RESULT_DIR/iostat.txt" 2>&1 &
IOSTAT_PID=$!

# vmstat: 5-second intervals (iowait is column 16)
vmstat 5 $(( DURATION / 5 + 2 )) > "$RESULT_DIR/vmstat.txt" 2>&1 &
VMSTAT_PID=$!

# sar NFS client stats: 10-second intervals
sar -n NFS 10 $(( DURATION / 10 + 2 )) > "$RESULT_DIR/sar-nfs.txt" 2>&1 &
SAR_PID=$!

# sar network throughput: 10-second intervals
sar -n DEV 10 $(( DURATION / 10 + 2 )) > "$RESULT_DIR/sar-net.txt" 2>&1 &
SAR_NET_PID=$!

# ---------------------------------------------------------------------------
# 3. Run fio — Phase A: 4 KB random writes (worker result fragment writes)
# ---------------------------------------------------------------------------
log "Phase A: 4 KB random writes (${FIO_JOBS} jobs, ${DURATION}s)..."
fio \
  --name="rand-write-4k" \
  --directory="$FIO_DIR" \
  --ioengine=libaio \
  --rw=randwrite \
  --bs=4k \
  --iodepth=16 \
  --numjobs="$FIO_JOBS" \
  --size=256m \
  --runtime="${DURATION}" \
  --time_based \
  --group_reporting \
  --output-format=json \
  --output="$RESULT_DIR/fio-randwrite.json" \
  2>&1 | tee "$RESULT_DIR/fio-randwrite.log" || true

# ---------------------------------------------------------------------------
# 4. Run fio — Phase B: 1 MB sequential reads (model file loading)
# ---------------------------------------------------------------------------
log "Phase B: 1 MB sequential reads (${FIO_JOBS} jobs, ${DURATION}s)..."
fio \
  --name="seq-read-1m" \
  --directory="$FIO_DIR" \
  --ioengine=libaio \
  --rw=read \
  --bs=1m \
  --iodepth=4 \
  --numjobs="$FIO_JOBS" \
  --size=256m \
  --runtime="${DURATION}" \
  --time_based \
  --group_reporting \
  --output-format=json \
  --output="$RESULT_DIR/fio-seqread.json" \
  2>&1 | tee "$RESULT_DIR/fio-seqread.log" || true

# ---------------------------------------------------------------------------
# 5. Stop background collectors
# ---------------------------------------------------------------------------
log "Stopping background collectors..."
kill "$IOSTAT_PID" "$VMSTAT_PID" "$SAR_PID" "$SAR_NET_PID" 2>/dev/null || true
wait "$IOSTAT_PID" "$VMSTAT_PID" "$SAR_PID" "$SAR_NET_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Capture post-run NFS stats
# ---------------------------------------------------------------------------
log "Capturing post-run NFS stats..."
nfsstat -c > "$RESULT_DIR/nfsstat-after.txt" 2>&1 || true

# ---------------------------------------------------------------------------
# 7. Extract key metrics and write summary.json
# ---------------------------------------------------------------------------
log "Extracting key metrics..."

# Average iowait from vmstat (column 15, 0-indexed)
IOWAIT=$(awk 'NR>3 {sum+=$15; n++} END {if(n>0) printf "%.1f", sum/n; else print "0"}' \
  "$RESULT_DIR/vmstat.txt" 2>/dev/null || echo "0")

# Average disk util from iostat (last column of device lines)
DISK_UTIL=$(grep -E "^(sda|nvme|vd|xvd|sd)" "$RESULT_DIR/iostat.txt" 2>/dev/null \
  | awk '{sum+=$NF; n++} END {if(n>0) printf "%.1f", sum/n; else print "0"}' || echo "0")

# Net throughput (RX+TX) from sar-net, excluding loopback
NET_MB=$(grep -v "^$\|IFACE\|Average\|lo\|Linux" "$RESULT_DIR/sar-net.txt" 2>/dev/null \
  | awk '{rx+=$5; tx+=$6; n++} END {if(n>0) printf "%.1f", (rx+tx)/n/1024; else print "0"}' || echo "0")

# NFS ops/sec from sar-nfs
NFS_OPS=$(grep -v "^$\|call/s\|Average\|Linux" "$RESULT_DIR/sar-nfs.txt" 2>/dev/null \
  | awk '{sum+=$2; n++} END {if(n>0) printf "%.1f", sum/n; else print "0"}' || echo "0")

# NFS RTT from fio json (clat mean in microseconds → ms)
NFS_RTT=$(jq -r '
  .jobs[0].read.clat_ns.mean // .jobs[0].write.clat_ns.mean // 0
  | . / 1000000 | . * 10 | round | . / 10
' "$RESULT_DIR/fio-randwrite.json" 2>/dev/null || echo "0")

# NFS retransmissions (difference in retrans between before/after)
RETRANS_BEFORE=$(grep -A2 "retrans\|Retrans" "$RESULT_DIR/nfsstat-before.txt" 2>/dev/null \
  | grep -oE '[0-9]+' | head -1 || echo "0")
RETRANS_AFTER=$(grep -A2 "retrans\|Retrans" "$RESULT_DIR/nfsstat-after.txt" 2>/dev/null \
  | grep -oE '[0-9]+' | head -1 || echo "0")
NFS_RETRANS=$(( RETRANS_AFTER - RETRANS_BEFORE ))
(( NFS_RETRANS < 0 )) && NFS_RETRANS=0

# Write throughput from fio randwrite
WRITE_BW=$(jq -r '.jobs[0].write.bw // 0 | . / 1024 | . * 10 | round | . / 10' \
  "$RESULT_DIR/fio-randwrite.json" 2>/dev/null || echo "0")

# Read throughput from fio seqread
READ_BW=$(jq -r '.jobs[0].read.bw // 0 | . / 1024 | . * 10 | round | . / 10' \
  "$RESULT_DIR/fio-seqread.json" 2>/dev/null || echo "0")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME=$(hostname)

cat > "$RESULT_DIR/summary.json" <<EOF
{
  "tier":                  $TIER,
  "timestamp":             "$TIMESTAMP",
  "host":                  "$HOSTNAME",
  "nfs_mount":             "$NFS_MOUNT",
  "duration_s":            $DURATION,
  "fio_jobs":              $FIO_JOBS,
  "iowait_pct":            $IOWAIT,
  "disk_util_pct":         $DISK_UTIL,
  "net_throughput_MBps":   $NET_MB,
  "nfs_ops_per_sec":       $NFS_OPS,
  "nfs_rtt_ms":            $NFS_RTT,
  "nfs_retrans":           $NFS_RETRANS,
  "write_bw_MBps":         $WRITE_BW,
  "read_bw_MBps":          $READ_BW
}
EOF

log "Summary written to $RESULT_DIR/summary.json"
cat "$RESULT_DIR/summary.json"

# ---------------------------------------------------------------------------
# 8. Cleanup fio test files
# ---------------------------------------------------------------------------
log "Cleaning up fio test files..."
rm -rf "$FIO_DIR"

log "Tier ${TIER} benchmark complete. Results in: $RESULT_DIR"
echo ""
echo "Run all tiers, then summarize with:"
echo "  $0 --analyze --output-dir $OUTPUT_DIR"
