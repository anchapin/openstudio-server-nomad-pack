job "[[ var "job_name" . ]]-web" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"
  priority    = [[ var "web_priority" . ]]

  update {
    max_parallel      = [[ var "web_update_max_parallel" . ]]
    health_check      = "[[ var "web_update_health_check" . ]]"
    min_healthy_time  = "[[ var "web_update_min_healthy_time" . ]]"
    healthy_deadline  = "[[ var "web_update_healthy_deadline" . ]]"
    progress_deadline = "[[ var "web_update_progress_deadline" . ]]"
    auto_revert       = [[ var "web_update_auto_revert" . ]]
  }

  group "web" {
    # WARNING: web_count must remain 1 (the default).
    # The OpenStudio Server web process uses local filesystem state (e.g. uploaded
    # analysis files under /mnt/openstudio) without a distributed file-locking scheme.
    # Running more than one web replica causes split-brain: each allocation writes to
    # its own private view of the filesystem, so file operations on one node are
    # invisible to the others.  This mirrors the Helm chart constraint
    # (web-hpa.yaml maxReplicas: 1, "NFS cannot guarantee file locking using multiple
    # clients").
    #
    # To safely run web_count > 1 you must first implement one of:
    #   a) A distributed lock manager (e.g. Redlock via Redis) wrapping every
    #      filesystem operation in the web process, OR
    #   b) Stateless file handling: move all persistent artefacts to object storage
    #      (e.g. S3) and eliminate local-disk writes from the request path.
    count = [[ var "web_count" . ]]

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

    network {
      port "http" {
        static = [[ var "web_port" . ]]
        to     = 8080
      }
    }

    # Prestart: wait for MongoDB and Redis to be registered and healthy in Consul
    task "wait-for-deps" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "busybox:1.36"
        command = "sh"
        args = [
          "-ec",
          "until wget -qO- \"http://consul.service.consul:8500/v1/health/service/openstudio-db?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-db\"'; do sleep 2; done; until wget -qO- \"http://consul.service.consul:8500/v1/health/service/openstudio-redis?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-redis\"'; do sleep 2; done",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "web" {
      driver = "docker"

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

      [[ if not (var "vault_integration_enabled" .) ]]
      env {
        MONGO_PASSWORD      = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD      = "[[ var "redis_password" . ]]"
        APP_SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
      }
      [[ end ]]

      config {
        image = "[[ var "web_image" . ]]"
        ports = ["http"]
        [[ if ne (var "web_command" .) "" ]]
        command = "[[ var "web_command" . ]]"
        [[ end ]]
        [[ if var "web_args" . ]]
        args = [[ var "web_args" . | toJson ]]
        [[ end ]]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      service {
        name     = "openstudio-web"
        port     = "http"
        provider = "consul"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.[[ var "job_name" . ]].rule=Host(`[[ var "ingress_domain" . ]]`)",
          "traefik.http.routers.[[ var "job_name" . ]].entrypoints=web",
          "traefik.http.services.[[ var "job_name" . ]].loadbalancer.server.port=$${NOMAD_PORT_http}",
          [[ if var "ingress_tls_enabled" . ]]
          "traefik.http.routers.[[ var "job_name" . ]]-tls.rule=Host(`[[ var "ingress_domain" . ]]`)",
          "traefik.http.routers.[[ var "job_name" . ]]-tls.entrypoints=websecure",
          "traefik.http.routers.[[ var "job_name" . ]]-tls.tls=true",
          [[ end ]]
        ]

        check {
          name     = "openstudio-web-http"
          type     = "http"
          path     = "/status"
          interval = "[[ var "web_health_check_interval" . ]]"
          timeout  = "[[ var "web_health_check_timeout" . ]]"
        }
      }

      resources {
        cpu        = [[ var "web_cpu" . ]]
        memory     = [[ var "web_memory" . ]]
        memory_max = [[ var "web_memory_max" . ]]
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

  group "web-background" {
    count = [[ var "web_background_count" . ]]

    [[ if var "web_background_autoscaling_enabled" . ]]
    scaling {
      enabled = true
      min     = [[ var "web_background_min_replicas" . ]]
      max     = [[ var "web_background_max_replicas" . ]]

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

    # Prestart: wait for MongoDB, Redis, and the web service to be healthy in Consul
    task "wait-for-deps" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "busybox:1.36"
        command = "sh"
        args = [
          "-ec",
          "until wget -qO- \"http://consul.service.consul:8500/v1/health/service/openstudio-db?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-db\"'; do sleep 2; done; until wget -qO- \"http://consul.service.consul:8500/v1/health/service/openstudio-redis?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-redis\"'; do sleep 2; done; until wget -qO- \"http://consul.service.consul:8500/v1/health/service/openstudio-web?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-web\"'; do sleep 2; done",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "web-background" {
      driver = "docker"

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

      [[ if not (var "vault_integration_enabled" .) ]]
      env {
        MONGO_PASSWORD      = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD      = "[[ var "redis_password" . ]]"
        APP_SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
      }
      [[ end ]]

      config {
        image = "[[ var "web_background_image" . ]]"
        [[ if ne (var "web_background_command" .) "" ]]
        command = "[[ var "web_background_command" . ]]"
        [[ end ]]
        [[ if var "web_background_args" . ]]
        args = [[ var "web_background_args" . | toJson ]]
        [[ end ]]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      service {
        name     = "openstudio-web-background"
        provider = "consul"

        tags = [
          "traefik.enable=false",
        ]

        check {
          name     = "openstudio-web-background-alive"
          type     = "script"
          command  = "/bin/sh"
          args     = ["-c", "exit 0"]
          interval = "[[ var "web_health_check_interval" . ]]"
          timeout  = "[[ var "web_health_check_timeout" . ]]"
          task     = "web-background"
        }
      }

      resources {
        cpu    = [[ var "web_background_cpu" . ]]
        memory = [[ var "web_background_memory" . ]]
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
