[[ if var "enable_image_prepull" . ]]
job "[[ var "job_name" . ]]-system-hooks" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "system"

  # Only schedule on nodes that have the Docker driver enabled.
  constraint {
    attribute = "${attr.driver.docker}"
    value     = "1"
  }

  group "prepull-worker-images" {
    [[ template "constraints" (var "worker_constraints" .) ]]
    [[ if ne (var "worker_instance_type" .) "" ]]
    constraint {
      attribute = "${attr.platform.aws.instance-type}"
      operator  = "="
      value     = "[[ var "worker_instance_type" . ]]"
    }
    [[ end ]]
    [[ if var "worker_runtime_image" . ]]
    # pull-worker-image uses raw_exec to pull+tag atomically; add an explicit
    # constraint so Nomad's implicit driver filter is visible in the job spec
    # and the pre-pull target_nodes count stays in sync with scheduler reality.
    constraint {
      attribute = "${attr.driver.raw_exec}"
      operator  = "="
      value     = "1"
    }
    [[ end ]]

    restart {
      attempts = 3
      mode     = "fail"
    }

    task "pull-worker-image" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      [[ if var "worker_runtime_image" . ]]
      # When worker_runtime_image is set, use raw_exec so we can both pull the
      # image from the registry and tag it as the host-local alias in one atomic
      # step. This prevents worker allocations from ever contacting the upstream
      # registry at runtime (avoids Pulp TLS handshake timeouts on every alloc start).
      # Requires raw_exec driver to be enabled on worker nodes (see bootstrap-179d-node.sh).
      driver = "raw_exec"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        command = "/bin/sh"
        args    = ["-c", "docker pull [[ var "worker_image" . ]] && docker tag [[ var "worker_image" . ]] [[ var "worker_runtime_image" . ]] && echo 'worker image pulled and tagged as [[ var "worker_runtime_image" . ]]'"]
      }
      [[ else ]]
      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        image      = "[[ var "worker_image" . ]]"
        force_pull = false
        command    = "sh"
        args       = ["-c", "echo worker image cached successfully"]

        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }
      [[ end ]]

      resources {
        cpu    = 100
        memory = 64
      }
    }

    # Long-running sentinel task that keeps the allocation alive after all
    # prestart tasks complete, so the node retains the pre-pulled image layers.
    # Uses the worker image (worker_runtime_image if set, else worker_image) so
    # Nomad's Docker image GC tracks this alloc as holding a reference to the
    # worker image. Without this, GC removes the image when worker allocs stop
    # (e.g. during a redeployment), causing the next set of worker allocs to fail
    # with "pull access denied" on nodes where the runtime alias was GC'd.
    task "image-cache-ready" {
      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        image      = "[[ if var "worker_runtime_image" . ]][[ var "worker_runtime_image" . ]][[ else ]][[ var "worker_image" . ]][[ end ]]"
        force_pull = false
        command    = "sleep"
        args       = ["999999999"]

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

  group "prepull-core-images" {
    [[ template "constraints" (var "web_constraints" .) ]]

    restart {
      attempts = 3
      mode     = "fail"
    }

    task "pull-web-image" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

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

      resources {
        cpu    = 100
        memory = 64
      }
    }

    task "pull-web-background-image" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        image   = "[[ var "web_background_image" . ]]"
        command = "sh"
        args    = ["-c", "echo pulled web background image"]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    task "pull-db-image" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        image   = "[[ var "db_image" . ]]"
        command = "sh"
        args    = ["-c", "echo pulled db image"]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    task "pull-redis-image" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        image   = "[[ var "redis_image" . ]]"
        command = "sh"
        args    = ["-c", "echo pulled redis image"]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    task "pull-rserve-image" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        image   = "[[ var "rserve_image" . ]]"
        command = "sh"
        args    = ["-c", "echo pulled rserve image"]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }

    [[ if var "enable_vector_collection" . ]]
    task "pull-vector" {
      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        image   = "[[ var "vector_image" . ]]"
        command = "sh"
        args    = ["-c", "echo pulled vector image"]
        logging {
          type = "[[ var "log_driver_type" . ]]"
          config {
            max-size = "[[ var "log_max_size" . ]]"
            max-file = "[[ var "log_max_files" . ]]"
          }
        }
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
    [[ end ]]

    task "image-cache-ready-core" {
      driver = "docker"

      kill_timeout = "[[ var "prepull_kill_timeout" . ]]"

      config {
        image   = "[[ var "verification_image" . ]]"
        command = "sh"
        args    = ["-c", "sleep 999999999"]
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
[[ end ]]
