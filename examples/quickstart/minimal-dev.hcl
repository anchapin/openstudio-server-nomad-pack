# Minimal variable overrides for CI / local dev testing.
#
# Single-node, minimal resources.  Ephemeral storage — data does not survive
# allocation restarts.  No Vault, no Consul Connect, no autoscaling.
#
# Usage:
#   nomad-pack run -var-file examples/quickstart/minimal-dev.hcl packs/openstudio-server

job_name    = "openstudio-server-dev"
datacenters = ["dc1"]

# Ephemeral storage — suitable for CI and local dev only.
db_storage_type = "ephemeral"
redis_storage_type   = "ephemeral"

# Reduce resource usage for a single-node developer environment.
web_cpu            = 300
web_memory         = 2048
web_background_memory = 2048
db_cpu             = 300
db_memory          = 512
redis_cpu          = 128
redis_memory       = 256
worker_cpu         = 1000
worker_memory      = 1024

# Container image tags for local dev.  Use the same tag for all services to avoid
# version mismatch issues (e.g. web-background and worker must match the web
# image version).
web_image             = "nrel/openstudio-server:179-flock"
web_background_image  = "nrel/openstudio-server:179-flock"
worker_image          = "nrel/openstudio-server:179-flock"
rserve_image          = "nrel/openstudio-rserve:179-flock"

# One worker, no autoscaling.
# Override production defaults (min:2, max:20 per Helm HPA) for resource-constrained dev.
worker_count               = 1
worker_autoscaling_enabled = false
worker_min_replicas        = 1
worker_max_replicas        = 2

# Disable the linux/amd64 arch constraint so the worker can be scheduled on macOS
# and ARM64 dev nodes (e.g. Apple Silicon running native Nomad).
enable_arch_constraint = false

# On macOS Docker Desktop, wait-for-deps containers (network_mode=host) run inside
# the Docker VM and cannot reach the Mac's 127.0.0.1. Use host.docker.internal
# so they can resolve the natively-running Consul agent.
consul_address = "host.docker.internal:8500"

# On macOS Docker Desktop, the web container runs in a Docker bridge network and
# cannot reach 127.0.0.1 on the host.  The OpenStudio Server app's startup script
# uses Docker Compose hostnames ('db' for MongoDB, 'queue' for Redis).  We map
# them to host-gateway (the Docker host IP) so the app can find the services.
# We also pin MongoDB, Redis, and Rserve to fixed ports so the hostnames work reliably.
db_static_port    = 27017
redis_static_port = 6379
rserve_static_port = 6311
web_extra_hosts   = ["db:host-gateway", "queue:host-gateway", "rserve:host-gateway"]
# Worker downloads analysis/data_point payloads from APP_CONFIG os_server_host_url
# ('http://web:80' in docker env). Map 'web' to host-gateway so worker can reach
# the web task via the host's static web_port.
worker_extra_hosts = ["db:host-gateway", "queue:host-gateway", "web:host-gateway"]

# REDIS_URL must use redis:// scheme prefix so Rails' URI.parse() correctly
# extracts host/port. The default 'queue:6379' (without //) is parsed as a
# URI scheme rather than host:port, causing Redis to fall back to 127.0.0.1.
web_redis_url     = "redis://queue:6379"
# Work around intermittent Rserve plotting errors during LHS sample generation
# in local dev by using the app's Ruby sampler backend.
os_server_sampling_backend = "ruby"

# Shared data volume: both web and web-background need access to the same
# /mnt/openstudio directory (replicating the Docker Compose 'osdata' named volume).
# The web container writes uploaded ZIPs there; web-background workers read them
# during InitializeAnalysis, and the worker container reads/writes simulation data.
# Use a Docker named volume (not a macOS bind mount) to avoid VirtioFS write-
# consistency issues on Apple Silicon: named volumes live in the Docker VM
# filesystem and bypass the VirtioFS layer, preventing CRC corruption of ZIPs.
# Pre-create with: docker volume create openstudio-osdata-dev
dev_shared_volume_name = "openstudio-osdata-dev"

# Disable security hardening options that prevent the app from writing to
# required paths (/opt/openstudio/server/log, /tmp, /opt/nginx/conf, etc.).
# These are appropriate for local dev only — do not carry over to production.
docker_readonly_rootfs = false
# The OpenStudio Server image (User: "") expects to run as root. Forcing 1000:1000
# (the production default) breaks the startup scripts. Use root for local dev.
docker_user     = ""
docker_cap_drop = []
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
