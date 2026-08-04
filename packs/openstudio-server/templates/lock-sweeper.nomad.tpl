[[ if var "enable_lock_sweeper" . ]]
job "[[ var "job_name" . ]]-lock-sweeper" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "batch"

  priority = [[ var "web_priority" . ]]

  periodic {
    cron             = "[[ var "lock_sweeper_interval" . ]]"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "lock-sweeper" {
    count = 1

    volume "shared-nfs" {
      type      = "host"
      source    = "[[ var "lock_sweeper_nfs_volume" . ]]"
      read_only = false
    }

    task "lock-sweeper" {
      driver = "docker"
      user   = "[[ var "docker_user" . ]]"

      volume_mount {
        volume      = "shared-nfs"
        destination = "/mnt/openstudio"
        read_only   = false
      }

      config {
        image           = "alpine:3.20"
        command         = "/bin/sh"
        args            = ["/local/lock-sweeper.sh"]
        readonly_rootfs = false
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
      }

      template {
        destination = "local/lock-sweeper.sh"
        perms       = "755"
        data        = <<EOH
#!/bin/sh
set -eu

SHARED_ROOT="/mnt/openstudio"
STALE_MINUTES=[[ var "lock_sweeper_stale_threshold_minutes" . ]]

list_stale_locks() {
  find "$SHARED_ROOT" -type f -name 'analysis_zip.lock' -mmin "+$STALE_MINUTES" 2>/dev/null | while IFS= read -r lock_path; do
    [ -n "$lock_path" ] || continue
    receipt_path="$(printf '%s\n' "$lock_path" | sed 's/\.lock$/.receipt/')"
    if [ ! -e "$receipt_path" ]; then
      printf '%s\n' "$lock_path"
    fi
  done
}

count_stale_locks() {
  list_stale_locks | awk 'END { print NR + 0 }'
}

stale_before="$(count_stale_locks)"
removed=0
stale_locks="$(list_stale_locks)"

if [ -n "$stale_locks" ]; then
  old_ifs=$IFS
  IFS='
'
  set -f
  for lock_path in $stale_locks; do
    [ -n "$lock_path" ] || continue
    if rm -f "$lock_path"; then
      removed=$((removed + 1))
    fi
  done
  set +f
  IFS=$old_ifs
fi

stale_after="$(count_stale_locks)"
echo "lock_sweep ts=$(date +%s) stale_before=${stale_before} removed=${removed} stale_after=${stale_after}"
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
