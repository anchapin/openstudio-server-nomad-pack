[[ if var "enable_queue_health_alert" . ]]
job "[[ var "job_name" . ]]-queue-health-alert" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "batch"

  priority = [[ var "web_priority" . ]]

  periodic {
    cron             = "[[ var "alert_check_interval" . ]]"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "queue-health-alert" {
    count = 1

    [[ template "openstudio_server.restart_block" (dict "attempts" 0 "mode" "fail") ]]

    task "check-queue-health" {
      driver = "docker"

      config {
        image           = "[[ var "queue_sweeper_image" . ]]"
        command         = "/bin/sh"
        args            = ["/local/check-queue-health.sh"]
        readonly_rootfs = false
      }

      template {
        destination = "local/check-queue-health.sh"
        perms       = "755"
        data        = <<EOH
#!/bin/sh
set -eu

REDIS_HOST="openstudio-redis.service.consul"
REDIS_PORT="6379"
SIM_QUEUE_KEY="resque:queue:simulations"
FAILED_QUEUE_KEY="resque:failed"
WORKERS_KEY="resque:workers"
BASELINE_PREFIX="openstudio:queue-health:[[ var "job_name" . ]]"
PREV_SIM_KEY="${BASELINE_PREFIX}:last-simulations"
PREV_TS_KEY="${BASELINE_PREFIX}:last-ts"
STALE_LOCK_MIN_IDLE=[[ var "queue_sweeper_max_lock_age_seconds" . ]]
STALE_LOCK_THRESHOLD=[[ var "alert_stale_lock_threshold" . ]]
QUEUE_GROWTH_DELTA=[[ var "alert_queue_growth_delta" . ]]
FAILED_JOB_THRESHOLD=[[ var "alert_failed_job_threshold" . ]]

redis_cmd() {
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"
}

is_integer() {
  case "$1" in
    ''|*[!0-9-]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

append_reason() {
  if [ -n "$reasons" ]; then
    reasons="${reasons},$1"
  else
    reasons="$1"
  fi
}

count_stale_locks() {
  count=0
  for key in $(redis_cmd --scan --pattern 'resque:analysis:*:queuing' 2>/dev/null); do
    [ -z "$key" ] && continue
    ttl="$(redis_cmd TTL "$key" 2>/dev/null | tr -d '[:space:]')"
    if [ "$ttl" != "-1" ]; then
      continue
    fi
    idle="$(redis_cmd OBJECT IDLETIME "$key" 2>/dev/null | tr -d '[:space:]')"
    if is_integer "$idle" && [ "$idle" -ge "$STALE_LOCK_MIN_IDLE" ]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

count_working_workers() {
  count=0
  for worker in $(redis_cmd SMEMBERS "$WORKERS_KEY" 2>/dev/null); do
    [ -z "$worker" ] && continue
    payload="$(redis_cmd GET "resque:worker:${worker}" 2>/dev/null || true)"
    if [ -n "$payload" ]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

ts="$(date -u +%s)"
reasons=""

if ! redis_cmd PING >/dev/null 2>&1; then
  echo "queue_health ts=${ts} status=alert reasons=redis_unreachable simulations=-1 failed=-1 workers_working=-1 stale_locks=-1"
  exit 2
fi

simulations="$(redis_cmd LLEN "$SIM_QUEUE_KEY" 2>/dev/null | tr -d '[:space:]')"
failed="$(redis_cmd LLEN "$FAILED_QUEUE_KEY" 2>/dev/null | tr -d '[:space:]')"
previous_simulations="$(redis_cmd GET "$PREV_SIM_KEY" 2>/dev/null | tr -d '[:space:]' || true)"
stale_locks="$(count_stale_locks)"
workers_working="$(count_working_workers)"
queue_delta=0

if ! is_integer "$simulations"; then simulations=0; fi
if ! is_integer "$failed"; then failed=0; fi
if ! is_integer "$stale_locks"; then stale_locks=0; fi
if ! is_integer "$workers_working"; then workers_working=0; fi

if is_integer "$previous_simulations"; then
  queue_delta=$((simulations - previous_simulations))
  if [ "$queue_delta" -gt 0 ] && [ "$queue_delta" -ge "$QUEUE_GROWTH_DELTA" ]; then
    append_reason "queue_growth"
  fi
fi

if [ "$failed" -ge "$FAILED_JOB_THRESHOLD" ]; then
  append_reason "failed_jobs"
fi

if [ "$stale_locks" -ge "$STALE_LOCK_THRESHOLD" ]; then
  append_reason "stale_locks"
fi

[[ if var "alert_queuing_gate_enabled" . ]]
# Queuing-gate deadlock: at least one analysis is enqueued (a
# resque:analysis:*:queuing lock exists) but no data-point jobs exist anywhere
# (simulations queue empty) and the analysis_wrappers queue that web workers
# drain to enqueue data-point jobs is empty, while workers are still
# registered. In that state no new data-point jobs can ever be produced.
GATE_QUEUE_KEY="resque:queue:analysis_wrappers"
analysis_wrappers="$(redis_cmd LLEN "$GATE_QUEUE_KEY" 2>/dev/null | tr -d '[:space:]')"
if ! is_integer "$analysis_wrappers"; then analysis_wrappers=0; fi

analysis_queuing_count=0
analysis_ids=""
if [ "$simulations" -eq 0 ] && [ "$analysis_wrappers" -eq 0 ] && [ "$workers_working" -gt 0 ]; then
  for key in $(redis_cmd --scan --pattern 'resque:analysis:*:queuing' 2>/dev/null); do
    [ -z "$key" ] && continue
    analysis_queuing_count=$((analysis_queuing_count + 1))
    analysis_id="$(printf '%s' "$key" | sed -n 's/^resque:analysis:\([^:]*\):queuing$/\1/p')"
    if [ -n "$analysis_id" ]; then
      if [ -n "$analysis_ids" ]; then
        analysis_ids="${analysis_ids},${analysis_id}"
      else
        analysis_ids="$analysis_id"
      fi
    fi
  done
  if [ "$analysis_queuing_count" -gt 0 ]; then
    append_reason "queuing_gate_deadlock"
    echo "queue_stagnation_alert type=queuing_gate_deadlock analysis_ids=${analysis_ids} count=${analysis_queuing_count} simulations=${simulations} analysis_wrappers=${analysis_wrappers} workers_working=${workers_working}"
  fi
fi
[[ end ]]

redis_cmd SET "$PREV_SIM_KEY" "$simulations" >/dev/null
redis_cmd SET "$PREV_TS_KEY" "$ts" >/dev/null

status="ok"
if [ -n "$reasons" ]; then
  status="alert"
else
  reasons="none"
fi

echo "queue_health ts=${ts} status=${status} reasons=${reasons} simulations=${simulations} failed=${failed} workers_working=${workers_working} stale_locks=${stale_locks}"

if [ "$status" = "alert" ]; then
  exit 2
fi
EOH
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
[[ end ]]
