# Post-Mortem: Worker Image-Cache Sentinel Failure — 2026-08-03 (Incident B)

**Status:** Resolved  
**Severity:** P1 — production simulation throughput at 1.3 % of target for ~28 minutes  
**Impact:** 6,500+ worker allocations failed immediately after scale-up; 32,000-DP batch ran at 83 concurrent workers instead of ~6,500

---

## Timeline (EDT)

| Time     | Event |
|----------|-------|
| ~18:44   | `fresh-redeploy-openstack.sh` launched with `openstack-production.hcl` + `openstack-site-local.hcl` for 32k-DP batch |
| ~18:50   | Autoscaler fires; scales workers 2 → 83 on first queue evaluation |
| ~18:50   | 288 / 324 worker allocations fail: `Failed to pull 'openstudio-worker:local': pull access denied` |
| ~18:52   | Autoscaler re-evaluates; stuck at 83 desired (deployment in `running` state) |
| ~19:09   | Investigation begins; root cause confirmed (sentinel missing) |
| ~19:09   | Manual system-hooks prewarm job deployed (temp fix) |
| ~19:15   | Worker job v3 deployed; autoscaler blocked by active rolling update (`max_parallel=1`) |
| ~19:21   | Emergency redeploy: v4 with `max_parallel=0, count=2000`; autoscaler fires → 10,000 desired |
| ~19:22   | 6,517 workers running; throughput restored |
| ~19:27   | Safe update stanza restored (`max_parallel=1`); temp prepull job **purged** |
| ~19:27   | Docker GC evicts `openstudio-worker:local` tag within ~3 min of sentinel exit |
| ~19:32   | All 8,118 worker allocs fail again; job shows `Status: pending` |
| ~19:35   | Permanent `openstudio-server-system-hooks` job deployed with `sleep` sentinel |
| ~19:41   | 6,520 workers running; incident closed |

---

## Root Cause

`fresh-redeploy-openstack.sh` deploys the main pack with `enable_image_prepull=false`
(line 1802 of the script) to avoid job-name collisions with the prewarm jobs. The
post-deploy reconciler then purges the prewarm job at Phase 3 completion. This leaves
**no `sleep` sentinel task running on any node**.

`worker_runtime_image = "openstudio-worker:local"` (set in `openstack-site-local.hcl`)
is a local Docker image alias, not a registry image. Docker's image GC treats unreferenced
aliases as evictable. Under load, Docker prunes the alias within **~3–10 minutes** of the
last container using it exiting.

All subsequent worker allocations fail immediately with `pull access denied` because there
is no registry at `openstudio-worker:local` — it is a local alias only.

### Why this recurred

This exact failure was documented in **Incident A** (same date, earlier in the day, 243,500-DP run,
commit `35e6078`). The post-mortem for Incident A added:

- `docs/infrastructure/pre-run-checklist.md` — item 2: "Pre-pull complete" gate
- `scripts/verify-prepull.sh` — sentinel health verification script

Both are **verification tools, not automated fixes**. The deploy script was not changed to
deploy the permanent sentinel. The checklist was not run before Incident B.

---

## Contributing Factors

| Factor | Description |
|--------|-------------|
| Pre-run checklist not followed | `verify-prepull.sh` exists but was not run before the batch. Item 2 would have caught the missing sentinel immediately after Phase 1. |
| `worker_queue_simulations_target = 6` | Produced `ceil(32000/6) = 5,334` desired workers, not reaching the `10,000` ceiling. Changed to `3` in commit `58c1b56`. |
| Autoscaler blocked by active deployment | With `max_parallel=1`, the rolling update of 44 workers was holding a deployment lock. Autoscaler will not re-evaluate during `running` deployments. Required emergency `max_parallel=0` redeploy to unblock. |
| Temp prepull job purged without sentinel replacement | Purging the temp prewarm job with `--purge` caused the same sentinel-exit → GC cycle as the script bug. |
| `worker_max_replicas = 10,000` > physical cluster capacity (~6,800) | 3,483 worker allocs queued permanently, adding continuous scheduler load with no benefit. |

---

## Fixes Applied (This Incident)

| Commit | Change |
|--------|--------|
| `58c1b56` | Lowered `worker_queue_simulations_target` from `6` to `3` in `openstack-production.hcl` |
| `94913d1` | Deploy permanent `openstudio-server-system-hooks` sentinel after prewarm purge in reconciler Phase 3 |

---

## Long-Term Corrective Actions

### LT-1: `verify-prepull.sh` gate in deploy script (implemented)

`fresh-redeploy-openstack.sh` now calls `scripts/verify-prepull.sh` as a blocking gate
after `run_system_hooks_phase` and before Phase 2. If any node is missing the sentinel,
the deploy aborts before any worker allocations are attempted.

### LT-2: Deploy sentinel in error-exit cleanup trap (implemented)

The `cleanup_background_jobs` EXIT trap now calls `deploy_permanent_sentinel_quietly`
before `stop_prepull_job_if_running`. If the main script exits with an error after Phase 1
(before the reconciler reaches Phase 3), the permanent sentinel is deployed so the image
alias is preserved.

### LT-3: Lower `worker_max_replicas` to physical cluster capacity (implemented)

Changed from `10,000` to `6,800` in `openstack-production.hcl` with derivation comment:

```hcl
# Physical ceiling: floor((node_ram_mb - 2048) / worker_memory) × compute_node_count
# floor((79872 - 2048) / 1250) = 62 allocs/node × 110 compute nodes = 6820
worker_max_replicas = 6800
```

This eliminates ~3,483 permanently-unplaceable queued allocs that were adding scheduler
load with no throughput benefit.

### LT-4: Emergency `max_parallel=0` procedure documented (implemented)

Added to `docs/infrastructure/operations-guide.md` §"Autoscaler blocked — force immediate
scale-up with `max_parallel=0`". Includes step-by-step procedure and warning to restore
`max_parallel=1` immediately after.

### LT-5: Prometheus alert rules (implemented)

Created `monitoring/prometheus-alert-rules.yml` with four alert rules:

| Alert | Threshold | Severity |
|-------|-----------|----------|
| `OpenStudioWorkerAllocHighFailureRate` | failed/(running+1) > 50 % for 2 min | critical |
| `OpenStudioWorkerCountBelowDesired` | running/(running+queued) < 80 % for 5 min | warning |
| `OpenStudioSystemHooksSentinelFailing` | any failed alloc in system-hooks for 1 min | critical |
| `OpenStudioQueueHighNoScaleUp` | queue > 5000 and worker count delta < 10 over 10 min | warning |

### LT-6: Reconciler status written to stable path (implemented)

The detached reconciler now copies its metadata file to
`/tmp/openstudio-reconciler-<job_name>.metadata` in addition to the tmpdir path. This
survives terminal closure. The deploy script output prints the stable path with a
`cat` hint.

### LT-7: `worker_queue_simulations_target` comment updated to show formula (implemented)

Replaced prose comment with formula derivation in `openstack-production.hcl`:

```hcl
# Formula: choose target ≤ ceil(expected_peak_queue / worker_max_replicas)
# At 32k queue and 6800 max: target ≤ ceil(32000/6800) = 5. Use 3 for headroom.
worker_queue_simulations_target = 3
```

---

## Lessons Learned

1. **Documentation is not automation.** A checklist and a verification script are better
   than nothing, but they rely on an operator remembering to run them under time pressure.
   The deploy script now enforces the verification automatically (LT-1).

2. **Purging prewarm jobs in cleanup paths requires a sentinel replacement first.**
   Any code path that calls `nomad job stop --purge` on a prewarm/sentinel job must
   deploy the permanent sentinel before the purge. This now applies to both the normal
   (reconciler Phase 3) and error-exit (cleanup trap) paths.

3. **The Nomad Autoscaler scaling lock is not obvious from the dashboard.** The job
   shows `Status: running` with a deployment in-flight, but there is no UI indicator that
   the autoscaler is blocked. The `nomad job deployments` output is the only way to detect
   this. Emergency procedure documented in the operations guide.

4. **`worker_max_replicas` should track physical cluster capacity**, not an aspirational
   ceiling. Allocs that can never place waste scheduler CPU and confuse capacity metrics.
   Re-derive the value any time nodes are added or removed or when `worker_memory` changes.

---

## Action Items

| ID | Action | Owner | Status |
|----|--------|-------|--------|
| LT-1 | verify-prepull gate in deploy script | infra | ✅ Done |
| LT-2 | Sentinel in cleanup trap | infra | ✅ Done |
| LT-3 | Lower `worker_max_replicas` to 6800 | infra | ✅ Done |
| LT-4 | Document emergency max_parallel=0 procedure | infra | ✅ Done |
| LT-5 | Prometheus alert rules | infra | ✅ Done |
| LT-6 | Stable reconciler status path | infra | ✅ Done |
| LT-7 | Fix simulations_target comment | infra | ✅ Done |
| LT-8 | This post-mortem | infra | ✅ Done |
| OP-1 | Load `monitoring/prometheus-alert-rules.yml` into production Prometheus | infra | ⬜ Pending |
| OP-2 | Consider eliminating `worker_runtime_image` alias pattern in favour of a pull-through registry cache at the Docker daemon level (`/etc/docker/daemon.json` mirror config) | infra | ⬜ Future |

---

## Related

- [Incident A post-mortem](../docs/) — same failure class, same date, earlier run (243,500-DP batch)
- `docs/infrastructure/pre-run-checklist.md` — operator gate before every large run
- `scripts/verify-prepull.sh` — sentinel health check
- `docs/infrastructure/operations-guide.md` §"Scaling Workers When a Deployment Is Stuck"
