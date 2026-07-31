# Next Session Prompt

All core services are now **fully healthy** in Consul. The scale-out
infrastructure work from prior sessions is complete. See commit history for
detailed change log.

## Current Baseline

- 60 Nomad nodes ready (21 × azimuth.compute2-179d, ~39 × CM.Medium/CM.Tiny)
- All 6 OpenStudio services healthy in Consul:
  - `openstudio-db` (MongoDB on nomad-client-114, static port 27017)
  - `openstudio-redis` (Redis on nomad-client-114, static port 6379)
  - `openstudio-rserve` (pinned to nomad-client-59)
  - `openstudio-web` (nomad-client-120)
  - `openstudio-web-background` (nomad-client-61)
  - `openstudio-worker` (3 running, autoscaler active)
- Docker hostname discovery fixed: `/local/patch-hosts.sh` (Consul template)
  maps `db` → MongoDB IP and `queue` → Redis IP in startup scripts.
- Web, db, and redis are constrained to `meta.disk_type = local-large`
  (179d nodes) to avoid disk-full failures with large Docker images.

## Known remaining issues

1. **infra-setup not re-run on 179d nodes**: The Docker data-root, NFS dir,
   and Docker volumes plugin setup from infra-setup.nomad has NOT been applied
   to nomad-client-112 through 132. Currently Docker uses its default data-root
   on these nodes. To fix: re-run infra-setup after confirming the new
   consul.hcl fix (127.0.0.1:8500) is in the template.

2. **Old nodes may need Consul cleanup**: The batch Consul config fix was applied
   to all old nodes (1-111) but some 179d nodes (112-132) may still have stale
   configs. Run `scripts/fix-consul-all-nodes.sh` if service registration issues
   recur.

3. **Worker autoscaling**: Check that the autoscaler is scaling workers up to
   meet simulation demand. Worker allocs should increase with queue depth.

4. **NFS mount on 179d nodes**: Verify `/nfs/opensstudio/batch/openstudio`
   is accessible from all worker nodes. Workers need NFS for simulation I/O.

## Bootstrap script for new 179d nodes

When adding new azimuth.compute2-179d nodes, run `scripts/bootstrap-179d-node.sh`
to provision Docker, Nomad, Consul, CNI plugins, and all required configs.

## Constraints

- Preserve `web_count = 1`
- Keep vCPU usage within the 9,600 vCPU practical ceiling
- Static ports 27017 (MongoDB) and 6379 (Redis) must remain available on their
  host nodes — do not run other jobs needing these ports on nodes with db/redis
