#!/bin/bash
# OpenStudio Server Health Monitor
# Run this script to continuously monitor remediation progress

set -euo pipefail

NOMAD_ADDR="http://10.60.126.125:4646"
CONSUL_ADDR="http://192.168.100.87:8500"
OS_SERVER="http://10.60.126.125"
Rserve_HOST="192.168.100.18"
Rserve_PORT="6311"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }

check_consul_services() {
    local services=$(curl -s --max-time 5 "$CONSUL_ADDR/v1/catalog/services" 2>/dev/null | jq -r 'keys[]' 2>/dev/null | grep -E "openstudio" | sort)
    if [[ -z "$services" ]]; then
        fail "Consul: No openstudio-* services registered"
        return 1
    else
        ok "Consul services: $(echo $services | tr '\n' ' ')"
        return 0
    fi
}

check_rserve_connectivity() {
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$Rserve_HOST/$Rserve_PORT" 2>/dev/null; then
        ok "Rserve: Port $Rserve_PORT open on $Rserve_HOST"
        return 0
    else
        fail "Rserve: Cannot connect to $Rserve_HOST:$Rserve_PORT"
        return 1
    fi
}

check_rserve_nomad() {
    local alloc_id=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/job/openstudio-server-rserve/allocations" 2>/dev/null | jq -r '.[] | select(.ClientStatus=="running") | .ID' | head -1)
    if [[ -z "$alloc_id" || "$alloc_id" == "null" ]]; then
        fail "Rserve: No running allocation"
        return 1
    fi
    local state=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/allocation/$alloc_id" 2>/dev/null | jq -r '.TaskStates.rserve.State')
    if [[ "$state" == "running" ]]; then
        ok "Rserve: Nomad task running (alloc: ${alloc_id:0:8})"
        return 0
    else
        fail "Rserve: Nomad task state = $state"
        return 1
    fi
}

check_web_allocation() {
    local alloc_id=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/job/openstudio-server-web/allocations" 2>/dev/null | jq -r '.[] | select(.ClientStatus=="running") | .ID' | head -1)
    if [[ -z "$alloc_id" || "$alloc_id" == "null" ]]; then
        fail "Web: No running allocation"
        return 1
    fi
    local state=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/allocation/$alloc_id" 2>/dev/null | jq -r '.TaskStates.web.State')
    if [[ "$state" == "running" ]]; then
        ok "Web: Nomad task running (alloc: ${alloc_id:0:8})"
        return 0
    else
        fail "Web: Nomad task state = $state"
        return 1
    fi
}

check_workers() {
    local total=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/job/openstudio-server-worker/allocations" 2>/dev/null | jq '. | length')
    local running=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/job/openstudio-server-worker/allocations" 2>/dev/null | jq '[.[] | select(.ClientStatus=="running")] | length')
    local failed=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/job/openstudio-server-worker/allocations" 2>/dev/null | jq '[.[] | select(.ClientStatus=="failed")] | length')
    log "Workers: $running running / $failed failed / $total total"
    if [[ $running -gt 0 ]]; then
        ok "Workers: $running healthy"
        return 0
    else
        fail "Workers: None running!"
        return 1
    fi
}

check_analyses() {
    # Check a single representative analysis (more reliable than full list)
    local analysis_uuid="489388c6-aba4-4ad9-bcf8-1ea7be5fb582"
    local data=$(curl -s --max-time 10 "$OS_SERVER/analyses/$analysis_uuid.json" 2>/dev/null)
    if ! echo "$data" | jq -e . >/dev/null 2>&1; then
        warn "Analyses: Invalid JSON response from API"
        return 1
    fi
    local name=$(echo "$data" | jq -r '.analysis.name // "unknown"')
    local datapoints=$(echo "$data" | jq -r '.analysis.datapoints_count // 0')
    local run_flag=$(echo "$data" | jq -r '.analysis.run_flag // false')
    local status=$(echo "$data" | jq -r '.analysis.status // "unknown"')
    
    log "Analysis '$name': datapoints=$datapoints run_flag=$run_flag status=$status"
    if [[ "$datapoints" -gt 0 ]]; then
        ok "Analyses: Datapoints being generated!"
        return 0
    elif [[ "$run_flag" == "true" ]]; then
        warn "Analyses: Queued (run_flag=true) but 0 datapoints (waiting for Rserve)"
        return 1
    else
        fail "Analyses: Not running"
        return 1
    fi
}

check_resque_queues() {
    local analyses=$(curl -s --max-time 5 "$OS_SERVER/resque/queues/analyses" 2>/dev/null | sed -n 's/.*of <b>\([0-9]*\)<\/b>.*/\1/p' || echo "0")
    local simulations=$(curl -s --max-time 5 "$OS_SERVER/resque/queues/simulations" 2>/dev/null | sed -n 's/.*of <b>\([0-9]*\)<\/b>.*/\1/p' || echo "0")
    local background=$(curl -s --max-time 5 "$OS_SERVER/resque/queues/background" 2>/dev/null | sed -n 's/.*of <b>\([0-9]*\)<\/b>.*/\1/p' || echo "0")
    local working=$(curl -s --max-time 5 "$OS_SERVER/resque/working" 2>/dev/null | sed -n 's/.*class="wi">\([0-9]*\).*/\1/p' || echo "0")
    log "Resque: analyses=$analyses simulations=$simulations background=$background working=$working"
    if [[ $working -gt 0 ]]; then
        ok "Resque: $working workers actively processing"
        return 0
    elif [[ $analyses -gt 0 || $simulations -gt 0 ]]; then
        warn "Resque: Jobs queued but no workers processing"
        return 1
    else
        log "Resque: All queues empty"
        return 0
    fi
}

check_db_redis() {
    local db_alloc=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/job/openstudio-server-db/allocations" 2>/dev/null | jq -r '.[] | select(.ClientStatus=="running") | .ID' | head -1)
    local redis_alloc=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/job/openstudio-server-redis/allocations" 2>/dev/null | jq -r '.[] | select(.ClientStatus=="running") | .ID' | head -1)
    local db_ok=0 redis_ok=0
    
    if [[ -n "$db_alloc" && "$db_alloc" != "null" ]]; then
        # DB task may be named "mongodb" or "db"
        local db_state=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/allocation/$db_alloc" 2>/dev/null | jq -r '.TaskStates.mongodb.State // .TaskStates.db.State // "unknown"')
        [[ "$db_state" == "running" ]] && db_ok=1
    fi
    if [[ -n "$redis_alloc" && "$redis_alloc" != "null" ]]; then
        local redis_state=$(curl -s --max-time 5 "$NOMAD_ADDR/v1/allocation/$redis_alloc" 2>/dev/null | jq -r '.TaskStates.redis.State // "unknown"')
        [[ "$redis_state" == "running" ]] && redis_ok=1
    fi
    
    if [[ $db_ok -eq 1 && $redis_ok -eq 1 ]]; then
        ok "DB/Redis: Both running"
        return 0
    else
        fail "DB/Redis: DB=$db_ok Redis=$redis_ok"
        return 1
    fi
}

# Main check function
run_checks() {
    echo "=========================================="
    echo "Health Check - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    
    local all_pass=0
    check_consul_services && ((all_pass++)) || true
    check_rserve_nomad && ((all_pass++)) || true
    check_rserve_connectivity && ((all_pass++)) || true
    check_web_allocation && ((all_pass++)) || true
    check_db_redis && ((all_pass++)) || true
    check_workers && ((all_pass++)) || true
    check_analyses && ((all_pass++)) || true
    check_resque_queues && ((all_pass++)) || true
    
    echo "------------------------------------------"
    if [[ $all_pass -eq 8 ]]; then
        ok "ALL CHECKS PASSED ($all_pass/8) - System Healthy!"
        return 0
    else
        warn "PARTIAL: $all_pass/8 checks passed"
        return 1
    fi
}

# Loop mode
if [[ "${1:-}" == "--loop" ]]; then
    INTERVAL="${2:-30}"
    log "Starting continuous monitoring (interval: ${INTERVAL}s). Press Ctrl+C to stop."
    echo ""
    while true; do
        run_checks
        echo ""
        sleep "$INTERVAL"
    done
else
    run_checks
fi