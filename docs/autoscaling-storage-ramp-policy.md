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

Scale up in steps of **≤ 5 workers** per cooldown window, and use a **longer scale-down
cooldown** to avoid thrashing when the queue briefly empties between batches.

### Pack Variables

| Variable | Purpose | Conservative | Aggressive |
|---|---|---|---|
| `worker_autoscaling_scale_up_cooldown` | Gap between scale-up events | `15m` | `5m` |
| `worker_autoscaling_scale_down_cooldown` | Gap between scale-down events | `30m` | `10m` |
| `worker_autoscaling_evaluation_interval` | How often policies are evaluated | `60s` | `30s` |
| `worker_autoscaling_min` | Minimum worker count (warm floor) | `2` | `1` |
| `worker_autoscaling_max` | Hard cap on worker count | `10` | `50` |

> **Note:** `worker_autoscaling_scale_up_cooldown` replaces the legacy `autoscaler_cooldown`
> variable for the worker scaling policy. The `autoscaler_cooldown` variable is still read
> by other check strategies; set `worker_autoscaling_scale_up_cooldown` specifically for
> NFS-safe worker ramp control.

### Conservative Profile (NFS / Shared Storage)

```hcl
worker_autoscaling_enabled              = true
worker_autoscaling_min                  = 2
worker_autoscaling_max                  = 10
worker_autoscaling_scale_up_cooldown    = "15m"
worker_autoscaling_scale_down_cooldown  = "30m"
worker_autoscaling_evaluation_interval  = "60s"
worker_cpu_target_utilization           = 60
```

### Aggressive Profile (Local or High-Throughput Storage)

```hcl
worker_autoscaling_enabled              = true
worker_autoscaling_min                  = 1
worker_autoscaling_max                  = 50
worker_autoscaling_scale_up_cooldown    = "5m"
worker_autoscaling_scale_down_cooldown  = "10m"
worker_autoscaling_evaluation_interval  = "30s"
worker_cpu_target_utilization           = 50
```

---

## iowait Threshold Gates

Before raising `worker_autoscaling_max` or shortening `worker_autoscaling_scale_up_cooldown`,
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
| 40–60% | **Pause scale-up.** Set `worker_autoscaling_max = <current_count>` to hold |
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
| Requeued depth | `worker_queue_requeued_target` | `2–5` (workers per requeued job) |
| Total simulations depth | `worker_queue_simulations_target` | `5–10` (workers per simulation in queue) |

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
nomad-pack run . \
  -var "worker_autoscaling_max=<current_running_count>" \
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
  nomad-pack run . \
    -var "worker_autoscaling_min=${count}" \
    -var "worker_autoscaling_max=${count}" \
    --name <job_name>
  sleep 300
done
```

### Step 4 — Re-enable Autoscaling with Conservative Settings

```bash
nomad-pack run . \
  -var "worker_autoscaling_enabled=true" \
  -var "worker_autoscaling_min=2" \
  -var "worker_autoscaling_max=10" \
  -var "worker_autoscaling_scale_up_cooldown=15m" \
  -var "worker_autoscaling_scale_down_cooldown=30m" \
  --name <job_name>
```

### Abort Criteria

Stop all autoscaling and run a fixed worker count if any of the following occur:

- iowait remains above 60% for more than 10 minutes after holding the worker count
- More than 3 simulations fail with NFS-related errors (ESTALE, ETIMEDOUT) in 15 minutes
- MongoDB or Redis health checks fail due to disk I/O starvation

```bash
# Disable autoscaling entirely and fix worker count:
nomad-pack run . \
  -var "worker_autoscaling_enabled=false" \
  -var "worker_count=<safe_count>" \
  --name <job_name>
```

---

## Related Variables

See [`docs/variables.md`](variables.md) for full descriptions of all autoscaling variables:

- `worker_autoscaling_enabled`
- `worker_autoscaling_min` / `worker_autoscaling_max`
- `worker_autoscaling_scale_up_cooldown` *(new)*
- `worker_autoscaling_scale_down_cooldown` *(new)*
- `worker_autoscaling_evaluation_interval` *(new)*
- `worker_autoscaling_cpu_enabled` / `worker_cpu_target_utilization`
- `worker_autoscaling_queue_enabled`
- `worker_queue_requeued_target` / `worker_queue_simulations_target`
- `autoscaler_cooldown` *(legacy global cooldown)*
- `nomad_autoscaler_enabled`
