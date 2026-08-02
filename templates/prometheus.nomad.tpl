[[ if var "prometheus_enabled" . ]]
job "[[ var "job_name" . ]]-prometheus" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "service"

  group "prometheus" {
    count = 1
    [[ template "constraints" (var "prometheus_constraints" .) ]]
    [[ template "affinities" (var "prometheus_affinities" .) ]]
    [[ template "spreads" (var "prometheus_spreads" .) ]]

    network {
      port "http" {
        static = [[ var "prometheus_static_port" . ]]
      }
      port "redis_exporter" {
        static = 9121
      }
    }

    task "redis-exporter" {
      driver = "docker"

      config {
        image       = "[[ var "redis_exporter_image" . ]]"
        force_pull  = false
        network_mode = "host"
        args  = ["--check-keys=resque:queue:simulations,resque:queue:requeued"]
      }

      template {
        destination = "secrets/env"
        env         = true
        data        = <<EOT
{{ with service "openstudio-redis" -}}
REDIS_ADDR=redis://{{ (index . 0).Address }}:{{ (index . 0).Port }}
{{- else -}}
REDIS_ADDR=redis://openstudio-redis.service.consul:6379
{{- end }}
REDIS_PASSWORD=[[ var "redis_password" . ]]
EOT
      }

      service {
        name     = "openstudio-redis-exporter"
        port     = "redis_exporter"
        provider = "nomad"
        check {
          name     = "openstudio-redis-exporter-tcp"
          type     = "tcp"
          interval = "30s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }

    task "prometheus" {
      driver = "docker"

      config {
        image       = "[[ var "prometheus_image" . ]]"
        force_pull  = false
        network_mode = "host"
        args = [
          "--config.file=/local/prometheus.yml",
          "--storage.tsdb.path=/tmp/prometheus",
          "--web.listen-address=:9090",
        ]
      }

      template {
        destination = "local/prometheus.yml"
        data        = <<EOH
global:
  scrape_interval: [[ var "prometheus_scrape_interval" . ]]

scrape_configs:
  - job_name: 'openstudio-redis-exporter'
    static_configs:
      - targets: ['127.0.0.1:9121']
EOH
      }

      service {
        name     = "openstudio-prometheus"
        port     = "http"
        provider = "nomad"
        check {
          name     = "openstudio-prometheus-tcp"
          type     = "tcp"
          interval = "30s"
          timeout  = "5s"
        }
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}
[[ end ]]
