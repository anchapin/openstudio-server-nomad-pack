# openstudio-server-nomad-pack

A [Nomad Pack](https://github.com/hashicorp/nomad-pack) for deploying [OpenStudio Server](https://github.com/NREL/openstudio-server) to [HashiCorp Nomad](https://www.nomadproject.io/) clusters. This pack is designed as a lighter-weight alternative to the Kubernetes Helm chart.

## Prerequisites

- **Nomad Cluster**: A running Nomad cluster (v1.0+) with the Docker task driver enabled.
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

The pack currently renders separate jobs for:
- `<job_name>-db` (MongoDB, registered in Consul as `openstudio-db`)
- `<job_name>-rserve`
- `<job_name>` (OpenStudio placeholder job with Redis scaffold)

## Deployment Checklist (Preflight)

Before your first `nomad-pack run`, confirm:

- [ ] Nomad cluster and Consul integration are healthy
- [ ] Persistent storage prerequisites are in place (`host_volume` or CSI)
- [ ] If `worker_autoscaling_enabled = true`: Nomad Autoscaler is deployed and running

## Pack Registry Layout Scaffold

This repository now includes the registry-aligned scaffold at:

- `packs/openstudio-server/templates`

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

GitHub Actions validates pull requests targeting `develop` with:

- `nomad-pack fmt -check -recursive .`
- `nomad-pack render .`

## Startup Dependency Checks

The `web` task group includes a `prestart` init task that blocks web container startup until both backing services are registered as healthy in Consul:

- `openstudio-db`
- `openstudio-redis`

## Persistent Storage

By default, MongoDB and Redis use **host volumes** (`mongodb_storage_type = "host_volume"`, `redis_storage_type = "host_volume"`), ensuring data survives container restarts and rescheduling. Set either to `"ephemeral"` to disable persistent volume wiring (useful for throwaway CI environments).

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

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `job_name` | `string` | The name of the Nomad job | `"openstudio-server"` |
| `app_version` | `string` | Version tag for OpenStudio Server components | `"latest"` |
| `nomad_namespace` | `string` | Nomad namespace in which all pack jobs are registered | `"default"` |
| `mongodb_storage_type` | `string` | MongoDB storage type (`host_volume`, `csi`, or `ephemeral`) | `"host_volume"` |
| `mongodb_volume_source` | `string` | Nomad host_volume name or CSI volume ID for MongoDB data | `"openstudio-mongodb"` |
| `redis_storage_type` | `string` | Redis storage type (`host_volume`, `csi`, or `ephemeral`) | `"host_volume"` |
| `redis_volume_source` | `string` | Nomad host_volume name or CSI volume ID for Redis data | `"openstudio-redis"` |
| `nfs_shared_volume_enabled` | `bool` | Enable shared NFS volume in web and worker task groups | `false` |
| `nfs_volume_source` | `string` | Nomad host_volume name (recommended) or CSI volume ID for the NFS shared volume | `"openstudio-nfs"` |
| `nfs_volume_mount_path` | `string` | Mount path for the NFS volume in web and worker tasks | `"/mnt/openstudio"` |
| `worker_min_replicas` | `number` | Minimum worker replica count | `1` |
| `worker_max_replicas` | `number` | Maximum worker replica count | `3` |
| `vault_integration_enabled` | `bool` | Enable Nomad Vault stanzas in tasks | `false` |
| `ingress_domain` | `string` | Hostname for Traefik router rules and service ingress | `"localhost"` |
| `ingress_tls_enabled` | `bool` | When `true`, adds Traefik TLS (`websecure`) router tags to the web service | `false` |
| `region` | `string` | The Nomad region to deploy into | `"global"` |
| `datacenters` | `list(string)` | Eligible datacenters | `["dc1"]` |
| `web_image` | `string` | Docker image for OpenStudio Web | `"nrel/openstudio-server:latest"` |
| `worker_image` | `string` | Docker image for OpenStudio Worker | `"nrel/openstudio-server:latest"` |
| `worker_count` | `number` | Number of Nomad worker allocations | `1` |
| `worker_update_max_parallel` | `number` | Maximum workers updated concurrently | `1` |
| `worker_update_health_check` | `string` | Worker update health check mode | `"task_states"` |
| `worker_update_min_healthy_time` | `string` | Minimum healthy time before worker promotion | `"30s"` |
| `worker_update_healthy_deadline` | `string` | Deadline for worker allocations to become healthy | `"5m"` |
| `worker_update_progress_deadline` | `string` | Deadline for the worker rollout to make progress | `"10m"` |
| `worker_update_auto_revert` | `bool` | Automatically revert failed worker rollout | `true` |
| `worker_priority` | `number` | Nomad priority for calculation workers | `40` |
| `worker_queues` | `string` | Queue list for worker processing | `"requeued,simulations"` |
| `worker_process_count` | `string` | Worker container `COUNT` env value | `"1"` |
| `worker_autoscaling_enabled` | `bool` | Enables worker autoscaling policy | `true` |
| `worker_autoscaling_min` | `number` | Minimum worker allocations under autoscaling | `1` |
| `worker_autoscaling_max` | `number` | Maximum worker allocations under autoscaling | `10` |
| `worker_autoscaling_cooldown` | `string` | Worker autoscaling cooldown duration | `"2m"` |
| `worker_queue_requeued_query` | `string` | Prometheus query for `requeued` queue depth | `"sum(openstudio_worker_queue_depth{queue=\"requeued\"})"` |
| `worker_queue_requeued_target` | `number` | Target value for `requeued` queue depth per allocation | `1` |
| `worker_queue_simulations_query` | `string` | Prometheus query for `simulations` queue depth | `"sum(openstudio_worker_queue_depth{queue=\"simulations\"})"` |
| `worker_queue_simulations_target` | `number` | Target value for `simulations` queue depth per allocation | `5` |
| `web_background_image` | `string` | Docker image for OpenStudio Web-Background | `"nrel/openstudio-server:latest"` |
| `web_background_count` | `number` | Number of Web-Background tasks | `1` |
| `db_image` | `string` | MongoDB image | `"mongo:4.2"` |
| `mongodb_storage_type` | `string` | MongoDB storage type (`host_volume`, `csi`, or `ephemeral`) | `"host_volume"` |
| `mongodb_volume_source` | `string` | host_volume name or CSI volume ID for MongoDB | `"openstudio-mongodb"` |
| `redis_image` | `string` | Redis image | `"redis:6.2-alpine"` |
| `redis_storage_type` | `string` | Redis storage type (`host_volume`, `csi`, or `ephemeral`) | `"host_volume"` |
| `redis_volume_source` | `string` | host_volume name or CSI volume ID for Redis | `"openstudio-redis"` |
| `nfs_shared_volume_enabled` | `bool` | Enable shared NFS volume in web and worker groups | `false` |
| `nfs_volume_source` | `string` | Nomad host_volume name (recommended) or CSI volume ID for the NFS shared volume | `"openstudio-nfs"` |
| `nfs_volume_mount_path` | `string` | Mount path for the NFS volume in web and worker tasks | `"/mnt/openstudio"` |
| `rserve_image` | `string` | Rserve image | `"nrel/rserve:latest"` |
| `enable_vault_mongo_secrets` | `bool` | Enable Vault template rendering for MongoDB credentials. | `false` |
| `vault_mongo_secret_path` | `string` | Vault path containing MongoDB credentials. | `"secret/data/openstudio/mongodb"` |
| `vault_mongo_username_key` | `string` | Vault secret data key for MongoDB username. | `"username"` |
| `vault_mongo_password_key` | `string` | Vault secret data key for MongoDB password. | `"password"` |
| `poststop_cleanup_image` | `string` | Image used by poststop cleanup tasks | `"alpine:3.20"` |
| `poststop_cleanup_paths` | `list(string)` | Directories removed during poststop cleanup | `["/alloc/tmp/analysis", "/alloc/tmp/openstudio/analysis"]` |
| `docker_user` | `string` | Non-root UID:GID used by Docker tasks | `"1000:1000"` |
| `docker_readonly_rootfs` | `bool` | Enables Docker read-only root filesystem | `true` |
| `docker_cap_drop` | `list(string)` | Linux capabilities dropped from Docker tasks | `["ALL"]` |
| `db_constraints` | `any` | Constraint blocks for the `db` group | `[]` |
| `db_affinities` | `any` | Affinity blocks for the `db` group | `[]` |
| `db_spreads` | `any` | Spread blocks for the `db` group | `[]` |
| `redis_constraints` | `any` | Constraint blocks for the `redis` group | `[]` |
| `redis_affinities` | `any` | Affinity blocks for the `redis` group | `[]` |
| `redis_spreads` | `any` | Spread blocks for the `redis` group | `[]` |
| `rserve_constraints` | `any` | Constraint blocks for the `rserve` group | `[]` |
| `rserve_affinities` | `any` | Affinity blocks for the `rserve` group | `[]` |
| `rserve_spreads` | `any` | Spread blocks for the `rserve` group | `[]` |
| `backup_enabled` | `bool` | Enable periodic state backup job | `true` |
| `backup_cron` | `string` | Nomad cron schedule for backup job | `"0 2 * * * *"` |
| `backup_prohibit_overlap` | `bool` | Prevent overlapping backup runs | `true` |
| `backup_nfs_host_volume` | `string` | Host volume name for NFS-backed state backups | `"openstudio-backups"` |
| `backup_mount_path` | `string` | In-container backup mount path | `"/backups"` |
| `backup_subdirectory` | `string` | Subdirectory under backup mount | `"openstudio-state"` |
| `backup_retention_days` | `number` | Backup retention in days | `14` |
| `mongodb_backup_uri` | `string` | MongoDB connection URI for backup/restore jobs | `"mongodb://openstudio-db.service.consul:27017"` |
| `redis_backup_host` | `string` | Redis hostname for backup/restore jobs | `"openstudio-redis.service.consul"` |
| `redis_backup_port` | `number` | Redis port for backup/restore jobs | `6379` |
| `restore_enabled` | `bool` | Enable on-demand state restore job definition | `true` |
| `enable_consul_connect` | `bool` | Enable Consul Connect sidecar proxies for mTLS service-to-service communication | `true` |
| `enable_batch_verification` | `bool` | Enable standalone batch connectivity verification job | `false` |
| `verification_image` | `string` | Image used to run batch verification checks | `"busybox:1.36"` |
| `verification_targets` | `list(string)` | Connectivity targets in `component=host:port` format | `["db=openstudio-db.service.consul:27017","redis=openstudio-redis.service.consul:6379","rserve=openstudio-rserve.service.consul:6311"]` |

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

- `templates/openstudio-server.nomad.tpl`: Core OpenStudio Server scaffolding and MongoDB (`openstudio-db`) service.
- `templates/redis.nomad.tpl`: Redis cache service (`openstudio-redis`) on port `6379`.
- `templates/rserve.nomad.tpl`: Rserve service (`openstudio-rserve`) on port `6311`.
- `templates/worker.nomad.tpl`: Resque worker task group with rolling deploys, Nomad Autoscaler scaling, and optional Vector sidecar.
- `templates/nomad-autoscaler.nomad.tpl`: Optional Nomad Autoscaler daemon job stub (disabled by default).
- `templates/batch-verification.nomad.tpl`: Optional batch connectivity verification job.

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
| `nomad_autoscaler_enabled` | `false` | Render optional autoscaler daemon stub (`templates/nomad-autoscaler.nomad.tpl`) |
| `worker_min_replicas` | `1` | Minimum worker allocations |
| `worker_max_replicas` | `3` | Maximum worker allocations |
| `autoscaler_cooldown` | `"2m"` | Cooldown between scaling decisions |
| `autoscaler_prometheus_address` | `""` | Prometheus URL for the Autoscaler plugin |
| `worker_queue_requeued_query` | see vars | PromQL for the `requeued` queue depth |
| `worker_queue_simulations_query` | see vars | PromQL for the `simulations` queue depth |

The optional autoscaler stub is preconfigured with `nomad-apm` as the default APM source and includes a commented Prometheus block you can enable if you want PromQL-based checks.

### Vector Sidecar

Set `enable_vector_collection = true` to ship worker allocation logs to a Vector pipeline. The sidecar starts before the worker task (`lifecycle { hook = "prestart" sidecar = true }`) and tails all allocation logs from `/alloc/logs/*.std*`.
## Backup and Restore Batch Jobs

This pack now includes:

- **Periodic backup job**: `<job_name>-state-backup`
  - Runs on `backup_cron`
  - Writes MongoDB and Redis snapshots into `backup_nfs_host_volume`
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
| `vault_enabled` | `bool` | Enable task-level Vault role authorization blocks | `false` |
| `vault_default_role` | `string` | Default Vault role for all tasks when no task override is set | `""` |
| `vault_db_role` | `string` | Vault role override for MongoDB task | `""` |
| `vault_redis_role` | `string` | Vault role override for Redis task | `""` |
| `vault_rserve_role` | `string` | Vault role override for Rserve task | `""` |
| `vault_vector_role` | `string` | Vault role override for Vector sidecars | `""` |
| `vault_policies` | `list(string)` | Additional policies to attach to Nomad-issued Vault tokens | `[]` |
| `vault_namespace` | `string` | Vault Enterprise namespace for token requests | `""` |
| `vault_change_mode` | `string` | Token/secret change handling mode (`restart`/`noop`/`signal`) | `"restart"` |
| `vault_change_signal` | `string` | Signal used when `vault_change_mode = "signal"` | `"SIGHUP"` |
| `vault_env` | `bool` | Expose Vault token in task environment | `true` |

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

Policies use the `openstudio` namespace by default. Update the `namespace` block label in the HCL file if your cluster uses a different namespace.

For full instructions — including token creation, namespace scoping, and token rotation — see **[docs/acl-policies.md](./docs/acl-policies.md)**.

## Helm to Nomad Parity & Differences

| Kubernetes / Helm | Nomad Equivalent | Status |
| --- | --- | --- |
| Helm chart | Nomad Pack | Scaffolded |
| `values.yaml` | `variables.hcl` | Scaffolded |
| Deployment/Pod | Job & Task Groups | Scaffolded (Web, DB, Redis, Worker, Rserve) |
| Container | Task (`docker` driver) | Scaffolded |
| Service | Consul `service` registration | Scaffolded |
| HPA / KEDA ScaledObject | Nomad Autoscaler | Implemented (Worker, Prometheus target-value checks) |
| StorageClass / PVC | Nomad CSI volumes / `host_volume` | Implemented (DB/Redis) |
| ServiceAccount / RBAC | Nomad ACLs / Vault Roles | Implemented |
| Helm Hooks | Nomad Lifecycle hooks / Periodic Jobs | Implemented (poststop cleanup tasks) |

## Stateful DB/Redis Storage

By default, MongoDB and Redis use `host_volume` storage. To change the persistence mode, set `mongodb_storage_type` and `redis_storage_type` to `host_volume`, `csi`, or `ephemeral`. Set `mongodb_volume_source` and `redis_volume_source` to the corresponding host_volume name or CSI volume ID.

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
| Helm Hooks | Nomad Lifecycle hooks / Periodic Jobs | Planned |

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

## License

This project is dual-licensed under either MIT or BSD-3-Clause. See:

- [LICENSE](LICENSE)
- [LICENSE-MIT](LICENSE-MIT)
- [LICENSE-BSD-3-CLAUSE](LICENSE-BSD-3-CLAUSE)
