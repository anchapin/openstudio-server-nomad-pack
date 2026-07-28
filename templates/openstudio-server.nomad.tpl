job "[[ var "job_name" . ]]" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  type        = "service"
  meta {
    app_version           = "[[ var "app_version" . ]]"
    worker_min_replicas   = "[[ var "worker_min_replicas" . ]]"
    worker_max_replicas   = "[[ var "worker_max_replicas" . ]]"
    ingress_domain        = "[[ var "ingress_domain" . ]]"
    vault_integration     = "[[ var "vault_integration_enabled" . ]]"
  }

  # Placeholder groups mapping to openstudio-server components:
  # web, web-background, worker, db, redis, rserve.

  group "web" {
    count = 1

    network {
      port "http" {
        to = 8080
      }
    }

    task "web" {
      driver = "docker"

      config {
        image = "[[ var "web_image" . ]]"
        ports = ["http"]
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

        check {
          name     = "openstudio-web-tcp"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }

        check {
          name     = "openstudio-web-liveness"
          type     = "http"
          path     = "/up"
          interval = "10s"
          timeout  = "2s"
        }

        check {
          name     = "openstudio-web-readiness"
          type     = "http"
          path     = "/"
          interval = "10s"
          timeout  = "2s"
        }
      }

      resources {
        cpu    = [[ var "db_cpu" . ]]
        memory = [[ var "db_memory" . ]]
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
  
  group "db" {
    count = 1
    [[ if ne (var "mongodb_storage_type" .) "ephemeral" ]]
    volume "mongodb_data" {
      type      = "[[ var "mongodb_storage_type" . ]]"
      source    = "[[ var "mongodb_volume_source" . ]]"
      read_only = false
    }
    [[ end ]]
    [[ template "constraints" (var "db_constraints" .) ]]
    [[ template "affinities" (var "db_affinities" .) ]]
    [[ template "spreads" (var "db_spreads" .) ]]
    
    network {
      port "db" {
        to = 27017
      }
    }

    task "mongodb" {
      driver = "docker"

      config {
        image = "[[ var "db_image" . ]]"
        ports = ["db"]
        user = "[[ var "docker_user" . ]]"
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop = [[ var "docker_cap_drop" . | toJson ]]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      [[ if ne (var "mongodb_storage_type" .) "ephemeral" ]]
      volume_mount {
        volume      = "mongodb_data"
        destination = "/data/db"
        read_only   = false
      }
      [[ end ]]

      env {
        APP_VERSION               = "[[ var "app_version" . ]]"
        MONGODB_STORAGE_TYPE      = "[[ var "mongodb_storage_type" . ]]"
        MONGODB_VOLUME_SOURCE     = "[[ var "mongodb_volume_source" . ]]"
        WORKER_MIN_REPLICAS       = "[[ var "worker_min_replicas" . ]]"
        WORKER_MAX_REPLICAS       = "[[ var "worker_max_replicas" . ]]"
        VAULT_INTEGRATION_ENABLED = "[[ var "vault_integration_enabled" . ]]"
        INGRESS_DOMAIN            = "[[ var "ingress_domain" . ]]"
      }

      [[ if var "vault_integration_enabled" . ]]
      vault {}
      [[ end ]]

      service {
        name = "openstudio-db"
        port = "db"
        provider = "consul"
        tags = [
          "ingress.domain=[[ var "ingress_domain" . ]]"
        ]

        [[ if var "enable_consul_connect" . ]]
        connect {
          sidecar_service {
            proxy {
              local_service_address = "127.0.0.1"
              local_service_port    = 27017
            }
          }
        }
        [[ end ]]
        
        check {
          name     = "openstudio-db-tcp"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }

    task "cleanup-poststop" {
      driver = "docker"

      lifecycle {
        hook = "poststop"
      }

      config {
        image   = "[[ var "poststop_cleanup_image" . ]]"
        command = "sh"
        args = [
          "-ec",
          <<EOT
set -eu
[[ range var "poststop_cleanup_paths" . -]]
rm -rf "[[ . ]]"
[[ end -]]
EOT
        ]
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
        user = "[[ var "docker_user" . ]]"
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop = [[ var "docker_cap_drop" . | toJson ]]
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

  group "redis" {
    count = 1
    [[ template "constraints" (var "redis_constraints" .) ]]
    [[ template "affinities" (var "redis_affinities" .) ]]
    [[ template "spreads" (var "redis_spreads" .) ]]

    network {
      port "redis" {
        to = 6379
      }
    }

    task "redis" {
      driver = "docker"

      config {
        image = "[[ var "redis_image" . ]]"
        ports = ["redis"]
        user = "[[ var "docker_user" . ]]"
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop = [[ var "docker_cap_drop" . | toJson ]]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      service {
        name = "openstudio-redis"
        port = "redis"
        provider = "consul"
        tags = [
          "ingress.domain=[[ var "ingress_domain" . ]]"
        ]

        [[ if var "enable_consul_connect" . ]]
        connect {
          sidecar_service {
            proxy {
              local_service_address = "127.0.0.1"
              local_service_port    = 6379
            }
          }
        }
        [[ end ]]

        check {
          name     = "openstudio-redis-tcp"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }

      resources {
        cpu    = [[ var "redis_cpu" . ]]
        memory = [[ var "redis_memory" . ]]
      }
    }

    task "cleanup-poststop" {
      driver = "docker"

      lifecycle {
        hook = "poststop"
      }

      config {
        image   = "[[ var "poststop_cleanup_image" . ]]"
        command = "sh"
        args = [
          "-ec",
          <<EOT
set -eu
[[ range var "poststop_cleanup_paths" . -]]
rm -rf "[[ . ]]"
[[ end -]]
EOT
        ]
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
        user = "[[ var "docker_user" . ]]"
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop = [[ var "docker_cap_drop" . | toJson ]]
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
