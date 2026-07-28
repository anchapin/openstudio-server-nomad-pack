job "[[ var "job_name" . ]]-web" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"
  priority    = [[ var "web_priority" . ]]

  group "web" {
    count = 1

    [[ if var "nfs_shared_volume_enabled" . ]]
    volume "nfs-shared" {
      type            = "csi"
      source          = "[[ var "nfs_volume_source" . ]]"
      access_mode     = "multi-node-multi-writer"
      attachment_mode = "file-system"
    }
    [[ end ]]

    network {
      port "http" {
        static = 80
        to     = 8080
      }
    }

    task "web" {
      driver = "docker"

      [[ if var "nfs_shared_volume_enabled" . ]]
      volume_mount {
        volume      = "nfs-shared"
        destination = "[[ var "nfs_volume_mount_path" . ]]"
        read_only   = false
      }
      [[ end ]]

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

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.[[ var "job_name" . ]].rule=Host(`[[ var "ingress_domain" . ]]`)",
          "traefik.http.routers.[[ var "job_name" . ]].entrypoints=web",
          "traefik.http.services.[[ var "job_name" . ]].loadbalancer.server.port=$${NOMAD_PORT_http}",
          [[ if var "ingress_tls_enabled" . ]]
          "traefik.http.routers.[[ var "job_name" . ]]-tls.rule=Host(`[[ var "ingress_domain" . ]]`)",
          "traefik.http.routers.[[ var "job_name" . ]]-tls.entrypoints=websecure",
          "traefik.http.routers.[[ var "job_name" . ]]-tls.tls=true",
          [[ end ]]
        ]

        check {
          type     = "http"
          path     = "/"
          interval = "10s"
          timeout  = "2s"
        }
      }

      resources {
        cpu    = [[ var "web_cpu" . ]]
        memory = [[ var "web_memory" . ]]
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
