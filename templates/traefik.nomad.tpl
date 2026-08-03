[[ if var "deploy_traefik" . ]]
job "[[ var "job_name" . ]]-traefik" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"

  [[ template "openstudio_server.update_block" (dict "max_parallel" 1 "health_check" "checks" "min_healthy_time" "10s" "healthy_deadline" "5m" "progress_deadline" "10m" "auto_revert" true) ]]

  group "traefik" {
    count = 1

    [[ template "openstudio_server.arch_constraint" . ]]

    network {
      port "http" {
        static = [[ var "traefik_http_port" . ]]
      }
      port "https" {
        static = [[ var "traefik_https_port" . ]]
      }
      port "dashboard" {
        static = [[ var "traefik_dashboard_port" . ]]
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image = "[[ var "traefik_image" . ]]"
        ports = ["http", "https", "dashboard"]
        args = [
          "--providers.consulcatalog.endpoint.address=consul.service.consul:8500",
          "--entrypoints.web.address=:[[ var "traefik_http_port" . ]]",
          "--entrypoints.web.transport.respondingTimeouts.readTimeout=[[ var "traefik_read_timeout" . ]]",
          "--entrypoints.web.transport.respondingTimeouts.writeTimeout=[[ var "traefik_write_timeout" . ]]",
          "--entrypoints.websecure.address=:[[ var "traefik_https_port" . ]]",
          "--entrypoints.websecure.transport.respondingTimeouts.readTimeout=[[ var "traefik_read_timeout" . ]]",
          "--entrypoints.websecure.transport.respondingTimeouts.writeTimeout=[[ var "traefik_write_timeout" . ]]",
          "--api.dashboard=true",
          "--api.insecure=[[ if var "traefik_api_insecure" . ]]true[[ else ]]false[[ end ]]",
        ]
      }

      resources {
        cpu    = 200
        memory = 128
      }

      service {
        name     = "traefik"
        port     = "http"
        provider = "consul"

        check {
          name     = "traefik-http-alive"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
[[ end ]]
