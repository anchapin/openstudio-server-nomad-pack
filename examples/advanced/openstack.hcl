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
#   nomad-pack run -var-file examples/advanced/openstack.hcl --name openstudio-server packs/openstudio-server
#   nomad-pack destroy -var-file examples/advanced/openstack.hcl --name openstudio-server packs/openstudio-server

job_name    = "openstudio-server"
datacenters = ["dc1"]

# ── Images ────────────────────────────────────────────────────────────────────
# Pull from local pulp registry to avoid Docker Hub DNS/timeouts.
web_image            = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-server:179-flock"
web_background_image = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-server:179-flock"
worker_image         = "pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-server:179-flock"
# Worker allocations use a host-local alias to avoid runtime registry lookups.
# system-hooks pre-pull tags this alias after pulling worker_image (raw_exec pull+tag).
# Using a short unqualified name ensures Docker never contacts a registry at alloc start.
worker_runtime_image = "openstudio-worker:local"
worker_force_pull    = false
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
#
# NFS MOUNT TUNING (Balanced profile — recommended for 100+ concurrent workers):
# Add the following to /etc/fstab on every Nomad client node, replacing
# <manila-share-ip> and <export-path> with your Manila share endpoint
# (from: openstack share access-list <share-name>):
#
#   <manila-share-ip>:<export-path> /mnt/openstudio nfs \
#     nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev \
#     0 0
#
# Key options:
#   nfsvers=4.1  — session-based reconnect; works with OpenStack Manila/Ganesha
#   rsize/wsize=1048576 — 1 MiB buffers; ~16x fewer round-trips vs the 64 KiB default
#   hard         — never silently drop writes; retry until the server responds
#   timeo=600    — 60 s RPC timeout; tolerates Manila HA failover
#   noresvport   — allows reconnection from a non-privileged port (required by Manila)
#   _netdev      — wait for network before mounting (prevents boot hangs)
#
# For very high concurrency (200+ workers) or if write throughput is still a
# bottleneck, add the `async` option and tune Ganesha Nb_Worker=128.
# See docs/nfs-tuning-guide.md for Conservative/Balanced/Aggressive profiles,
# benchmark methodology, and guardrails.
nfs_shared_volume_enabled = true
nfs_volume_type           = "host_volume"
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"

# ── Resources ────────────────────────────────────────────────────────────────
# Helm-equivalent sizing converted to Nomad units (1 CPU core ≈ 1000 MHz).
web_cpu               = 6000
web_memory            = 51200
web_memory_max        = 61440
# Helm-equivalent Passenger tuning:
#   MAX_POOL = ceil((web_memory * 0.75) / web_passenger_memory_per_process)
#            = ceil((51200 * 0.75) / 250) = 154
#   MAX_REQUESTS = ceil(worker_max_replicas * web_max_requests_multiplier)
#                = ceil(10000 * 1.05) = 10500
web_passenger_memory_per_process = 250
web_max_pool                     = 154
web_max_requests_multiplier      = 1.05
web_max_requests                 = 10500
web_background_cpu        = 16000  # scaled: 56 workers × ~286 MHz/worker
web_background_memory     = 16384  # scaled: 56 workers × ~293 MB/worker (16 GiB soft)
web_background_memory_max = 32768  # 2× soft limit (32 GiB hard ceiling)
web_background_worker_count = 56   # increased from 42 — proportional to above CPU/memory budget
web_background_queues = "background,analyses"  # matches Helm hardcoded QUEUES order
# Mongoid connection pool: web — one pool per Passenger process.
# Set equal to MAX_POOL (154) so no process stalls waiting for a MongoDB connection
# when all 154 Passenger slots are active simultaneously.
web_mongoid_pool_size = 154
# Mongoid connection pool: web-background — one pool per Resque child process.
# 56 children + 2 headroom = 58 connections so every forked child can acquire
# a MongoDB connection immediately without blocking.
web_background_mongoid_pool_size = 58
db_cpu                = 4000
db_memory             = 22528
db_memory_max         = 45056
redis_cpu             = 8000
redis_memory          = 16384
# Redis queue durability / high-throughput tuning (aligned with helm config guidance).
redis_config_maxclients         = 50000
redis_config_tcp_backlog        = 511
redis_config_timeout_seconds    = 0
# Keepalive: prevents NAT/firewall dropping idle Redis connections during long
# background initialization steps (e.g. large analysis extraction).  60 s is
# aggressive; increase to 300 s for more relaxed environments.
redis_config_tcp_keepalive      = 60
redis_config_maxmemory          = "22000000000"
redis_config_maxmemory_policy   = "noeviction"
redis_config_appendfsync        = "everysec"
redis_config_save               = ""
# Allow Redis to burst to 1.5× its soft limit during mass-enqueue spikes without
# being OOM-killed by the kernel; the hard cap prevents runaway allocation.
redis_memory_max                = 24576

# Optional hard pin for dedicated high-memory Redis nodes.
# Set this to a real Nomad node.class label in your cluster (for example:
# "stateful-highmem") when that pool exists.
redis_node_class = ""
# rserve_count: keep at 1 (default) for typical OpenStack research deployments.
# Increase to 2 only if concurrent worker count regularly exceeds ~10 workers.
# Requires issue #361 (multi-replica-safe routing) before scaling above 1.
# See docs/rserve-horizontal-scaling.md for full benchmark rationale.
rserve_cpu            = 2000
rserve_memory         = 4096
# Worker: 750 MHz / 875 MB soft / 2 GB max per allocation — dense-pack configuration.
# On azimuth.compute1-179d-250disk (62 vCPU ≈ 124,000 MHz, ~79.4 GB usable RAM):
#   CPU-bound:  124,000 / 750  = 165 workers per node
#   Mem-bound:  (80,412 - 1,000) / 875 = 90 workers per node  ← binding constraint
# 113 nodes × 90 workers = 10,170 workers total (exceeds 10,000 target).
# memory_max = 2,048 MB gives simulations 2× burst headroom. 90 workers × 2,048 MB
# = 184,320 MB — above node RAM, so Nomad will not co-locate 90 bursting workers
# simultaneously; in practice simulations burst at staggered times.
worker_cpu         = 750
worker_memory      = 875
worker_memory_max  = 2048
# Restrict workers to this OpenStack flavor (also used by deploy scripts for
# pre-pull readiness checks).
worker_instance_type = "azimuth.compute1-179d-250disk"

# Autoscaling — queue-based.
# Queue-depth checks drive scale-up from simulation backlog.
# Dense-pack math (within 9,600 vCPU practical ceiling):
#   10,000 workers × 750 MHz = 7,500,000 MHz ≈ 7,500 vCPU reserved
#   Remaining ~2,100 vCPU covers infra services + scheduler overhead
# Start with 4 workers; autoscaler ramps to demand up to 10,000.
worker_count               = 4
worker_autoscaling_enabled = true
worker_autoscaling_queue_enabled = true
worker_autoscaling_cpu_enabled = false
worker_min_replicas        = 0      # Allow scale-to-zero when both queues are empty
worker_max_replicas        = 10000
# Queue depth from redis_exporter key sizes (exposed via in-pack Prometheus job).
worker_queue_simulations_query = "redis_key_size{key=\"resque:queue:simulations\"}"
# Keep the requeued check neutral when that queue is empty so it doesn't
# suppress scale-out driven by the simulations queue.
worker_queue_requeued_query    = "redis_key_size{key=\"resque:queue:requeued\"}"
# Scale out earlier: tolerate at most 2 queued simulation jobs per worker before
# adding more allocations (default is 5 — too permissive for burst workloads).
worker_queue_simulations_target = 2
worker_queue_requeued_target    = 1
# Process simulations before retries — fresh jobs take priority over requeued ones.
worker_queues = "simulations,requeued"
# Prometheus endpoint used by queue-depth checks in worker.nomad.tpl.
# Keep this on a stable service address so autoscaler does not depend on
# Prometheus being co-located on the same node.
autoscaler_prometheus_address = "http://openstudio-prometheus.service.consul:9090"

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
docker_ulimit_nofile = "65535:65535"
# For fresh CSI volume recreation on this cluster, run DB/Redis as root so
# first-start directory creation inside mounted volumes cannot fail on ownership.
db_docker_user    = ""
redis_docker_user = ""
db_docker_ulimit_nofile    = "262144:262144"
redis_docker_ulimit_nofile = "131072:131072"

# ── Features ─────────────────────────────────────────────────────────────────
# Do NOT enable in-pack Traefik for production.
# Use OpenStack Octavia LBaaS for ingress (TLS termination via Barbican, HA ACTIVE/STANDBY).
# Enabling in-pack Traefik (deploy_traefik = true) is only appropriate for dev/Vagrant.
# See docs/traefik-openstack-decision.md for the full go/no-go rationale and Octavia setup steps.
deploy_traefik = false

# External LB / jump-host IP — used for Consul service tag routing hints only.
ingress_domain = "10.60.126.125"

# Disable Vector log collection to reduce image pulls and resource overhead.
enable_vector_collection = false

# No Consul Connect mTLS for initial testing.
enable_consul_connect = false

# Enable system-wide image pre-pull to reduce pull storms/timeouts during
# aggressive worker autoscaling.
enable_image_prepull = true

# Deploy in-pack Prometheus + Redis exporter for queue-depth autoscaling metrics.
prometheus_enabled = true
prometheus_alert_rules_enabled = true
prometheus_scrape_nomad_enabled = true
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
}]

autoscaler_constraints = [{
  attribute = "$${attr.driver.docker}"
  operator  = "="
  value     = "1"
}]
autoscaler_affinities = [{
  attribute = "$${meta.node_role}"
  operator  = "="
  value     = "web"
  weight    = 100
},
{
  attribute = "$${meta.disk_type}"
  operator  = "="
  value     = "local-large"
  weight    = 60
}]

# Keep non-worker services on web-role nodes.
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
}]

# Keep stateful/service jobs on web-role nodes and workers on worker-role nodes.

web_constraints = [{
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
}]

db_constraints = [
{
  attribute = "$${meta.node_role}"
  operator  = "="
  value     = "web"
},
{
  attribute = "$${meta.disk_type}"
  operator  = "="
  value     = "local-large"
},
{
  attribute = "$${attr.driver.docker}"
  operator  = "="
  value     = "1"
}]

redis_constraints = [
{
  attribute = "$${meta.node_role}"
  operator  = "="
  value     = "web"
},
{
  attribute = "$${meta.disk_type}"
  operator  = "="
  value     = "local-large"
},
{
  attribute = "$${attr.driver.docker}"
  operator  = "="
  value     = "1"
}]

# Keep worker-only nodes isolated from all non-worker services.
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
}]

# Run batch verification after deploy to confirm all services are reachable.
enable_batch_verification = false

# Proactive stale-lock recovery: clears orphaned resque:analysis:*:queuing
# locks from Redis automatically.  Locks orphan when web-background dies
# mid-enqueue; without this, all other analyses block indefinitely.
enable_queue_sweeper                   = true
queue_sweeper_cron                     = "*/2 * * * *"
queue_sweeper_max_lock_age_seconds     = 120

# ── Vault ─────────────────────────────────────────────────────────────────────
vault_integration_enabled = false
vault_enabled             = false

# ── Backup / restore ─────────────────────────────────────────────────────────
backup_enabled  = false
restore_enabled = false

# ── Nomad Autoscaler (CPU-based worker scaling) ───────────────────────────────
nomad_autoscaler_enabled   = true
autoscaler_nomad_address   = "http://nomad.service.consul:4646"
nomad_autoscaler_image     = "hashicorp/nomad-autoscaler:0.5.0"

# Storage-aware ramp guardrails (see docs/autoscaling-storage-ramp-policy.md).
# These values are intentionally conservative for an OpenStack environment where
# workers share NFS-backed storage. Increase max or shorten cooldowns only after
# confirming iowait stays below 40% through a full burst-and-drain cycle.
worker_autoscaling_scale_up_cooldown   = "10m"
worker_autoscaling_scale_down_cooldown = "20m"
worker_autoscaling_evaluation_interval = "30s"

# ── MongoDB / Redis / Rserve port binding ─────────────────────────────────────
# The OpenStudio Server startup scripts (start-server, start-web-background,
# start-workers) use Docker Compose-style hostnames: 'db:27017' for MongoDB
# and 'queue:6379' for Redis. Rserve clients in the app connect to 'rserve:6311'.
# In Nomad, service discovery is via Consul.
# We use:
#   1. Static host ports (27017 / 6379 / 6311) so wait-for-it and Rserve clients
#      can find services on fixed ports at the resolved host IP.
#      resolved host IP.
#   2. A Consul template stanza (in web.nomad.tpl) that generates
#      /local/patch-hosts.sh containing the current service IPs.
#   3. The command overrides below run patch-hosts.sh before start-server so
#      that 'db', 'queue', and 'rserve' resolve correctly inside the container.
db_static_port    = 27017
redis_static_port = 6379
rserve_static_port = 6311

web_command = "/bin/sh"
web_args    = ["-c", "sh /local/patch-hosts.sh && exec /usr/local/bin/start-server"]

web_background_command = "/bin/sh"
# start-web-background has COUNT=6 hardcoded; bypass it and call rake directly
# so our COUNT=web_background_worker_count env var is honoured.
web_background_args    = ["-c", "sh /local/patch-hosts.sh && cd /opt/openstudio/server && exec bundle exec rake environment resque:workers"]

worker_command = "/bin/sh"
worker_args    = ["-c", "sh /local/patch-hosts.sh && exec /usr/local/bin/start-workers"]
