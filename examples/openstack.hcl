# OpenStack (NREL aurora-179d) test configuration for openstudio-server-nomad-pack.
#
# Targets the existing Nomad cluster in OpenStack:
#   - 25× CM.Medium nodes: 16 vCPU, 32 GB RAM — used for web/db/redis/rserve/workers
#   -  9× CM.Tiny nodes:    4 vCPU,  8 GB RAM — not targeted (too small for OS server)
#
# Prerequisites (see infra-setup.nomad):
#   1. Consul server running on nomad-server (192.168.100.87:8500)
#   2. Nomad clients configured with consul.address = 192.168.100.87:8500
#   3. Docker data-root moved to local storage on clients that run heavy images
#
# Usage:
#   export NOMAD_ADDR=http://localhost:4646  # SSH tunnel must be open
#   nomad-pack run . -var-file examples/openstack.hcl --name openstudio-server
#   nomad-pack destroy . -var-file examples/openstack.hcl --name openstudio-server

job_name    = "openstudio-server"
datacenters = ["dc1"]

# ── Images ────────────────────────────────────────────────────────────────────
# Pull from local pulp registry to avoid Docker Hub DNS/timeouts.
web_image            = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-server:179-flock"
web_background_image = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-server:179-flock"
worker_image         = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-server:179-flock"
rserve_image         = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-rserve:179-flock"
db_image             = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/mongo:8.0.12"
redis_image          = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/redis:6.0.9"
verification_image   = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/registry.k8s.io/e2e-test-images/busybox:1.29-2"
poststop_cleanup_image = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/registry.k8s.io/e2e-test-images/busybox:1.29-2"

# ── Service discovery ─────────────────────────────────────────────────────────
# Point wait-for-deps health checks directly at the central Consul server
# (all clients register services there via the consul stanza in nomad client config).
consul_address = "192.168.100.87:8500"

# ── Storage ───────────────────────────────────────────────────────────────────
# Ephemeral for DB and Redis — no host_volume registration needed for initial testing.
# Upgrade to host_volume once testing confirms the stack works end-to-end.
db_storage_type    = "ephemeral"
redis_storage_type = "ephemeral"

# Shared web+worker volume: use the NFS path directly as a bind mount.
# All clients mount nomad-server:/nfs/opensstudio/batch at /nfs/opensstudio/batch.
# This gives web and worker tasks a shared filesystem for analysis artefacts.
dev_shared_data_path = "/nfs/opensstudio/batch/openstudio"

# ── Resources (sized for CM.Medium: 16 vCPU, 32 GB RAM) ─────────────────────
web_cpu            = 1000
web_memory         = 4096
web_background_cpu    = 500
web_background_memory = 2048
db_cpu             = 500
db_memory          = 1024
redis_cpu          = 256
redis_memory       = 512
rserve_cpu         = 1000
rserve_memory      = 2048
worker_cpu         = 1000
worker_memory      = 1024
# memory_max must be set explicitly — the default (6144 MB) would allow workers to burst
# far beyond what the node can actually provide, causing OOM kills under load.
# Set to a realistic ceiling: enough headroom above the soft limit for simulation spikes.
worker_memory_max  = 2048

# Start with 2 workers; scale up once the stack is healthy.
# Capacity calculation (23 CM.Medium + 9 CM.Tiny available after infra services):
#   Nomad placement limit (memory=1024 MB):  744 workers
#   Memory_max-safe ceiling (memory_max=2048 MB): 372 workers  ← binding constraint
#   worker_max_replicas set to 362 (safe ceiling minus small buffer)
worker_count               = 2
worker_autoscaling_enabled = false
worker_min_replicas        = 1
worker_max_replicas        = 362

# ── Scheduling ────────────────────────────────────────────────────────────────
# Enforce linux/amd64 constraint (all OpenStack nodes are Ubuntu x86_64).
enable_arch_constraint = true

# ── Security hardening ────────────────────────────────────────────────────────
# Disable readonly rootfs — the OpenStudio Server app writes to /opt/openstudio/server/log,
# /tmp, /opt/nginx/conf, etc. at runtime. Enable once those paths are properly handled.
docker_readonly_rootfs = false
# Run containers as root — the openstudio-server image expects root at startup.
docker_user     = ""
docker_cap_drop = []

# ── Features ─────────────────────────────────────────────────────────────────
# Disable Vector log collection to reduce image pulls and resource overhead.
enable_vector_collection = false

# No Consul Connect mTLS for initial testing.
enable_consul_connect = false

# Disable system-wide image pre-pull for now.
enable_image_prepull = false

# Pin rserve to a node with local Docker storage configured
# to avoid NFS xattr capability extraction failures.
rserve_constraints = [
  {
    attribute = "$${node.unique.name}"
    operator  = "="
    value     = "nomad-client-59"
  }
]

# Run batch verification after deploy to confirm all services are reachable.
enable_batch_verification = false

# ── Vault ─────────────────────────────────────────────────────────────────────
vault_integration_enabled = false
vault_enabled             = false

# ── Backup / restore ─────────────────────────────────────────────────────────
backup_enabled  = false
restore_enabled = false
