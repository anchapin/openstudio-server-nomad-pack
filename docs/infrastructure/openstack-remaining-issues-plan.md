# OpenStack Remaining Issues Plan

## Goal

Finish stabilizing the OpenStudio Server deployment on OpenStack without exceeding the
**9,600 vCPU practical ceiling**. The current priority is to resolve the remaining web
deployment issue and confirm the stack is stable before any additional scale-out.

## Current State

- Nomad cluster is up and responsive.
- `openstudio-db`, `openstudio-redis`, `openstudio-rserve`, and `openstudio-worker` are
  healthy in Consul.
- `openstudio-web` is still not passing health.
- `web-background` is running in the latest web deployment.
- A stale history of failed web allocs exists from earlier bad retries / delayed
  reschedule behavior.
- The OpenStack var-file has already been updated for dense packing and worker autoscaling.

## Suspected Remaining Issues

1. The `web` task group has a history of failed allocs and delayed reschedules.
2. `wait-for-deps` in web-related allocations has repeatedly been the gating task.
3. The current deployment may still be affected by stale alloc history rather than a
   fresh placement attempt.

## Recovery Plan

### 1. Confirm the exact current blocker

- Inspect `nomad job status openstudio-server-web`.
- Inspect the latest `web` and `web-background` allocations.
- Inspect the latest evals, especially any `alloc-failure` or delayed reschedule eval.
- Confirm whether the latest `web-background` alloc is healthy or just running.

### 2. Verify dependency health from the node running the web alloc

- From the alloc node, curl the Consul health endpoints for:
  - `openstudio-db`
  - `openstudio-redis`
  - `openstudio-rserve`
- Confirm the exact `wait-for-deps` shell command exits successfully outside Nomad.
- If the command succeeds manually but not in Nomad, focus on alloc lifecycle / reschedule
  state.

### 3. Eliminate stale deploy state

- Purge the `openstudio-server-web` job cleanly.
- Confirm no `web` allocs remain in running or pending state.
- Redeploy from scratch with the current `examples/openstack.hcl`.

### 4. Verify web health, not just task start

- Confirm `web-background` passes its prestart and starts the main container.
- Confirm `web` task starts and registers `openstudio-web` in Consul.
- Check `openstudio-web` passes its HTTP health check.

### 5. If `web` still does not place

- Inspect the latest failed `web` alloc.
- Check for:
  - memory pressure
  - port conflicts
  - node placement constraints
  - delayed reschedule / backoff behavior
  - bad health checks
- Only adjust configuration if the failure cause is persistent and reproducible.

### 6. Keep the dense-pack settings bounded

- Preserve the practical cluster ceiling of 9,600 vCPU.
- Keep worker density within the current dense-pack assumptions.
- Do not raise worker scale limits without re-checking total headroom for system overhead.

## Success Criteria

- `openstudio-db`, `openstudio-redis`, `openstudio-rserve`, `openstudio-worker`, and
  `openstudio-web` are all passing in Consul.
- `nomad job status openstudio-server-web` shows both `web` and `web-background` healthy.
- No delayed reschedule or stale alloc-failure eval is blocking the next deployment.
- The deployment is stable long enough to proceed with any further scaling.

