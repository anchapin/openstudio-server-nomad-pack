job "[[ var "job_name" . ]]-worker" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"
  priority    = [[ var "worker_priority" . ]]

  update {
    max_parallel      = [[ var "worker_update_max_parallel" . ]]
    health_check      = "[[ var "worker_update_health_check" . ]]"
    min_healthy_time  = "[[ var "worker_update_min_healthy_time" . ]]"
    healthy_deadline  = "[[ var "worker_update_healthy_deadline" . ]]"
    progress_deadline = "[[ var "worker_update_progress_deadline" . ]]"
    auto_revert       = [[ var "worker_update_auto_revert" . ]]
  }

  group "worker" {
    count = [[ var "worker_count" . ]]

    [[ if var "worker_autoscaling_enabled" . ]]
    scaling {
      enabled = true
      min     = [[ var "worker_min_replicas" . ]]
      max     = [[ var "worker_max_replicas" . ]]

      policy {
        cooldown            = "[[ var "autoscaler_cooldown" . ]]"
        evaluation_interval = "30s"

        [[ if var "worker_autoscaling_cpu_enabled" . ]]
        check "cpu-utilization" {
          source = "nomad-apm"
          query  = "avg_cpu"

          strategy "target-value" {
            target = [[ var "worker_cpu_target_utilization" . ]]
          }
        }
        [[ end ]]

        check "queue-requeued-depth" {
          source = "prometheus"
          query  = [[ var "worker_queue_requeued_query" . | toJson ]]

          config {
            prometheus_address = "[[ var "autoscaler_prometheus_address" . ]]"
          }

          strategy "target-value" {
            target = [[ var "worker_queue_requeued_target" . ]]
          }
        }

        check "queue-simulations-depth" {
          source = "prometheus"
          query  = [[ var "worker_queue_simulations_query" . | toJson ]]

          config {
            prometheus_address = "[[ var "autoscaler_prometheus_address" . ]]"
          }

          strategy "target-value" {
            target = [[ var "worker_queue_simulations_target" . ]]
          }
        }
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
    [[ template "openstudio_server.arch_constraint" . ]]

    # Prestart: wait for MongoDB and Redis to be registered and healthy in Consul
    task "wait-for-deps" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "busybox:1.36"
        network_mode = "host"
        command = "sh"
        args = [
          "-ec",
          "until wget -qO- \"http://127.0.0.1:8500/v1/health/service/openstudio-db?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-db\"'; do sleep 2; done; until wget -qO- \"http://127.0.0.1:8500/v1/health/service/openstudio-redis?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-redis\"'; do sleep 2; done",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

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

      [[ if var "vault_integration_enabled" . ]]
      [[ if not (var "vault_enabled" .) ]]
      vault {
        policies      = ["[[ var "vault_policy" . ]]"]
        change_mode   = "restart"
        change_signal = "SIGTERM"
      }
      [[ end ]]

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
APP_SECRET_KEY_BASE={{ .Data.data.secret_key_base | toJSON }}
{{ end }}
EOT
      }
      [[ end ]]

      [[ if var "vault_enabled" . ]]
      vault {
        role = "[[ var "vault_default_role" . ]]"
      }
      [[ end ]]

      config {
        image           = "[[ var "worker_image" . ]]"
        command         = "[[ var "worker_command" . ]]"
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        [[ if var "worker_args" . ]]
        args = [[ var "worker_args" . | toJson ]]
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
        QUEUES = "[[ var "worker_queues" . ]]"
        COUNT  = "[[ var "worker_process_count" . ]]"
        [[ if not (var "vault_integration_enabled" .) ]]
        MONGO_PASSWORD      = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD      = "[[ var "redis_password" . ]]"
        APP_SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
        [[ end ]]
      }

      resources {
        cpu        = [[ var "worker_cpu" . ]]
        memory     = [[ var "worker_memory" . ]]
        memory_max = [[ var "worker_memory_max" . ]]
      }

      kill_timeout = "[[ var "worker_kill_timeout" . ]]"

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

    [[ if var "enable_vector_collection" . ]]
    task "vector" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image = "[[ var "vector_image" . ]]"
        args  = ["--config", "local/vector.toml"]
      }

      template {
        data        = <<EOH
[sources.alloc_logs]
type = "file"
include = ["/alloc/logs/*.std*"]

[sinks.console]
type = "console"
inputs = ["alloc_logs"]
encoding.codec = "json"
EOH
        destination = "local/vector.toml"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
    [[ end ]]
  }
}
