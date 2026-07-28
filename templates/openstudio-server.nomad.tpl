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
  
  group "db" {
    count = 1

    [[ if ne (var "mongodb_storage_type" .) "ephemeral" ]]
    volume "mongodb_data" {
      type      = "[[ var "mongodb_storage_type" . ]]"
      source    = "[[ var "mongodb_volume_source" . ]]"
      read_only = false
    }
    [[ end ]]
    
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
        
        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
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

  group "redis" {
    count = 1

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

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
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
