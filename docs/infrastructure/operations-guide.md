# OpenStudio Server Nomad Pack — Operations Guide

This page is the single entry point for all operational documentation. Each section below
describes a topic and links to the dedicated guide that covers it in depth.

---

## Service Topology

```mermaid
graph LR
  web --> redis
  web --> mongodb
  web --> rserve
  web --> worker
  worker --> redis
  worker --> mongodb
```

The `web` task group blocks on a `prestart` check that waits for `openstudio-db`,
`openstudio-redis`, and `openstudio-rserve` to be healthy in Consul before the web
container starts.

---

## Web Replica Constraint

> [!WARNING]
> **`web_count` must remain `1` (the default).** Setting it higher will silently
> corrupt analysis state.

### Root cause

The OpenStudio Server web process stores uploaded analysis artefacts (input files, result
archives, temporary data) on the **local container filesystem** — typically under
`/mnt/openstudio` when NFS is mounted, or in the allocation's private scratch space when
it is not.  There is no distributed file-locking mechanism protecting these paths.

When `web_count > 1`, each Nomad allocation gets its own isolated view of that filesystem.
A file written by allocation A is invisible to allocation B, so subsequent requests routed
to B fail to find artefacts that A created.  This is the same constraint documented in the
upstream Helm chart (`templates/web/web-hpa.yaml`, `maxReplicas: 1`):

> *"For this to work and have more than 1 web pod we'll need to implement a distributed
> file locking scheme — NFS cannot guarantee file locking using multiple clients."*

The NFS CSI volume (enabled with `nfs_shared_volume_enabled = true`) provides shared
storage, but it does **not** provide advisory file locks across clients: concurrent
writers can still race and corrupt state.

### How to relax this constraint

Two architectural changes are required before `web_count > 1` is safe:

| Approach | What is needed |
|---|---|
| **Distributed lock manager** | Wrap every filesystem operation in the web process with an atomic lock acquired via a distributed backend (e.g. [Redlock](https://redis.io/docs/latest/develop/use/patterns/distributed-locks/) over the existing Redis instance). All replicas share the same NFS volume; the lock prevents concurrent writes to the same path. |
| **Stateless file handling** | Eliminate local-disk writes from the request path by moving all persistent artefacts to object storage (e.g. Amazon S3, MinIO, or an S3-compatible endpoint). The web process becomes fully stateless and any number of replicas can run safely. |

Until one of these approaches is implemented in the upstream OpenStudio Server
application, keep `web_count = 1`.

---

## Guides

### 🚀 Getting Started: Single-Node Dev Cluster

**[docs/modelers/getting-started-single-node.md](../modelers/getting-started-single-node.md)**

Start here if you are deploying for the first time on a developer laptop or a single-node test
environment. Covers:

- Prerequisites (Nomad, Consul, CNI plugins, Docker, nomad-pack versions)
- Agent config snippets for macOS and Linux with `host_volume` enabled
- Full `nomad-pack run` command with a minimal override file
- How to verify all six services reach `running`
- Access instructions for the OpenStudio Server web UI
- Common errors and their fixes (port conflicts, volume permission denied, image pull failures)

---

### 💾 Storage Preparation

**[docs/infrastructure/storage.md](./storage.md)**

Covers everything you need to provision persistent storage *before* running `nomad-pack run`:

- Step-by-step instructions for registering a CSI plugin job and verifying plugin health
- `host_volume` stanza configuration for the Nomad client agent config
- Persistent volume examples for MongoDB and Redis data directories
- Volume permissions and UID/GID ownership requirements per service container
- Teardown and cleanup steps to avoid orphaned volumes

---

### 📋 Variable Reference

**[docs/variables.md](../variables.md)**

Full reference for every pack variable sourced directly from `packs/openstudio-server/variables.hcl`:

- Complete table: name, type, default, description, example override
- Annotated override file examples: minimal dev, production HA, air-gapped/private-registry
- Notes on variable interactions (e.g., `worker_count` vs. resource limits, Vault toggle flow)

---

### 🔐 Nomad ACL Policy Setup

**[docs/infrastructure/acl-policies.md](./acl-policies.md)**

Minimum ACL capabilities required to deploy and manage this pack:

- HCL policy files for operator, read-only, and CI/CD service token roles
- Commands to create policies and generate tokens
- Scoping policies to a specific Nomad namespace

---

### 🔑 Vault Policy Setup

**[docs/infrastructure/vault-policies.md](./vault-policies.md)**

HashiCorp Vault integration for secrets management:

- Vault policy HCL for each service that reads secrets (web, web-background, worker)
- `vault` stanza with `change_mode` and `change_signal` examples
- Nomad ≥ 1.7 labeled `vault` block vs. legacy Nomad < 1.7 stanza syntax
- KV v2 secret path conventions and token TTL / renewal recommendations
- Enabling the Nomad secrets engine in Vault

---

### 🔄 Kubernetes-to-Nomad Migration

**[docs/infrastructure/migration-k8s-to-nomad.md](./migration-k8s-to-nomad.md)**

Step-by-step migration from the [NREL openstudio-server Helm chart](https://github.com/NREL/openstudio-server):

- Pre-migration checklist: data backups, DNS/Consul service name mapping, image registry access
- Side-by-side Helm `values.yaml` → Nomad Pack variable mapping table
- MongoDB data migration (mongodump / mongorestore with volume mount examples)
- Redis persistence migration steps
- Post-migration smoke-test commands for all six services
- Rollback procedure if migration fails

---

## Nomad Autoscaler Integration

> [!IMPORTANT]
> **Prerequisite: Nomad Autoscaler daemon must be deployed before enabling worker autoscaling.**  
> If `worker_autoscaling_enabled = true` but the daemon is not running, Nomad silently ignores the `scaling` block and worker count remains fixed.  
> Recommended path: deploy the [official Nomad Autoscaler pack](https://developer.hashicorp.com/nomad/tools/autoscaling/deployment/nomad).
>
> **CPU scaling (`worker_autoscaling_cpu_enabled`) uses the `nomad-apm` source** and reads metrics directly from the Nomad API — no Prometheus is required.  
> **Prometheus is required only for queue-depth scaling** (`worker_queue_requeued_query` / `worker_queue_simulations_query`). You can enable CPU autoscaling without a Prometheus stack.

This pack also ships an optional stub at `packs/openstudio-server/templates/nomad-autoscaler.nomad.tpl` gated by `nomad_autoscaler_enabled = false`. The stub defaults to the `nomad-apm` source and includes comments showing where to add an optional Prometheus source.

When worker autoscaling is enabled, this pack now includes a built-in `nomad-apm` CPU check (`avg_cpu`) as the primary simple-scaling path. This requires no external metrics stack and is controlled by `worker_autoscaling_cpu_enabled` and `worker_cpu_target_utilization` (default `50`, matching Helm HPA behavior). Existing Prometheus queue-depth checks remain available for advanced backlog-aware tuning.

### Cloud node pool autoscaling

In Kubernetes, worker pod autoscaling (HPA) and node autoscaling (Cluster Autoscaler annotations)
are separate systems. In Nomad, the **Nomad Autoscaler daemon** can manage both workload scaling and
cluster capacity scaling from one place.

For cloud-backed worker nodes, add a target policy that scales your node pool directly (for example
an AWS Auto Scaling Group):

```hcl
target "aws-asg" {
  dry-run = "false"             # Set true to validate policy behavior safely
  aws_region = "us-east-1"      # Region containing the ASG
  asg_name   = "nomad-clients"  # ASG backing Nomad client nodes
}
```

Use the same pattern for GCP Managed Instance Groups with the `gce-mig` target plugin.

> **Tip:** `packs/openstudio-server/templates/nomad-autoscaler.nomad.tpl` includes ready-to-uncomment `target "aws-asg"` and
> `target "gce-mig"` stanzas inside the inline `autoscaler.hcl` config block. Uncomment and fill in
> the appropriate fields for your cloud provider — no HCL needs to be written from scratch.

See:

- Nomad Autoscaler AWS ASG target:
  [developer.hashicorp.com/nomad/tools/autoscaling/plugins/target/aws-asg](https://developer.hashicorp.com/nomad/tools/autoscaling/plugins/target/aws-asg)
- Nomad Autoscaler GCE MIG target:
  [developer.hashicorp.com/nomad/tools/autoscaling/plugins/target/gce-mig](https://developer.hashicorp.com/nomad/tools/autoscaling/plugins/target/gce-mig)

For Kubernetes `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` equivalence during node
termination, protect critical tasks with Nomad controls such as:

- `max_client_disconnect` (allow temporary client loss without immediate replacement)
- `prevent_reschedule_on_lost` (avoid automatic rescheduling after client loss)

---

## Quick-Reference: Pack Variables

| Variable | Default | What it does |
|----------|---------|--------------|
| `job_name` | `openstudio-server` | Nomad job name |
| `datacenters` | `["dc1"]` | Eligible datacenters |
| `worker_count` | `1` | Number of worker replicas |
| `worker_autoscaling_enabled` | `false` | Enable Nomad Autoscaler |
| `db_storage_type` | `host_volume` | `host_volume`, `csi`, or `ephemeral` |
| `redis_storage_type` | `host_volume` | `host_volume`, `csi`, or `ephemeral` |
| `vault_integration_enabled` | `false` | Enable Vault KV secret template injection (`secrets/env`) |
| `vault_enabled` | `false` | Enable explicit role-based Vault blocks in tasks |
| `enable_consul_connect` | `false` | Enable Consul Connect mTLS mesh |
| `backup_enabled` | `false` | Enable MongoDB backup batch job |

See the full reference in [docs/variables.md](./variables.md).

---

## Deployment Checklist

Before running `nomad-pack run` for the first time:

- [ ] Nomad cluster is running and all client nodes are `ready`
- [ ] Consul is running and the Nomad–Consul integration is configured
- [ ] `host_volume` stanzas are added to every eligible Nomad client config **and** the client has been reloaded, _or_ CSI volumes are registered
- [ ] Volume directories exist and are owned by UID/GID `999` (MongoDB and Redis container user)
- [ ] Docker can pull required images on every Nomad client node
- [ ] If ACLs are enabled: operator token exported as `NOMAD_TOKEN`
- [ ] If Vault is enabled: secrets written to the correct KV v2 paths and Nomad policies applied
- [ ] If `worker_autoscaling_enabled = true`: Nomad Autoscaler is deployed and running

### OpenStack reliability checks (recommended cadence)

Run these from the pack root after bootstrap/deploy and then on a schedule (for example, every 15 minutes for ingress and daily for audits):

```bash
# Ingress route + external URL + Traefik metrics endpoint
make os-ingress-check

# Reconcile jump-host Traefik config to managed baseline, then validate ingress
make os-traefik-reconcile

# Verify critical jobs are constrained to the intended node_role
make os-conformance-audit

# Report low-disk Nomad clients before ENOSPC causes allocation failures
make os-disk-audit

# Audit legacy/orphan jobs that can trigger pack metadata drift
make os-legacy-job-audit

# Verify required ingress + periodic OpenStudio alert rules are loaded
PROMETHEUS_URL=http://<prometheus-host>:9090 make os-alerts-check

# Check recent queue-sweeper/watchdog Consul transient warning rate
make os-consul-transient-check
```

To automatically quarantine low-disk nodes, run:

```bash
NOMAD_ADDR=http://127.0.0.1:4646 \
JUMP_HOST=ubuntu@10.60.105.39 \
NOMAD_SERVER_HOST=ubuntu@10.60.126.125 \
./scripts/remediate-low-disk-nodes.sh --apply --drain --threshold-mb 20480
```

By default, the script will **not** quarantine `node_role=web` nodes. Override only when you have replacement web-role capacity:

```bash
./scripts/remediate-low-disk-nodes.sh --apply --drain --threshold-mb 20480 --allow-web-role-quarantine
```

---

## Disk Reservation — Automatic Node Ineligibility

> **Root cause (2026-08-03 incident):** Two Nomad client nodes filled their 242 GiB disks
> entirely (ENOSPC) during a single large simulation run. Nomad continued scheduling allocs
> onto them until all disk writes failed. No automatic ineligibility was triggered.

### Configure `reserved.disk` on every Nomad client

Add (or update) the following in each client's Nomad configuration file
(typically `/etc/nomad.d/client.hcl`):

```hcl
client {
  reserved {
    # 20 GiB in MiB — Nomad stops scheduling new allocs when free disk drops below this.
    # Set to the minimum headroom required for OS/system operation plus one alloc worth
    # of ephemeral scratch space.
    disk = 20480
  }
}
```

After editing, reload the Nomad agent:

```bash
systemctl reload nomad
# or (if reload is not supported)
systemctl restart nomad
```

**Verify the threshold is active:**

```bash
# Check the node's reserved disk field
nomad node status -json <node_id> | jq '{
  disk_free_mb: .NodeResources.Disk.DiskMB,
  reserved_disk_mb: .Reserved.DiskMB
}'
```

> **Nomad Vagrant cluster:** Update `vagrant/provision/nomad-client.sh` to include the
> `client.reserved.disk` stanza in the generated `client.hcl` so new nodes provisioned
> by Vagrant inherit this setting automatically.

### Disk sizing recommendation

For large simulation runs (100,000+ data points), 250 GiB per node is insufficient.
See [storage.md — Disk Sizing for Large Simulation Runs](./storage.md#disk-sizing-for-large-simulation-runs)
for per-DP footprint estimates and recommended node sizes.

---

## Scaling Workers When a Deployment Is Stuck

> **Root cause (2026-08-03 incident):** `nomad job scale` is blocked when an active
> deployment is in-flight. The correct workaround is non-obvious and critical.

### Do NOT use `nomad deployment pause`

`pause` suspends health evaluation but does **not** release the scaling lock. `nomad job scale`
will still return `job scaling blocked due to active deployment`.

### Correct procedure

1. **Identify the stuck deployment:**
   ```bash
   nomad job deployments openstudio-server-worker
   ```

2. **Fail the deployment** (releases the scaling lock immediately):
   ```bash
   nomad deployment fail <deployment_id>
   ```

3. **Snapshot the current job spec:**
   ```bash
   nomad job inspect -json openstudio-server-worker > /tmp/worker_job.json
   ```

4. **Edit the desired count:**
   ```bash
   # Set TaskGroups[0].Count to the desired scale (e.g. 250)
   python3 -c "
   import json, sys
   j = json.load(open('/tmp/worker_job.json'))
   j['TaskGroups'][0]['Count'] = 250
   json.dump(j, sys.stdout)
   " > /tmp/worker_job_scaled.json
   ```

5. **Strip read-only fields** (Nomad rejects them on submit):
   ```bash
   python3 -c "
   import json, sys
   j = json.load(open('/tmp/worker_job_scaled.json'))
   for field in ['CreateIndex','ModifyIndex','JobModifyIndex','Version','SubmitTime','Status','StatusDescription','Stable']:
       j.pop(field, None)
   json.dump({'Job': j}, sys.stdout)
   " > /tmp/worker_payload.json
   ```

6. **Submit via the Nomad API:**
   ```bash
   curl -X POST ${NOMAD_ADDR}/v1/jobs \
     -H 'Content-Type: application/json' \
     -d @/tmp/worker_payload.json
   ```

### Autoscaler blocked — force immediate scale-up with `max_parallel=0`

> **Root cause (2026-08-03 incident, repeated):** The Nomad Autoscaler will not evaluate
> scaling policies while a deployment is `running`. With `max_parallel=1` (the normal safe
> setting), a rolling update of N workers takes N × `min_healthy_time` minutes.

When you need workers to scale up immediately and an active deployment is blocking the
autoscaler:

1. **Confirm autoscaler is blocked:**
   ```bash
   nomad job deployments openstudio-server-worker | head -5
   # Should show a deployment in "running" state
   ```

2. **Push a new version with `max_parallel=0`** (unlimited parallel — all allocs replaced
   simultaneously) and the desired seed count:
   ```bash
   NOMAD_ADDR=http://<nomad-server>:4646 nomad-pack render \
     --var-file examples/advanced/openstack-production.hcl \
     --var-file examples/advanced/openstack-site-local.hcl \
     --var "enable_image_prepull=false" \
     --var "worker_count=2000" \
     --name openstudio-server . | grep -A9999 "openstudio-server/worker.nomad:" | tail -n +2 \
     | nomad job run -
   ```

   Alternatively, inspect the current spec, patch `MaxParallel=0` and `Count`, then
   submit via the API (same as the "stuck deployment" procedure above).

3. **Immediately restore `max_parallel=1`** once the autoscaler fires (check `nomad job
   deployments` — a new one should appear within 30 s):
   ```bash
   # Render and push the normal worker spec with max_parallel=1
   NOMAD_ADDR=http://<nomad-server>:4646 nomad-pack run \
     --var-file examples/advanced/openstack-production.hcl \
     --var-file examples/advanced/openstack-site-local.hcl \
     --var "enable_image_prepull=false" \
     --name openstudio-server .
   ```

> ⚠️ Never leave `max_parallel=0` in place. A future rolling update will replace all
> running workers simultaneously, causing a complete worker outage during the transition.



**Always verify the image immediately after an auto-revert:**

```bash
nomad job inspect openstudio-server-worker | grep -i image
```

Auto-revert restores the last *stable* version — the version that was marked stable
before the current deployment started. If the stable baseline was pinned to an old or
wrong image (e.g. `openstudio-worker:local` absent on most nodes), the revert silently
restores a broken state.

**To update the stable baseline:** deploy the correct image, wait for `min_healthy_time`
to elapse with all allocs healthy, then confirm:

```bash
nomad job history openstudio-server-worker | grep -E "Version|Stable"
```

---

## Pending Application-Level Fixes (openstudio-server repo)

The following bugs were identified during the 2026-08-03 incident. They require changes
in the **`openstudio-server`** application repository (not this pack). Track them as
pull requests against `NREL/openstudio-server`.

### 1. Nil guard in `RunSimulateDataPoint#perform`

**File:** `app/jobs/resque_jobs/run_simulate_data_point.rb`

**Symptom:** If a Resque payload uses the wrong arg format (`args: [analysis_id, dp_id]`
instead of `args: [dp_id]`), `DataPoint.find(analysis_id)` returns `nil`, execution
continues silently, and the DP stays at `na` forever with no error in any log.

**Required change:**

```ruby
# Resque payload format: {"class": "ResqueJobs::RunSimulateDataPoint", "args": ["<data_point_id>"]}
# IMPORTANT: args must contain exactly ONE element (the data_point_id string).
# Passing [analysis_id, data_point_id] causes DataPoint.find(analysis_id) => nil => silent skip.
def self.perform(data_point_id, options = {})
  data_point = DataPoint.find(data_point_id)
  raise ArgumentError, "DataPoint '#{data_point_id}' not found — check Resque payload arg format (must be single dp_id string)" if data_point.nil?
  # ... rest of method unchanged
```

### 2. `batch_run.rb` nil `end_time=` / BSON document key bug

**File:** `app/lib/analysis_library/batch_run.rb` (lines 28 and 82)

**Symptoms:**
- `undefined method 'end_time=' for nil:NilClass` at line 82
- `NilClass instances are not allowed as keys in a BSON document` at line 28

**Suspected root cause:** The `Job` or `Analysis` record is `nil` at line 82. This
likely occurs when the analysis is in a partially-initialized state (e.g., submitted but
not yet persisted, or deleted between enqueue and execution).

**Required change:** Add nil guards before line 82:

```ruby
# In batch_run.rb around line 82:
raise ArgumentError, "Job record is nil in batch_run at end_time assignment" if job.nil?
job.end_time = Time.now
```

**Live cluster impact:** Analysis `0a6703b4` on the live cluster is permanently failed
due to this bug. Its results are unavailable. Re-initiate from the web UI if required.

---

## Node Replacement

When a Nomad client node is replaced (e.g., an OpenStack VM is terminated and a new VM
joins the cluster with a different UUID), any CSI volume that was pinned to the old node
via `topology_required` will become unschedulable. This section describes how to detect
the staleness and restore service.

### Detection

**Step 1 — Observe unschedulable DB job:**

```bash
nomad job status openstudio-server-db
```

Look for an allocation stuck in `pending` with a placement failure like:

```
Placement Failure
  Task Group "db" (failed to place 1 allocation):
    * Constraint "topology" filtered 1 nodes
```

**Step 2 — Confirm the volume topology pin is stale:**

```bash
nomad volume status openstudio-mongodb
```

The `Topology` field will list the old node UUID. Compare it against the current client
nodes:

```bash
nomad node status
```

If the node UUID in the volume's topology does not appear in the node list, the pin is
stale and must be updated.

---

### Automated Remediation (preferred)

If you are using the `deploy-openstack.sh` helper script, re-running it with `--deploy`
automatically re-executes preflight with `--rebind-stale --emit-topology-vars` and
re-deploys the pack with updated topology pins:

```bash
./scripts/deploy-openstack.sh --deploy
```

The script performs these steps internally:
1. Runs `preflight-storage.sh --rebind-stale --emit-topology-vars` to detect the new
   node UUID and emit updated `*_csi_topology_node_id` variable values.
2. Passes those values to `nomad-pack run` to update the DB and Redis job topology pins.
3. Validates that the DB and Redis jobs reach a healthy state before returning.

No manual intervention is required when this path is available.

---

### Manual Remediation

Use this path when the automated deploy script is unavailable or when you need to
perform the update step-by-step.

**Step 1 — Re-run preflight to capture the new node UUID:**

```bash
DB_CSI_PLUGIN_ID=hostpath-web-plugin0 \
  ./scripts/preflight-storage.sh \
    --var-file examples/advanced/openstack.hcl \
    --rebind-stale --emit-topology-vars 2>/dev/null \
  | grep _csi_topology_node_id
```

Example output:

```
db_csi_topology_node_id    = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
redis_csi_topology_node_id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
```

**Step 2 — Re-deploy with updated topology pins:**

```bash
nomad-pack run \
  -var-file examples/advanced/openstack.hcl \
  -var "db_csi_topology_node_id=<new-uuid>" \
  -var "redis_csi_topology_node_id=<new-uuid>" \
  --name openstudio-server .
```

Replace `<new-uuid>` with the UUID captured in Step 1.

**Step 3 — Verify recovery:**

```bash
nomad job status openstudio-server-db
nomad job status openstudio-server-redis
```

Both jobs should show all allocations in `running` state within a few minutes.

> **Note:** If `nomad volume status openstudio-mongodb` still shows the old node UUID
> after re-deploying, the CSI plugin may need to be restarted or the volume deregistered
> and re-registered. Consult the [Storage guide](storage.md) for volume lifecycle
> operations.

---

## Teardown Order

Before destroying the pack, stop the stateless jobs first so that all Nomad allocations
reach a terminal state before any downstream cleanup (NFS unmount, volume deletion, etc.).

Use the provided helper script:

```bash
# Default namespace ("default")
./scripts/pre-teardown.sh

# Non-default namespace via flag
./scripts/pre-teardown.sh --namespace openstudio

# Non-default namespace via environment variable
NOMAD_NAMESPACE=openstudio ./scripts/pre-teardown.sh

# Custom job name and namespace
./scripts/pre-teardown.sh --namespace openstudio my-custom-job-name
```

`JOB_NAME` defaults to `openstudio-server`. The namespace defaults to `"default"` but
should match the `nomad_namespace` variable used when the pack was deployed. The script
stops jobs in this order:

1. `<JOB_NAME>-worker` (drains in-flight simulations first)
2. `<JOB_NAME>-web`
3. `<JOB_NAME>-rserve`
4. `<JOB_NAME>-db`
5. `<JOB_NAME>-redis`
6. `<JOB_NAME>-system-hooks` (stopped with `-global`)
7. `<JOB_NAME>-state-backup` (optional, if present)
8. `<JOB_NAME>-state-restore` (optional, if present)
9. `<JOB_NAME>-batch-verify` (optional, if present)
10. `<JOB_NAME>-test` (optional, if present)
11. `<JOB_NAME>-nomad-autoscaler` (optional, if present)
12. `<JOB_NAME>-autoscaler` (legacy optional name, if present)

Then it prints the `nomad-pack destroy packs/openstudio-server` instruction.

> **Note for non-default namespace deployments:** Always pass `--namespace` (or set
> `NOMAD_NAMESPACE`) when the pack was deployed with `nomad_namespace != "default"`.
> Without it, `nomad job stop` targets the `default` namespace and silently succeeds
> without stopping anything.

Once the script exits successfully, run:

```bash
nomad-pack destroy packs/openstudio-server
```

### Why no `sleep`?

The Helm chart's `hooks/pre-delete-hook.yaml` runs `kubectl delete deployment … && sleep 60`
as a workaround for Kubernetes' non-deterministic pod drain timing — there is no blocking
primitive that guarantees pods are dead before the hook exits.

`nomad job stop` is deterministic: it **blocks until every allocation is dead**. No sleep
is needed, making this approach cleaner and more reliable than the Helm equivalent.

---

## Queue-Sweeper / Watchdog Rollout Safety

Use the dedicated runbook for periodic-job rollout checks, forced-run validation, alert
signals, and short-lived allocation forensics:

- [queue-sweeper-watchdog-rollout.md](./queue-sweeper-watchdog-rollout.md)

Critical invariants enforced by the pack:

1. `stall-watchdog` runs only as a task group inside `<job_name>-queue-sweeper` (no standalone job).
2. If both `enable_queue_sweeper` and `enable_stall_watchdog` are true, cron values must match.
3. Transient Consul control-plane throttling (429/5xx) is handled as skip-cycle (exit 0), not hard failure.

---

### Periodic-job operational helpers

```bash
# Capture short-lived periodic alloc evidence before GC removes it
./scripts/capture-periodic-forensics.sh --job-name openstudio-server --namespace default

# Count recent Consul transient warnings in queue-sweeper/watchdog logs
./scripts/check-queue-sweeper-consul-transient-rate.sh --job-name openstudio-server --namespace default
```

---

## `nomad-pack run` Deployment Metadata Drift (`pack.deployment_name`)

Some upgraded environments retain legacy jobs that can break `nomad-pack run` lookups with:

- `Failed To Query For Previously Deployed Jobs`
- `pack.deployment_name` query failures

Safest remediation path implemented in repo scripts:

1. Enforce consolidated scheduler source by purging known legacy standalone job IDs (notably `<job_name>-stall-watchdog`).
2. Retry `nomad-pack run` once after purge.
3. If metadata query still fails but core jobs register successfully, continue with explicit warning.

One-time manual cleanup command (if needed):

```bash
nomad job stop -purge <job_name>-stall-watchdog
```

One-time prefix audit helper (dry-run by default):

```bash
NOMAD_ADDR=http://<nomad-host>:4646 ./scripts/audit-legacy-pack-jobs.sh --job-name <job_name> --namespace <ns>
# Apply safe known-legacy purge set:
NOMAD_ADDR=http://<nomad-host>:4646 ./scripts/audit-legacy-pack-jobs.sh --job-name <job_name> --namespace <ns> --apply
```

---

## Ingress Alerts

The `openstudio_ingress` group in `monitoring/prometheus-alert-rules.yml` provides continuous alerting for Traefik route and backend health.  These fire automatically — no manual `check-openstack-ingress.sh` run required.

### Alert: TraefikRouterMissing (critical)

**Meaning:** The `openstudio-server@consulcatalog` Traefik router has been absent or has had no entry points for 5+ minutes.  All requests will return 404.  This is the primary signal for the class of outage that occurred on 2026-08-03.

**Response steps:**

1. Confirm the Nomad web job is running:
   ```bash
   nomad job status openstudio-server-web
   ```
2. Confirm the Consul service is healthy:
   ```bash
   consul catalog services | grep openstudio
   consul health service openstudio-web
   ```
3. Validate Traefik's Consul Catalog endpoint configuration:
   ```bash
   ./scripts/validate-traefik-consul-endpoint.sh
   ```
4. Run the full ingress smoke check:
   ```bash
   ./scripts/check-openstack-ingress.sh
   # or
   make os-ingress-check
   ```
5. If the Consul provider address is wrong or missing, re-apply the managed Traefik baseline:
   ```bash
   make os-traefik-reconcile
   ```
6. Verify the router is visible in the Traefik API after reconciliation:
   ```bash
   curl -s http://<traefik-host>:8080/api/http/routers | \
     jq '.[] | select(.name | contains("openstudio"))'
   ```

---

### Alert: TraefikIngressHighErrorRate (warning)

**Meaning:** The `openstudio-server@consulcatalog` router is returning HTTP 404 for more than 10 % of requests over a 5-minute window.  The route exists but requests are not matching or the application is returning 404 upstream.

**Response steps:**

1. Check the current router rule (Host/Path/PathPrefix):
   ```bash
   curl -s http://<traefik-host>:8080/api/http/routers | \
     jq '.[] | select(.name | contains("openstudio")) | {name,rule,status}'
   ```
2. Verify the `ingress_domain` variable matches the domain clients are requesting and the Host header is correct:
   ```bash
   ./scripts/check-openstack-ingress.sh
   ```
3. Check application-level 404s in web allocation logs:
   ```bash
   WEB_ALLOC=$(nomad job allocs -json openstudio-server-web | jq -r '.[0].ID')
   nomad alloc logs "$WEB_ALLOC" web | grep " 404 "
   ```
4. If the path prefix has changed, redeploy with the correct `ingress_path_prefix` variable.
5. Escalate to `OpenStudioIngressHigh404Ratio` (entrypoint-level, >30 %) if the issue is not router-specific.

---

### Alert: TraefikBackendUnhealthy (critical)

**Meaning:** Traefik's `traefik_service_server_up` metric reports zero healthy servers for `openstudio-web`.  Every routed request will return 502/503.

**Response steps:**

1. Check the web job allocation:
   ```bash
   nomad job status openstudio-server-web
   nomad alloc status <web-alloc-id>
   ```
2. Inspect Consul health checks for `openstudio-web`:
   ```bash
   consul health service openstudio-web
   ```
3. View web allocation logs for startup errors:
   ```bash
   nomad alloc logs -stderr <web-alloc-id> web
   ```
4. If the allocation is in `failed` or `lost` state, restart the job:
   ```bash
   nomad job stop openstudio-server-web
   nomad-pack run --name openstudio-server packs/openstudio-server
   ```
5. If Consul health checks are failing but the process is running, check the health check endpoint:
   ```bash
   curl -v http://<web-node-ip>:<web_port>/
   ```
6. After the web job recovers, confirm Traefik detects the backend:
   ```bash
   curl -s http://<traefik-host>:8080/api/http/services | \
     jq '.[] | select(.name | contains("openstudio")) | {name, serverStatus}'
   ```

---

### Alert: OpenStudioTraefikConfigReloadFailed (critical)

**Meaning:** `traefik_config_last_reload_success == 0` — Traefik failed to apply its most recent configuration.  The running config is stale; routes may be out of date.

**Response steps:**

1. Check Traefik logs for the parse/validation error:
   ```bash
   nomad alloc logs -stderr <traefik-alloc-id> traefik | tail -50
   ```
2. Validate the static config file:
   ```bash
   traefik healthcheck --configFile /etc/traefik/traefik.yml
   ```
3. Correct the config and force a reconcile:
   ```bash
   make os-traefik-reconcile
   ```

---

### Loading / reloading alert rules

Alert rules are stored in `monitoring/prometheus-alert-rules.yml`.  To deploy them:

```bash
# Copy into the Prometheus config directory on the Prometheus node
scp monitoring/prometheus-alert-rules.yml ubuntu@<prometheus-node>:/etc/prometheus/rules/

# Add to Prometheus rule_files: if not already present:
# rule_files:
#   - /etc/prometheus/rules/prometheus-alert-rules.yml

# Reload Prometheus (no restart required):
curl -X POST http://<prometheus-host>:9090/-/reload

# Confirm rules are loaded:
curl -s http://<prometheus-host>:9090/api/v1/rules | \
  jq '.data.groups[] | select(.name=="openstudio_ingress") | .rules[].name'
```

Expected output includes: `TraefikRouterMissing`, `TraefikIngressHighErrorRate`, `TraefikBackendUnhealthy`, `OpenStudioTraefikConfigReloadFailed`, `OpenStudioIngressNoHealthyBackend`, `OpenStudioIngressHigh404Ratio`.

Validate all required OpenStudio alert rules (ingress + periodic watchdog/sweeper):

```bash
./scripts/check-prometheus-openstudio-rules.sh --prometheus-url http://<prometheus-host>:9090
```

---

## High-scale worker rollout guardrails (5k+ workers)

Use the staged procedure in
[`openstack-staged-rollout-runbook.md`](./openstack-staged-rollout-runbook.md),
including the **runtime discovery canary-first** gate before worker expansion.

Recommended high-scale worker update controls:

- `worker_update_canary=25`
- `worker_update_max_parallel=100`
- `worker_update_stagger="15s"`
- `worker_update_auto_promote=false`
- `worker_update_auto_revert=true`

Required observability signals during rollout:

- Deployment health: `nomad job deployments <job>-worker`
- Allocation stability: failed/unhealthy alloc rate, restart bursts
- Startup guardrails: `wait_for_deps_timeout`, `*_runtime_resolve_failed`
- Control-plane stress indicators: Consul 429 / template failure recurrences

Rollback path:

1. `nomad job scale <job>-worker 0`
2. `nomad job revert <job>-worker 0` (optional fast rollback)
3. `nomad-pack run --name <job> -var-file <previous-verified-vars> packs/openstudio-server`

---

## Incident Response Runbooks

Use these runbooks for production incident diagnosis and recovery:

- [runbooks/queue-stall.md](./runbooks/queue-stall.md) — diagnose queue growth, identify
  bad worker versions, clear stale `analysis_zip.lock` files, drain old worker
  allocations safely, and validate recovery.

## Further Reading

- [Nomad Pack documentation](https://developer.hashicorp.com/nomad/tools/nomad-pack)
- [Nomad documentation](https://developer.hashicorp.com/nomad/docs)
- [Consul documentation](https://developer.hashicorp.com/consul/docs)
- [Vault documentation](https://developer.hashicorp.com/vault/docs)
- [OpenStudio Server (upstream)](https://github.com/NREL/openstudio-server)

## Incident Post-Mortems

- [2026-08-03 Incident B — Worker Image-Cache Sentinel Failure (32k-DP run)](post-mortem-2026-08-03-b.md)
