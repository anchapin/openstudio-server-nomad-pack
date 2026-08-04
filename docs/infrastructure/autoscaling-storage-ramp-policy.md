# Storage-Aware Autoscaling Ramp Policy

This document describes how to configure and operate worker autoscaling safely when
OpenStudio Server uses shared NFS storage. It covers ramp guardrails, iowait threshold
gates, queue depth tuning, and emergency backoff procedures.

---

## Why Storage-Aware Ramping Matters

When `worker_autoscaling_enabled = true`, the Nomad Autoscaler can add many workers in
rapid succession during a job burst. Each new worker immediately opens its simulation
output files on the shared NFS volume. The resulting simultaneous I/O — model downloads,
output writes, and log flushes — can saturate the NFS server's I/O bandwidth. This is
called **storage shock**.

Symptoms of storage shock:
- `iowait` spikes above 40% on NFS client nodes
- Simulation run times increase (NFS calls block workers)
- Redis/MongoDB health checks time out due to disk I/O starvation
- The Nomad health check deadline fires and triggers a spurious scale-down

Controlled ramping prevents these events by limiting how many workers are added per
cooldown window.

---

## Recommended Ramp Policy

### Core Principle

Avoid startup cooldown traps and bound ramp velocity:
- Keep `worker_count` equal to `worker_min_replicas` so deployment does not trigger an
  immediate downscale that blocks later scale-up.
- Use queue targets that represent **queued jobs per worker** (for OpenStack defaults,
  `20`/`20`), then tune from observed queue drain and iowait.
- Increase `worker_max_replicas` in staged increments after soak evidence instead of
  starting with an unbounded ceiling.

### Pack Variables

| Variable | Purpose | Conservative | Aggressive |
|---|---|---|---|
| `worker_autoscaling_scale_up_cooldown` | Gap between scale-up events | `15m` | `5m` |
| `worker_autoscaling_scale_down_cooldown` | Gap between scale-down events | `30m` | `10m` |
| `worker_autoscaling_evaluation_interval` | How often policies are evaluated | `60s` | `30s` |
| `worker_min_replicas` | Minimum worker count (warm floor) | `2` | `1` |
| `worker_max_replicas` | Hard cap on worker count | `10` | `50` |
| `worker_queue_query_window` | PromQL smoothing window (`max_over_time`) | `2m` | `1m` |

> **Note:** Use `worker_autoscaling_scale_up_cooldown` and
> `worker_autoscaling_scale_down_cooldown` for worker ramp control.

### Conservative Profile (NFS / Shared Storage)

```hcl
worker_autoscaling_enabled              = true
worker_count                            = 2
worker_min_replicas                     = 2
worker_max_replicas                     = 10
worker_autoscaling_scale_up_cooldown    = "15m"
worker_autoscaling_scale_down_cooldown  = "30m"
worker_autoscaling_evaluation_interval  = "60s"
worker_queue_query_window               = "2m"
worker_cpu_target_utilization           = 60
```

### Aggressive Profile (Local or High-Throughput Storage)

```hcl
worker_autoscaling_enabled              = true
worker_count                            = 1
worker_min_replicas                     = 1
worker_max_replicas                     = 50
worker_autoscaling_scale_up_cooldown    = "5m"
worker_autoscaling_scale_down_cooldown  = "10m"
worker_autoscaling_evaluation_interval  = "30s"
worker_queue_query_window               = "1m"
worker_cpu_target_utilization           = 50
```

---

## iowait Threshold Gates

Before raising `worker_max_replicas` or shortening `worker_autoscaling_scale_up_cooldown`,
check the iowait percentage on the Nomad client nodes hosting workers.

### How to Check iowait

```bash
# On each Nomad client node:
iostat -c 5 3         # column "%iowait" — average over 3 samples of 5s
# Or via vmstat:
vmstat 5 3            # column "wa"
```

### Decision Matrix

| iowait | Action |
|---|---|
| < 20% | Safe to scale up; current ramp policy is healthy |
| 20–40% | Monitor; do not shorten cooldown further |
| 40–60% | **Pause scale-up.** Set `worker_max_replicas = <current_count>` to hold |
| > 60% | **Emergency backoff** (see below) |

### Prometheus Alert (Optional)

If Prometheus is deployed (`prometheus_enabled = true`), add an alert rule:

```yaml
- alert: NomadClientHighIOWait
  expr: avg(node_cpu_seconds_total{mode="iowait"}) by (instance) / avg(node_cpu_seconds_total) by (instance) > 0.40
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "NFS I/O saturation — pause worker scale-up"
```

---

## Queue Depth Targets and Cooldown Tuning

Queue-depth autoscaling (`worker_autoscaling_queue_enabled = true`) tracks two Prometheus
metrics:

| Check | Variable | Recommended Target |
|---|---|---|
| Requeued depth | `worker_queue_requeued_target` | `10–20` queued jobs per worker |
| Total simulations depth | `worker_queue_simulations_target` | `10–20` queued jobs per worker |

Queue checks use the Nomad autoscaler `pass-through` strategy. The template computes desired
workers directly in PromQL:

`desired = ceil(clamp_min(max_over_time(queue_depth[worker_queue_query_window]) / jobs_per_worker, 0))`

This avoids the exponential feedback loop that can occur when `target-value` is applied to a
raw queue-length metric.

### Cooldown Tuning Guidance

- **Scale-up cooldown too short** → multiple scale-up events fire before new workers are
  healthy → NFS I/O spike. Symptom: iowait rises within minutes of a burst.
- **Scale-down cooldown too short** → workers are terminated while still draining their
  last simulation → wasted work + lost run data. Symptom: incomplete results in MongoDB.
- **Evaluation interval too short** → high Nomad API polling load with no scaling benefit.
  Keep at `30s` or longer unless you have < 5 workers and sub-minute queue drain times.

Start with the conservative profile and tighten incrementally after observing two full
burst-and-drain cycles without iowait crossing 40%.

---

## Emergency Backoff Procedure

Use this procedure when iowait exceeds 60% or simulations are failing due to NFS timeouts.

### Step 1 — Hold the Current Worker Count

```bash
# Find the current deployed worker count:
nomad job status <job_name>-worker | grep -i "running\|desired"

# Set max = current running count to prevent further scale-up:
nomad-pack run packs/openstudio-server \
  -var "worker_max_replicas=<current_running_count>" \
  --name <job_name>
```

### Step 2 — Wait for iowait to Drop

```bash
# Watch iowait on NFS client nodes — wait until sustained below 20%:
watch -n 5 'iostat -c 1 1 | tail -2'
```

### Step 3 — Drain Workers Gradually (if still elevated)

```bash
# Scale workers down one at a time with a 5-minute gap:
for count in $(seq <current-1> -1 <target_floor>); do
  nomad-pack run packs/openstudio-server \
    -var "worker_min_replicas=${count}" \
    -var "worker_max_replicas=${count}" \
    --name <job_name>
  sleep 300
done
```

### Step 4 — Re-enable Autoscaling with Conservative Settings

```bash
nomad-pack run packs/openstudio-server \
  -var "worker_autoscaling_enabled=true" \
  -var "worker_count=2" \
  -var "worker_min_replicas=2" \
  -var "worker_max_replicas=10" \
  -var "worker_autoscaling_scale_up_cooldown=15m" \
  -var "worker_autoscaling_scale_down_cooldown=30m" \
  -var "worker_queue_query_window=2m" \
  --name <job_name>
```

### Abort Criteria

Stop all autoscaling and run a fixed worker count if any of the following occur:

- iowait remains above 60% for more than 10 minutes after holding the worker count
- More than 3 simulations fail with NFS-related errors (ESTALE, ETIMEDOUT) in 15 minutes
- MongoDB or Redis health checks fail due to disk I/O starvation

```bash
# Disable autoscaling entirely and fix worker count:
nomad-pack run packs/openstudio-server \
  -var "worker_autoscaling_enabled=false" \
  -var "worker_count=<safe_count>" \
  --name <job_name>
```

---

## Related Variables

See [`docs/variables.md`](variables.md) for full descriptions of all autoscaling variables:

- `worker_autoscaling_enabled`
- `worker_count`
- `worker_min_replicas` / `worker_max_replicas`
- `worker_autoscaling_scale_up_cooldown` *(new)*
- `worker_autoscaling_scale_down_cooldown` *(new)*
- `worker_autoscaling_evaluation_interval` *(new)*
- `worker_autoscaling_cpu_enabled` / `worker_cpu_target_utilization`
- `worker_autoscaling_queue_enabled`
- `worker_queue_query_window` *(new)*
- `worker_queue_requeued_target` / `worker_queue_simulations_target`
- `nomad_autoscaler_enabled`
