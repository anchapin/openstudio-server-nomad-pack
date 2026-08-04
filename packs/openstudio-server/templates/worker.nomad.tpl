[[ if eq (var "batch_engine" .) "internal" ]]
job "[[ var "job_name" . ]]-worker" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"
  priority    = [[ var "worker_priority" . ]]
  meta {
    deployment_marker = "[[ var "deployment_marker" . ]]"
  }

  [[ template "openstudio_server.update_block" (dict "max_parallel" (var "worker_update_max_parallel" .) "canary" (var "worker_update_canary" .) "auto_promote" (var "worker_update_auto_promote" .) "stagger" (var "worker_update_stagger" .) "health_check" (var "worker_update_health_check" .) "min_healthy_time" (var "worker_update_min_healthy_time" .) "healthy_deadline" (var "worker_update_healthy_deadline" .) "progress_deadline" (var "worker_update_progress_deadline" .) "auto_revert" (var "worker_update_auto_revert" .)) ]]

  group "worker" {
    count = [[ var "worker_count" . ]]
    [[ if ne (var "worker_instance_type" .) "" ]]
    constraint {
      attribute = "${attr.platform.aws.instance-type}"
      operator  = "="
      value     = "[[ var "worker_instance_type" . ]]"
    }
    [[ end ]]
    [[ template "constraints" (var "worker_constraints" .) ]]
    [[ range $nodeID := var "worker_excluded_node_ids" . ]]
    constraint {
      attribute = "${node.unique.id}"
      operator  = "!="
      value     = "[[ $nodeID ]]"
    }
    [[ end ]]
    [[ template "affinities" (var "worker_affinities" .) ]]
    [[ template "spreads" (var "worker_spreads" .) ]]


    [[ if var "worker_autoscaling_enabled" . ]]
    scaling {
      enabled = true
      min     = [[ var "worker_min_replicas" . ]]
      max     = [[ var "worker_max_replicas" . ]]

      policy {
        cooldown             = "[[ var "worker_autoscaling_scale_down_cooldown" . ]]"
        cooldown_on_scale_up = "[[ var "worker_autoscaling_scale_up_cooldown" . ]]"
        evaluation_interval  = "[[ var "worker_autoscaling_evaluation_interval" . ]]"

        [[ if var "worker_autoscaling_cpu_enabled" . ]]
        check "cpu-utilization" {
          source = "nomad-apm"
          query  = "avg_cpu"

          strategy "target-value" {
            target = [[ var "worker_cpu_target_utilization" . ]]
          }
        }
        [[ end ]]

        [[ if var "worker_autoscaling_queue_enabled" . ]]
        check "queue-requeued-depth" {
          source = "prometheus"
          query  = [[ printf "ceil(clamp_min((sum(max_over_time(%s[%s])) or vector(0)) / %v, 0))" (var "worker_queue_requeued_query" .) (var "worker_queue_query_window" .) (var "worker_queue_requeued_target" .) | toJson ]]

          config {
            prometheus_address = "[[ var "autoscaler_prometheus_address" . ]]"
          }

          strategy "pass-through" {}
        }

        check "queue-simulations-depth" {
          source = "prometheus"
          query  = [[ printf "ceil(clamp_min((sum(max_over_time(%s[%s])) or vector(0)) / %v, 0))" (var "worker_queue_simulations_query" .) (var "worker_queue_query_window" .) (var "worker_queue_simulations_target" .) | toJson ]]

          config {
            prometheus_address = "[[ var "autoscaler_prometheus_address" . ]]"
          }

          strategy "pass-through" {}
        }
        [[ end ]]
      }
    }
    [[ end ]]
    [[ if var "nfs_shared_volume_enabled" . ]]
    [[ if eq (var "nfs_volume_type" .) "csi" ]]
    volume "nfs-shared" {
      type            = "csi"
      source          = "[[ var "nfs_volume_source" . ]]"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
    [[ else ]]
    volume "nfs-shared" {
      type      = "host"
      source    = "[[ var "nfs_volume_source" . ]]"
      read_only = false
    }
    [[ end ]]
    [[ end ]]
    [[ if var "worker_local_scratch_enabled" . ]]
    ephemeral_disk {
      size    = [[ var "worker_local_scratch_size" . ]]
      sticky  = [[ var "worker_local_scratch_sticky" . ]]
      migrate = true
    }
    [[ end ]]
    [[ if var "enable_arch_constraint" . ]]
    [[ template "openstudio_server.arch_constraint" . ]]
    [[ end ]]

    [[ template "openstudio_server.wait_for_deps_task" (dict "root" . "include_rserve" false "proceed_on_timeout" (var "worker_wait_for_deps_proceed_on_timeout" .)) ]]

    task "worker" {
      driver = "docker"
      user   = "[[ var "docker_user" . ]]"

      [[ if var "nfs_shared_volume_enabled" . ]]
      volume_mount {
        volume      = "nfs-shared"
        destination = "[[ var "nfs_volume_mount_path" . ]]"
        read_only   = false
      }
      [[ end ]]

      [[ template "openstudio_server.vault_integration_block" . ]]

      [[ if var "vault_integration_enabled" . ]]
      template {
        destination = "secrets/env"
        env         = true
        change_mode = "restart"
        data        = <<-EOT
{{ with secret "[[ var "vault_kv_mongodb_path" . ]]" }}
MONGO_PASSWORD={{ .Data.data.password | toJSON }}
{{ end }}
{{ with secret "[[ var "vault_kv_redis_path" . ]]" }}
REDIS_PASSWORD={{ .Data.data.password | toJSON }}
{{ end }}
{{ with secret "[[ var "vault_kv_app_path" . ]]" }}
SECRET_KEY_BASE={{ .Data.data.secret_key_base | toJSON }}
{{ end }}
EOT
      }
      [[ end ]]

      [[ template "openstudio_server.vault_block" (dict "root" .) ]]

      config {
        image      = "[[ if var "worker_runtime_image" . ]][[ var "worker_runtime_image" . ]][[ else ]][[ var "worker_image" . ]][[ end ]]"
        force_pull = [[ var "worker_force_pull" . ]]
        command    = "[[ var "worker_command" . ]]"
        ulimit {
          nofile = "[[ var "docker_ulimit_nofile" . ]]"
        }
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        [[ if var "worker_extra_hosts" . ]]
        extra_hosts = [[ var "worker_extra_hosts" . | toJson ]]
        [[ end ]]
        [[ if var "worker_args" . ]]
        args = [[ var "worker_args" . | toJson ]]
        [[ end ]]
        [[ if var "dev_shared_volume_name" . ]]
        mounts = [
          {
            type   = "volume"
            source = "[[ var "dev_shared_volume_name" . ]]"
            target = "[[ var "nfs_volume_mount_path" . ]]"
          }
        ]
        [[ else if var "dev_shared_data_path" . ]]
        mounts = [
          {
            type   = "bind"
            source = "[[ var "dev_shared_data_path" . ]]"
            target = "[[ var "nfs_volume_mount_path" . ]]"
          }
        ]
        [[ end ]]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      env {
        MONGO_USER = "[[ var "mongo_user" . ]]"
        QUEUES     = "[[ var "worker_queues" . ]]"
        COUNT      = "[[ var "worker_process_count" . ]]"
        [[ if var "worker_local_scratch_enabled" . ]]
        WORKER_SCRATCH_PATH = "[[ var "worker_scratch_path" . ]]"
        [[ end ]]
        [[ if var "web_redis_url" . ]]
        REDIS_URL = "[[ var "web_redis_url" . ]]"
        [[ end ]]
        [[ if not (var "vault_integration_enabled" .) ]]
        MONGO_PASSWORD  = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD  = "[[ var "redis_password" . ]]"
        SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
        [[ end ]]
        [[ if var "swift_artifact_storage_enabled" . ]]
        ARTIFACT_STORAGE_BACKEND = "swift"
        OS_AUTH_URL              = "[[ var "swift_auth_url" . ]]"
        OS_USERNAME              = "[[ var "swift_username" . ]]"
        OS_PASSWORD              = "[[ var "swift_password" . ]]"
        OS_TENANT_NAME           = "[[ var "swift_tenant_name" . ]]"
        OS_REGION_NAME           = "[[ var "swift_region" . ]]"
        OS_AUTH_VERSION          = "[[ var "swift_auth_version" . ]]"
        SWIFT_CONTAINER          = "[[ var "swift_container" . ]]"
        [[ end ]]
      }

      template {
        destination = "local/patch-hosts.sh"
        change_mode = "script"
        change_script {
          command       = "/bin/sh"
          args          = ["-c", "grep -vE ' (db|queue|rserve|web)$' /etc/hosts > /alloc/hosts.tmp 2>/dev/null; cat /alloc/hosts.tmp > /etc/hosts; sh /local/patch-hosts.sh"]
          timeout       = "30s"
          fail_on_error = false
        }
        data = <<-EOT
#!/bin/sh
set -eu

MAX_ATTEMPTS=[[ var "web_worker_runtime_service_resolution_attempts" . ]]
BASE_DELAY=[[ var "web_worker_runtime_service_resolution_backoff_seconds" . ]]
RUNTIME_RESOLUTION_ENABLED=[[ var "web_worker_runtime_service_resolution_enabled" . ]]

if [ "$RUNTIME_RESOLUTION_ENABLED" != "true" ]; then
  echo "worker_runtime_resolution_disabled legacy_template_watch_mode_removed=true" >&2
  exit 0
fi

if [ "$MAX_ATTEMPTS" -lt 1 ]; then
  echo "worker_runtime_invalid_attempts value=$MAX_ATTEMPTS" >&2
  exit 1
fi

if [ "$BASE_DELAY" -lt 1 ]; then
  echo "worker_runtime_invalid_backoff value=$BASE_DELAY" >&2
  exit 1
fi

resolve_alias() {
  service="$1"
  alias="$2"
  attempt=1
  delay="$BASE_DELAY"
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    ip=""
    if command -v getent >/dev/null 2>&1; then
      ip="$(getent hosts "$service.service.consul" 2>/dev/null | awk 'NR==1 {print $1}')"
    fi
    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
      ip="$(nslookup "$service.service.consul" 2>/dev/null | awk '/^Address [0-9]+: / {print $3; exit} /^Address: / {print $2; exit}')"
    fi
    if [ -n "$ip" ]; then
      echo "$ip $alias" >> /etc/hosts
      echo "worker_runtime_resolve_ok service=$service alias=$alias ip=$ip attempt=$attempt"
      return 0
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    [ "$delay" -gt 8 ] && delay=8
  done
  echo "worker_runtime_resolve_failed service=$service alias=$alias" >&2
  return 1
}

resolve_alias "openstudio-db" "db"
resolve_alias "openstudio-redis" "queue"
resolve_alias "openstudio-rserve" "rserve"
resolve_alias "openstudio-web" "web"
EOT
      }

      resources {
        cpu        = [[ var "worker_cpu" . ]]
        memory     = [[ var "worker_memory" . ]]
        memory_max = [[ var "worker_memory_max" . ]]
      }

      kill_timeout = "[[ var "worker_kill_timeout" . ]]"

      restart {
        attempts = [[ var "worker_restart_attempts" . ]]
        delay    = "[[ var "worker_restart_delay" . ]]"
        interval = "[[ var "worker_restart_interval" . ]]"
        mode     = "delay"
      }

      service {
        name     = "openstudio-worker"
        provider = "consul"

        check {
          name     = "worker-alive"
          type     = "script"
          command  = "/bin/sh"
          args     = ["-c", "[[ var "worker_health_check_command" . ]]"]
          interval = "30s"
          timeout  = "5s"
        }
      }
    }

    [[ template "openstudio_server.vector_task" . ]]
  }

}
[[ end ]]
