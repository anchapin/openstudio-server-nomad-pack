# OpenStack Nomad Stabilization Runbook

## Goal

Bring the OpenStack Nomad deployment to a clean, production-like state so analyses can be submitted reliably.

## Root cause: CSI hook failure (`csi_hook failed ... does not exist in volumes list`)

This is the most common DB/Redis failure mode after a cluster recovery or ephemeral-mode
temporary deployment.

**Why it happens:**

1. The pack's `db.nomad.tpl` / `redis.nomad.tpl` templates reference a CSI volume by name
   (`db_volume_source` / `redis_volume_source`).
2. Nomad's `csi_hook` pre-run hook looks up the volume in the **Nomad volume registry** and
   verifies that a node with the matching CSI plugin node component is available to attach it.
3. After cluster recovery or `nomad volume deregister` (run during ephemeral-mode fallback),
   the Nomad volume registration is deleted — but the Cinder/Manila backing volume still
   exists in OpenStack.  The job template still references the old name, so the next alloc
   fails immediately with: `pre-run hook "csi_hook" failed … volume id "openstudio-mongodb"
   does not exist in the volumes list`.
4. Even when the volume registration exists, if the Nomad scheduler places the alloc on a
   **different node** than the one where the CSI plugin node component is running, the hook
   fails for the same reason.

**The fix (automated, applied as of this PR):**

- `preflight-storage.sh --rebind-stale` detects stale registrations (wrong plugin, no
  topology, or 0 healthy nodes) and deregisters + re-registers them automatically.
- `preflight-storage.sh --emit-topology-vars` extracts the Nomad node UUID that owns each
  CSI volume and emits `db_csi_topology_node_id=<uuid>` and
  `redis_csi_topology_node_id=<uuid>` on stdout.
- `deploy-openstack.sh` captures these IDs and passes them as `--var` overrides to
  `nomad-pack run`.  The templates inject a hard `constraint { attribute =
  "${node.unique.id}" }` that pins the DB/Redis allocs to their CSI topology node.
- This flow is idempotent and runs on every `deploy-openstack.sh --deploy` invocation.

## Target state

- Nomad clients correctly split by role:
  - `worker` nodes on `azimuth.compute1-179d-250disk`
  - `web` / service nodes on `azimuth.web1-179d` or `azimuth.web2-179d`
- Consul registration uses the local agent on every active client
- Docker/Nomad client config is consistent on all active nodes
- MongoDB and Redis use persistent CSI storage, pinned to their topology node
- Web/worker share NFS-backed storage for analysis artifacts
- `web_count = 1`
- Pack redeployed from `examples/advanced/openstack.hcl`
- One smoke analysis completes successfully

## Recommended execution order

### 1. Normalize node roles

For each active node:

- worker pool:
  - `scripts/bootstrap-179d-node.sh --role worker`
- service nodes:
  - `scripts/bootstrap-179d-node.sh --role web`

This should be used for any newly added nodes and for any node that was missing role-specific config.

### 2. Fix Consul registration drift

Run:

```bash
./scripts/fix-consul-all-nodes.sh
```

This rewrites `consul { address = "127.0.0.1:8500" }` on active clients and restarts Nomad once per node.

### 3. Re-run infra setup once

Run the infra convergence job to ensure:

- Docker data-root points to local storage
- Nomad client config is consistent
- Docker host volumes are enabled

Use:

```bash
nomad-pack render -var "enable_infra_setup=true" packs/openstudio-server | nomad job run -
```

### 4. Confirm storage prerequisites

Use the OpenStack/Nomad storage profile:

- MongoDB: `db_storage_type = "csi"`
- Redis: `redis_storage_type = "csi"`
- DB/Redis CSI plugin IDs: set `DB_CSI_PLUGIN_ID` / `REDIS_CSI_PLUGIN_ID` (or shared `CSI_PLUGIN_ID`) to the web-role plugin ID (for example `hostpath-web-plugin0`) when running helper scripts
- Shared analysis data: `nfs_shared_volume_enabled = true`
- NFS volume type: `host_volume`
- NFS volume source: `openstudio-nfs`

If role-scoped hostpath plugins are not deployed yet, deploy them first:

```bash
NOMAD_ADDR=http://10.60.126.125:4646 \
./scripts/deploy-hostpath-csi-role-plugins.sh
```

#### 4a. Automated storage preflight (recommended — runs automatically via deploy-openstack.sh)

`preflight-storage.sh` is invoked automatically by `deploy-openstack.sh` with `--rebind-stale`
and `--emit-topology-vars`.  It performs the following checks and repairs:

| Check | Action |
|---|---|
| CSI plugin registered and healthy | Fails fast with actionable error |
| Volume present and plugin matches | Pass |
| Volume registered with wrong plugin | Deregisters and re-creates (stale rebind) |
| Volume registration has no topology segments | Deregisters and re-creates (stale rebind) |
| Volume present but 0 healthy nodes | Deregisters and re-creates (stale rebind) |
| Volume absent entirely | Creates (requires `--create-missing-csi` / `--rebind-stale`) |
| Host volume advertised by at least 1 eligible node | Pass |

After checks pass, `--emit-topology-vars` outputs the Nomad node UUID for each CSI volume.
`deploy-openstack.sh` captures these IDs and passes them as `db_csi_topology_node_id` /
`redis_csi_topology_node_id` pack variables, which inject a hard `constraint { attribute =
"${node.unique.id}" }` into the DB and Redis job templates.  This prevents the scheduler
from placing these allocs on nodes where the CSI volume cannot be attached — the root cause
of `"pre-run hook csi_hook failed ... does not exist in the volumes list"` errors.

To run the storage preflight manually (audit mode, read-only):

```bash
NOMAD_ADDR=http://localhost:4646 \
DB_CSI_PLUGIN_ID=hostpath-web-plugin0 \
./scripts/preflight-storage.sh --var-file examples/advanced/openstack.hcl
```

To auto-create missing and fix stale CSI volume registrations:

```bash
NOMAD_ADDR=http://localhost:4646 \
DB_CSI_PLUGIN_ID=hostpath-web-plugin0 \
./scripts/preflight-storage.sh \
  --var-file examples/advanced/openstack.hcl \
  --rebind-stale \
  --emit-topology-vars
```

#### 4b. Break-glass: manual volume deregister + re-register

Use this only when `--rebind-stale` cannot recover the volume (e.g., the CSI plugin itself
needs redeployment first).

```bash
# 1. Stop the affected job so Nomad releases the volume claim
nomad job stop -purge openstudio-server-db   # or openstudio-server-redis

# 2. Force-deregister the stale volume record
nomad volume deregister openstudio-mongodb   # or openstudio-redis

# 3. Verify CSI plugin is healthy
nomad plugin status -type csi

# 4. Re-create the volume registration with the correct plugin
DB_CSI_PLUGIN_ID=hostpath-web-plugin0 \
./scripts/preflight-storage.sh \
  --var-file examples/advanced/openstack.hcl \
  --rebind-stale

# 5. Identify topology node and re-deploy with the pin
TOPO_VARS=$(DB_CSI_PLUGIN_ID=hostpath-web-plugin0 \
  ./scripts/preflight-storage.sh \
    --var-file examples/advanced/openstack.hcl \
    --emit-topology-vars 2>/dev/null | grep _csi_topology_node_id)
eval "${TOPO_VARS}"
nomad-pack run \
  -var-file examples/advanced/openstack.hcl \
  -var "db_csi_topology_node_id=${db_csi_topology_node_id}" \
  -var "redis_csi_topology_node_id=${redis_csi_topology_node_id}" \
  --name openstudio-server .
```

### 5. Redeploy the pack

**Normal deploy** — the full automated flow (preflight → rebind stale → emit topology → phase-gated deploy):

```bash
bash scripts/deploy-openstack.sh --deploy
```

`deploy-openstack.sh` automatically passes `DB_CSI_PLUGIN_ID` and `REDIS_CSI_PLUGIN_ID` from
environment variables.  Set them before calling deploy if the plugin IDs differ from the
default (`nfs`):

```bash
DB_CSI_PLUGIN_ID=hostpath-web-plugin0 \
REDIS_CSI_PLUGIN_ID=hostpath-web-plugin0 \
bash scripts/deploy-openstack.sh --deploy
```

**Manual nomad-pack run** (bypasses the automated flow — use only when the automated flow is
unavailable):

```bash
nomad-pack run -var-file examples/advanced/openstack.hcl packs/openstudio-server
```

> ⚠ When deploying manually, run `preflight-storage.sh --rebind-stale --emit-topology-vars`
> first and pass the emitted topology node IDs as `--var` overrides, otherwise DB/Redis may
> land on nodes where the CSI volume is not accessible.

### 5a. Expand node root disks when disk pressure is recurrent

If allocations fail with `no space left on device` during image extraction/logging,
increase root disk sizes for replacement worker nodes (quota permitting) instead of
recycling undersized nodes repeatedly.

Quick quota check:

```bash
openstack quota show "$(openstack token issue -f value -c project_id)" -f value -c gigabytes
openstack volume list --all-projects=false -f value -c Size | awk '{s+=$1} END {print s+0}'
```

Provision replacements with larger root volumes (example: 120 GiB):

```bash
ROOT_DISK_GB=120 ./scripts/provision-worker-nodes.sh --count 5
```

The bootstrap script now sets `client.reserved.disk = 20480` (20 GiB), so nodes become
ineligible before low-disk conditions break container pulls.

### 6. Verify health

Check:

- `openstudio-db`
- `openstudio-redis`
- `openstudio-rserve`
- `openstudio-web`
- `openstudio-worker`

All should be running and registered in Consul.

Run post-deploy guardrails:

```bash
make os-ingress-check
make os-conformance-audit
make os-disk-audit
```

If jump-host Traefik drift is detected, reconcile it to the managed baseline:

```bash
make os-traefik-reconcile
```

If low-disk nodes are identified, quarantine and drain them before they hit ENOSPC:

```bash
./scripts/remediate-low-disk-nodes.sh --apply --drain --threshold-mb 20480
```

### 7. Run a smoke analysis

Submit one small analysis from the web UI and confirm:

- the job reaches the worker queue
- artifact files appear in the shared NFS path
- results can be opened from the web UI

## Notes

- Keep `web_count = 1`.
- Treat Helm sizing as a reference for CPU/RAM and disk capacity only; keep Nomad-native storage and placement where it is better suited.
- If the pack fails again, inspect the newest failed allocation before changing configuration.
