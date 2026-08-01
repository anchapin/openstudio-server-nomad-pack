job "[[ var "job_name" . ]]-web" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"
  priority    = [[ var "web_priority" . ]]
  meta {
    deployment_marker = "openstack-aurora-179d"
  }

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

    [[ template "constraints" (var "web_constraints" .) ]]
    [[ if ne (var "web_rserve_colocation_node" .) "" ]]
    constraint {
      attribute = "${node.unique.name}"
      operator  = "="
      value     = "[[ var "web_rserve_colocation_node" . ]]"
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

    network {
      port "http" {
        static = [[ var "web_port" . ]]
        to     = [[ var "web_container_port" . ]]
      }
    }

    # Prestart: wait for MongoDB, Redis, and Rserve to be registered and healthy in Consul
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
          "until wget -qO- \"http://[[ var "consul_address" . ]]/v1/health/service/openstudio-db?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-db\"'; do sleep 2; done; until wget -qO- \"http://[[ var "consul_address" . ]]/v1/health/service/openstudio-redis?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-redis\"'; do sleep 2; done; until wget -qO- \"http://[[ var "consul_address" . ]]/v1/health/service/openstudio-rserve?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-rserve\"'; do sleep 2; done",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "web" {
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

      env {
        MONGO_USER      = "[[ var "mongo_user" . ]]"
        QUEUES          = "analysis_wrappers"
        [[ if gt (var "web_mongoid_pool_size" .) 0 ]]
        MONGOID_POOL    = "[[ var "web_mongoid_pool_size" . ]]"
        [[ end ]]
        [[ if gt (var "web_max_requests" .) 0 ]]
        MAX_REQUESTS    = "[[ var "web_max_requests" . ]]"
        [[ else ]]
        MAX_REQUESTS    = "[[ printf "%.0f" (ceil (mulf (var "worker_max_replicas" .) (var "web_max_requests_multiplier" .))) ]]"
        [[ end ]]
        [[ if gt (var "web_max_pool" .) 0 ]]
        MAX_POOL        = "[[ var "web_max_pool" . ]]"
        [[ else ]]
        MAX_POOL        = "[[ printf "%.0f" (ceil (divf (mulf (var "web_memory" .) 0.75) (var "web_passenger_memory_per_process" .))) ]]"
        [[ end ]]
        OS_SERVER_NUMBER_OF_WORKERS = "[[ var "worker_process_count" . ]]"
        [[ if var "os_server_sampling_backend" . ]]
        OS_SERVER_SAMPLING_BACKEND = "[[ var "os_server_sampling_backend" . ]]"
        [[ end ]]
        [[ if var "web_redis_url" . ]]
        REDIS_URL       = "[[ var "web_redis_url" . ]]"
        [[ end ]]
        [[ if not (var "vault_integration_enabled" .) ]]
        MONGO_PASSWORD  = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD  = "[[ var "redis_password" . ]]"
        SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
        [[ end ]]
      }

      # Consul template to resolve 'db', 'queue', and 'rserve' hostnames used by the
      # OpenStudio Server startup scripts (which were written for Docker Compose
      # where MongoDB is 'db:27017', Redis is 'queue:6379', and Rserve is 'rserve:6311').
      # The generated script is executed via web_command/web_args overrides.
      #
      # Multi-replica Rserve routing: `shuffle` randomises the list of healthy Rserve
      # service instances on every Consul template re-render. `with index ... 0` picks
      # one entry from that shuffled list, providing round-robin-style load distribution
      # across replicas. Only instances that pass their Consul health check are included;
      # unhealthy allocations are automatically excluded, so a single replica failure
      # does not stall the optimization workflow.
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
{{ with index (shuffle (service "openstudio-rserve")) 0 -}}
echo "{{ .Address }} rserve" >> /etc/hosts
{{ end -}}
EOT
      }

      config {
        image           = "[[ var "web_image" . ]]"
        ports           = ["http"]
        ulimit {
          nofile = "[[ var "docker_ulimit_nofile" . ]]"
        }
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        [[ if var "web_extra_hosts" . ]]
        extra_hosts     = [[ var "web_extra_hosts" . | toJson ]]
        [[ end ]]
        [[ if ne (var "web_command" .) "" ]]
        command = "[[ var "web_command" . ]]"
        [[ end ]]
        [[ if var "web_args" . ]]
        args = [[ var "web_args" . | toJson ]]
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

      service {
        name     = "openstudio-web"
        port     = "http"
        provider = "consul"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.[[ var "job_name" . ]].rule=Host(`[[ var "ingress_domain" . ]]`)",
          "traefik.http.routers.[[ var "job_name" . ]].entrypoints=web",
          "traefik.http.services.[[ var "job_name" . ]].loadbalancer.server.port=$${NOMAD_PORT_http}",
          "traefik.http.services.[[ var "job_name" . ]].loadbalancer.responseForwarding.flushInterval=[[ var "traefik_request_timeout" . ]]",
          "traefik.http.middlewares.[[ var "job_name" . ]]-upload.buffering.maxRequestBodyBytes=[[ var "traefik_max_request_body_size" . ]]",
          "traefik.http.routers.[[ var "job_name" . ]].middlewares=[[ var "job_name" . ]]-upload",
          [[ if var "ingress_tls_enabled" . ]]
          "traefik.http.routers.[[ var "job_name" . ]]-tls.rule=Host(`[[ var "ingress_domain" . ]]`)",
          "traefik.http.routers.[[ var "job_name" . ]]-tls.entrypoints=websecure",
          "traefik.http.routers.[[ var "job_name" . ]]-tls.tls=true",
          "traefik.http.routers.[[ var "job_name" . ]]-tls.middlewares=[[ var "job_name" . ]]-upload",
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
    # WARNING: web-background must remain a singleton allocation.
    # Throughput tuning should be done with web_background_worker_count (COUNT),
    # not by increasing group replicas.
    count = 1
    [[ template "constraints" (var "web_constraints" .) ]]

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

    # Prestart: create and chmod the shared analysis directory on NFS before workers start.
    # Mirrors the helm chart's init-fix-shared-storage-perms init container.
    # Without this, a fresh NFS volume may lack the analyses directory; partial
    # extraction failures then leave stale files that cause "Destination already exists"
    # on the next initialization attempt.
    task "init-shared-storage-perms" {
      lifecycle {
        hook    = "prestart"
        sidecar = false
      }

      driver = "docker"
      user   = "0:0"

      [[ if var "nfs_shared_volume_enabled" . ]]
      volume_mount {
        volume      = "nfs-shared"
        destination = "[[ var "nfs_volume_mount_path" . ]]"
        read_only   = false
      }
      [[ end ]]

      config {
        image   = "[[ var "poststop_cleanup_image" . ]]"
        # Run as root so we can mkdir and chmod on the NFS mount.
        # CHOWN + FOWNER are re-added after the global cap_drop = ["ALL"].
        cap_drop = ["ALL"]
        cap_add  = ["CHOWN", "FOWNER"]
        command = "sh"
        args = [
          "-c",
          <<-EOF
set -eu
mkdir -p [[ var "nfs_volume_mount_path" . ]]/server/assets/analyses
chmod 2775 [[ var "nfs_volume_mount_path" . ]]/server
chmod 2777 [[ var "nfs_volume_mount_path" . ]]/server/assets [[ var "nfs_volume_mount_path" . ]]/server/assets/analyses
echo "init-shared-storage-perms: ensured writable permissions on [[ var "nfs_volume_mount_path" . ]]/server/assets/analyses"
EOF
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    # Prestart: wait for MongoDB, Redis, and Rserve to be healthy in Consul
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
          "until wget -qO- \"http://[[ var "consul_address" . ]]/v1/health/service/openstudio-db?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-db\"'; do sleep 2; done; until wget -qO- \"http://[[ var "consul_address" . ]]/v1/health/service/openstudio-redis?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-redis\"'; do sleep 2; done; until wget -qO- \"http://[[ var "consul_address" . ]]/v1/health/service/openstudio-rserve?passing=true\" | tr -d '[:space:]' | grep -q '\"Service\":\"openstudio-rserve\"'; do sleep 2; done",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "web-background" {
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

      env {
        MONGO_USER      = "[[ var "mongo_user" . ]]"
        QUEUES          = "[[ var "web_background_queues" . ]]"
        COUNT           = "[[ var "web_background_worker_count" . ]]"
        [[ if gt (var "web_background_mongoid_pool_size" .) 0 ]]
        MONGOID_POOL    = "[[ var "web_background_mongoid_pool_size" . ]]"
        [[ else ]]
        MONGOID_POOL    = "[[ add (var "web_background_worker_count" .) 2 ]]"
        [[ end ]]
        OS_SERVER_NUMBER_OF_WORKERS = "[[ var "worker_process_count" . ]]"
        [[ if var "os_server_sampling_backend" . ]]
        OS_SERVER_SAMPLING_BACKEND = "[[ var "os_server_sampling_backend" . ]]"
        [[ end ]]
        [[ if var "web_redis_url" . ]]
        REDIS_URL       = "[[ var "web_redis_url" . ]]"
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
{{ range service "openstudio-rserve" -}}
echo "{{ .Address }} rserve" >> /etc/hosts
{{ end -}}
EOT
      }

      config {
        image           = "[[ var "web_background_image" . ]]"
        ulimit {
          nofile = "[[ var "docker_ulimit_nofile" . ]]"
        }
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        [[ if var "web_extra_hosts" . ]]
        extra_hosts     = [[ var "web_extra_hosts" . | toJson ]]
        [[ end ]]
        [[ if ne (var "web_background_command" .) "" ]]
        command = "[[ var "web_background_command" . ]]"
        [[ end ]]
        [[ if var "web_background_args" . ]]
        args = [[ var "web_background_args" . | toJson ]]
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
        cpu        = [[ var "web_background_cpu" . ]]
        memory     = [[ var "web_background_memory" . ]]
        [[ if gt (var "web_background_memory_max" .) 0 ]]memory_max = [[ var "web_background_memory_max" . ]][[ end ]]
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
