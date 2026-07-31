# Next Session Prompt

Read [`docs/openstack-remaining-issues-plan.md`](docs/openstack-remaining-issues-plan.md)
first and continue from there.

## Current Baseline

- Keep all scaling decisions within the **9,600 vCPU practical ceiling**.
- `openstudio-db`, `openstudio-redis`, `openstudio-rserve`, and `openstudio-worker`
  are healthy in Consul.
- `openstudio-web` is still not passing health.
- `web-background` is running in the latest deployment.
- The remaining issue is the web task group / deployment stability, not core services.
- The OpenStack var-file already reflects dense worker packing and autoscaling.

## What to do next

1. Inspect the latest `openstudio-server-web` status, evals, and allocs.
2. Confirm the `wait-for-deps` logic from the web alloc node.
3. Purge stale web state if needed, then redeploy fresh.
4. Verify `openstudio-web` registers in Consul and passes health.
5. Only then consider any additional scale-out work.

## Constraints

- Preserve `web_count = 1`.
- Keep worker scale limits bounded by the 9,600 vCPU practical limit.
- Do not widen worker capacity unless the deployment is stable and headroom still works.
