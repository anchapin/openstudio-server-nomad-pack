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

        [[ if var "worker_autoscaling_queue_enabled" . ]]
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
    [[ if var "enable_arch_constraint" . ]]
    [[ template "openstudio_server.arch_constraint" . ]]
    [[ end ]]

    # Prestart: wait for MongoDB and Redis to be registered and healthy in Consul
    task "wait-for-deps" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "[[ var "verification_image" . ]]"
        network_mode = "host"
        command = "sh"
        args = [
          "-ec",
          "until wget -qO- \"http://[[ var "consul_address" . ]]/v1/health/service/openstudio-db?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-db\"'; do sleep 2; done; until wget -qO- \"http://[[ var "consul_address" . ]]/v1/health/service/openstudio-redis?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-redis\"'; do sleep 2; done",
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
SECRET_KEY_BASE={{ .Data.data.secret_key_base | toJSON }}
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
        image           = "[[ if var "worker_runtime_image" . ]][[ var "worker_runtime_image" . ]][[ else ]][[ var "worker_image" . ]][[ end ]]"
        force_pull      = [[ var "worker_force_pull" . ]]
        command         = "[[ var "worker_command" . ]]"
        ulimit {
          nofile = "[[ var "docker_ulimit_nofile" . ]]"
        }
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        [[ if var "worker_extra_hosts" . ]]
        extra_hosts     = [[ var "worker_extra_hosts" . | toJson ]]
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
        QUEUES = "[[ var "worker_queues" . ]]"
        COUNT  = "[[ var "worker_process_count" . ]]"
        [[ if var "web_redis_url" . ]]
        REDIS_URL = "[[ var "web_redis_url" . ]]"
        [[ end ]]
        [[ if not (var "vault_integration_enabled" .) ]]
        MONGO_PASSWORD  = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD  = "[[ var "redis_password" . ]]"
        SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
        [[ end ]]
      }

      template {
        destination   = "local/patch-hosts.sh"
        change_mode   = "noop"
        left_delimiter  = "{{"
        right_delimiter = "}}"
        data = <<-EOT
#!/bin/sh
{{ range service "openstudio-db" -}}
echo "{{ .Address }} db" >> /etc/hosts
{{ end -}}
{{ range service "openstudio-redis" -}}
echo "{{ .Address }} queue" >> /etc/hosts
{{ end -}}
{{ range $i, $s := shuffle (service "openstudio-rserve") -}}
{{ if eq $i 0 -}}
echo "{{ $s.Address }} rserve" >> /etc/hosts
{{ end -}}
{{ end -}}
EOT
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
