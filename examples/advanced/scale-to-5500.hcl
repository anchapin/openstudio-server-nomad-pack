# scale-to-5500.hcl — Reference overrides for sustainably scaling the worker
# fleet to 5,500 allocations.
#
# PURPOSE
# -------
# This file documents the complete set of knobs that keep a 5,500-worker
# OpenStudio Server deployment healthy. It is the *corrected* configuration
# applied after the 2026-08-08 incident, in which a deep Redis backlog combined
# with a 2m scale-up cooldown and an unbounded per-cycle delta mapped the queue
# to thousands of desired workers almost instantly (2 → 500 → 5500 in ~10 min).
# The resulting thundering herd saturated the web task (Passenger/nginx load
# 154, 4,033 processes, MAX_REQUESTS=5775), made the Consul /status health check
# time out, and flipped Traefik's route to a 404 page.
#
# USAGE
# -----
# Apply on top of the base profile (last var-file wins):
#
#   nomad-pack run \
#     -var-file examples/advanced/openstack-production.hcl \
#     -var-file examples/advanced/scale-to-5500.hcl \
#     -var-file openstack-site-local.hcl \
#     packs/openstudio-server
#
# Every value below is a deliberately conservative *ceiling*; raise any knob
# only after measuring headroom on the live cluster. Copy the values you adopt
# into openstack-site-local.hcl (gitignored, site-specific) — do not commit
# site IPs.
#
# RELATED
# -------
# - scripts/scale-test-runbook.sh — staged scale test (100 → 1,000 → 2,500 → 5,500)
# - docs/infrastructure/operations-guide.md — day-2 operations
# - docs/compatibility.md — pack ↔ app version matrix

# ---------- Web: bounded request queue + resilient health check ----------
# MAX_REQUESTS was auto-derived as ceil(worker_max_replicas * 1.05) = 5775,
# which let Passenger accumulate a 5,775-item queue. Bound it explicitly.
# Raise only with evidence of web capacity headroom.
web_max_requests = 500

# The web container can exceed a 2s probe under extreme load without being
# down. A single failed probe must not drop the Traefik route (the 404 root
# cause). 30s/15s probes, require 2 consecutive successes before passing, and
# tolerate 3 consecutive failures before Consul marks the service critical.
web_health_check_interval                 = "30s"
web_health_check_timeout                  = "15s"
web_health_check_success_before_passing   = 2
web_health_check_failures_before_critical = 3

# ---------- Worker autoscaling: bounded pace, not bounded ceiling ----------
# 5,500 is the memory-oversubscription ceiling computed for the 110-node
# compute pool (80% cluster RAM utilization target) — see
# openstack-production.hcl. Keep the ceiling; bound the *rate* of approach.
worker_max_replicas   = 5500
worker_min_replicas   = 50    # keep a warm floor so a fresh backlog is picked up promptly
worker_count          = 50    # seed count must equal worker_min_replicas to avoid an immediate scale-down event

# Rate limits. Each evaluation cycle moves the fleet by at most
# worker_autoscaling_max_scale_delta allocations; with a 60s evaluation
# interval and a 15m scale-up cooldown the ceiling is ~150 new workers per
# 15m window. Do NOT raise max_scale_delta above 10 on this fleet until the
# staged scale test proves Consul agents, web, and NFS stay healthy.
worker_autoscaling_max_scale_delta     = 10
worker_autoscaling_evaluation_interval = "60s"
worker_autoscaling_scale_up_cooldown   = "15m"
worker_autoscaling_scale_down_cooldown = "20m"

# Queue-depth targets: ceil(queue_depth / target) = desired workers.
# The live deployment drifted to dividing by 1 (requeued) and 3 (simulations),
# so a 32k backlog requested ~32k workers (clamped to max). Dividing by 20
# maps the same backlog to ~1,600 desired workers and lets the rate limits
# above ramp the fleet without overshoot.
worker_queue_requeued_target    = 20
worker_queue_simulations_target = 20
worker_queue_query_window       = "5m"

# ---------- Worker placement: never co-locate with web/stateful nodes ----------
# The web task is the single ingress choke point. Workers must not share a node
# with web/web-background or the stateful MongoDB/Redis/Rserve nodes. The base
# profile already targets workers to meta.node_role = "worker" via
# worker_constraints; keep that and additionally pin the web node(s) by ID so a
# mislabeled node cannot receive workers:
#
#   worker_excluded_node_ids = ["<web-node-id>", "<db-node-id>", "<redis-node-id>"]
#
# Find node IDs with: nomad node status -verbose | grep -A2 '<node>'

# ---------- Thundering-herd infrastructure ----------
# Traefik reads Consul Catalog for the web route. On 1,000+ worker fleets each
# worker's Nomad template engine makes concurrent health API requests through
# the local Consul agent; the default per-client connection limit (100) is
# exceeded → HTTP 429 → Traefik cannot fetch the catalog → route dropped.
# Point Traefik at the Consul *server* (isolated connection pool) and raise the
# per-client limit on every agent to ceil(workers_per_node * 4) * 2.
#
#   traefik_consul_catalog_address = "192.168.100.87:8500"   # Consul server (site-local)
#   consul_http_max_conns_per_client = 1500                  # applied by infra-setup
