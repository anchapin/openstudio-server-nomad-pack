# OpenStack Production override — tuned defaults for OpenStack-hosted Nomad clusters.
#
# Tuned against staged rollout evidence (see docs/openstack-staged-rollout-runbook.md).
# Typical target node flavour: 8 vCPU / 16 GB RAM compute nodes.
#
# SITE-SPECIFIC OVERRIDES
# -----------------------
# This file contains portable defaults. Values that differ per OpenStack deployment
# (ingress IP/hostname, datacenter name, private registry, etc.) must be supplied
# in a separate site-local override file. Copy the template and fill in your values:
#
#   cp examples/advanced/openstack-site-local.hcl.template openstack-site-local.hcl
#   # edit openstack-site-local.hcl, then deploy with:
#   nomad-pack run \
#     -var-file examples/advanced/openstack-production.hcl \
#     -var-file openstack-site-local.hcl .
#
# The site-local file takes precedence (last -var-file wins) and should NOT be
# committed to source control.
#
# Usage (without site-local):
#   nomad-pack run -var-file examples/advanced/openstack-production.hcl .
#
# Prerequisites:
#   - Vault cluster integrated with Nomad (vault_enabled = true below)
#   - MongoDB and Redis host volumes provisioned on Nomad clients (UID/GID 999:999)
#   - NFS-backed host volume "openstudio-nfs" mounted on all compute nodes
#   - Nomad Autoscaler daemon: enabled via nomad_autoscaler_enabled = true (set below)
#   - Prometheus + redis_exporter: enabled via prometheus_enabled = true (set below)
#   - Baseline metrics captured before deployment (see rollout runbook)
#
# Rollback: re-deploy your prior var-file or see §Abort and Rollback Procedure in
#   docs/openstack-staged-rollout-runbook.md.

# ---------- Identity ----------
job_name    = "openstudio-server"
app_version = "3.10.0"
region      = "global"
# SITE-SPECIFIC: Override datacenters in openstack-site-local.hcl.
# Use your actual Nomad datacenter name(s); "dc1" is the Nomad default.
datacenters = ["dc1"]

# ---------- Images ----------
# Public DockerHub images. If your cluster cannot reach DockerHub (air-gapped),
# override these in openstack-site-local.hcl using your internal registry mirror.
# See examples/advanced/openstack-site-local.hcl.template for the override pattern.
web_image            = "nrel/openstudio-server:3.10.0"
web_background_image = "nrel/openstudio-server:3.10.0"
worker_image         = "nrel/openstudio-server:3.10.0"
# worker_runtime_image: leave empty to pull worker_image directly.
# Set only when using a registry-prefetch alias to avoid TLS timeouts (see variables.hcl).
worker_runtime_image = ""
rserve_image         = "nrel/openstudio-rserve:3.10.0"
db_image             = "mongo:8.0"
redis_image          = "redis:6.0.9-alpine"
verification_image   = "busybox:1.36"
poststop_cleanup_image = "alpine:3.20"
vector_image              = "timberio/vector:0.30.0-alpine"
enable_vector_collection  = true
prometheus_image       = "prom/prometheus:v2.53.2"
redis_exporter_image   = "oliver006/redis_exporter:v1.62.0"
nomad_autoscaler_image = "hashicorp/nomad-autoscaler:0.5.0"

# Scrape Nomad telemetry for worker alloc failure rate and sentinel alerts.
# Requires Nomad server config: telemetry { prometheus_metrics = true }
prometheus_scrape_nomad_enabled = true
# prometheus_nomad_scrape_target defaults to "nomad.service.consul:4646";
# override in openstack-site-local.hcl if Consul DNS is unavailable.

# ---------- Web ----------
# web_count MUST remain 1 — NFS does not provide distributed file-locking.
# See docs/infrastructure/operations-guide.md §'Web Replica Constraint'.
web_count    = 1
web_priority = 80
web_cpu      = 6000   # MHz — sufficient for Passenger + request routing
web_memory   = 51200  # MB  — covers Passenger workers + upload buffer
web_memory_max = 61440
web_constraints = [
  {
    attribute = "$${meta.node_role}"
    operator  = "="
    value     = "web"
  },
  {
    attribute = "$${attr.driver.docker}"
    operator  = "="
    value     = "1"
  },
  {
    attribute = "$${meta.disk_type}"
    operator  = "="
    value     = "local-large"
  }
]

# Keep stateful/service jobs on web-role nodes and worker jobs on worker-role nodes.
db_constraints = [
  {
    attribute = "$${meta.node_role}"
    operator  = "="
    value     = "web"
  },
  {
    attribute = "$${attr.driver.docker}"
    operator  = "="
    value     = "1"
  },
  {
    attribute = "$${meta.disk_type}"
    operator  = "="
    value     = "local-large"
  }
]

redis_constraints = [
  {
    attribute = "$${meta.node_role}"
    operator  = "="
    value     = "web"
  },
  {
    attribute = "$${attr.driver.docker}"
    operator  = "="
    value     = "1"
  },
  {
    attribute = "$${meta.disk_type}"
    operator  = "="
    value     = "local-large"
  }
]

rserve_constraints = [
  {
    attribute = "$${meta.node_role}"
    operator  = "="
    value     = "web"
  },
  {
    attribute = "$${attr.driver.docker}"
    operator  = "="
    value     = "1"
  },
  {
    attribute = "$${meta.disk_type}"
    operator  = "="
    value     = "local-large"
  }
]

# Traefik Host rule — must match the DNS name or IP/hostname used to reach the cluster.
# SITE-SPECIFIC: set this in openstack-site-local.hcl.
# ingress_domain = "openstudio.yourdomain.com"

# ---------- Web-background ----------
# Keep singleton: web-background is fixed at one allocation in the template.
web_background_cpu    = 16000  # MHz
web_background_memory = 16384  # MB
web_background_memory_max = 32768

web_background_worker_count        = 56
# Prioritize analysis lifecycle work before generic background jobs.
web_background_queues              = "analyses,background"

# patch-hosts.sh injects openstudio-db/redis/rserve Consul service IPs as
# 'db', 'queue', 'rserve' into /etc/hosts before the app starts.
# Without this the app startup script can't resolve those hostnames.
web_command = "/bin/sh"
web_args    = ["-c", "sh /local/patch-hosts.sh && exec /usr/local/bin/start-server"]
web_background_command = "/bin/sh"
# start-web-background has COUNT=6 hardcoded; bypass it and call rake directly
# so our COUNT=web_background_worker_count env var is honoured.
web_background_args    = ["-c", "sh /local/patch-hosts.sh && cd /opt/openstudio/server && exec bundle exec rake environment resque:workers"]

# ---------- Worker ----------
# Tuned values from staged rollout (see rollout runbook for rationale).
# 8-vCPU / 16 GB node: 2 allocations fit at 3 000 MHz / 6 144 MB each.
worker_priority      = 50
worker_cpu           = 1500   # MHz — leaves headroom for OS + Docker on 8-vCPU nodes
worker_memory        = 1250   # MB  — based on observed p99 RSS ~1080 MiB; 16% headroom; 64 allocs/node × 119 nodes
worker_memory_max    = 4000   # MB  — burst to full node memory before OOM
worker_process_count = "3"    # 3 processes × 500 MHz ≈ 4 500 MHz per allocation; 50 % more concurrent sims at same alloc count
worker_command = "/bin/sh"
worker_args    = ["-c", "sh /local/patch-hosts.sh && exec /usr/local/bin/start-workers"]
worker_constraints = [
  {
    attribute = "$${meta.node_role}"
    operator  = "="
    value     = "worker"
  },
  {
    attribute = "$${attr.driver.docker}"
    operator  = "="
    value     = "1"
  },
  {
    attribute = "$${meta.disk_type}"
    operator  = "="
    value     = "local-large"
  }
]

# Seed count; keep this equal to worker_min_replicas to avoid an immediate
# startup scale-down event that can put the policy into cooldown.
worker_count = 2

# 90 min kill timeout — covers longest observed OpenStack analysis runtime.
# Must be ≥ your longest simulation; shorter values cause data loss on drains.
worker_kill_timeout = "5400s"

# Autoscaling — CPU + queue-depth strategies (both active simultaneously).
# Prerequisites: Prometheus (prometheus_enabled) and Autoscaler daemon
# (nomad_autoscaler_enabled) must be deployed for queue-depth scaling to work.
prometheus_enabled       = true
nomad_autoscaler_enabled = true

# Autoscaler and Prometheus addresses — use Consul DNS (the variable defaults).
# Only override these in openstack-site-local.hcl when Consul DNS is unavailable
# on your cluster (e.g. Consul not running on worker nodes):
#   autoscaler_nomad_address      = "http://<nomad-server-ip>:4646"
#   autoscaler_prometheus_address = "http://<prometheus-ip>:9090"
#
# Default: autoscaler_nomad_address      = "http://nomad.service.consul:4646"
# Default: autoscaler_prometheus_address = "http://openstudio-prometheus.service.consul:9090"

# Place Prometheus on web-role infrastructure nodes (same placement domain as
# db/redis in this OpenStack profile). This cluster uses Nomad node metadata
# (meta.node_role), not node_class labels, for role targeting.
prometheus_constraints = [
  {
    attribute = "$${meta.node_role}"
    operator  = "="
    value     = "web"
  },
  {
    attribute = "$${attr.driver.docker}"
    operator  = "="
    value     = "1"
  },
  {
    attribute = "$${meta.disk_type}"
    operator  = "="
    value     = "local-large"
  }
]

autoscaler_constraints = [
  {
    attribute = "$${meta.node_role}"
    operator  = "="
    value     = "web"
  },
  {
    attribute = "$${attr.driver.docker}"
    operator  = "="
    value     = "1"
  },
  {
    attribute = "$${meta.disk_type}"
    operator  = "="
    value     = "local-large"
  }
]

worker_autoscaling_enabled       = true
worker_autoscaling_cpu_enabled   = false
worker_autoscaling_queue_enabled = true   # Scale on Redis queue depth via Prometheus
worker_min_replicas              = 2
# Physical ceiling: floor((node_ram_mb - 2048) / worker_memory) × compute_node_count
# floor((79872 - 2048) / 1250) = 62 allocs/node × 110 compute nodes = 6820
# Observed practical capacity: 6521 (below theoretical due to OS/system overhead).
#
# Memory oversubscription cap (Mode 3 OOM protection):
#   Cluster RAM: 110 nodes × 79872 MB = 8,585,920 MB total
#   80% utilization target: 8,585,920 × 0.80 = 6,868,736 MB
#   At worker_memory=1250 MB: 6,868,736 / 1250 = 5,495 → 5,500
#   Leaves ~1,715 GB cluster-wide headroom for workers bursting above reservation.
#   Reducing further only if mass-OOM events (>500 workers) recur in production.
worker_max_replicas              = 5500

# 60 % CPU target: conservative threshold to trigger scale-out before iowait spikes.
worker_cpu_target_utilization = 60

# Queue-depth target: ceil(queue_depth / target) = desired workers, clamped to [min, max].
# Formula: choose target ≤ ceil(expected_peak_queue / worker_max_replicas)
# At 32k queue and 6800 max: target ≤ ceil(32000 / 6800) = 5. Use 3 for headroom.
# - requeued: 1 worker per queued retry (recovery-oriented; keep at 1)
worker_queue_simulations_target = 3   # ceil(32000/3)=10667 → clamped to worker_max_replicas
worker_queue_requeued_target    = 1

# Scale-up cooldown: 2 min keeps queue bursts from waiting on long cooldown windows.
# Scale-down cooldown: 10 min reduces oscillation after burst drains.
worker_autoscaling_scale_up_cooldown   = "2m"
worker_autoscaling_scale_down_cooldown = "10m"

# Rolling update — prevents simultaneous eviction of running simulations.
# auto_revert=false: CRITICAL — prevents rollback to low-count version on partial placement failures.
# progress_deadline="0": CRITICAL — disables 20m timeout; large deployments stall at cluster capacity.
worker_update_max_parallel      = 1
worker_update_min_healthy_time  = "1m"
worker_update_healthy_deadline  = "10m"
worker_update_progress_deadline = "0"
worker_update_auto_revert       = false

# ---------- MongoDB ----------
# 2 000 MHz / 4 096 MB covers observed query load during Stage 3 soak.
db_cpu    = 4000   # MHz
db_memory = 22528  # MB — working set fits in RAM for typical project sizes
db_memory_max = 45056

db_static_port    = 27017
db_storage_type   = "csi"
db_volume_source  = "openstudio-mongodb"

# ---------- Redis ----------
redis_cpu    = 8000   # MHz
redis_memory = 16384  # MB
redis_memory_max = 24576

redis_static_port    = 6379
redis_storage_type   = "csi"
redis_volume_source  = "openstudio-redis"

# Redis TCP keepalive — prevents NAT/firewall dropping idle Resque connections.
redis_config_tcp_keepalive = 60

# ---------- Shared NFS (web + worker) ----------
# Recommended: OS-level NFS mount registered as a Nomad host_volume.
# See docs/infrastructure/storage.md for fstab + client.hcl setup instructions.
nfs_shared_volume_enabled = true
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"

# ---------- Rserve ----------
rserve_static_port = 6311
rserve_cpu    = 2000   # MHz
rserve_memory = 4096   # MB

# ---------- Logging ----------
log_max_size  = "50m"
log_max_files = 5

# ---------- Docker hardening ----------
# These defaults (non-root, read-only rootfs, drop ALL caps) are inherited from
# variables.hcl; listed here explicitly for visibility.
docker_user            = ""
docker_readonly_rootfs = false
docker_cap_drop        = []
# MongoDB and Redis run as 999:999 (image default). The CSI wipe script sets
# chmod 777 on /data so uid 999 can create subdirectories on first boot.
db_docker_user    = "999:999"
redis_docker_user = "999:999"

# ---------- Consul Connect mTLS ----------
# Enable service-mesh mTLS between all components.
enable_consul_connect = false

# ---------- Vault ----------
# Remove or set to false if Vault is not available in your OpenStack environment.
vault_integration_enabled = false
vault_enabled             = false
vault_default_role        = "openstudio-server"
vault_db_role             = "openstudio-db"
vault_redis_role          = "openstudio-redis"
vault_rserve_role         = "openstudio-rserve"
vault_policies            = ["openstudio-kv-read"]
vault_change_mode         = "restart"

# ---------- Backups ----------
# Enabled with 14-day retention. Requires "openstudio-backups" host volume.
backup_enabled        = true
backup_cron           = "0 0 2 * * *"
backup_volume_source  = "openstudio-backups"
backup_retention_days = 14
restore_enabled       = true

# ---------- Queue sweeper ----------
# Automatically clears orphaned resque:analysis:*:queuing locks from Redis.
# These locks stall all analyses in the queue until cleared.
enable_queue_sweeper                 = true
queue_sweeper_cron                   = "*/2 * * * *"
queue_sweeper_max_lock_age_seconds   = 120

# ---------- Stall watchdog ----------
# Detects data points frozen in "started" status (hung EnergyPlus processes
# holding Resque slots with no updated_at progress).  Stops worker allocs so
# Nomad reschedules fresh workers and coordinators re-queue stalled DPs.
# Complements queue-sweeper — both failure modes must be covered.
enable_stall_watchdog            = true
stall_watchdog_cron              = "*/15 * * * *"
stall_watchdog_max_stall_seconds = 3600   # 60 min — above longest normal sim
stall_watchdog_restart_allocs    = true
# stall_watchdog_nomad_address: uses http://localhost:4646 by default (via network_mode=host).
# Override in openstack-site-local.hcl only if Nomad is not reachable at localhost from
# within the task (e.g. NAT environments, non-host network mode):
#   stall_watchdog_nomad_address = "http://<nomad-server-ip>:4646"

# ---------- Image pre-pull ----------
# Pre-pulls all images on every compute node to eliminate cold-start delays.
# prepull_kill_timeout must be ≥ 600 s (10 min) — shorter values evict the cache.
enable_image_prepull   = true
prepull_kill_timeout   = "600s"

# ---------- Worker local scratch (staged artifact publish) ----------
# Uncomment once the application honours WORKER_SCRATCH_PATH and copies
# final artifacts to shared NFS before task completion (see docs/worker-local-scratch.md).
# worker_local_scratch_enabled = true
# worker_local_scratch_size    = 10240   # 10 GiB per allocation
# worker_local_scratch_sticky  = false   # clear on GC; set true to resume across restarts
# worker_scratch_path          = "/scratch"
