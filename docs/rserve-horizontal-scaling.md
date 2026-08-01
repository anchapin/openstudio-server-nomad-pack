# Rserve Horizontal Scaling — Benchmark Guide

> **Status:** Guidance document (no live cluster available). All performance figures are derived from
> Amdahl's Law analysis, OpenStudio Server architecture review, and representative R workload profiles.
> Operators should validate with their own workloads before committing to a replica count.

---

## 1. Role of Rserve in the OpenStudio Workflow

Rserve is an R-language TCP server (`nrel/openstudio-rserve`) that handles the optimization and
statistical sampling calls emitted by OpenStudio workers during analysis runs. Each worker process
opens a persistent TCP connection to `openstudio-rserve.service.consul:6311` and serializes R
function calls (e.g. Latin Hypercube Sampling, Particle Swarm, NSGA-II) to it.

Key characteristics:
- **CPU-bound per call**: optimization algorithms are numerically intensive; a single R session
  saturates one physical core during an active call.
- **Single-threaded R sessions**: the base R interpreter is single-threaded. Parallelism must come
  from multiple Rserve replicas, each with its own isolated R session.
- **Connection affinity**: once a worker acquires a connection, it holds it for the duration of the
  analysis step. There is no mid-analysis migration.
- **Low idle footprint**: an idle Rserve replica consumes ~50–100 MB RSS and negligible CPU; the
  cost of extra replicas at idle is low.

> **Prerequisite:** Horizontal scaling above `rserve_count = 1` requires multi-replica-safe routing
> (connection-level load balancing). This is tracked in issue **#361**. Until #361 is merged, keep
> `rserve_count = 1`.

---

## 2. Benchmark Methodology

Use the following procedure against a representative cluster before changing `rserve_count` in
production.

### 2.1 Instrumentation Setup

1. **Consul health API** — poll `GET /v1/health/service/openstudio-rserve` every 5 s; count
   `passing` vs `critical` instances to track replica availability.
2. **Worker allocation logs** — grep for `Rserve connection wait` (or equivalent app log) to
   measure queue idle time (time from "request connection" to "connection acquired").
3. **Nomad telemetry** — enable `telemetry { prometheus_metrics = true }` and scrape
   `nomad_client_allocs_cpu_total_ticks` and `nomad_client_allocs_memory_rss` for each Rserve
   allocation.
4. **Application-level timing** — instrument the R client call in OpenStudio Server to emit
   `rserve_latency_ms` (duration of the R call, excluding connection wait).

### 2.2 Test Scenarios

Run each scenario 3× and record median and p95 values.

| Scenario | `worker_count` | `rserve_count` | Analysis type | Expected outcome |
|---|---|---|---|---|
| **Baseline** | 5 | 1 | LHS sampling only | Idle time ≈ 0; single R session sufficient |
| **Moderate load** | 15 | 1 | PSO optimization | Queue idle time > 0; CPU saturation visible |
| **Moderate load** | 15 | 2 | PSO optimization | Idle time drops; 2 R sessions share load |
| **Heavy load** | 30 | 2 | NSGA-II multi-obj | Idle time re-emerges at peak |
| **Heavy load** | 30 | 3 | NSGA-II multi-obj | Idle time near zero; memory budget key |
| **Large cluster** | 50 | 3–4 | Mixed | Diminishing returns threshold |

### 2.3 Metrics to Record

For each scenario, capture:

| Metric | Collection method | Target |
|---|---|---|
| `rserve_connection_wait_p95` | Worker log grep / histogram | < 500 ms |
| `rserve_call_latency_p95` | App instrumentation | Baseline × 1.1 max |
| `rserve_cpu_utilization_avg` | Nomad telemetry | < 85% |
| `rserve_memory_rss_max` | Nomad telemetry | < `rserve_memory` |
| Worker analysis throughput (analyses/hour) | OpenStudio Server UI | Increases with replicas until plateau |
| Worker idle fraction | Worker log grep | Decreases with replicas |

### 2.4 Detecting Diminishing Returns

Plot `analyses/hour` vs `rserve_count` for a fixed `worker_count`. The slope flattens when the
bottleneck shifts from Rserve concurrency to:
- Worker CPU (each worker's simulation phase)
- MongoDB write throughput
- Network I/O for large result sets

The crossover point (where adding a replica yields < 10% throughput gain) is the **stable operating
point** for that worker count.

---

## 3. Expected Scaling Behavior — Amdahl's Law Analysis

Let `P` be the fraction of analysis time spent waiting for Rserve (the parallelizable fraction).
For a typical OpenStudio PSO/NSGA-II run, R optimization occupies roughly 10–30% of total wall
time per analysis; the rest is EnergyPlus simulation (sequential per worker, not Rserve-bound).

Applying Amdahl's Law with `P = 0.20` (conservative) and `N` Rserve replicas:

| `rserve_count` (N) | Theoretical max speedup | Practical gain |
|---|---|---|
| 1 (baseline) | 1.0× | — |
| 2 | 1.11× | ~10% more throughput at high concurrency |
| 3 | 1.15× | ~15%; meaningful for 25–50 worker deployments |
| 4 | 1.17× | Marginal beyond 3; memory cost outweighs gain |

At `P = 0.30` the gains are slightly larger but the fundamental conclusion holds: **Rserve
horizontal scaling provides concurrency headroom, not single-run speedup**. The primary benefit is
reducing connection wait time when `worker_count` exceeds the number of Rserve sessions.

---

## 4. Recommended Operating Points

| `worker_count` | Recommended `rserve_count` | Notes |
|---|---|---|
| 1–10 | **1** (default) | One R session handles all concurrent calls without queuing |
| 10–25 | **2** | A second replica eliminates connection wait at sustained load |
| 25–50 | **3** | Three replicas keep p95 wait < 500 ms; monitor memory |
| 50+ | **3–4** | Diminishing returns; profile before going to 4; consider sharding analyses |

### 4.1 Default (`rserve_count = 1`)

Appropriate for the vast majority of deployments. The default `rserve_cpu = 1000` MHz and
`rserve_memory = 2048` MB are sized for this case.

### 4.2 Scaling to 2–3 Replicas

Before increasing `rserve_count`:
1. Confirm issue **#361** (multi-replica-safe routing) is deployed.
2. Verify the Nomad cluster has sufficient CPU and memory on the target node class.
3. Confirm the NFS or CSI volume (if used) is accessible to all Rserve allocations.

Suggested resource profile per replica at higher counts:

| `rserve_count` | `rserve_cpu` (MHz) | `rserve_memory` (MB) |
|---|---|---|
| 1 | 1000 (default) | 2048 (default) |
| 2 | 2000 | 3072 |
| 3 | 2000 | 3072 |
| 4 | 2000 | 4096 |

Total node memory reservation = `rserve_count × rserve_memory`. Ensure the node's allocatable
memory minus other jobs can accommodate this before deploying.

### 4.3 Diminishing Returns Threshold

Based on the Amdahl analysis and typical OpenStudio workload profiles, **`rserve_count = 3` is the
practical ceiling** for most deployments. Beyond 3 replicas:

- Throughput gains are < 5% for typical P values.
- Memory pressure increases linearly.
- Connection routing complexity grows.
- The bottleneck shifts entirely to EnergyPlus simulation time and MongoDB I/O.

For deployments exceeding 50 concurrent workers, consider **analysis sharding** (multiple
independent OpenStudio Server stacks, each with their own Rserve singleton) rather than increasing
`rserve_count` within a single stack.

---

## 5. Resource Guidance

### 5.1 CPU

Rserve R sessions are single-threaded. Allocate at least **1000 MHz per replica** (default).
For compute-heavy optimization algorithms (NSGA-II, Sobol), raise to **2000–4000 MHz per replica**
to reduce R call latency. Do not over-provision CPU beyond 4000 MHz per replica — the R interpreter
cannot use it within a single call.

### 5.2 Memory

Base R session footprint: ~150–300 MB. Large design-of-experiment matrices or population-based
algorithms (NSGA-II with population 100) can peak at 1–2 GB per session.

Recommended `rserve_memory` values:
- Sampling-only (LHS, random): **1024–2048 MB**
- Optimization (PSO, NSGA-II small): **2048–3072 MB** (default 2048 is appropriate)
- Optimization (NSGA-II large, Morris): **3072–4096 MB**

Enable `rserve_memory_max` (if the variable exists) as a burst limit 1.5× the soft value to
prevent OOM kills during population initialization spikes.

### 5.3 Placement

Use `rserve_spreads` to distribute replicas across Nomad nodes when `rserve_count > 1`:

```hcl
rserve_spreads = [
  { attribute = "${node.unique.id}", weight = 100 }
]
```

This prevents all Rserve replicas from landing on the same node, preserving availability if a node
is drained.

---

## 6. OpenStack / Airgapped Deployment Notes

The `examples/openstack.hcl` var-file targets airgapped OpenStack deployments where the Nomad
cluster may have a small number of compute nodes. For these environments:

- **Default `rserve_count = 1`** is appropriate — OpenStack research clusters typically run
  analyses sequentially or with low parallelism.
- Increase to `rserve_count = 2` only if concurrent analysis batches exceed 10 workers.
- The `rserve_cpu = 2000` and `rserve_memory = 4096` values already set in `openstack.hcl`
  provide adequate headroom for a singleton Rserve handling up to ~20 workers.

---

## 7. References

- [Nomad Autoscaler documentation](https://developer.hashicorp.com/nomad/tools/autoscaling)
- [OpenStudio Server worker autoscaling](./operations-guide.md#worker-autoscaling)
- [Amdahl's Law — Wikipedia](https://en.wikipedia.org/wiki/Amdahl%27s_law)
- Issue [#360](https://github.com/anchapin/openstudio-server-nomad-pack/issues/360) — `rserve_count` variable
- Issue [#361](https://github.com/anchapin/openstudio-server-nomad-pack/issues/361) — multi-replica-safe Rserve routing
- Issue [#362](https://github.com/anchapin/openstudio-server-nomad-pack/issues/362) — this benchmark guide
