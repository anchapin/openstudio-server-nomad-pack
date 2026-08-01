variable "job_name" {
  type        = string
  description = "The name of the Nomad job."
  default     = "openstudio-server"
}

variable "app_version" {
  type        = string
  # Keep this in sync with the image tag used in web_image, worker_image,
  # web_background_image, and rserve_image whenever versions are bumped.
  description = "Application version tag injected as APP_VERSION into all OpenStudio Server containers. Must match the image tag used in web_image, worker_image, web_background_image, and rserve_image to avoid version mismatch."
  default     = "3.11.0"
}

variable "worker_min_replicas" {
  type        = number
  description = "Minimum number of worker replicas. Aligned with Helm chart worker-hpa.yaml minReplicas: 2."
  default     = 2
}

variable "worker_max_replicas" {
  type        = number
  description = "Maximum number of worker replicas. Aligned with Helm chart worker-hpa.yaml maxReplicas: 20."
  default     = 20
}

variable "vault_integration_enabled" {
  type        = bool
  description = "Enable Vault KV v2 secrets injection via Nomad template stanzas (`secrets/env`). Typically enabled together with vault_enabled so tasks use explicit Vault roles."
  default     = false
}

variable "ingress_domain" {
  type        = string
  description = "Ingress domain used when constructing service hostnames and Traefik router rules."
  default     = "localhost"
}

variable "ingress_tls_enabled" {
  type        = bool
  description = "When true, adds Traefik TLS router tags for the websecure entrypoint on the web service."
  default     = false
}

variable "deploy_traefik" {
  type        = bool
  description = "When true, deploy a Traefik ingress job alongside the OpenStudio Server stack."
  default     = false
}

variable "traefik_image" {
  type        = string
  description = "Traefik Docker image to use."
  default     = "traefik:v3"
}

variable "traefik_http_port" {
  type        = number
  description = "Traefik HTTP entrypoint port."
  default     = 80
}

variable "traefik_https_port" {
  type        = number
  description = "Traefik HTTPS entrypoint port."
  default     = 443
}

variable "traefik_dashboard_port" {
  type        = number
  description = "Traefik dashboard port."
  default     = 8080
}

variable "traefik_api_insecure" {
  type        = bool
  description = "Enable the Traefik insecure API/dashboard (--api.insecure=true). Set to true only for local development. In production, keep this false and protect the dashboard with authentication and TLS."
  default     = false
}

variable "nomad_namespace" {
  type        = string
  description = "The Nomad namespace in which all pack jobs are registered. Use 'default' for the built-in namespace."
  default     = "default"
}

variable "region" {
  type        = string
  description = "The Nomad region where the job will be deployed."
  default     = "global"
}

variable "datacenters" {
  type        = list(string)
  description = "A list of datacenters in the region which are eligible for task placement."
  default     = ["dc1"]
}

# Image versions / repositories
variable "web_image" {
  type        = string
  description = "The image name and tag for the OpenStudio Server web container."
  default     = "nrel/openstudio-server:179-flock"
}

variable "web_command" {
  type        = string
  description = "Optional command override for the web task. Leave empty to use the image default entrypoint."
  default     = ""
}

variable "web_args" {
  type        = list(string)
  description = "Optional args passed to web_command when set."
  default     = []
}

variable "web_priority" {
  type        = number
  description = "Nomad job priority for the OpenStudio Web UI job (Nomad scale 1–100). Must always exceed worker_priority so the scheduler favours the web UI over workers during resource contention. Mirrors the Kubernetes high-priority PriorityClass (value 1000000) used by the Helm chart. WARNING: do not set this lower than or equal to worker_priority."
  default     = 80
}

variable "web_cpu" {
  type        = number
  description = "CPU shares allocated to the OpenStudio Web task."
  default     = 1000
}

variable "web_memory" {
  type        = number
  description = "Memory (MB) allocated to the OpenStudio Web task."
  default     = 2048
}

variable "web_memory_max" {
  type        = number
  description = "Memory hard limit (MB) for the OpenStudio Web task (Nomad memory_max). Must be greater than web_memory for burst capacity."
  default     = 4096
}

variable "web_count" {
  type        = number
  description = "The number of web task group allocations. MUST remain 1 (the default). The OpenStudio Server web process writes uploaded analysis artefacts to local container filesystem without a distributed file-locking scheme. When nfs_shared_volume_enabled = true, NFS provides a shared filesystem but does NOT guarantee POSIX file-locking across multiple simultaneous web writers — each allocation still has its own isolated view of open file handles. Setting web_count > 1 therefore causes split-brain: requests routed to replica B cannot find files written by replica A. This mirrors the Kubernetes Helm chart constraint (web-hpa.yaml maxReplicas: 1). To safely run web_count > 1 you must first implement either: (a) a distributed lock manager such as Redlock via Redis wrapping every filesystem operation, or (b) stateless file handling by moving all persistent artefacts to object storage (e.g. S3/MinIO). See docs/storage.md §'Web Replica Constraint' for details."
  default     = 1
}

variable "web_port" {
  type        = number
  description = "Host-side static port mapped to the web container HTTP port."
  default     = 80
}

variable "web_container_port" {
  type        = number
  description = "Port that the web container's nginx listens on internally. The OpenStudio Server image listens on port 80 by default. Must match the nginx listen directive in the image."
  default     = 80
}

variable "web_redis_url" {
  type        = string
  description = "REDIS_URL env var injected into web and worker containers. Defaults to 'redis://queue:6379' which resolves via /etc/hosts patch to the Consul-registered Redis address. Set to empty string when Vault injects REDIS_URL directly. Override with 'redis://host.docker.internal:6379' on macOS dev."
  default     = "redis://queue:6379"
}

variable "os_server_sampling_backend" {
  type        = string
  description = "Optional override for OS_SERVER_SAMPLING_BACKEND in web and web-background tasks. Valid values: 'rserve' (default app behavior) or 'ruby' (Rserve-independent LHS sampling fallback). Leave empty to use the image default."
  default     = ""
}

variable "worker_extra_hosts" {
  type        = list(string)
  description = "Additional /etc/hosts entries for the worker container, in 'hostname:ip' format. Use 'host-gateway' as the IP value to map to the Docker host machine. Required on macOS dev when the worker's start-workers script uses hostnames (db, queue) that must resolve to the host running MongoDB/Redis."
  default     = []
}

variable "web_health_check_interval" {
  type        = string
  description = "Interval between Consul health checks for the web service."
  default     = "10s"
}

variable "web_health_check_timeout" {
  type        = string
  description = "Timeout for Consul health checks for the web service."
  default     = "2s"
}

variable "web_update_max_parallel" {
  type        = number
  description = "Maximum number of web allocations updated in parallel."
  default     = 1
}

variable "web_update_health_check" {
  type        = string
  description = "Health check mode for web rolling updates."
  default     = "checks"
}

variable "web_update_min_healthy_time" {
  type        = string
  description = "How long a web allocation must remain healthy before promotion."
  default     = "30s"
}

variable "web_update_healthy_deadline" {
  type        = string
  description = "Maximum time for a web allocation to become healthy."
  default     = "5m"
}

variable "web_update_progress_deadline" {
  type        = string
  description = "Maximum time for the web rolling update to make progress."
  default     = "10m"
}

variable "web_update_auto_revert" {
  type        = bool
  description = "Automatically revert a web deployment if the update fails."
  default     = true
}

variable "web_background_cpu" {
  type        = number
  description = "CPU shares allocated to the OpenStudio web-background task."
  default     = 250
}

variable "web_background_memory" {
  type        = number
  description = "Memory (MB) allocated to the OpenStudio web-background task."
  default     = 512
}

variable "worker_image" {
  type        = string
  description = "The image name and tag for the OpenStudio Server worker container."
  default     = "nrel/openstudio-server:179-flock"
}

variable "worker_command" {
  type        = string
  description = "Command used to start the worker task."
  default     = "/usr/local/bin/start-workers"
}

variable "worker_args" {
  type        = list(string)
  description = "Optional args passed to worker_command."
  default     = []
}

variable "worker_health_check_command" {
  type        = string
  description = "Shell command used by the worker service health check."
  default     = "pgrep -f resque > /dev/null"
}

variable "worker_count" {
  type        = number
  description = "The number of worker task group allocations."
  default     = 1
}

variable "worker_instance_type" {
  type        = string
  description = "Optional worker node instance type/flavor selector (matches attr.platform.aws.instance-type). Leave empty to disable."
  default     = ""
}

variable "worker_constraints" {
  type        = any
  description = "Placement constraints for the worker group."
  default     = []
}

variable "worker_affinities" {
  type        = any
  description = "Placement affinities for the worker group."
  default     = []
}

variable "worker_spreads" {
  type        = any
  description = "Spread rules for the worker group."
  default     = []
}

variable "worker_excluded_node_ids" {
  type        = list(string)
  description = "Node IDs that workers must not run on. Useful for protecting stateful service nodes (for example CSI topology-pinned MongoDB/Redis nodes) from worker placement."
  default     = []
}

variable "worker_update_max_parallel" {
  type        = number
  description = "Maximum number of worker allocations updated in parallel."
  default     = 1
}

variable "worker_update_health_check" {
  type        = string
  description = "Health check mode for worker rolling updates."
  default     = "task_states"
}

variable "worker_update_min_healthy_time" {
  type        = string
  description = "How long a worker allocation must remain healthy before promotion."
  default     = "30s"
}

variable "worker_update_healthy_deadline" {
  type        = string
  description = "Maximum time for a worker allocation to become healthy."
  default     = "5m"
}

variable "worker_update_progress_deadline" {
  type        = string
  description = "Maximum time for the worker rolling update to make progress. Must be greater than worker_kill_timeout (default 5200s ≈ 87m). Defaults to 2h to ensure kill_timeout never exceeds progress_deadline."
  default     = "2h"
}

variable "worker_update_auto_revert" {
  type        = bool
  description = "Automatically revert a worker deployment if the update fails."
  default     = true
}

variable "worker_priority" {
  type        = number
  description = "Nomad job priority for calculation workers (Nomad scale 1–100). Must always be less than web_priority so the web UI is scheduled preferentially during resource contention. Mirrors the Kubernetes low-priority PriorityClass (value 10000) used by the Helm chart. WARNING: do not set this higher than or equal to web_priority."
  default     = 40
}

variable "worker_queues" {
  type        = string
  description = "Comma-separated queue list processed by worker tasks."
  default     = "requeued,simulations"
}

variable "worker_process_count" {
  type        = string
  description = "COUNT environment variable passed to worker containers. Also injected into web and web-background as OS_SERVER_NUMBER_OF_WORKERS so analyses can enqueue simulation datapoints."
  default     = "1"
}

variable "worker_cpu" {
  type        = number
  description = "CPU shares allocated to the OpenStudio worker task. These defaults are intentionally higher than Helm to support higher simulation concurrency per Nomad allocation."
  default     = 2000
}

variable "worker_memory" {
  type        = number
  description = "Memory (MB) allocated to the OpenStudio worker task. These defaults are intentionally higher than Helm to support higher simulation concurrency per Nomad allocation."
  default     = 4096
}

variable "worker_memory_max" {
  type        = number
  description = "Memory hard limit (MB) for the OpenStudio worker task (Nomad memory_max)."
  default     = 6144
}

variable "worker_kill_timeout" {
  type        = string
  description = "Grace period Nomad grants the worker task to finish in-flight work before force-killing it on drain or update. Must be >= the longest expected simulation run. Matches Helm terminationGracePeriodSeconds: 5200. WARNING: reducing this below the longest simulation duration will result in data loss on node drains and rolling updates."
  default     = "5200s"
}

variable "worker_autoscaling_enabled" {
  type        = bool
  description = "Enable Nomad Autoscaler integration for the worker task group. When false (default), the scaling block is omitted and worker_count controls the fixed allocation count."
  default     = false
}

variable "worker_autoscaling_cpu_enabled" {
  type        = bool
  description = "Enable the built-in Nomad APM CPU autoscaling check for workers (avg_cpu target-value strategy)."
  default     = true
}

variable "worker_autoscaling_queue_enabled" {
  type        = bool
  description = "Enable Prometheus-based queue-depth autoscaling checks for workers. Requires a running Prometheus instance at autoscaler_prometheus_address scraping queue metrics. Defaults to false — safe to omit if Prometheus is not deployed."
  default     = false
}

variable "worker_cpu_target_utilization" {
  type        = number
  description = "Target worker CPU utilization percentage used by the nomad-apm avg_cpu scaling check."
  default     = 50
}

variable "nomad_autoscaler_enabled" {
  type        = bool
  description = "Render an optional Nomad Autoscaler daemon job stub. When false (default), the autoscaler job template is omitted."
  default     = false
}

variable "nomad_autoscaler_image" {
  type        = string
  description = "The image name and tag for the Nomad Autoscaler daemon. See https://github.com/hashicorp/nomad-autoscaler/releases for available versions."
  default     = "hashicorp/nomad-autoscaler:0.4.7"
}

variable "autoscaler_nomad_address" {
  type        = string
  description = "Address of the Nomad server for the Nomad Autoscaler to connect to. Use the private IP when Consul DNS is not available (e.g. 'http://192.168.100.87:4646')."
  default     = "http://nomad.service.consul:4646"
}

variable "autoscaler_prometheus_address" {
  type        = string
  description = "Address of the Prometheus server used by the Nomad Autoscaler APM plugin to evaluate scaling checks."
  default     = "http://openstudio-prometheus.service.consul:9090"
}

variable "autoscaler_cooldown" {
  type        = string
  description = "Cooldown duration between worker autoscaling actions (e.g. '60m', '30m'). Defaults to 60m to match the Helm chart stabilizationWindowSeconds of 3600."
  default     = "60m"
}

variable "autoscaler_constraints" {
  type        = any
  description = "Placement constraints for the optional Nomad Autoscaler group."
  default     = []
}

variable "autoscaler_affinities" {
  type        = any
  description = "Placement affinities for the optional Nomad Autoscaler group."
  default     = []
}

variable "autoscaler_spreads" {
  type        = any
  description = "Spread rules for the optional Nomad Autoscaler group."
  default     = []
}

variable "prometheus_enabled" {
  type        = bool
  description = "Render an in-pack Prometheus job for autoscaler queue-depth metrics."
  default     = false
}

variable "prometheus_image" {
  type        = string
  description = "Prometheus image used by the optional in-pack Prometheus job."
  default     = "prom/prometheus:v2.53.2"
}

variable "prometheus_static_port" {
  type        = number
  description = "Static host port for the optional in-pack Prometheus HTTP endpoint."
  default     = 9090
}

variable "prometheus_scrape_interval" {
  type        = string
  description = "Prometheus global scrape interval for the optional in-pack Prometheus job."
  default     = "15s"
}

variable "prometheus_constraints" {
  type        = any
  description = "Placement constraints for the optional Prometheus group."
  default     = []
}

variable "prometheus_affinities" {
  type        = any
  description = "Placement affinities for the optional Prometheus group."
  default     = []
}

variable "prometheus_spreads" {
  type        = any
  description = "Spread rules for the optional Prometheus group."
  default     = []
}

variable "redis_exporter_image" {
  type        = string
  description = "Redis exporter image used by the optional in-pack Prometheus job."
  default     = "oliver006/redis_exporter:v1.62.0"
}

variable "worker_queue_requeued_query" {
  type        = string
  description = "Prometheus query for requeued backlog depth."
  default     = "sum(openstudio_worker_queue_depth{queue=\"requeued\"})"
}

variable "worker_queue_requeued_target" {
  type        = number
  description = "Target queue depth for requeued jobs per worker allocation."
  default     = 1
}

variable "worker_queue_simulations_query" {
  type        = string
  description = "Prometheus query for simulations backlog depth."
  default     = "sum(openstudio_worker_queue_depth{queue=\"simulations\"})"
}

variable "worker_queue_simulations_target" {
  type        = number
  description = "Target queue depth for simulation jobs per worker allocation."
  default     = 5
}

variable "web_background_image" {
  type        = string
  description = "The image name and tag for the OpenStudio Server web-background container."
  default     = "nrel/openstudio-server:179-flock"
}

variable "web_background_command" {
  type        = string
  description = "Command run by the web-background task. Defaults to the image's start-web-background script, which launches Resque workers for background analysis lifecycle queues."
  default     = "/usr/local/bin/start-web-background"
}

variable "web_background_queues" {
  type        = string
  description = "Resque QUEUES env var for the web-background task. Controls which queue(s) the start-web-background Resque workers process. Keep both 'background' and 'analyses': the 'analyses' queue handles analysis initialization/cleanup (including directory setup before zip extraction), and 'background' handles general async tasks. The 'analysis_wrappers' queue is consumed by the web task. Omitting 'analyses' causes the 'Destination already exists' error on re-initialization. Separate multiple queues with commas. NOTE: Use QUEUES (not QUEUE) — the application's resque:setup task explicitly resets QUEUE to prevent environment leaks."
  default     = "background,analyses"
}

variable "web_background_args" {
  type        = list(string)
  description = "Optional args passed to web_background_command when set."
  default     = []
}

variable "web_background_count" {
  type        = number
  description = "The number of web-background task allocations. Must remain 1. Horizontal scale-out for this group is intentionally disabled; increase web_background_worker_count (COUNT) instead."
  default     = 1
}

variable "web_background_worker_count" {
  type        = number
  description = "COUNT env var for the web-background task: number of Resque child worker processes per allocation. Increase to drain the background/analyses/analysis_wrappers queues faster. Tune in proportion to web_background_memory."
  default     = 6
}

variable "web_background_autoscaling_enabled" {
  type        = bool
  description = "Deprecated for this pack profile. Keep false: web-background is pinned to a single allocation by design."
  default     = false
}

variable "web_background_min_replicas" {
  type        = number
  description = "Minimum number of web-background replicas when autoscaling is enabled."
  default     = 1
}

variable "web_background_max_replicas" {
  type        = number
  description = "Maximum number of web-background replicas when autoscaling is enabled."
  default     = 5
}

variable "web_background_autoscaling_cpu_enabled" {
  type        = bool
  description = "Enable the built-in Nomad APM CPU autoscaling check for the web-background task group (avg_cpu target-value strategy). Only applies when web_background_autoscaling_enabled is true."
  default     = false
}

variable "web_background_cpu_target_utilization" {
  type        = number
  description = "Target CPU utilization percentage for the web-background nomad-apm avg_cpu scaling check."
  default     = 50
}

variable "db_image" {
  type        = string
  description = "The MongoDB database image name and tag. BREAKING UPGRADE NOTE: persisted data volumes created on mongo:4.2 must be migrated in sequence 4.2 -> 4.4 -> 5.0 -> 6.0.7; do not skip major versions. See docs/upgrading.md for the full procedure."
  default     = "mongo:6.0.7"
}

variable "db_cpu" {
  type        = number
  description = "CPU shares allocated to the MongoDB task."
  default     = 1000
}

variable "db_memory" {
  type        = number
  description = "Memory (MB) allocated to the MongoDB task."
  default     = 4096
}

variable "db_memory_max" {
  type        = number
  description = "Memory hard limit (MB) for the MongoDB task (Nomad memory_max)."
  default     = 6144
}

variable "db_health_check_interval" {
  type        = string
  description = "Interval between Consul health checks for the MongoDB service."
  default     = "10s"
}

variable "db_health_check_timeout" {
  type        = string
  description = "Timeout for Consul health checks for the MongoDB service."
  default     = "2s"
}

variable "db_storage_type" {
  type        = string
  description = "MongoDB storage type: host_volume, csi, or ephemeral. Use ephemeral to disable persistent volume wiring."
  default     = "host_volume"
}

variable "db_volume_source" {
  type        = string
  description = "Nomad volume source name for MongoDB persistent storage (host_volume name or CSI volume ID)."
  default     = "openstudio-mongodb"
}

variable "db_csi_plugin_id" {
  type        = string
  description = "Optional CSI plugin ID used by OpenStack helper scripts when creating the MongoDB volume. No effect unless db_storage_type = \"csi\"."
  default     = ""
}

# Intentionally uses redis:6.2-alpine (newer, smaller) instead of the Helm chart's
# redis:6.0.9. Operators should align the Redis major.minor version with their
# target OpenStudio Server release requirements.
variable "redis_image" {
  type        = string
  description = "The Redis image name and tag. Intentionally diverges from the Helm chart default (redis:6.0.9) by using redis:6.2-alpine; align Redis major.minor with your target OpenStudio Server release requirements."
  default     = "redis:6.2-alpine"
}

variable "redis_cpu" {
  type        = number
  description = "CPU shares allocated to the Redis task."
  default     = 250
}

variable "redis_memory" {
  type        = number
  description = "Memory (MB) allocated to the Redis task."
  default     = 1024
}

variable "redis_storage_type" {
  type        = string
  description = "Redis storage type: host_volume, csi, or ephemeral. Use ephemeral to disable persistent volume wiring."
  default     = "host_volume"
}

variable "redis_volume_source" {
  type        = string
  description = "Nomad volume source name for Redis persistent storage (host_volume name or CSI volume ID)."
  default     = "openstudio-redis"
}

variable "redis_csi_plugin_id" {
  type        = string
  description = "Optional CSI plugin ID used by OpenStack helper scripts when creating the Redis volume. No effect unless redis_storage_type = \"csi\"."
  default     = ""
}

variable "redis_health_check_interval" {
  type        = string
  description = "Interval between Consul health checks for the Redis service."
  default     = "10s"
}

variable "redis_health_check_timeout" {
  type        = string
  description = "Timeout for Consul health checks for the Redis service."
  default     = "2s"
}

variable "nfs_shared_volume_enabled" {
  type        = bool
  description = "When true, an NFS shared volume is declared and mounted in both web and worker task groups. Volume type is controlled by nfs_volume_type."
  default     = false
}

variable "nfs_volume_type" {
  type        = string
  description = "Storage backend for the NFS shared volume. Use \"host_volume\" (default, recommended) for an OS-level NFS mount registered as a Nomad host volume, or \"csi\" for a CSI-managed NFS volume. Mirrors the db_storage_type / redis_storage_type pattern."
  default     = "host_volume"
}

variable "nfs_volume_source" {
  type        = string
  description = "Nomad volume ID for the NFS shared volume used by web and worker task groups. For host_volume this is the host_volume name; for csi this is the CSI volume ID."
  default     = "openstudio-nfs"
}

variable "nfs_volume_mount_path" {
  type        = string
  description = "Mount path inside web and worker tasks where the NFS shared volume is attached."
  default     = "/mnt/openstudio"
}

variable "web_rserve_colocation_node" {
  type        = string
  description = "Optional hard node name pin applied to both the web and rserve task groups. Set to a Nomad node name (for example, \"nomad-client-172\") to force web and rserve onto the same host when shared local paths must be identical. Leave empty to disable explicit co-location pinning."
  default     = ""
}

variable "dev_shared_data_path" {
  type        = string
  description = "Host path to bind-mount as the shared data volume at nfs_volume_mount_path (e.g. /mnt/openstudio) in the web, web-background, and worker tasks. Intended for single-node development where a full NFS setup is impractical. When set, a Docker bind mount is added to each task so all three containers share the same host directory, replicating the Docker Compose osdata named volume behaviour. Leave empty (default) in production; use nfs_shared_volume_enabled instead. NOTE: On macOS with Docker Desktop, use dev_shared_volume_name instead to avoid VirtioFS write-consistency issues."
  default     = ""
}

variable "dev_shared_volume_name" {
  type        = string
  description = "Docker named volume to mount at nfs_volume_mount_path in the web, web-background, and worker tasks. Preferred over dev_shared_data_path on macOS/Docker Desktop: named volumes live in the Docker VM filesystem and bypass VirtioFS, avoiding write-consistency issues (CRC corruption) that occur with macOS host bind mounts. Pre-create with 'docker volume create <name>' before deploying. Leave empty (default) when using dev_shared_data_path or nfs_shared_volume_enabled."
  default     = ""
}

variable "rserve_image" {
  type        = string
  description = "The Rserve image name and tag."
  default     = "nrel/openstudio-rserve:179-flock"
}

variable "rserve_command" {
  type        = string
  description = "Optional command override for the Rserve task. Leave empty to use the image default entrypoint."
  default     = ""
}

variable "rserve_args" {
  type        = list(string)
  description = "Optional args passed to rserve_command when set."
  default     = []
}

variable "rserve_cpu" {
  type        = number
  description = "CPU shares allocated to the Rserve task."
  default     = 1000
}

variable "rserve_memory" {
  type        = number
  description = "Memory (MB) allocated to the Rserve task."
  default     = 2048
}

variable "rserve_health_check_interval" {
  type        = string
  description = "Interval between Consul health checks for the Rserve service."
  default     = "10s"
}

variable "rserve_health_check_timeout" {
  type        = string
  description = "Timeout for Consul health checks for the Rserve service."
  default     = "2s"
}

variable "enable_consul_connect" {
  type        = bool
  description = "Enable Consul Connect sidecar proxies for mTLS service-to-service communication."
  default     = false
}

# Logging configuration variables
variable "log_driver_type" {
  type        = string
  description = "The logging driver to use for the containers."
  default     = "json-file"
}

variable "log_max_size" {
  type        = string
  description = "The maximum size of log files before rotation."
  default     = "10m"
}

variable "log_max_files" {
  type        = number
  description = "The maximum number of log files to keep."
  default     = 3
}

# Vector configuration variables
variable "enable_vector_collection" {
  type        = bool
  description = "Enable Vector sidecar for log collection."
  default     = true
}

variable "vector_image" {
  type        = string
  description = "The Vector image name and tag."
  default     = "timberio/vector:0.30.0-alpine"
}

# Scheduling helper inputs
variable "db_constraints" {
  type        = any
  description = "Placement constraints for the db group."
  default     = []
}

variable "web_constraints" {
  type        = any
  description = "Placement constraints for the web group. Use to pin the web task to nodes with sufficient disk (e.g. 179d nodes) for large Docker image pulls."
  default     = []
}

variable "db_affinities" {
  type        = any
  description = "Placement affinities for the db group."
  default     = []
}

variable "db_spreads" {
  type        = any
  description = "Spread rules for the db group."
  default     = []
}

variable "redis_constraints" {
  type        = any
  description = "Placement constraints for the redis group."
  default     = []
}

variable "redis_affinities" {
  type        = any
  description = "Placement affinities for the redis group."
  default     = []
}

variable "redis_spreads" {
  type        = any
  description = "Spread rules for the redis group."
  default     = []
}

variable "rserve_constraints" {
  type        = any
  description = "Placement constraints for the rserve group."
  default     = []
}

variable "rserve_affinities" {
  type        = any
  description = "Placement affinities for the rserve group."
  default     = []
}

variable "rserve_spreads" {
  type        = any
  description = "Spread rules for the rserve group."
  default     = []
}

# Backup and restore jobs
variable "backup_enabled" {
  type        = bool
  description = "Enable the periodic MongoDB and Redis backup batch job."
  default     = false
}

variable "backup_cron" {
  type        = string
  description = "Cron expression for the periodic backup schedule. The value is used in a crons list in the periodic stanza."
  default     = "0 2 * * * *"
}

variable "backup_prohibit_overlap" {
  type        = bool
  description = "Prevent overlapping backup runs."
  default     = true
}

variable "backup_volume_type" {
  type        = string
  description = "Storage backend for the backup and restore state volume. Use \"host_volume\" (default) for a Nomad host volume or \"csi\" for a CSI-managed volume."
  default     = "host_volume"
}

variable "backup_volume_source" {
  type        = string
  description = "Nomad volume source for state backups. For host_volume this is the host volume name; for csi this is the CSI volume ID."
  default     = "openstudio-backups"
}

variable "backup_mount_path" {
  type        = string
  description = "Path inside backup tasks where the backup state volume is mounted."
  default     = "/backups"
}

variable "backup_subdirectory" {
  type        = string
  description = "Subdirectory name under the backup mount where OpenStudio state backups are written."
  default     = "openstudio-state"
}

variable "backup_retention_days" {
  type        = number
  description = "How many days of backup files to retain."
  default     = 14
}

variable "db_backup_uri" {
  type        = string
  description = "MongoDB URI used by backup and restore jobs."
  default     = "mongodb://openstudio-db.service.consul:27017"
}

variable "redis_backup_host" {
  type        = string
  description = "Redis host used by backup and restore jobs."
  default     = "openstudio-redis.service.consul"
}

variable "redis_backup_port" {
  type        = number
  description = "Redis port used by backup and restore jobs."
  default     = 6379
}

variable "restore_enabled" {
  type        = bool
  description = "Enable the on-demand restore batch job definition."
  default     = false
}

# Docker runtime hardening variables
variable "docker_user" {
  type        = string
  description = "UID:GID to run containers as (non-root). Applies to web, worker, and rserve tasks."
  default     = "1000:1000"
}

variable "docker_ulimit_nofile" {
  type        = string
  description = "Default Docker nofile ulimit (soft:hard) applied to web, web-background, worker, rserve, and autoscaler tasks."
  default     = "65535:65535"
}

variable "db_static_port" {
  type        = number
  description = <<-EOT
    Host-side static port for the MongoDB container. Default 0 means Nomad allocates a dynamic port.
    Set to 27017 for local dev when containers need to reach MongoDB via a fixed port
    (e.g. when using web_extra_hosts to map the 'db' hostname on macOS Docker Desktop).
  EOT
  default     = 0
}

variable "redis_static_port" {
  type        = number
  description = <<-EOT
    Host-side static port for the Redis container. Default 0 means Nomad allocates a dynamic port.
    Set to 6379 for local dev when containers need to reach Redis via a fixed port
    (e.g. when using web_extra_hosts to map the 'queue' hostname on macOS Docker Desktop).
  EOT
  default     = 0
}

variable "rserve_static_port" {
  type        = number
  description = <<-EOT
    Host-side static port for the Rserve container. Default 0 means Nomad allocates a dynamic port.
    Set to 6311 for local dev when containers need to reach Rserve via a fixed port
    (e.g. when using web_extra_hosts to map the 'rserve' hostname on macOS Docker Desktop).
  EOT
  default     = 0
}

variable "web_extra_hosts" {
  type        = list(string)
  description = <<-EOT
    Extra host-to-IP mappings to inject into the web and web-background containers
    (Docker --add-host / extra_hosts). Useful on macOS Docker Desktop to map legacy
    Docker Compose service hostnames ('db', 'queue', 'rserve') to host.docker.internal
    so the OpenStudio Server app can reach MongoDB, Redis, and Rserve. Example:
      web_extra_hosts = ["db:host-gateway", "queue:host-gateway", "rserve:host-gateway"]
    'host-gateway' is a Docker special value resolving to the host machine's IP.
  EOT
  default     = []
}

variable "db_docker_user" {
  type        = string
  description = "User to run the MongoDB container as. MongoDB official images expect UID/GID 999."
  default     = "999:999"
}

variable "db_docker_ulimit_nofile" {
  type        = string
  description = "Docker nofile ulimit (soft:hard) for MongoDB. Increase this for high worker concurrency to prevent file descriptor exhaustion."
  default     = "262144:262144"
}

variable "redis_docker_user" {
  type        = string
  description = "User to run the Redis container as. Redis official images expect UID/GID 999."
  default     = "999:999"
}

variable "redis_docker_ulimit_nofile" {
  type        = string
  description = "Docker nofile ulimit (soft:hard) for Redis. Keep this high when queue fan-out is aggressive."
  default     = "131072:131072"
}

variable "docker_readonly_rootfs" {
  type        = bool
  description = "Enable Docker read-only root filesystem."
  default     = true
}

variable "enable_arch_constraint" {
  type        = bool
  description = "When true, the worker job enforces hard constraints requiring os.name=linux and cpu.arch=amd64. Set false for macOS or ARM64 local dev nodes."
  default     = true
}

variable "consul_address" {
  type        = string
  description = <<-EOT
    HTTP address of the Consul agent used by wait-for-deps prestart tasks.
    Default (127.0.0.1:8500) works when Consul runs natively on the same host
    as the Nomad client, or on Linux with Docker host-networking.
    On macOS Docker Desktop (where Docker containers cannot reach the host
    loopback), set this to "host.docker.internal:8500" so that containers
    with network_mode=host can reach a natively-running Consul agent.
  EOT
  default     = "127.0.0.1:8500"
}

variable "docker_cap_drop" {
  type        = list(string)
  description = "Linux capabilities to drop from Docker containers."
  default     = ["ALL"]
}

variable "enable_image_prepull" {
  type        = bool
  description = "When true, renders the system-hooks job that pre-pulls all heavy images on every eligible node before scheduling."
  default     = true
}

variable "prepull_kill_timeout" {
  type        = string
  description = "kill_timeout applied to every task in the image pre-pull system job. Must be >= 10 minutes to allow large image layers to be pulled."
  default     = "600s"
}

variable "poststop_cleanup_image" {
  type        = string
  description = "The image used for poststop cleanup lifecycle tasks."
  default     = "alpine:3.20"
}

variable "poststop_cleanup_paths" {
  type        = list(string)
  description = "Directories removed by poststop cleanup lifecycle tasks when allocations stop."
  default = [
    "/alloc/tmp/analysis",
    "/alloc/tmp/openstudio/analysis",
  ]
}

# Batch verification configuration
variable "enable_batch_verification" {
  type        = bool
  description = "Enable standalone batch connectivity verification job."
  default     = false
}

variable "verification_image" {
  type        = string
  description = "The image used for batch connectivity verification checks."
  default     = "busybox:1.36"
}

variable "verification_targets" {
  type        = list(string)
  description = "Connectivity targets in component=host:port format for batch verification."
  default = [
    "db=openstudio-db.service.consul:27017",
    "redis=openstudio-redis.service.consul:6379",
    "rserve=openstudio-rserve.service.consul:6311",
  ]
}

# Queue sweeper — proactive stale Redis queuing-lock recovery
variable "enable_queue_sweeper" {
  type        = bool
  description = "Enable periodic batch job that automatically clears stale resque:analysis:*:queuing locks from Redis. A lock is stale if it has no TTL and has been idle for longer than queue_sweeper_max_lock_age_seconds."
  default     = false
}

variable "queue_sweeper_cron" {
  type        = string
  description = "Cron schedule for the queue-sweeper periodic job (UTC). Runs every 2 minutes by default to recover stale locks quickly."
  default     = "*/2 * * * *"
}

variable "queue_sweeper_max_lock_age_seconds" {
  type        = number
  description = "Minimum idle seconds (OBJECT IDLETIME) before a TTL-less queuing lock is considered stale and eligible for deletion. Default 120s (2 min) — shorter than a typical analysis enqueue cycle while long enough to avoid racing an active enqueue."
  default     = 120
}

variable "queue_sweeper_image" {
  type        = string
  description = "Docker image used for the queue-sweeper task. Must include redis-cli."
  default     = "redis:6.2-alpine"
}

variable "queue_sweeper_cpu" {
  type        = number
  description = "CPU MHz reserved for the queue-sweeper task."
  default     = 50
}

variable "queue_sweeper_memory" {
  type        = number
  description = "Memory (MiB) reserved for the queue-sweeper task."
  default     = 64
}

# Vault KV secrets integration variables (vault_integration_enabled mechanism)
variable "vault_policy" {
  type        = string
  description = "Fallback Vault policy attached to task tokens when vault_integration_enabled is true and vault_enabled is false."
  default     = "openstudio-server"
}

variable "vault_kv_mongodb_path" {
  type        = string
  description = "Vault KV v2 path for MongoDB credentials (must contain a 'password' key)."
  default     = "secret/data/openstudio/mongodb"
}

variable "vault_kv_redis_path" {
  type        = string
  description = "Vault KV v2 path for Redis credentials (must contain a 'password' key)."
  default     = "secret/data/openstudio/redis"
}

variable "vault_kv_app_path" {
  type        = string
  description = "Vault KV v2 path for application secrets (must contain a 'secret_key_base' key)."
  default     = "secret/data/openstudio/app"
}

variable "mongo_password" {
  type        = string
  description = "Plaintext MongoDB password used when vault_integration_enabled is false."
  default     = ""
}

variable "mongo_user" {
  type        = string
  description = "MongoDB username injected as MONGO_USER into web, web-background, and worker containers. Must match the user configured in db.nomad.tpl."
  default     = ""
}

variable "redis_password" {
  type        = string
  description = "Plaintext Redis password used when vault_integration_enabled is false."
  default     = ""
}

variable "app_secret_key_base" {
  type        = string
  description = "Plaintext application secret key base used when vault_integration_enabled is false."
  default     = ""
}

# Vault role-based authorization variables
variable "vault_enabled" {
  type        = bool
  description = "Enable explicit Nomad `vault { role = ... }` blocks for task token issuance. Usually set with vault_integration_enabled for full role-based + KV secret injection."
  default     = false
}

variable "vault_default_role" {
  type        = string
  description = "Default Vault role used by tasks when a task-specific role is not set."
  default     = ""
}

variable "vault_db_role" {
  type        = string
  description = "Vault role override for the MongoDB task."
  default     = ""
}

variable "vault_redis_role" {
  type        = string
  description = "Vault role override for the Redis task."
  default     = ""
}

variable "vault_rserve_role" {
  type        = string
  description = "Vault role override for the Rserve task."
  default     = ""
}

variable "vault_policies" {
  type        = list(string)
  description = "Additional Vault policies to attach to Nomad-issued Vault tokens."
  default     = []
}

variable "vault_namespace" {
  type        = string
  description = "Vault namespace used for task token requests (Enterprise Vault)."
  default     = ""
}

variable "vault_change_mode" {
  type        = string
  description = "How tasks react to Vault token or secret changes."
  default     = "restart"
}

variable "vault_change_signal" {
  type        = string
  description = "Signal sent to tasks when vault_change_mode is set to signal."
  default     = "SIGHUP"
}

variable "vault_env" {
  type        = bool
  description = "Expose Vault token to tasks as environment variables."
  default     = true
}

# Test job variables (openstudio_test.nomad.tpl)
variable "test_web_port" {
  type        = number
  description = "Port for the HTTP health check against openstudio-web.service.consul."
  default     = 80
}

variable "test_redis_port" {
  type        = number
  description = "Port for the TCP check against openstudio-redis.service.consul."
  default     = 6379
}

variable "test_mongo_port" {
  type        = number
  description = "Port for the TCP check against openstudio-db.service.consul (MongoDB)."
  default     = 27017
}

variable "test_rserve_port" {
  type        = number
  description = "Port for the TCP check against openstudio-rserve.service.consul."
  default     = 6311
}

variable "test_timeout_seconds" {
  type        = number
  description = "Per-check timeout in seconds passed to curl --max-time and nc -w."
  default     = 10
}

variable "test_retry_count" {
  type        = number
  description = "Number of curl retries for the web HTTP health check."
  default     = 3
}

variable "test_curl_image_tag" {
  type        = string
  description = "Tag for the curlimages/curl image used in the web HTTP check task."
  default     = "8.9.1"
}

variable "test_busybox_image_tag" {
  type        = string
  description = "Tag for the busybox image used in TCP check tasks."
  default     = "stable"
}

# Node class / placement variables
variable "compute_node_class" {
  type        = string
  description = "Nomad node class label for CPU-intensive compute nodes. Used by the openstudio_server.compute_node_constraint helper macro."
  default     = "compute"
}

variable "system_node_class" {
  type        = string
  description = "Nomad node class label for infrastructure/system nodes. Used by the openstudio_server.system_node_constraint helper macro."
  default     = "system"
}
