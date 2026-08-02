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
        image        = "[[ var "redis_exporter_image" . ]]"
        force_pull   = false
        network_mode = "host"
        args  = ["--check-keys=resque:queue:simulations,resque:queue:requeued,resque:failed"]
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
        image        = "[[ var "prometheus_image" . ]]"
        force_pull   = false
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

[[ if var "prometheus_alert_rules_enabled" . ]]
rule_files:
  - "/local/alert_rules.yml"
[[ end ]]

scrape_configs:
  - job_name: 'openstudio-redis-exporter'
    static_configs:
      - targets: ['127.0.0.1:9121']
EOH
      }

[[ if var "prometheus_alert_rules_enabled" . ]]
      template {
        destination = "local/alert_rules.yml"
        data        = <<EOH
groups:
  - name: openstudio_worker_stall
    rules:

      # Simulations queue has jobs that are not being consumed.
      # Normal state: queue drains to 0 quickly as workers pick up jobs.
      # A sustained backlog means workers are down, not registered, or hung.
      - alert: OpenStudioSimulationsQueueBacklog
        expr: sum(redis_key_size{key="resque:queue:simulations"}) > 0
        for: [[ var "prometheus_alert_simulations_queue_minutes" . ]]m
        labels:
          severity: warning
        annotations:
          summary: "OpenStudio simulations queue backlog"
          description: "resque:queue:simulations has {{ $value }} pending jobs for > [[ var "prometheus_alert_simulations_queue_minutes" . ]] min. Workers may be down or not consuming. Check: curl http://10.60.126.125/resque/queues"

      # Requeued queue has retry jobs that are not being consumed.
      # Jobs land here after a first failure. A sustained backlog means all
      # worker slots are occupied (possibly by in-flight stalled simulations).
      # Complement with: ./scripts/detect-stalled-datapoints.sh --dry-run
      - alert: OpenStudioRequeuedQueueBacklog
        expr: sum(redis_key_size{key="resque:queue:requeued"}) > 0
        for: [[ var "prometheus_alert_requeued_queue_minutes" . ]]m
        labels:
          severity: warning
        annotations:
          summary: "OpenStudio requeued jobs not being consumed"
          description: "resque:queue:requeued has {{ $value }} retry jobs for > [[ var "prometheus_alert_requeued_queue_minutes" . ]] min. All worker slots may be held by stalled simulations. Run: ./scripts/detect-stalled-datapoints.sh --restart-allocs"

      # Resque failed queue is non-empty.
      # Failures are written here when a worker dies mid-job (e.g. alloc restart).
      # A non-zero count that persists requires manual retry or investigation.
      - alert: OpenStudioFailedJobs
        expr: sum(redis_key_size{key="resque:failed"}) > 0
        for: [[ var "prometheus_alert_failed_jobs_minutes" . ]]m
        labels:
          severity: warning
        annotations:
          summary: "OpenStudio Resque failed jobs present"
          description: "{{ $value }} job(s) in resque:failed queue for > [[ var "prometheus_alert_failed_jobs_minutes" . ]] min. Check: http://10.60.126.125/resque/failures"
EOH
      }
[[ end ]]

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
