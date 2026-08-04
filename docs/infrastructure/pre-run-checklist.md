# Pre-Run Checklist

Before starting any large simulation batch, work through this checklist top-to-bottom.
Each item corresponds to a failure mode observed during production incidents. Skipping
items when you are in a hurry is how multi-day stalls happen.

---

## 1. Disk headroom on all Nomad client nodes

> **Root cause:** Two nodes exhausted 242 GiB disks during a single run. ENOSPC caused
> silent alloc failures; no automatic ineligibility was triggered.

Check free disk on every eligible node:

```bash
# Quick overview from Nomad (shows reserved vs used):
nomad node status -json | jq -r '.[] | select(.Status == "ready") |
  "\(.Name) (\(.ID[:8])): disk_free=\(.NodeResources.Disk.DiskMB)MiB"'

# Or SSH directly:
df -h /var/lib/nomad /opt/nomad /tmp
```

**Pass criteria:** Every node has ≥ 20 GiB free disk. Nodes with < 20 GiB free must be
cleaned up before the run. See [storage.md — Disk Sizing](./storage.md#disk-sizing-for-large-simulation-runs)
for per-DP footprint estimates and recommended node sizes.

**Automated gate:** If `client.reserved.disk = 20480` is configured in `nomad-client.hcl`,
Nomad will stop scheduling new allocs on nodes below this threshold automatically.
See [operations-guide.md — Disk Reservation](./operations-guide.md) for configuration steps.

---

## 2. Image pre-pull complete on all eligible nodes

> **Root cause:** `system-hooks` pre-pull failed on most nodes. Workers started before
> images were cached, causing mass alloc failures with `pull access denied`.

```bash
# Check all system-hooks alloc sentinels are running:
./scripts/verify-prepull.sh

# If any node shows sentinel=stopped or sentinel=missing, investigate:
nomad job status openstudio-server-system-hooks
nomad alloc logs <hooks_alloc_id> pull-worker-image

# Optionally wait up to 10 minutes for all sentinels to become healthy:
./scripts/verify-prepull.sh --timeout 600
```

**Pass criteria:** `verify-prepull.sh` exits 0 with all nodes `sentinel=running`.

**Why the sentinel matters:** The `image-cache-ready` task holds the Docker image
reference so Docker GC never evicts the cached layers. If the sentinel exits, cached
layers may be GC'd between alloc restarts, causing the next wave of workers to pull
again — and fail if the registry is unavailable.

---

## 2a. Stateful services are pinned to web-role nodes

> **Root cause:** Missing `db_constraints` allowed MongoDB placement on worker nodes under
> high image churn, coupling stateful services to disk-starved workers.

```bash
nomad job inspect openstudio-server-db | grep -E 'meta.node_role|disk_type'
nomad job inspect openstudio-server-redis | grep -E 'meta.node_role|disk_type'
nomad job inspect openstudio-server-rserve | grep -E 'meta.node_role|disk_type'
```

**Pass criteria:** Each service job has role constraints equivalent to:
- `${meta.node_role} = web`
- `${meta.disk_type} = local-large`
- `${attr.driver.docker} = 1`

---

## 3. No stuck or pending deployments

> **Root cause:** An in-flight deployment blocked `nomad job scale`, requiring the
> manual API workaround.

```bash
# Check worker job deployment status:
nomad job deployments openstudio-server-worker | head -5
```

**Pass criteria:** Most-recent deployment is `successful` (not `running`, `pending`,
or `failed`). If a deployment is stuck, see
[operations-guide.md — Scaling Workers When a Deployment Is Stuck](./operations-guide.md).

**Also verify the image after any auto-revert:**
```bash
nomad job inspect openstudio-server-worker | grep -i image
```
Auto-revert restores the last stable version, which may have an old/wrong image.

---

## 4. Resque failed queue is clear (or understood)

> **Root cause:** ~1,847 `PruneDeadWorkerDirtyExit` entries required manual replay.

```bash
# Check failed queue depth:
nomad alloc exec -task redis <redis_alloc_id> redis-cli LLEN resque:failed </dev/null

# Inspect first few entries:
nomad alloc exec -task redis <redis_alloc_id> redis-cli LRANGE resque:failed 0 4 </dev/null
```

**Pass criteria:** `LLEN resque:failed` == 0, or the only entries are known
non-infra-recoverable failures (e.g., `batch_run.rb` app bugs on specific analysis IDs).

**If `PruneDeadWorkerDirtyExit` entries exist:** These are auto-replayed by the
queue-sweeper when `enable_queue_sweeper = true` and
`queue_sweeper_replay_dirty_exit = true`. Verify the queue-sweeper is enabled and has
run at least once since the entries appeared.

---

## 5. No stale "started" data points

> **Root cause:** ~74k DPs were stuck in `started` with no Redis entries after a
> previous run's workers were killed without cleanup.

```bash
# Via the OpenStudio Server web API:
curl -s http://<web-host>:<port>/status.json | python3 -m json.tool | grep started
```

**Pass criteria:** `data_points.started` == 0.

If stale started DPs exist from a prior run:
1. Check whether the stall-watchdog cleared them: `nomad job status openstudio-server-stall-watchdog`
2. Manually reset and re-enqueue if needed: `./scripts/requeue-stuck-datapoints.sh <dp_id_file>`

---

## 6. Workers are at the correct count

```bash
nomad job status openstudio-server-worker | grep -E "Count|Status"
```

**Pass criteria:**
- Workers are scaled to the intended starting count (e.g., 250 for a large run).
- All allocated workers show `running` (not `pending` or `failed`).
- No more than ~5% of desired workers are `pending` after 5 minutes (indicates
  scheduling issues such as resource exhaustion or image pre-pull failures).

**Recommended ramp:** Start at 100–250 workers. Confirm 90%+ healthy within 5 minutes
before scaling further.

---

## 7. Stable baseline version has correct image

> **Root cause:** The stable baseline (v40) still pointed to `openstudio-worker:local`,
> which was absent on most nodes. An auto-revert would have silently restored a broken state.

```bash
# Show version history and which version is the stable baseline:
nomad job history openstudio-server-worker

# Show image for a specific version:
nomad job history -version <N> openstudio-server-worker | grep image
```

**Pass criteria:** The `stable = true` version uses the same image as the current
desired deployment.

If the stable version is wrong, run the deployment to completion with the correct image
before starting a simulation run. Nomad marks a version stable only after
`min_healthy_time` passes with all allocs healthy.

---

## 8. Quick connectivity smoke check (optional but recommended for new clusters)

```bash
# Run the batch verification job to TCP-ping all services:
./scripts/run-batch-verification.sh

# Or with a custom job name:
nomad-pack render -var "enable_batch_verification=true" packs/openstudio-server | nomad job run -
nomad job status openstudio-server-batch-verify
```

**Pass criteria:** `batch_verification_summary total=N passed=N failed=0` in the job logs.

---

## 9. Ingress route smoke check (required for OpenStack)

> **Root cause:** Traefik returned 404 because the Consul Catalog endpoint was misconfigured
> (`http://127.0.0.1:8500` instead of `127.0.0.1:8500`), so no `openstudio-web` router loaded.

```bash
# Validates Traefik config guardrail + router presence + HTTP path:
./scripts/check-openstack-ingress.sh

# Equivalent Makefile wrapper:
make os-ingress-check
```

**Pass criteria:** script exits 0 and reports:
- `providers.consulCatalog.endpoint.address` is valid `host:port`
- router `openstudio-server@consulcatalog` is enabled
- local and external HTTP checks return 2xx/3xx

---

## 10. Prometheus ingress alert rules loaded (recommended for production)

Confirm that the `openstudio_ingress` alert group is loaded in Prometheus so continuous alerting is active for Traefik route and backend health.

```bash
curl -s http://<prometheus-host>:9090/api/v1/rules | \
  jq '.data.groups[] | select(.name=="openstudio_ingress") | .rules[].name'
```

**Pass criteria:** output includes `TraefikRouterMissing`, `TraefikIngressHighErrorRate`, and `TraefikBackendUnhealthy`.

If the rules are missing:

```bash
# Copy the rules file and reload Prometheus
scp monitoring/prometheus-alert-rules.yml ubuntu@<prometheus-node>:/etc/prometheus/rules/
curl -X POST http://<prometheus-host>:9090/-/reload
```

See `docs/infrastructure/operations-guide.md` § "Ingress Alerts — Loading / reloading alert rules" for full instructions.

---

## Summary checklist

| # | Check | Command | Pass criteria |
|---|-------|---------|---------------|
| 1 | Disk headroom | `df -h` or `nomad node status -json` | ≥ 20 GiB free on all nodes |
| 2a | Stateful service placement | `nomad job inspect <job>` | db/redis/rserve constrained to web-role nodes |
| 2 | Pre-pull complete | `./scripts/verify-prepull.sh` | Exit 0, all `sentinel=running` |
| 3 | No stuck deployment | `nomad job deployments openstudio-server-worker` | Latest = `successful` |
| 4 | Failed queue clear | `redis-cli LLEN resque:failed` | 0 (or only app-bug entries) |
| 5 | No stale started DPs | `/status.json` → `data_points.started` | 0 |
| 6 | Workers at correct count | `nomad job status openstudio-server-worker` | Count correct, all `running` |
| 7 | Stable baseline image correct | `nomad job history openstudio-server-worker` | Stable version = correct image |
| 8 | Connectivity smoke check | `./scripts/run-batch-verification.sh` | `failed=0` |
| 9 | Ingress route smoke check (OpenStack) | `./scripts/check-openstack-ingress.sh` | Exit 0 + router enabled + HTTP 2xx/3xx |
| 10 | Prometheus ingress alerts loaded | `curl .../api/v1/rules` (see above) | `TraefikRouterMissing` + 2 others present |
