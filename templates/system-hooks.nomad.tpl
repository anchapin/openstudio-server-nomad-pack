job "[[ var "job_name" . ]]-system-hooks" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  type        = "system"

  group "prepull" {
    task "pull-web-image" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "[[ var "web_image" . ]]"
        command = "sh"
        args    = ["-c", "echo pulled web image"]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }
    }

    task "pull-worker-image" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      config {
        image   = "[[ var "worker_image" . ]]"
        command = "sh"
        args    = ["-c", "echo pulled worker image"]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }
    }

    task "image-cache-ready" {
      driver = "docker"

      config {
        image   = "alpine:3.20"
        command = "sh"
        args    = ["-c", "sleep infinity"]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      resources {
        cpu    = 20
        memory = 32
      }
    }
  }
}
