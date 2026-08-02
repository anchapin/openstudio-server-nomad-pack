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

    restart {
      attempts = 3
      interval = "2m"
      delay    = "10s"
      mode     = "fail"
    }

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

echo "queue_sweeper_summary found=${stale} cleared=${cleared}"
EOH
      }

      resources {
        cpu    = [[ var "queue_sweeper_cpu" . ]]
        memory = [[ var "queue_sweeper_memory" . ]]
      }

      env {
        REDIS_URL = "redis://openstudio-redis.service.consul:[[ var "redis_port" . ]]"
      }
    }
  }
}
[[ end ]]
