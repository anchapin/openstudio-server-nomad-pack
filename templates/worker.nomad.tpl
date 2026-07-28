job "[[ var "job_name" . ]]-worker" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  type        = "service"
  priority    = [[ var "worker_priority" . ]]

  group "worker" {
    count = [[ var "worker_count" . ]]

    task "worker" {
      driver = "docker"

      config {
        image   = "[[ var "worker_image" . ]]"
        command = "/usr/local/bin/start-workers"
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
      }

      resources {
        cpu    = [[ var "worker_cpu" . ]]
        memory = [[ var "worker_memory" . ]]
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
