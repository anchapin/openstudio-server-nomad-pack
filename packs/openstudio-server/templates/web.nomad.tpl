job "[[ var "job_name" . ]]-web" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"
  priority    = [[ var "web_priority" . ]]
  meta {
    deployment_marker = "[[ var "deployment_marker" . ]]"
  }

  [[ template "openstudio_server.update_block" (dict "max_parallel" (var "web_update_max_parallel" .) "canary" (var "web_update_canary" .) "auto_promote" (var "web_update_auto_promote" .) "stagger" (var "web_update_stagger" .) "health_check" (var "web_update_health_check" .) "min_healthy_time" (var "web_update_min_healthy_time" .) "healthy_deadline" (var "web_update_healthy_deadline" .) "progress_deadline" (var "web_update_progress_deadline" .) "auto_revert" (var "web_update_auto_revert" .)) ]]

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

    [[ template "openstudio_server.wait_for_deps_task" (dict "root" . "include_rserve" true "proceed_on_timeout" (var "web_wait_for_deps_proceed_on_timeout" .)) ]]

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

      [[ template "openstudio_server.vault_integration_block" . ]]

      [[ if var "vault_integration_enabled" . ]]
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

      [[ template "openstudio_server.vault_block" (dict "root" .) ]]

      env {
        MONGO_USER = "[[ var "mongo_user" . ]]"
        QUEUES     = "analysis_wrappers"
        [[ if gt (var "web_mongoid_pool_size" .) 0 ]]
        MONGOID_POOL = "[[ var "web_mongoid_pool_size" . ]]"
        [[ end ]]
        [[ if gt (var "web_max_requests" .) 0 ]]
        MAX_REQUESTS = "[[ var "web_max_requests" . ]]"
        [[ else ]]
        MAX_REQUESTS = "[[ printf "%.0f" (ceil (mulf (var "worker_max_replicas" .) (var "web_max_requests_multiplier" .))) ]]"
        [[ end ]]
        [[ if gt (var "web_max_pool" .) 0 ]]
        MAX_POOL = "[[ var "web_max_pool" . ]]"
        [[ else ]]
        MAX_POOL = "[[ printf "%.0f" (ceil (divf (mulf (var "web_memory" .) 0.75) (var "web_passenger_memory_per_process" .))) ]]"
        [[ end ]]
        OS_SERVER_NUMBER_OF_WORKERS = "[[ var "worker_process_count" . ]]"
        [[ if var "os_server_sampling_backend" . ]]
        OS_SERVER_SAMPLING_BACKEND = "[[ var "os_server_sampling_backend" . ]]"
        [[ end ]]
        [[ if var "web_redis_url" . ]]
        REDIS_URL = "[[ var "web_redis_url" . ]]"
        [[ end ]]
        [[ if not (var "vault_integration_enabled" .) ]]
        MONGO_PASSWORD  = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD  = "[[ var "redis_password" . ]]"
        SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
        [[ end ]]
        [[ if var "swift_artifact_storage_enabled" . ]]
        ARTIFACT_STORAGE_BACKEND = "swift"
        OS_AUTH_URL              = "[[ var "swift_auth_url" . ]]"
        OS_USERNAME              = "[[ var "swift_username" . ]]"
        OS_PASSWORD              = "[[ var "swift_password" . ]]"
        OS_TENANT_NAME           = "[[ var "swift_tenant_name" . ]]"
        OS_REGION_NAME           = "[[ var "swift_region" . ]]"
        OS_AUTH_VERSION          = "[[ var "swift_auth_version" . ]]"
        SWIFT_CONTAINER          = "[[ var "swift_container" . ]]"
        [[ end ]]
        [[ if ne (var "batch_engine" .) "internal" ]]
        # ── External batch dispatcher flags ──────────────────────────────────
        # The Ruby app reads OS_EXTERNAL_BATCH to enable its batch dispatcher
        # code path, and BATCH_PROVIDER to select the backend adapter.
        OS_EXTERNAL_BATCH = "true"
        BATCH_PROVIDER    = "[[ var "batch_engine" . ]]"
        [[ if eq (var "batch_engine" .) "nomad_batch" ]]
        # Nomad Batch provider settings passed to the dispatcher.
        # NOMAD_ADDR is automatically injected by the Nomad agent.
        # NOMAD_TOKEN is provided by the Workload Identity block below.
        NOMAD_BATCH_JOB_NAME  = "[[ var "job_name" . ]]-[[ var "nomad_batch_job_name" . ]]"
        NOMAD_BATCH_NAMESPACE = "[[ if ne (var "nomad_batch_namespace" .) "" ]][[ var "nomad_batch_namespace" . ]][[ else ]][[ var "nomad_namespace" . ]][[ end ]]"
        [[ end ]]
        [[ if eq (var "batch_engine" .) "aws_batch" ]]
        # AWS Batch provider settings.
        AWS_DEFAULT_REGION       = "[[ var "aws_region" . ]]"
        AWS_BATCH_JOB_QUEUE      = "[[ var "aws_batch_job_queue" . ]]"
        AWS_BATCH_JOB_DEFINITION = "[[ var "aws_batch_job_definition" . ]]"
        [[ end ]]
        [[ end ]]
      }

      [[ if eq (var "batch_engine" .) "nomad_batch" ]]
      # Nomad Workload Identity — grants the web task a short-lived token
      # scoped to submit/dispatch/read jobs in the batch namespace.
      # The agent exposes the token at ${NOMAD_TOKEN} automatically.
      identity {
        name = "nomad-batch-dispatcher"
        aud  = ["nomad.io"]
        ttl  = "[[ var "nomad_batch_identity_ttl" . ]]"
        env  = true
        file = false
      }
      [[ end ]]

      template {
        destination = "local/patch-hosts.sh"
        change_mode = "script"
        change_script {
          command       = "/bin/sh"
          args          = ["-c", "grep -vE ' (db|queue|rserve)$' /etc/hosts > /alloc/hosts.tmp 2>/dev/null; cat /alloc/hosts.tmp > /etc/hosts; sh /local/patch-hosts.sh"]
          timeout       = "30s"
          fail_on_error = true
        }
        data            = <<-EOT
[[ template "openstudio_server.runtime_hosts_patch_script" (dict "root" . "include_web_alias" false "log_prefix" "web") ]]
EOT
      }

      config {
        image = "[[ var "web_image" . ]]"
        ports = ["http"]
        ulimit {
          nofile = "[[ var "docker_ulimit_nofile" . ]]"
        }
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        [[ if var "web_extra_hosts" . ]]
        extra_hosts = [[ var "web_extra_hosts" . | toJson ]]
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

    [[ template "openstudio_server.vector_task" . ]]
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
        image = "[[ var "poststop_cleanup_image" . ]]"
        # Run as root so we can mkdir and chmod on the NFS mount.
        # CHOWN + FOWNER are re-added after the global cap_drop = ["ALL"].
        cap_drop = ["ALL"]
        cap_add  = ["CHOWN", "FOWNER"]
        command  = "sh"
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

    [[ template "openstudio_server.wait_for_deps_task" (dict "root" . "include_rserve" true "proceed_on_timeout" (var "web_wait_for_deps_proceed_on_timeout" .)) ]]

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

      [[ template "openstudio_server.vault_integration_block" . ]]

      [[ if var "vault_integration_enabled" . ]]
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

      [[ template "openstudio_server.vault_block" (dict "root" .) ]]

      env {
        MONGO_USER = "[[ var "mongo_user" . ]]"
        QUEUES     = "[[ var "web_background_queues" . ]]"
        COUNT      = "[[ var "web_background_worker_count" . ]]"
        [[ if gt (var "web_background_mongoid_pool_size" .) 0 ]]
        MONGOID_POOL = "[[ var "web_background_mongoid_pool_size" . ]]"
        [[ else ]]
        MONGOID_POOL = "[[ add (var "web_background_worker_count" .) 2 ]]"
        [[ end ]]
        OS_SERVER_NUMBER_OF_WORKERS = "[[ var "worker_process_count" . ]]"
        [[ if var "os_server_sampling_backend" . ]]
        OS_SERVER_SAMPLING_BACKEND = "[[ var "os_server_sampling_backend" . ]]"
        [[ end ]]
        [[ if var "web_redis_url" . ]]
        REDIS_URL = "[[ var "web_redis_url" . ]]"
        [[ end ]]
        [[ if not (var "vault_integration_enabled" .) ]]
        MONGO_PASSWORD  = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD  = "[[ var "redis_password" . ]]"
        SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
        [[ end ]]
      }

      template {
        destination = "local/patch-hosts.sh"
        change_mode = "script"
        change_script {
          command       = "/bin/sh"
          args          = ["-c", "grep -vE ' (db|queue|rserve)$' /etc/hosts > /alloc/hosts.tmp 2>/dev/null; cat /alloc/hosts.tmp > /etc/hosts; sh /local/patch-hosts.sh"]
          timeout       = "30s"
          fail_on_error = true
        }
        data            = <<-EOT
[[ template "openstudio_server.runtime_hosts_patch_script" (dict "root" . "include_web_alias" false "log_prefix" "web_background") ]]
EOT
      }

      config {
        image = "[[ var "web_background_image" . ]]"
        ulimit {
          nofile = "[[ var "docker_ulimit_nofile" . ]]"
        }
        readonly_rootfs = [[ var "docker_readonly_rootfs" . ]]
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        [[ if var "web_extra_hosts" . ]]
        extra_hosts = [[ var "web_extra_hosts" . | toJson ]]
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
        cpu                              = [[ var "web_background_cpu" . ]]
        memory                           = [[ var "web_background_memory" . ]]
        [[ if gt (var "web_background_memory_max" .) 0 ]]memory_max = [[ var "web_background_memory_max" . ]][[ end ]]
      }
    }

    [[ template "openstudio_server.vector_task" . ]]
  }

}
