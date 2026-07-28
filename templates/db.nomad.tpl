job "[[ var "job_name" . ]]-db" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  type        = "service"

  group "db" {
    count = 1

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

      service {
        name     = "openstudio-db"
        port     = "db"
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
