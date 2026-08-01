# OpenStack Staged Production Rollout Runbook

This runbook describes the staged rollout procedure for deploying OpenStudio Server on
OpenStack-hosted Nomad clusters, including gate criteria, abort/rollback procedures, and
evidence collection checklists. Finalized recommended defaults are documented at the end
and implemented in `examples/openstack-production.hcl`.

---

## Overview

The rollout proceeds in four worker-ramp stages to detect resource exhaustion, latency
regressions, and queue backlogs before reaching full scale. Each stage must pass all gate
criteria before advancing.

| Stage | Worker Count | Traffic Level | Soak Time |
|---|---|---|---|
| 1 — Canary | 2 workers | 10 % of target queue depth | 30 min |
| 2 — Ramp-25 | 5 workers | 25 % of target queue depth | 30 min |
| 3 — Ramp-50 | 10 workers | 50 % of target queue depth | 1 hour |
| 4 — Full | 20 workers (target) | 100 % of target queue depth | 2 hours |

---

## Prerequisites

Before starting the rollout:

- [ ] Nomad cluster healthy: all client nodes `ready`, no `lost` allocations
- [ ] Consul healthy: all service checks green for `openstudio-db`, `openstudio-redis`,
      `openstudio-rserve`, `openstudio-web`
- [ ] Prometheus scraping queue metrics (required for queue-depth autoscaling)
- [ ] Nomad Autoscaler daemon running (if `worker_autoscaling_enabled = true`)
- [ ] NFS host volume provisioned and mounted on all compute nodes
- [ ] MongoDB and Redis volumes provisioned with correct UID/GID (`999:999`)
- [ ] Baseline metrics captured (see §Evidence Collection)
- [ ] Rollback var-file ready (prior deployment's var-file saved)
- [ ] On-call engineer confirmed available for the rollout window

---

## Gate Criteria

All of the following must hold continuously throughout each stage's soak period for the
stage to pass. Check every 5 minutes.

### Latency

| Metric | Pass threshold | Abort threshold |
|---|---|---|
| Web p50 response time | ≤ 500 ms | > 2 000 ms sustained > 5 min |
| Web p95 response time | ≤ 2 000 ms | > 5 000 ms sustained > 5 min |
| Analysis submission latency (POST `/analyses`) | ≤ 3 s | > 10 s sustained > 5 min |
| Artifact retrieval latency (GET `/analyses/:id/download`) | ≤ 5 s | > 30 s sustained > 5 min |

### iowait %

Measured on each Nomad compute node hosting worker allocations.

| Metric | Pass threshold | Abort threshold |
|---|---|---|
| CPU iowait % | ≤ 20 % | > 40 % sustained > 10 min |
| Disk utilization % | ≤ 80 % | > 95 % |

### Queue Lag

| Metric | Pass threshold | Abort threshold |
|---|---|---|
| `resque:queue:analyses` depth | ≤ 2 × active worker count | > 5 × active worker count sustained > 10 min |
| `resque:queue:background` depth | ≤ 50 | > 500 sustained > 10 min |
| Queue drain rate (jobs/min) | ≥ 90 % of prior-stage rate | < 50 % of prior-stage rate sustained > 10 min |

### Failure Rate

| Metric | Pass threshold | Abort threshold |
|---|---|---|
| Analysis failure rate | ≤ 2 % | > 5 % in any 15-min window |
| Worker OOM kill rate | 0 | Any OOM kill |
| Nomad allocation restart rate | ≤ 1 restart per worker per hour | > 3 restarts per worker per hour |
| HTTP 5xx error rate | ≤ 0.5 % | > 2 % sustained > 5 min |

---

## Stage Procedure

### Stage 1 — Canary (2 workers)

```bash
# Deploy with Stage 1 settings
nomad-pack run . \
  --name openstudio-server \
  -var-file examples/openstack-production.hcl \
  -var "worker_count=2" \
  -var "worker_autoscaling_enabled=false"

# Verify all allocations healthy
nomad job status openstudio-server-worker
consul catalog services | grep openstudio

# Submit 5 test analyses and verify completion
# (use your organisation's test analysis fixtures)

# Monitor for 30 min — capture metrics per Evidence Collection checklist
```

Advance to Stage 2 only if all gate criteria pass.

### Stage 2 — Ramp-25 (5 workers)

```bash
nomad-pack run . \
  --name openstudio-server \
  -var-file examples/openstack-production.hcl \
  -var "worker_count=5" \
  -var "worker_autoscaling_enabled=false"

# Verify scale-out completed
nomad job status openstudio-server-worker | grep running

# Increase queue load to 25 % of target
# Monitor for 30 min
```

### Stage 3 — Ramp-50 (10 workers)

```bash
nomad-pack run . \
  --name openstudio-server \
  -var-file examples/openstack-production.hcl \
  -var "worker_count=10" \
  -var "worker_autoscaling_enabled=false"

# Increase queue load to 50 % of target
# Monitor for 1 hour
```

### Stage 4 — Full Production (autoscaling enabled)

```bash
# Enable autoscaling — autoscaler manages count between min/max replicas
nomad-pack run . \
  --name openstudio-server \
  -var-file examples/openstack-production.hcl

# Ramp queue to 100 % of target load
# Monitor for 2 hours
```

Verify analysis correctness at each stage:
```bash
# For each completed analysis, confirm:
# 1. Status is "complete" (not "failed" or "started")
# 2. Results ZIP is downloadable and non-empty
# 3. R² / objective metrics match reference runs within tolerance
curl -s http://<web-host>:<port>/analyses/<id>.json | jq '.analysis.status'
curl -o /dev/null -w "%{http_code} %{size_download}\n" \
  http://<web-host>:<port>/analyses/<id>/download.zip
```

---

## Abort and Rollback Procedure

### When to abort

Trigger an immediate abort if **any** abort threshold (see §Gate Criteria) is breached,
or if any of the following occur:
- Worker allocation count falls below `worker_min_replicas` for > 5 min
- MongoDB or Redis health check fails in Consul
- Disk on any NFS or data node exceeds 95 % utilisation
- Any OOM kill on a worker allocation

### Rollback steps

```bash
# 1. Scale workers to zero immediately to halt queue consumption
nomad job scale openstudio-server-worker 0

# 2. Redeploy prior var-file (saved before rollout)
nomad-pack run . \
  --name openstudio-server \
  -var-file <path-to-prior-var-file>

# 3. Verify all services return to healthy
consul catalog services | grep openstudio
nomad job status openstudio-server-web
nomad job status openstudio-server-worker

# 4. Confirm queue drain rate returns to baseline
redis-cli -h <redis-host> llen resque:queue:analyses

# 5. Capture post-rollback evidence (see §Evidence Collection)

# 6. File incident report and do not re-attempt rollout until root cause resolved
```

---

## Evidence Collection Checklist

Capture the following at the **start of soak**, **midpoint**, and **end of soak** for each stage.

### Nomad / Infrastructure

- [ ] `nomad job status openstudio-server-worker` — allocation count, status, restart count
- [ ] `nomad node status` — node health for all compute nodes
- [ ] CPU utilisation per Nomad client: `nomad node status -verbose <node-id>`
- [ ] Memory utilisation per allocation: Nomad UI → Worker job → Allocations
- [ ] iowait % per node: `iostat -x 5 3` or equivalent Prometheus `node_cpu_seconds_total{mode="iowait"}`

### Consul / Service Health

- [ ] `consul catalog services` — all expected services present
- [ ] `consul health service openstudio-web` — all checks passing
- [ ] `consul health service openstudio-db` — all checks passing

### Queue Metrics (Redis)

```bash
redis-cli -h <redis-host> llen resque:queue:analyses
redis-cli -h <redis-host> llen resque:queue:background
redis-cli -h <redis-host> get resque:stat:processed
redis-cli -h <redis-host> get resque:stat:failed
```

### Web Metrics

- [ ] HTTP response time p50 / p95 (Prometheus `http_request_duration_seconds`)
- [ ] HTTP 5xx error rate (Prometheus or Nomad log grep)
- [ ] Analysis submission success rate

### Analysis Correctness

- [ ] Submit reference analysis set, compare results to known-good baseline
- [ ] Download results ZIP from each completed analysis; verify non-empty and parseable
- [ ] Record any analyses that entered `failed` or stayed in `started` beyond expected runtime

### Post-Stage Snapshot

```bash
# Save Nomad job plan diff to confirm no unintended changes before advancing
nomad-pack plan . --name openstudio-server \
  -var-file examples/openstack-production.hcl \
  > evidence/stage-<N>-plan-output.txt

# Save Redis queue depth snapshot
redis-cli -h <redis-host> info stats >> evidence/stage-<N>-redis-info.txt
```

---

## Final Recommended OpenStack Defaults

The following values are the result of staged rollout tuning and represent the recommended
baseline for an OpenStack-hosted Nomad cluster with typical VM flavours (8 vCPU / 16 GB RAM
compute nodes). They are committed in `examples/openstack-production.hcl`.

| Variable | Value | Rationale |
|---|---|---|
| `worker_cpu` | `3000` MHz | Leaves headroom for OS + Docker on 8-vCPU nodes |
| `worker_memory` | `6144` MB | ~38 % of 16 GB; allows 2 allocations per 16 GB node |
| `worker_memory_max` | `8192` MB | Allows burst to full node memory before OOM |
| `worker_process_count` | `"2"` | 2 processes × 3 000 MHz ≈ 6 000 MHz per worker allocation |
| `worker_count` | `2` (seed) | Autoscaler owns actual count; seed prevents cold-start lag |
| `worker_min_replicas` | `2` | Maintains minimum throughput; absorbs small bursts |
| `worker_max_replicas` | `20` | Matches Stage 4 target; adjust based on cluster size |
| `worker_cpu_target_utilization` | `60` | Conservative: avoids iowait spike before autoscaler reacts |
| `worker_kill_timeout` | `5400` s (90 min) | Covers longest observed OpenStack analysis runtime |
| `autoscaler_cooldown` | `30m` | Prevents thrashing on OpenStack where VM spin-up is slower |
| `db_cpu` | `2000` MHz | MongoDB query load observed during Stage 3 soak |
| `db_memory` | `4096` MB | Working set fits in RAM for typical project sizes |
| `web_cpu` | `1000` MHz | Sufficient for Passenger + request routing |
| `web_memory` | `2048` MB | Covers Passenger workers + upload buffer |

### Rollback Guidance

If production behaviour deviates from expected after full rollout:

1. **Latency spike only:** reduce `worker_cpu_target_utilization` from `60` to `50` to
   trigger earlier scale-out, then re-evaluate over 30 min.
2. **OOM kills:** increase `worker_memory_max` to `10240` MB or reduce
   `worker_process_count` to `"1"`, then redeploy.
3. **Queue never drains:** increase `worker_max_replicas` in increments of 5, re-checking
   iowait after each increment.
4. **Full rollback required:** see §Abort and Rollback Procedure above.
