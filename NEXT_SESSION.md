# Next Session Prompt

Run a clean stabilization pass for the OpenStack Nomad deployment so I can
submit analyses reliably.

## Current focus

- Normalize node roles:
  - worker nodes on `azimuth.compute1-179d-250disk`
  - non-worker service nodes on `azimuth.web1-179d` / `azimuth.web2-179d`
- Finish node config convergence
- Verify persistent storage
- Redeploy the pack from the current OpenStack profile
- Smoke test the web UI with one small analysis

## Execute in order

1. Run `scripts/bootstrap-179d-node.sh --role worker` on worker nodes and
   `scripts/bootstrap-179d-node.sh --role web` on service nodes that still need
   bootstrap/config convergence.
2. Run `scripts/fix-consul-all-nodes.sh` to force local-agent Consul
   registration on every active client.
3. Run `nomad run infra-setup.nomad` once to normalize Docker data-root and
   Nomad client settings.
4. Confirm the OpenStack Nomad profile uses:
   - `db_storage_type = "csi"`
   - `redis_storage_type = "csi"`
   - `nfs_shared_volume_enabled = true`
   - `nfs_volume_type = "host_volume"`
   - `nfs_volume_source = "openstudio-nfs"`
5. Redeploy with `nomad-pack run -var-file examples/openstack.hcl .`
6. Verify `openstudio-db`, `openstudio-redis`, `openstudio-rserve`,
   `openstudio-web`, and `openstudio-worker` are all healthy.
7. Submit a smoke analysis and confirm it completes using the shared NFS path.

## Guardrails

- Keep `web_count = 1`.
- Do not switch back to ephemeral DB/Redis storage.
- Treat Helm sizing as the CPU/RAM/storage reference only; keep Nomad-native
  storage and placement where they are a better fit.
- If anything fails, inspect the newest failed allocation before changing more
  configuration.
