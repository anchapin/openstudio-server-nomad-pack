# openstudio-server-nomad-pack

A [Nomad Pack](https://github.com/hashicorp/nomad-pack) for deploying [OpenStudio Server](https://github.com/NREL/openstudio-server) to [HashiCorp Nomad](https://www.nomadproject.io/) clusters. This pack is designed as a lighter-weight alternative to the Kubernetes Helm chart.

## Prerequisites

- **Nomad Cluster**: A running Nomad cluster (v1.4.0+) with the Docker task driver enabled.
- **Consul**: A Consul cluster integrated with Nomad for service discovery and DNS resolution.
- **Vault** (Optional): A Vault cluster integrated with Nomad for secrets management.
- **Nomad Pack**: The `nomad-pack` CLI installed locally.
- **Traefik** (Optional): A [Traefik](https://doc.traefik.io/traefik/providers/consul-catalog/) instance configured with the Consul Catalog provider is required for HTTP ingress to the web task group. Traefik automatically discovers routes via the Consul service tags added by this pack. Set `ingress_domain` to your desired hostname and enable `ingress_tls_enabled` for HTTPS.

## Getting Started

For a complete step-by-step walkthrough — including prerequisites, Nomad + Consul agent config, host volume setup, deploy commands, service verification, and common errors — see **[docs/getting-started-single-node.md](./docs/getting-started-single-node.md)**.

For supported version combinations across the pack, OpenStudio Server, Nomad, and Consul, see **[docs/compatibility.md](./docs/compatibility.md)**.

Quick start (assumes Nomad and Consul are already running):

1. Ensure your Nomad cluster is running and Consul is active.
2. Render and run the pack:
   ```bash
   nomad-pack render .
   nomad-pack run .
   ```

The pack renders a dedicated Nomad job for each service component:

| Job | Template | Conditional |
|---|---|---|
| `<job_name>-web` | `web.nomad.tpl` | always |
| `<job_name>-worker` | `worker.nomad.tpl` | always |
| `<job_name>-db` | `db.nomad.tpl` | always (MongoDB, Consul: `openstudio-db`) |
| `<job_name>-redis` | `redis.nomad.tpl` | always (Consul: `openstudio-redis`) |
| `<job_name>-rserve` | `rserve.nomad.tpl` | always (Consul: `openstudio-rserve`) |
| `<job_name>-system-hooks` | `system-hooks.nomad.tpl` | `enable_image_prepull = true` (default) |
| `<job_name>-state-backup` | `state-backup.nomad.tpl` | `backup_enabled = true` (default) |
| `<job_name>-state-restore` | `state-restore.nomad.tpl` | `restore_enabled = true` (default) |
| `<job_name>-test` | `openstudio_test.nomad.tpl` | always |
| `<job_name>-autoscaler` | `nomad-autoscaler.nomad.tpl` | `nomad_autoscaler_enabled = true` |
| `<job_name>-batch-verify` | `batch-verification.nomad.tpl` | `enable_batch_verification = true` |
| `<job_name>-traefik` | `traefik.nomad.tpl` | `deploy_traefik = true` |

`templates/openstudio-server.nomad.tpl` is an architecture marker file that renders no job — it documents the split-job design.

## Deployment Checklist (Preflight)

Before your first `nomad-pack run`, confirm:

- [ ] Nomad cluster and Consul integration are healthy
- [ ] Persistent storage prerequisites are in place (`host_volume` or CSI)
- [ ] If `worker_autoscaling_enabled = true`: Nomad Autoscaler is deployed and running

## Pack Registry Layout Scaffold

This repository now includes the registry-aligned pack at:

- `packs/openstudio-server/metadata.hcl`
- `packs/openstudio-server/README.md`
- `packs/openstudio-server/variables.hcl`
- `packs/openstudio-server/outputs.tpl`
- `packs/openstudio-server/templates/*`

## Local Integration Testing (Vagrant + Consul/Nomad/Vault)

This repository includes a local multi-VM playground for validating Nomad Pack changes against a real micro-cluster.

### Prerequisites

- Vagrant
- VirtualBox (or another provider compatible with this `Vagrantfile`)

### Bring up the environment

```bash
vagrant up
```

This creates:

- `consul` (`192.168.56.10`) running a Consul server + UI
- `nomad-server` (`192.168.56.11`) running a Nomad server
- `nomad-client` (`192.168.56.12`) running a Nomad client with Docker
- `vault` (`192.168.56.13`) running Vault in dev mode (`root` token)

### Smoke checks

```bash
vagrant ssh consul -c "consul members"
vagrant ssh nomad-server -c "nomad server members"
vagrant ssh nomad-client -c "nomad node status"
vagrant ssh vault -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault status"
```

### Tear down

```bash
vagrant destroy -f
```

## CI Validation

GitHub Actions validation includes:

| Workflow | Trigger | What it checks |
|---|---|---|
| `pack-validation.yml` | push to `develop` or `main`, PR to `develop` or `main`, `workflow_dispatch` | fmt, render (default + batch-verification), validate, `examples/test-batch.nomad` job spec validation, Vagrantfile syntax, script syntax, version-bump tests, `variables.md` diff, README → `docs/variables.md` reference, `compatibility.md` version gate, Nomad dev-agent plan for all example var-files, `packs/` registry sync, integration test script |
| `acl-policy-validation.yml` | push/PR to `develop` or `main` on `policies/**` or `scripts/apply-acl-policies.sh` changes | `nomad fmt -check policies/` |
| `integration-test.yml` | PR to `develop` (path-filtered: `templates/**`, `variables.hcl`, `packs/**`, `scripts/**`, `examples/**`, `metadata.hcl`) | template render + e2e stack test against live Consul/Nomad dev agents |
| `release-version-bump.yml` | push to `main` | **Step 1:** auto-bumps patch version in `metadata.hcl`, commits, and pushes a `v*` git tag — triggers `release.yml` |
| `release.yml` | push of tag matching `v*` | **Step 2:** reads version from `metadata.hcl`, publishes GitHub Release with auto-generated notes |

The `pack-validation.yml` workflow runs on **push to `develop` or `main`** and on **pull requests targeting `develop` or `main`**. The `integration-test.yml` workflow runs on **pull requests targeting `develop`** only when template or variable files change.

## Startup Dependency Checks

The `web` task group includes a `prestart` init task that blocks web container startup until both backing services are registered as healthy in Consul:

- `openstudio-db`
- `openstudio-redis`

## Persistent Storage

By default, MongoDB and Redis use **host volumes** (`db_storage_type = "host_volume"`, `redis_storage_type = "host_volume"`), ensuring data survives container restarts and rescheduling. Set either to `"ephemeral"` to disable persistent volume wiring (useful for throwaway CI environments).

### MongoDB and Redis storage types

| Value | Nomad volume type | Notes |
|---|---|---|
| `host_volume` (default) | `host` | Volume must be pre-declared in each Nomad client agent config |
| `csi` | `csi` | CSI plugin must be deployed as a system job before use |
| `ephemeral` | — | No volume wired; data lost on allocation stop or reschedule |

**Pre-provisioning host volumes** (add to each Nomad client `client.hcl`):

```hcl
host_volume "openstudio-mongodb" {
  path      = "/var/lib/nomad/volumes/mongodb"
  read_only = false
}

host_volume "openstudio-redis" {
  path      = "/var/lib/nomad/volumes/redis"
  read_only = false
}
```

Create the directories on each node:

```bash
sudo mkdir -p /var/lib/nomad/volumes/mongodb /var/lib/nomad/volumes/redis
```

**Pre-provisioning CSI volumes** (example using the `nfs` CSI plugin):

```bash
nomad volume create mongodb-csi.hcl
nomad volume create redis-csi.hcl
```

### NFS shared volume (web and worker)

Enable the shared NFS volume for simulation input/output by setting `nfs_shared_volume_enabled = true`.
The recommended approach is an OS-level NFS mount registered as a Nomad `host_volume`, then
pointing `nfs_volume_source` at that host volume name.

```hcl
# override.hcl
nfs_shared_volume_enabled = true
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"
```

See **[docs/storage.md](./docs/storage.md#5-nfs-shared-volume-web-and-worker)** for the full setup:
`/etc/fstab`, `client.hcl` `host_volume`, override values, single-node skip guidance, and advanced
CSI NFS option.



## Configuration Variables

A full variable reference — including types, defaults, example override values, and notes on
variable interactions — is available in **[docs/variables.md](./docs/variables.md)**.

Annotated `override.hcl` files for common deployment scenarios are in the [`examples/`](./examples/) directory:

| File | Use case |
|---|---|
| [`examples/minimal-dev.hcl`](./examples/minimal-dev.hcl) | Single-node, minimal resources, ephemeral storage — CI and local dev |
| [`examples/production-ha.hcl`](./examples/production-ha.hcl) | Multi-datacenter, HA resources, Vault enabled |
| [`examples/airgapped.hcl`](./examples/airgapped.hcl) | Private registry image overrides, no Vault |

The raw variable declarations and defaults live in [`variables.hcl`](./variables.hcl).

## Pack Metadata

- Root pack metadata: [`metadata.hcl`](./metadata.hcl)
- Pack-scoped metadata: [`packs/openstudio-server/metadata.hcl`](./packs/openstudio-server/metadata.hcl)
- Keep both metadata files synchronized when pack metadata changes.

> **Variable reference:** All configurable variables — types, defaults, and descriptions — are
> documented in **[docs/variables.md](./docs/variables.md)** (auto-generated from `variables.hcl`
> by `scripts/generate-vars-doc.sh`). Do not maintain a duplicate table here;
> `variables.hcl` is the sole source of truth.

## Vault MongoDB Secret Mapping

When `enable_vault_mongo_secrets` is enabled, the MongoDB task renders a Nomad template from Vault and maps secret values into:

- `MONGO_INITDB_ROOT_USERNAME`
- `MONGO_INITDB_ROOT_PASSWORD`

## Scheduling Helpers

`templates/_helpers.tpl` defines reusable scheduling helpers for `constraint`, `affinity`, and `spread` stanzas.  
To target host environments, set group-level scheduling inputs, for example:

```hcl
db_constraints = [
  {
    attribute = "${attr.kernel.name}"
    operator  = "="
    value     = "linux"
  }
]

redis_affinities = [
  {
    attribute = "${attr.cpu.arch}"
    operator  = "="
    value     = "amd64"
    weight    = 80
  }
]
```

## Included Job Templates

- `templates/openstudio-server.nomad.tpl`: **Architecture marker file — renders no job.** Documents the split-job design; the previous monolithic job has been removed (fix #223).
- `templates/web.nomad.tpl`: Web application service (`<job_name>-web`, Consul: `openstudio-web`) on `web_port`.
- `templates/worker.nomad.tpl`: Resque worker job (`<job_name>-worker`) with rolling deploys, Nomad Autoscaler scaling, and optional Vector sidecar.
- `templates/db.nomad.tpl`: MongoDB service (`<job_name>-db`, Consul: `openstudio-db`) on port `27017`.
- `templates/redis.nomad.tpl`: Redis cache service (`<job_name>-redis`, Consul: `openstudio-redis`) on port `6379`.
- `templates/rserve.nomad.tpl`: Rserve service (`<job_name>-rserve`, Consul: `openstudio-rserve`) on port `6311`.
- `templates/system-hooks.nomad.tpl`: System job that pre-pulls all service images on every eligible node (`enable_image_prepull = true`, default).
- `templates/state-backup.nomad.tpl`: Periodic batch job (`<job_name>-state-backup`) that runs `mongodump` + Redis backup on `backup_cron` schedule (`backup_enabled = true`, default).
- `templates/state-restore.nomad.tpl`: On-demand parameterized batch job (`<job_name>-state-restore`) for manual restore dispatch (`restore_enabled = true`, default).
- `templates/openstudio_test.nomad.tpl`: Parameterized batch test job (`<job_name>-test`) for post-deploy service validation (always rendered).
- `templates/traefik.nomad.tpl`: Optional Traefik ingress job (`<job_name>-traefik`), enabled by `deploy_traefik = true`.
- `templates/nomad-autoscaler.nomad.tpl`: Optional Nomad Autoscaler daemon job stub (`<job_name>-autoscaler`), enabled by `nomad_autoscaler_enabled = true`.
- `templates/batch-verification.nomad.tpl`: Optional batch connectivity verification job (`<job_name>-batch-verify`), enabled by `enable_batch_verification = true`.

## Worker Scaling Configuration

The worker job (`<job_name>-worker`) supports two scaling models:

### Rolling Deploys

The `update` stanza ensures zero-downtime upgrades by rolling through allocations one at a time:

| Variable | Default | Description |
|---|---|---|
| `worker_update_max_parallel` | `1` | Number of allocations replaced simultaneously |
| `worker_update_health_check` | `"task_states"` | Health check mode for promotion |
| `worker_update_min_healthy_time` | `"30s"` | Time allocation must stay healthy before promotion |
| `worker_update_healthy_deadline` | `"5m"` | Max time for an allocation to become healthy |
| `worker_update_progress_deadline` | `"10m"` | Max time for the full rollout to progress |
| `worker_update_auto_revert` | `true` | Revert deployment if rollout fails |

### Nomad Autoscaler Integration

> [!IMPORTANT]
> **Prerequisite: Nomad Autoscaler daemon must already be deployed.**  
> Nomad silently ignores worker `scaling` blocks when the Autoscaler daemon is not running.  
> Recommended path: deploy the [official Nomad Autoscaler pack](https://developer.hashicorp.com/nomad/tools/autoscaling/deployment/nomad) before enabling worker autoscaling.

Set `worker_autoscaling_enabled = true` to activate worker scaling policies:

| Variable | Default | Description |
|---|---|---|
| `worker_autoscaling_enabled` | `false` | Enable/disable the `scaling` block |
| `worker_autoscaling_cpu_enabled` | `true` | Enable the built-in `nomad-apm` CPU check (`check "cpu-utilization"`); uses `source = "nomad-apm"` — **no external Prometheus required** |
| `worker_cpu_target_utilization` | `50` | Target worker CPU utilization % for the `nomad-apm` avg_cpu check; mirrors Helm HPA `targetCPUUtilizationPercentage: 50` |
| `nomad_autoscaler_enabled` | `false` | Render optional autoscaler daemon stub (`templates/nomad-autoscaler.nomad.tpl`) |
| `worker_min_replicas` | `1` | Minimum worker allocations |
| `worker_max_replicas` | `10` | Maximum worker allocations |
| `autoscaler_cooldown` | `"60m"` | Cooldown between scaling decisions |
| `autoscaler_prometheus_address` | `"http://prometheus:9090"` | Prometheus URL for the Autoscaler plugin (only required for PromQL queue-depth checks) |
| `worker_queue_requeued_query` | see vars | PromQL for the `requeued` queue depth |
| `worker_queue_simulations_query` | see vars | PromQL for the `simulations` queue depth |

> [!NOTE]
> **CPU check uses `nomad-apm` — no Prometheus needed.** When `worker_autoscaling_cpu_enabled = true`, the pack configures a `check "cpu-utilization"` block with `source = "nomad-apm"` and a `target-value` strategy at `worker_cpu_target_utilization` (default `50`). This is a built-in Nomad Autoscaler APM driver that reads directly from the Nomad API — no external metrics stack is required. The default of `50` mirrors the Helm chart's `targetCPUUtilizationPercentage: 50` HPA setting.
>
> The optional autoscaler stub is preconfigured with `nomad-apm` as the default APM source and includes a commented Prometheus block you can enable if you want PromQL-based queue-depth checks.

### Vector Sidecar

Set `enable_vector_collection = true` to ship worker allocation logs to a Vector pipeline. The sidecar starts before the worker task (`lifecycle { hook = "prestart" sidecar = true }`) and tails all allocation logs from `/alloc/logs/*.std*`.
## Backup and Restore Batch Jobs

This pack now includes:

- **Periodic backup job**: `<job_name>-state-backup`
  - Runs on `backup_cron`
  - Writes MongoDB and Redis snapshots into `backup_volume_source`
  - Cleans up old files based on `backup_retention_days`
- **Parameterized restore job**: `<job_name>-state-restore`
  - On-demand dispatch using backup file names from the backup directory
  - Restores MongoDB from `mongodump` archive
  - Restores Redis from serialized key dump

### Restore Dispatch Example

```bash
nomad job dispatch \
  -meta MONGO_BACKUP_FILE=mongo-20260728T060000Z.archive.gz \
  -meta REDIS_BACKUP_FILE=redis-20260728T060000Z.dump.tsv \
  openstudio-server-state-restore
```

## Consul Connect mTLS Service Mesh

When `enable_consul_connect = true`, the pack configures Consul Connect sidecar proxies for:
- `openstudio-db` on port `27017`
- `openstudio-redis` on port `6379`
- `openstudio-rserve` on port `6311`

These sidecars enforce mutual TLS for service-to-service traffic through the Connect mesh.

## Nomad ACL Policies

Pre-built ACL policy HCL files are provided in the [`policies/`](./policies/) directory. Apply them with `nomad acl policy apply` before deploying the pack on an ACL-enabled cluster.

| File | Role | Use When |
| --- | --- | --- |
| [`policies/operator.hcl`](./policies/operator.hcl) | Full deploy/stop/read | Cluster operators running `nomad-pack run/stop` and inspecting logs |
| [`policies/readonly.hcl`](./policies/readonly.hcl) | Read-only status & logs | Monitoring dashboards, support staff, and observability tools |
| [`policies/cicd.hcl`](./policies/cicd.hcl) | Minimal CI/CD service token | Automated pipelines that render, plan, run, and stop jobs |

### Applying a Policy

Replace `<policy-name>` and `<file>` with the desired values:

```sh
nomad acl policy apply \
  -name operator \
  -description "OpenStudio Server operator role" \
  - < policies/operator.hcl
```

Policies default to the `default` namespace, which matches the pack's `nomad_namespace` default. If you deployed to a custom namespace, update the namespace labels before applying:

```sh
sed -i 's/namespace "default"/namespace "my-namespace"/g' policies/*.hcl
# macOS: sed -i '' 's/namespace "default"/namespace "my-namespace"/g' policies/*.hcl
```

Or use the helper script: `bash scripts/apply-acl-policies.sh --namespace my-namespace`

For full instructions — including token creation, namespace scoping, and token rotation — see **[docs/acl-policies.md](./docs/acl-policies.md)**.

## Helm to Nomad Parity & Differences

| Kubernetes / Helm | Nomad Equivalent | Status |
| --- | --- | --- |
| Helm chart | Nomad Pack | ✅ Implemented |
| `values.yaml` | `variables.hcl` | ✅ Implemented |
| Deployment/Pod | Job & Task Groups | ✅ Implemented (Web, DB, Redis, Worker, Rserve) |
| Container | Task (`docker` driver) | ✅ Implemented |
| Service | Consul `service` registration | ✅ Implemented |
| HPA / KEDA ScaledObject | Nomad Autoscaler | Implemented (Worker, Prometheus target-value checks) |
| StorageClass / PVC | Nomad CSI volumes / `host_volume` | Implemented (DB/Redis) |
| ServiceAccount / RBAC | Nomad ACLs / Vault Roles | Implemented |
| Helm Hooks (pre-delete / teardown) | `scripts/pre-teardown.sh` — blocking `nomad job stop` (no sleep required) | Implemented |
| Helm Hooks (lifecycle / periodic) | Nomad Lifecycle hooks / Periodic Jobs | Implemented (poststop cleanup tasks) |

### Intentional Divergences from Helm Chart Defaults

The following defaults differ from the [NREL OpenStudio Server Helm chart](https://github.com/NREL/openstudio-server) by design. Operators migrating from Helm should review each entry and decide whether to align or keep the divergence.

| Variable | This Pack Default | Helm Default | Reason | When to align |
|----------|-------------------|--------------|--------|---------------|
| `worker_cpu` | `2000` (MHz) | `700m` CPU (≈ 700 MHz) | Intentionally higher to support greater simulation concurrency per Nomad allocation; Nomad schedules whole CPU shares rather than fractional Kubernetes millicores. | Set to `700` only if running on a severely resource-constrained cluster where worker placement is failing. |
| `worker_memory` | `4096` MB | `900Mi` (≈ 900 MB) | Intentionally higher to match the typical memory footprint of OpenStudio/EnergyPlus simulations running inside a single allocation; the Helm default targets container overhead only. | Reduce only after profiling actual simulation memory usage in your environment. |
| `redis_image` | `redis:6.2-alpine` | `redis:6.0.9` | Redis 6.2 receives active security patches and bug fixes; `alpine` reduces the image size. Redis 6.0.9 is end-of-life upstream. | Align to `redis:6.0.9` only if your OpenStudio Server release explicitly requires Redis 6.0.x and you have verified compatibility concerns with 6.2. |

## Stateful DB/Redis Storage

By default, MongoDB and Redis use `host_volume` storage. To change the persistence mode, set `db_storage_type` and `redis_storage_type` to `host_volume`, `csi`, or `ephemeral`. Set `db_volume_source` and `redis_volume_source` to the corresponding host_volume name or CSI volume ID.

See the [Persistent Storage](#persistent-storage) section above for pre-provisioning instructions.

## Consul Service Checks

The pack registers Consul service checks for datastore and API telemetry:

- `openstudio-db`: TCP check on MongoDB (`27017`)
- `openstudio-redis`: TCP check on Redis (`6379`)
- `openstudio-rserve`: TCP check on RServe (`6311`)
- `openstudio-web`: multi-check health telemetry:
  - TCP socket check on port `8080`
  - HTTP liveness check on `/up`
  - HTTP readiness check on `/`
- `openstudio-worker`: script check (`pgrep -f resque`) — confirms at least one Resque process is running in the allocation

## Batch Verification Checks

This pack includes an optional batch job template (`templates/batch-verification.nomad.tpl`) for connectivity checks across core services.

- Runs ICMP ping and TCP socket checks per target.
- Emits metric-style log lines:
  - `batch_verification_result ...`
  - `batch_verification_summary ...`
- Exits non-zero if any target is unreachable.

Run it with:

```bash
nomad-pack run -var "enable_batch_verification=true" .
```

Or with:

```bash
./scripts/run-batch-verification.sh
```

## Running Tests

The pack ships `templates/openstudio_test.nomad.tpl`, a `batch` + `parameterized` job that validates the full OpenStudio Server stack after deployment — the Nomad equivalent of a Helm test pod.

### What it checks

| Task | Check type | Target |
|------|-----------|--------|
| `web-http-check` | HTTP (`curl`) | `openstudio-web.service.consul:<test_web_port>/` |
| `redis-tcp-check` | TCP (`nc -z`) | `openstudio-redis.service.consul:<test_redis_port>` |
| `mongo-tcp-check` | TCP (`nc -z`) | `openstudio-db.service.consul:<test_mongo_port>` |
| `rserve-tcp-check` | TCP (`nc -z`) | `openstudio-rserve.service.consul:<test_rserve_port>` |

All four tasks must exit `0` for the job to succeed. The job uses `reschedule { attempts = 0 }` and `restart { attempts = 0 mode = "fail" }` for clear pass/fail semantics with no automatic retries.

### Dispatch

Render and register the test job alongside your deployment, then dispatch it:

```bash
# Render and run pack (test job is always included)
nomad-pack run .

# Dispatch the parameterized test job
nomad job dispatch openstudio-server-test

# Optionally override the per-check timeout (seconds)
nomad job dispatch -meta TEST_TIMEOUT=30 openstudio-server-test

# Tail logs for a specific check task
nomad alloc logs <alloc-id> web-http-check
nomad alloc logs <alloc-id> redis-tcp-check
```

### Overriding defaults

| Variable | Default | Description |
|----------|---------|-------------|
| `test_web_port` | `80` | Web HTTP check port |
| `test_redis_port` | `6379` | Redis TCP check port |
| `test_mongo_port` | `27017` | MongoDB TCP check port |
| `test_rserve_port` | `6311` | RServe TCP check port |
| `test_timeout_seconds` | `10` | Per-check timeout (seconds) |
| `test_retry_count` | `3` | curl retry count for web check |
| `test_curl_image_tag` | `latest` | Tag for `curlimages/curl` image |
| `test_busybox_image_tag` | `stable` | Tag for `busybox` image |

```bash
nomad-pack run -var "test_timeout_seconds=30" -var "test_web_port=8080" .
```

## Vault Integration

When `vault_integration_enabled` is `true`, every task group receives a `vault` block and a `template` stanza that securely injects credentials via Nomad's `secrets/env` mechanism. This replaces the plaintext fallback variables with dynamic secrets fetched from HashiCorp Vault KV v2.

### What gets injected

| Secret | Vault path variable | Env var rendered |
|--------|---------------------|-----------------|
| MongoDB password | `vault_kv_mongodb_path` | `MONGO_PASSWORD` |
| Redis password | `vault_kv_redis_path` | `REDIS_PASSWORD` |
| App secret key | `vault_kv_app_path` | `APP_SECRET_KEY_BASE` |

### Quick start

1. Write secrets to Vault:

```bash
vault kv put secret/openstudio/mongodb password="<strong-password>"
vault kv put secret/openstudio/redis    password="<strong-password>"
vault kv put secret/openstudio/app      secret_key_base="<hex-secret>"
```

2. Create a Vault policy:

```hcl
# openstudio-server.hcl
path "secret/data/openstudio/*" {
  capabilities = ["read"]
}
path "secret/metadata/openstudio/*" {
  capabilities = ["read", "list"]
}
```

```bash
vault policy write openstudio-server openstudio-server.hcl
```

3. Enable in the pack:

```bash
nomad-pack run \
  -var "vault_integration_enabled=true" \
  -var "vault_policy=openstudio-server" \
  .
```

### Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `vault_integration_enabled` | `false` | Toggle Vault secrets integration on or off |
| `vault_policy` | `"openstudio-server"` | Vault policy name attached to all task tokens |
| `vault_kv_mongodb_path` | `"secret/data/openstudio/mongodb"` | KV v2 path for MongoDB credentials |
| `vault_kv_redis_path` | `"secret/data/openstudio/redis"` | KV v2 path for Redis credentials |
| `vault_kv_app_path` | `"secret/data/openstudio/app"` | KV v2 path for application secrets |
| `mongo_password` | `""` | Plaintext MongoDB password (used when `vault_integration_enabled=false`) |
| `redis_password` | `""` | Plaintext Redis password (used when `vault_integration_enabled=false`) |
| `app_secret_key_base` | `""` | Plaintext app secret key base (used when `vault_integration_enabled=false`) |

When `vault_integration_enabled` is `false` (default), the `mongo_password`, `redis_password`, and `app_secret_key_base` variables are injected as plaintext environment variables. This preserves backwards-compatible behaviour for development deployments.

> **Requirements:** Nomad ≥ 1.1 with Vault integration enabled in the Nomad server config, and Vault ≥ 1.9 with KV v2 secrets engine. See [docs/vault-policies.md](./docs/vault-policies.md) for full setup guidance.

## Vault Role Authorization

When `vault_enabled` is `true`, this pack renders task-level Nomad `vault` blocks so Nomad can request Vault tokens automatically using configured roles.

- Use `vault_default_role` to apply one role to all tasks.
- Override specific tasks with `vault_db_role`, `vault_redis_role`, `vault_rserve_role`, and `vault_vector_role`.
- Optionally set `vault_policies`, `vault_namespace`, `vault_change_mode`, `vault_change_signal`, and `vault_env` to control token behavior.

For full setup instructions — including Vault policy HCL, KV v2 path conventions, Nomad ↔ Vault integration configuration, token TTL guidance, and both legacy and Nomad ≥ 1.7 `vault` block syntax — see **[docs/vault-policies.md](./docs/vault-policies.md)**.

## Migrating from Kubernetes

Teams running OpenStudio Server on Kubernetes via the [NREL Helm chart](https://github.com/NREL/openstudio-server) can follow the step-by-step guide in **[docs/migration-k8s-to-nomad.md](./docs/migration-k8s-to-nomad.md)**, which covers:

- Pre-migration checklist (data backups, Consul service name mapping, network prerequisites)
- Helm `values.yaml` → Nomad Pack variable mapping table
- MongoDB (`mongodump`/`mongorestore`) and Redis persistence migration procedures
- Post-migration smoke-test commands for all six services
- Rollback procedure (keeping the Kubernetes deployment scaled-down during migration)
- Known differences between Kubernetes and Nomad (service discovery, RBAC, storage, etc.)

## Documentation

All operational guides live in the [`docs/`](./docs/) directory. The
**[Operations Guide](./docs/operations-guide.md)** is the recommended starting point — it links
every topic with a brief description of what each guide covers.

| Guide | Description |
|-------|-------------|
| [Operations Guide](./docs/operations-guide.md) | Master index: topology diagram, deployment checklist, and links to all guides |
| [Getting Started: Single-Node Walkthrough](./docs/getting-started-single-node.md) | Zero-to-running on a developer laptop (macOS or Linux) |
| [Storage Preparation](./docs/storage.md) | CSI plugins, host volumes, permissions, and teardown |
| [Variable Reference](./docs/variables.md) | All pack variables with types, defaults, and override examples |
| [Nomad ACL Policy Setup](./docs/acl-policies.md) | Operator, read-only, and CI/CD role policies |
| [Vault Policy Setup](./docs/vault-policies.md) | Vault integration, KV v2 paths, and token TTL guidance |
| [Kubernetes-to-Nomad Migration](./docs/migration-k8s-to-nomad.md) | Helm chart migration checklist, data migration, rollback |

## Contributing

See **[CONTRIBUTING.md](./CONTRIBUTING.md)** for branch strategy, local testing steps,
PR process, changelog guidelines, and release instructions.

## License

This project is dual-licensed under either MIT or BSD-3-Clause. See:

- [LICENSE](LICENSE)
- [LICENSE-MIT](LICENSE-MIT)
- [LICENSE-BSD-3-CLAUSE](LICENSE-BSD-3-CLAUSE)
