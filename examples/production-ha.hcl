# Production HA override — multi-datacenter, HA resources, Vault enabled.
#
# Usage:
#   nomad-pack run -var-file examples/production-ha.hcl .
#
# Prerequisites:
#   - Vault cluster integrated with Nomad (vault_enabled = true)
#   - MongoDB and Redis host volumes provisioned on all Nomad clients
#   - NFS-backed host volume "openstudio-backups" mounted on backup-eligible clients
#   - Nomad Autoscaler daemon deployed (required for all worker autoscaling)
#   - Prometheus (required only for queue-depth scaling; CPU scaling uses nomad-apm and needs no external metrics)

# ---------- Identity ----------
job_name    = "openstudio-server"
app_version = "3.11.0"
region      = "us-east-1"
datacenters = ["dc1", "dc2", "dc3"]

# ---------- Images ----------
web_image            = "nrel/openstudio-server:3.11.0"
web_background_image = "nrel/openstudio-server:3.11.0"
worker_image         = "nrel/openstudio-server:3.11.0"
rserve_image         = "nrel/openstudio-rserve:3.11.0"

# ---------- Web ----------
web_priority = 90
web_cpu      = 1000
web_memory   = 2048

web_background_count = 2

# ---------- Web-background (autoscaling) ----------
# Static seed count; autoscaler owns the actual count.
web_background_autoscaling_enabled = true
web_background_min_replicas        = 1
web_background_max_replicas        = 5

# ---------- Worker (autoscaling) ----------
worker_priority      = 60
worker_cpu           = 4000
worker_memory        = 8192
worker_process_count = "2"

# Static seed count; autoscaler owns the actual count.
worker_count = 2

worker_autoscaling_enabled  = true
worker_autoscaling_cpu_enabled = true  # Uses nomad-apm (built-in Nomad API driver); no Prometheus required
worker_min_replicas         = 2
worker_max_replicas         = 20
autoscaler_cooldown         = "60m"

worker_update_max_parallel      = 2
worker_update_min_healthy_time  = "1m"
worker_update_healthy_deadline  = "10m"
worker_update_progress_deadline = "20m"

# ---------- MongoDB ----------
db_cpu    = 2000
db_memory = 4096

db_storage_type = "host_volume"
db_volume_source  = "openstudio-mongodb"

# Spread MongoDB across datacenters for HA.
db_spreads = [
  { attribute = "$${node.datacenter}", weight = 100 }
]

# ---------- Redis ----------
redis_cpu    = 500
redis_memory = 1024

redis_storage_type = "host_volume"
redis_volume_source  = "openstudio-redis"

redis_spreads = [
  { attribute = "$${node.datacenter}", weight = 100 }
]

# ---------- Shared NFS (web + worker) ----------
# Recommended: OS-level NFS mount registered as a Nomad host_volume.
# Prerequisites: see examples/volumes/openstudio-shared-host-volume.hcl for the
#   required fstab entry and client.hcl host_volume stanza before deploying.
# Note: web_count MUST remain 1 — NFS provides shared filesystem access but does
#   NOT guarantee POSIX file-locking across multiple simultaneous writers; multiple
#   web replicas cause split-brain writes. This mirrors the Helm chart constraint
#   (web-hpa.yaml maxReplicas: 1). See docs/storage.md §'Web Replica Constraint'.
nfs_shared_volume_enabled = true
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"

# web_count must stay 1 (NFS does not provide distributed file-locking).
# See docs/storage.md §'Web Replica Constraint' for details and upgrade path.
web_count = 1

# ---------- Rserve ----------
rserve_cpu    = 1000
rserve_memory = 2048

# ---------- Logging ----------
log_max_size  = "50m"
log_max_files = 5

# ---------- Consul Connect mTLS ----------
enable_consul_connect = true

# ---------- Vault ----------
vault_integration_enabled = true
vault_enabled             = true
vault_default_role        = "openstudio-server"
vault_db_role             = "openstudio-db"
vault_redis_role          = "openstudio-redis"
vault_rserve_role         = "openstudio-rserve"
vault_policies            = ["openstudio-kv-read"]
vault_change_mode         = "restart"

# ---------- Backups ----------
backup_enabled          = true
backup_cron             = "0 0 2 * * *"
backup_volume_source    = "openstudio-backups"
backup_retention_days   = 30
restore_enabled         = true
