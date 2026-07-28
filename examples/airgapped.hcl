# Air-gapped override — private registry image overrides, Vault disabled.
#
# Use this file when the Nomad cluster has no access to Docker Hub or other
# public registries.  Every image is redirected to an internal mirror.
# Vault integration is deliberately disabled; credentials are supplied via
# Nomad's encrypted variables or pre-seeded environment variables instead.
#
# Usage:
#   nomad-pack run -var-file examples/airgapped.hcl .

# ---------- Identity ----------
job_name    = "openstudio-server"
app_version = "3.7.0"
datacenters = ["dc1"]

# ---------- Private registry images ----------
# Replace "registry.internal" with your organisation's registry hostname/path.
web_image            = "registry.internal/openstudio-server:3.7.0"
web_background_image = "registry.internal/openstudio-server:3.7.0"
worker_image         = "registry.internal/openstudio-server:3.7.0"
db_image             = "registry.internal/mongo:4.2"
redis_image          = "registry.internal/redis:6.2-alpine"
rserve_image         = "registry.internal/openstudio-rserve:3.7.0"
vector_image         = "registry.internal/vector:0.30.0-alpine"
poststop_cleanup_image = "registry.internal/alpine:3.20"
verification_image   = "registry.internal/busybox:1.36"

# ---------- Storage (persistent, no cloud CSI required) ----------
mongodb_storage_type = "host"
mongodb_host_volume  = "openstudio-mongodb"

redis_storage_type = "host"
redis_host_volume  = "openstudio-redis"

# ---------- Vault — disabled (air-gapped clusters typically lack Vault) ----------
vault_integration_enabled  = false
vault_enabled               = false
enable_vault_mongo_secrets  = false

# ---------- Worker ----------
worker_count               = 2
worker_autoscaling_enabled = false   # No external Prometheus in air-gapped env
worker_cpu                 = 4000
worker_memory              = 8192

# ---------- Logging ----------
# Use journald so logs go to the host journal without requiring network egress.
log_driver_type = "journald"

# Disable Vector sidecar — no external log aggregator available.
enable_vector_collection = false

# ---------- Backups ----------
backup_enabled         = true
backup_nfs_host_volume = "openstudio-backups"
backup_retention_days  = 14
restore_enabled        = true

# ---------- Batch verification ----------
# Validate that all services are reachable before declaring the deployment healthy.
enable_batch_verification = true
verification_targets = [
  "db=openstudio-db.service.consul:27017",
  "redis=openstudio-redis.service.consul:6379",
  "rserve=openstudio-rserve.service.consul:6311",
]
