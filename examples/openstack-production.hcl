# OpenStack Production override — tuned defaults for OpenStack-hosted Nomad clusters.
#
# Tuned against staged rollout evidence (see docs/openstack-staged-rollout-runbook.md).
# Typical target node flavour: 8 vCPU / 16 GB RAM compute nodes.
#
# Usage:
#   nomad-pack run -var-file examples/openstack-production.hcl .
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
app_version = "3.11.0"
region      = "RegionOne"   # OpenStack region; update to match your deployment
datacenters = ["dc1"]       # Update to match your Nomad datacenter name(s)

# ---------- Images ----------
# All four image tags must be kept in alignment; bump together on version upgrades.
web_image            = "nrel/openstudio-server:3.11.0"
web_background_image = "nrel/openstudio-server:3.11.0"
worker_image         = "nrel/openstudio-server:3.11.0"
rserve_image         = "nrel/openstudio-rserve:3.11.0"

# ---------- Web ----------
# web_count MUST remain 1 — NFS does not provide distributed file-locking.
# See docs/operations-guide.md §'Web Replica Constraint'.
web_count    = 1
web_priority = 80
web_cpu      = 1000   # MHz — sufficient for Passenger + request routing
web_memory   = 2048   # MB  — covers Passenger workers + upload buffer

# ---------- Web-background ----------
web_background_count  = 2
web_background_cpu    = 2000   # MHz
web_background_memory = 2048   # MB

web_background_autoscaling_enabled = true
web_background_min_replicas        = 1
web_background_max_replicas        = 4

# ---------- Worker ----------
# Tuned values from staged rollout (see rollout runbook for rationale).
# 8-vCPU / 16 GB node: 2 allocations fit at 3 000 MHz / 6 144 MB each.
worker_priority      = 50
worker_cpu           = 3000   # MHz — leaves headroom for OS + Docker on 8-vCPU nodes
worker_memory        = 6144   # MB  — ~38 % of 16 GB; allows 2 allocations per node
worker_memory_max    = 8192   # MB  — burst to full node memory before OOM
worker_process_count = "2"    # 2 processes × 3 000 MHz ≈ 6 000 MHz per allocation

# Seed count; autoscaler owns actual count. 2 prevents cold-start lag.
worker_count = 2

# 90 min kill timeout — covers longest observed OpenStack analysis runtime.
# Must be ≥ your longest simulation; shorter values cause data loss on drains.
worker_kill_timeout = 5400

# Autoscaling — CPU + queue-depth strategies (both active simultaneously).
# Prerequisites: Prometheus (prometheus_enabled) and Autoscaler daemon
# (nomad_autoscaler_enabled) must be deployed for queue-depth scaling to work.
prometheus_enabled       = true
nomad_autoscaler_enabled = true

worker_autoscaling_enabled       = true
worker_autoscaling_cpu_enabled   = true
worker_autoscaling_queue_enabled = true   # Scale on Redis queue depth via Prometheus
worker_min_replicas              = 2
worker_max_replicas              = 20     # Stage 4 target; adjust to cluster size

# 60 % CPU target: conservative threshold to trigger scale-out before iowait spikes.
worker_cpu_target_utilization = 60

# Queue-depth targets: 1 worker per 15 queued simulations.
# At 300 queued jobs: 300 ÷ 15 = 20 workers (hits worker_max_replicas).
# Tune lower (e.g. 10) for faster ramp, higher (e.g. 20) to be more conservative.
worker_queue_simulations_target = 15
worker_queue_requeued_target    = 15

# Scale-up cooldown: 5 min allows fast ramp-up when the queue is deep.
# Scale-down cooldown: keep 20 min to avoid thrashing between simulation batches.
# The global autoscaler_cooldown is overridden per-direction below.
worker_autoscaling_scale_up_cooldown   = "5m"
worker_autoscaling_scale_down_cooldown = "20m"

# Legacy global cooldown (used by CPU check and as fallback); kept for reference.
autoscaler_cooldown = "30m"

# Rolling update — prevents simultaneous eviction of running simulations.
worker_update_max_parallel      = 1
worker_update_min_healthy_time  = "1m"
worker_update_healthy_deadline  = "10m"
worker_update_progress_deadline = "20m"

# ---------- MongoDB ----------
# 2 000 MHz / 4 096 MB covers observed query load during Stage 3 soak.
db_cpu    = 2000   # MHz
db_memory = 4096   # MB — working set fits in RAM for typical project sizes

db_storage_type   = "host_volume"
db_volume_source  = "openstudio-mongodb"

# ---------- Redis ----------
redis_cpu    = 500    # MHz
redis_memory = 1024   # MB

redis_storage_type   = "host_volume"
redis_volume_source  = "openstudio-redis"

# Redis TCP keepalive — prevents NAT/firewall dropping idle Resque connections.
redis_config_tcp_keepalive = 60

# ---------- Shared NFS (web + worker) ----------
# Recommended: OS-level NFS mount registered as a Nomad host_volume.
# See docs/storage.md for fstab + client.hcl setup instructions.
nfs_shared_volume_enabled = true
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"

# ---------- Rserve ----------
rserve_cpu    = 1000   # MHz
rserve_memory = 2048   # MB

# ---------- Logging ----------
log_max_size  = "50m"
log_max_files = 5

# ---------- Docker hardening ----------
# These defaults (non-root, read-only rootfs, drop ALL caps) are inherited from
# variables.hcl; listed here explicitly for visibility.
docker_user            = "1000:1000"
docker_readonly_rootfs = true
docker_cap_drop        = ["ALL"]

# ---------- Consul Connect mTLS ----------
# Enable service-mesh mTLS between all components.
enable_consul_connect = true

# ---------- Vault ----------
# Remove or set to false if Vault is not available in your OpenStack environment.
vault_integration_enabled = true
vault_enabled             = true
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
