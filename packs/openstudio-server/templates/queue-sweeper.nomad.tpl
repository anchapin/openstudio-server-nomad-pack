[[ if var "enable_queue_sweeper" . ]]
# queue-sweeper — periodic batch job that clears stale resque:analysis:*:queuing
# locks from Redis.  A lock is stale if it has no TTL and has been idle for
# longer than queue_sweeper_max_lock_age_seconds.  The job can run on any node
# that has Docker — it reaches Redis via Consul service DNS.
job "[[ var "job_name" . ]]-queue-sweeper" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "batch"

  priority = [[ var "web_priority" . ]]

  periodic {
    cron             = "[[ var "queue_sweeper_cron" . ]]"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "queue-sweeper" {
    count = 1

    [[ template "openstudio_server.restart_block" (dict "attempts" 3 "interval" "2m" "delay" "10s" "mode" "fail") ]]

    task "sweep" {
      driver = "docker"

      config {
        image           = "[[ var "queue_sweeper_image" . ]]"
        command         = "/bin/sh"
        args            = ["/local/sweep.sh"]
        readonly_rootfs = false
      }

      # Resolve Redis address via Consul service DNS
      template {
        destination = "local/sweep.sh"
        perms       = "755"
        data        = <<EOH
#!/bin/sh
set -eu

REDIS_HOST="{{ with service "openstudio-redis" }}{{ with index . 0 }}{{ .Address }}{{ end }}{{ end }}"
REDIS_PORT="{{ with service "openstudio-redis" }}{{ with index . 0 }}{{ .Port }}{{ end }}{{ end }}"
MAX_AGE=[[ var "queue_sweeper_max_lock_age_seconds" . ]]

if [ -z "$REDIS_HOST" ] || [ -z "$REDIS_PORT" ]; then
  echo "ERROR: could not resolve openstudio-redis via Consul" >&2
  exit 1
fi

redis_cmd() {
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"
}

echo "queue_sweeper_start redis=${REDIS_HOST}:${REDIS_PORT} max_age=${MAX_AGE}s"

stale=0
cleared=0

for key in $(redis_cmd --scan --pattern 'resque:analysis:*:queuing' 2>/dev/null); do
  [ -z "$key" ] && continue
  stale=$((stale + 1))

  ttl=$(redis_cmd TTL "$key" 2>/dev/null | tr -d '[:space:]')
  if [ "$ttl" = "-1" ]; then
    # No TTL — check idle time as a proxy for "this lock was never cleared"
    idle=$(redis_cmd OBJECT IDLETIME "$key" 2>/dev/null | tr -d '[:space:]')
    if echo "$idle" | grep -qE '^[0-9]+$' && [ "$idle" -ge "$MAX_AGE" ]; then
      result=$(redis_cmd DEL "$key" 2>/dev/null | tr -d '[:space:]')
      if [ "$result" = "1" ]; then
        echo "queue_sweeper_deleted key=${key} idle=${idle}s"
        cleared=$((cleared + 1))
      else
        echo "queue_sweeper_raced key=${key} (already gone)"
      fi
    else
      echo "queue_sweeper_skipped key=${key} idle=${idle}s (within grace period)"
    fi
  elif [ "$ttl" = "-2" ]; then
    echo "queue_sweeper_raced key=${key} (vanished)"
  else
    echo "queue_sweeper_active key=${key} ttl=${ttl}s (has TTL, skip)"
  fi
done

echo "queue_sweeper_lock_summary found=${stale} cleared=${cleared}"

replayed=0

[[ if var "queue_sweeper_replay_dirty_exit" . ]]
# --- Section 2: Auto-replay PruneDeadWorkerDirtyExit / TermException failures ---
# Workers killed mid-job during scale-down or node drain always produce
# PruneDeadWorkerDirtyExit. These are 100% infra-recoverable and must never require
# manual intervention.
#
# CRITICAL: Resque payload MUST use single-arg format:
#   {"class":"ResqueJobs::RunSimulateDataPoint","args":["<dp_id>"]}
# Passing [analysis_id, dp_id] causes DataPoint.find(analysis_id) => nil => SILENT SKIP.
# The DP stays at 'na' forever with no error in any log. Do NOT add a second arg.

REPLAY_DELAY=[[ var "queue_sweeper_replay_delay_seconds" . ]]
replayed=0
replay_skipped=0

failed_len=$(redis_cmd LLEN resque:failed 2>/dev/null | tr -d '[:space:]')
if [ -z "$failed_len" ]; then
  failed_len=0
fi
echo "queue_sweeper_failed_queue_check len=$failed_len"

if echo "$failed_len" | grep -qE '^[0-9]+$' && [ "$failed_len" -gt 0 ]; then
  # Read all entries at once to avoid index-shift problems during removal.
  # redis-cli outputs one list element per line.
  all_failed=$(redis_cmd LRANGE resque:failed 0 -1 2>/dev/null)

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue

    # Only auto-replay PruneDeadWorkerDirtyExit and TermException for RunSimulateDataPoint
    is_infra_recoverable=false
    if echo "$entry" | grep -q '"exception":"PruneDeadWorkerDirtyExit"' || \
       echo "$entry" | grep -q '"exception":"TermException"'; then
      if echo "$entry" | grep -q '"class":"ResqueJobs::RunSimulateDataPoint"'; then
        is_infra_recoverable=true
      fi
    fi

    if [ "$is_infra_recoverable" != "true" ]; then
      replay_skipped=$((replay_skipped + 1))
      continue
    fi

    # Extract dp_id — must be the ONLY element in args (single-arg format).
    # Matches:  "args":["<uuid>"]            — correct; replay
    # Skips:    "args":["<id1>","<id2>"]     — two-arg bug; do not replay silently
    dp_id=$(printf '%s' "$entry" | sed -n 's/.*"args":\["\([0-9a-fA-F-]*\)"\].*/\1/p')
    if [ -z "$dp_id" ]; then
      echo "queue_sweeper_replay_skip reason=could_not_extract_dp_id"
      replay_skipped=$((replay_skipped + 1))
      continue
    fi

    # Re-enqueue with correct single-arg format
    payload="{\"class\":\"ResqueJobs::RunSimulateDataPoint\",\"args\":[\"${dp_id}\"]}"
    queue_len=$(redis_cmd RPUSH resque:queue:simulations "$payload" 2>/dev/null | tr -d '[:space:]')

    # Remove replayed entry from failed queue by value (not index — avoids shift bugs)
    redis_cmd LREM resque:failed 1 "$entry" >/dev/null 2>&1 || true

    echo "queue_sweeper_replayed dp_id=${dp_id} queue_len=${queue_len}"
    replayed=$((replayed + 1))

    [ "$REPLAY_DELAY" -gt 0 ] && sleep "$REPLAY_DELAY"
  done <<REPLAY_EOF
$all_failed
REPLAY_EOF

  echo "queue_sweeper_replay_summary replayed=${replayed} skipped=${replay_skipped}"
fi
[[ end ]]

echo "queue_sweeper_summary locks_cleared=${cleared} replayed=${replayed}"
EOH
      }

      resources {
        cpu    = [[ var "queue_sweeper_cpu" . ]]
        memory = [[ var "queue_sweeper_memory" . ]]
      }

      env {
        REDIS_URL = "[[ var "web_redis_url" . ]]"
      }
    }
  }
}
[[ end ]]
