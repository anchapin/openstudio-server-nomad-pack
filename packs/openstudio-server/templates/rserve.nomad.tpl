[[/*
  rserve.nomad.tpl
  Only rendered when batch_engine = "internal" (the default).
  When batch_engine is set to "nomad_batch" or "aws_batch", Rserve is not
  needed for remote worker dispatch; the external runner environment provides
  its own R execution context.
*/]]
[[ if eq (var "batch_engine" .) "internal" ]]
job "[[ var "job_name" . ]]-rserve" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"
  meta {
    app_version       = "[[ var "app_version" . ]]"
    ingress_domain    = "[[ var "ingress_domain" . ]]"
    vault_integration = "[[ var "vault_integration_enabled" . ]]" # observability label; not consumed by the Nomad scheduler
    deployment_marker = "[[ var "deployment_marker" . ]]"
  }

  group "rserve" {
    count = [[ var "rserve_count" . ]]
    [[ template "constraints" (var "rserve_constraints" .) ]]
    [[ if ne (var "web_rserve_colocation_node" .) "" ]]
    constraint {
      attribute = "${node.unique.name}"
      operator  = "="
      value     = "[[ var "web_rserve_colocation_node" . ]]"
    }
    [[ end ]]
    [[ template "affinities" (var "rserve_affinities" .) ]]
    [[ template "spreads" (var "rserve_spreads" .) ]]
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
      port "rserve" {
        to     = 6311
        static = 6311
      }
    }

    task "rserve" {
      driver = "docker"
      user   = "[[ var "docker_user" . ]]"
      [[ if var "nfs_shared_volume_enabled" . ]]
      volume_mount {
        volume      = "nfs-shared"
        destination = "[[ var "nfs_volume_mount_path" . ]]"
        read_only   = false
      }
      [[ end ]]

      [[ template "openstudio_server.vault_block" (dict "root" . "role" (var "vault_rserve_role" .)) ]]

      config {
        image = "[[ var "rserve_image" . ]]"
        ports = ["rserve"]
        ulimit {
          nofile = "[[ var "docker_ulimit_nofile" . ]]"
        }
        [[ if ne (var "rserve_command" .) "" ]]
        command = "[[ var "rserve_command" . ]]"
        [[ else ]]
        # Use Rserve() with args parameter to pass --RS-conf to child Rserve process
        # Config file is rendered to local/Rserve.conf -> /local/Rserve.conf in container
        # Use a shell wrapper to keep parent process alive while child Rserve runs
        command = "/bin/sh"
        [[ end ]]
        # Override image entrypoint to allow shell execution
        entrypoint = [""]
        [[ if var "rserve_args" . ]]
        args = [[ var "rserve_args" . | toJson ]]
        [[ else ]]
        # Default: run Rserve via Rserve() function with args parameter
        # The args parameter passes command-line arguments to the child Rserve process
        # --RS-conf tells child Rserve to read config from /local/Rserve.conf
        # Wrapper script keeps parent alive while child runs
        args = ["-c", "R --vanilla -e \"library(Rserve); Rserve(debug=FALSE, port=6311, args='--vanilla --RS-conf /local/Rserve.conf')\" & wait"]
        [[ end ]]
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        # Rserve (R) needs /tmp to create its temp directory even with a read-only rootfs.
        mounts = [
          {
            type          = "tmpfs"
            target        = "/tmp"
            tmpfs_options = { size = 67108864 }
          }
        ]
      }

      # Rserve config to bind to all interfaces (0.0.0.0)
      # Renders to local/Rserve.conf -> /local/Rserve.conf in container
      template {
        data        = <<EOH
# Rserve configuration
# Bind to all interfaces so Nomad port mapping works
address 0.0.0.0
port 6311
EOH
        destination = "local/Rserve.conf"
        change_mode = "restart"
      }

      service {
        name     = "openstudio-rserve"
        port     = "rserve"
        provider = "consul"
        tags = [
          "ingress.domain=[[ var "ingress_domain" . ]]"
        ]

        [[ if var "enable_consul_connect" . ]]
        connect {
          sidecar_service {
            proxy {
              local_service_address = "127.0.0.1"
              local_service_port    = 6311
            }
          }
        }
        [[ end ]]

        check {
          name     = "openstudio-rserve-tcp"
          type     = "tcp"
          interval = "[[ var "rserve_health_check_interval" . ]]"
          timeout  = "[[ var "rserve_health_check_timeout" . ]]"
        }
      }

      resources {
        cpu    = [[ var "rserve_cpu" . ]]
        memory = [[ var "rserve_memory" . ]]
      }

      env {
        APP_VERSION               = "[[ var "app_version" . ]]"
        VAULT_INTEGRATION_ENABLED = "[[ var "vault_integration_enabled" . ]]"
      }

      [[ template "openstudio_server.vault_integration_block" . ]]
    }

    [[ template "openstudio_server.vector_task" . ]]
    [[ template "openstudio_server.cleanup_poststop_task" . ]]
  }
}

[[ end ]]
