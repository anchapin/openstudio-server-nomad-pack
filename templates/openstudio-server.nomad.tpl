job "[[ var "job_name" . ]]" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  type        = "service"

  # Placeholder groups mapping to openstudio-server components:
  # web, web-background, worker, db, redis, rserve.
  
  group "db" {
    count = 1

    [[ if eq (var "mongodb_storage_type" .) "host" ]]
    volume "mongodb-data" {
      type      = "host"
      source    = "[[ var "mongodb_host_volume" . ]]"
      read_only = false
    }
    [[ else if eq (var "mongodb_storage_type" .) "csi" ]]
    volume "mongodb-data" {
      type            = "csi"
      source          = "[[ var "mongodb_csi_volume" . ]]"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = false
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
        volume      = "mongodb-data"
        destination = "/data/db"
        read_only   = false
      }
      [[ end ]]

      service {
        name = "openstudio-db"
        port = "db"
        provider = "consul"
        
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

    [[ if eq (var "redis_storage_type" .) "host" ]]
    volume "redis-data" {
      type      = "host"
      source    = "[[ var "redis_host_volume" . ]]"
      read_only = false
    }
    [[ else if eq (var "redis_storage_type" .) "csi" ]]
    volume "redis-data" {
      type            = "csi"
      source          = "[[ var "redis_csi_volume" . ]]"
      access_mode     = "single-node-writer"
      attachment_mode = "file-system"
      read_only       = false
    }
    [[ end ]]

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

      [[ if ne (var "redis_storage_type" .) "ephemeral" ]]
      volume_mount {
        volume      = "redis-data"
        destination = "/data"
        read_only   = false
      }
      [[ end ]]

      service {
        name = "openstudio-redis"
        port = "redis"
        provider = "consul"

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
