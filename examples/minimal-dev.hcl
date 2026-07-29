# Minimal variable overrides for CI / local dev testing.
#
# Single-node, minimal resources.  Ephemeral storage — data does not survive
# allocation restarts.  No Vault, no Consul Connect, no autoscaling.
#
# Usage:
#   nomad-pack run -var-file examples/minimal-dev.hcl .

job_name    = "openstudio-server-dev"
datacenters = ["dc1"]

# Ephemeral storage — suitable for CI and local dev only.
mongodb_storage_type = "ephemeral"
redis_storage_type   = "ephemeral"

# Reduce resource usage for a single-node developer environment.
web_cpu     = 300
web_memory  = 512
db_cpu      = 300
db_memory   = 512
redis_cpu   = 128
redis_memory = 256
worker_cpu  = 1000
worker_memory = 2048

# One worker, no autoscaling.
# Override production defaults (min:2, max:20 per Helm HPA) for resource-constrained dev.
worker_count               = 1
worker_autoscaling_enabled = false
worker_min_replicas        = 1
worker_max_replicas        = 2

# Disable sidecars and optional features to minimise image-pull time.
enable_vector_collection  = false
enable_consul_connect     = false
enable_batch_verification = false

# No Vault in a local dev cluster.
vault_integration_enabled  = false
vault_enabled               = false

# Disable backups for ephemeral dev deployments.
backup_enabled  = false
restore_enabled = false

# Uncomment to deploy Traefik ingress alongside the stack.
# deploy_traefik = true
