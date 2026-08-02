# OpenStack Nomad Stabilization Runbook

## Goal

Bring the OpenStack Nomad deployment to a clean, production-like state so analyses can be submitted reliably.

## Target state

- Nomad clients correctly split by role:
  - `worker` nodes on `azimuth.compute1-179d-250disk`
  - `web` / service nodes on `azimuth.web1-179d` or `azimuth.web2-179d`
- Consul registration uses the local agent on every active client
- Docker/Nomad client config is consistent on all active nodes
- MongoDB and Redis use persistent storage
- Web/worker share NFS-backed storage for analysis artifacts
- `web_count = 1`
- Pack redeployed from `examples/openstack.hcl`
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
nomad run infra-setup.nomad
```

### 4. Confirm storage prerequisites

Use the OpenStack/Nomad storage profile:

- MongoDB: `db_storage_type = "csi"`
- Redis: `redis_storage_type = "csi"`
- DB/Redis CSI plugin IDs: `db_csi_plugin_id` / `redis_csi_plugin_id` set to the web-role plugin (for example `hostpath-web-plugin0`)
- Shared analysis data: `nfs_shared_volume_enabled = true`
- NFS volume type: `host_volume`
- NFS volume source: `openstudio-nfs`

If role-scoped hostpath plugins are not deployed yet, deploy them first:

```bash
NOMAD_ADDR=http://10.60.126.125:4646 \
./scripts/deploy-hostpath-csi-role-plugins.sh
```

Confirm the backing CSI/NFS volumes exist before redeploying.

Run the automated preflight check:

```bash
NOMAD_ADDR=http://10.60.126.125:4646 \
./scripts/preflight-storage.sh --var-file examples/openstack.hcl
```

The check fails fast when required CSI plugins/volumes are missing or when required
host volumes (for example `openstudio-nfs`) are not advertised by ready Nomad clients.

To auto-create missing MongoDB/Redis CSI volumes (when the CSI plugin is already healthy):

```bash
NOMAD_ADDR=http://10.60.126.125:4646 \
./scripts/preflight-storage.sh --var-file examples/openstack.hcl --create-missing-csi
```

### 5. Redeploy the pack

Deploy the current OpenStack profile:

```bash
nomad-pack run -var-file examples/openstack.hcl .
```

### 6. Verify health

Check:

- `openstudio-db`
- `openstudio-redis`
- `openstudio-rserve`
- `openstudio-web`
- `openstudio-worker`

All should be running and registered in Consul.

### 7. Run a smoke analysis

Submit one small analysis from the web UI and confirm:

- the job reaches the worker queue
- artifact files appear in the shared NFS path
- results can be opened from the web UI

## Notes

- Keep `web_count = 1`.
- Treat Helm sizing as a reference for CPU/RAM and disk capacity only; keep Nomad-native storage and placement where it is better suited.
- If the pack fails again, inspect the newest failed allocation before changing configuration.
