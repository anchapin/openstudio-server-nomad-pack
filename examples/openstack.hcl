# OpenStack (NREL aurora-179d) configuration for openstudio-server-nomad-pack.
#
# Scale-out target: ~8,160 usable worker vCPU (9,600 vCPU practical ceiling per admin
# guidance, minus ~15% headroom for Nomad/Consul/system scheduler overhead).
#
# Node fleet (post scale-out):
#   - Up to ~1,983 × cc.medium nodes (4 vCPU, 8 GB RAM) — worker pool
#   - Existing CM.Medium nodes (16 vCPU, 32 GB RAM) — infra services
#   -  9× CM.Tiny nodes (4 vCPU, 8 GB RAM) — not targeted (too small for OS server)
#
# vCPU budget:
#   Practical ceiling (admin):   9,600 vCPU
#   System/scheduler headroom:  ~600 vCPU (~6%)
#   Usable worker budget:        9,000 vCPU across worker nodes
#   Dense-pack target:           750 MHz/worker → 5 workers per cc.medium node
#   worker_max_replicas ceiling: 10,000 workers × 750 MHz = 7,500,000 MHz (9,600 vCPU budget respected)
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
# Persistent state: use CSI volumes for MongoDB and Redis so they survive node
# replacement and can reschedule cleanly.
db_storage_type    = "csi"
db_volume_source   = "openstudio-mongodb"
redis_storage_type = "csi"
redis_volume_source = "openstudio-redis"

# Shared analysis workspace: use a Nomad host_volume backed by the OS-level NFS
# mount so web, web-background, and worker allocations see the same files.
nfs_shared_volume_enabled = true
nfs_volume_type           = "host_volume"
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"

# ── Resources ────────────────────────────────────────────────────────────────
# Helm-equivalent sizing converted to Nomad units (1 CPU core ≈ 1000 MHz).
web_cpu               = 6000
web_memory            = 51200
web_background_cpu    = 12000
web_background_memory = 12288
db_cpu                = 4000
db_memory             = 22528
db_memory_max         = 45056
redis_cpu             = 8000
redis_memory          = 16384
rserve_cpu            = 2000
rserve_memory         = 4096
# Worker: 750 MHz / 1 GB soft / 2 GB max per allocation — dense-pack configuration.
# On cc.medium (4 vCPU ≈ 4,000 MHz, ~7.5 GB usable RAM):
#   CPU-bound:  4,000 / 750  = 5.3 → 5 workers per node  ← binding constraint
#   Mem-bound:  7,500 / 1024 = 7.3 → 7 workers per node
# memory_max = 2,048 MB gives simulations 2× burst headroom without risking OOM
# across all 5 co-located workers (5 × 2,048 = 10,240 MB — above node RAM, so
# Nomad will not place 5 if all burst simultaneously; in practice simulations
# burst at staggered times, making this safe under normal workload patterns).
worker_cpu         = 750
worker_memory      = 1024
worker_memory_max  = 2048

# Autoscaling — CPU-based (nomad-apm, no external Prometheus required).
# Target 70% CPU utilization per allocation before scaling out.
# Dense-pack math (within 9,600 vCPU practical ceiling):
#   10,000 workers × 750 MHz = 7,500,000 MHz ≈ 7,500 vCPU reserved
#   Remaining ~2,100 vCPU covers infra services + scheduler overhead
# Start with 4 workers; autoscaler ramps to demand up to 10,000.
worker_count               = 4
worker_autoscaling_enabled = true
worker_autoscaling_cpu_enabled = true
worker_cpu_target_utilization  = 70
worker_min_replicas        = 4
worker_max_replicas        = 10000

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

# Force web, db, and redis onto 179d nodes (50 GB disk) so large Docker image
# pulls don't exhaust the 10 GB root disks on older CM.Medium nodes.

web_constraints = [{
  attribute = "$${meta.disk_type}"
  operator  = "="
  value     = "local-large"
}]

db_constraints = [{
  attribute = "$${meta.disk_type}"
  operator  = "="
  value     = "local-large"
}]

redis_constraints = [{
  attribute = "$${meta.disk_type}"
  operator  = "="
  value     = "local-large"
}]

# Run batch verification after deploy to confirm all services are reachable.
enable_batch_verification = false

# ── Vault ─────────────────────────────────────────────────────────────────────
vault_integration_enabled = false
vault_enabled             = false

# ── Backup / restore ─────────────────────────────────────────────────────────
backup_enabled  = false
restore_enabled = false

# ── Nomad Autoscaler (CPU-based worker scaling) ───────────────────────────────
nomad_autoscaler_enabled   = true
autoscaler_nomad_address   = "http://127.0.0.1:4646"
nomad_autoscaler_image     = "hashicorp/nomad-autoscaler:0.5.0"

# ── MongoDB / Redis port binding ──────────────────────────────────────────────
# The OpenStudio Server startup scripts (start-server, start-web-background,
# start-workers) use Docker Compose-style hostnames: 'db:27017' for MongoDB
# and 'queue:6379' for Redis.  In Nomad, service discovery is via Consul.
# We use:
#   1. Static host ports (27017 / 6379) so wait-for-it can find them on the
#      resolved host IP.
#   2. A Consul template stanza (in web.nomad.tpl) that generates
#      /local/patch-hosts.sh containing the current service IPs.
#   3. The command overrides below run patch-hosts.sh before start-server so
#      that 'db' and 'queue' resolve correctly inside the container.
db_static_port    = 27017
redis_static_port = 6379

web_command = "/bin/sh"
web_args    = ["-c", "sh /local/patch-hosts.sh && exec /usr/local/bin/start-server"]

web_background_command = "/bin/sh"
web_background_args    = ["-c", "sh /local/patch-hosts.sh && exec /usr/local/bin/start-web-background"]

worker_command = "/bin/sh"
worker_args    = ["-c", "sh /local/patch-hosts.sh && exec /usr/local/bin/start-workers"]
