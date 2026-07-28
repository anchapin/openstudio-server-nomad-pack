# openstudio-server-nomad-pack

A [Nomad Pack](https://github.com/hashicorp/nomad-pack) for deploying [OpenStudio Server](https://github.com/NREL/openstudio-server) to [HashiCorp Nomad](https://www.nomadproject.io/) clusters. This pack is designed as a lighter-weight alternative to the Kubernetes Helm chart.

## Prerequisites

- **Nomad Cluster**: A running Nomad cluster (v1.0+) with the Docker task driver enabled.
- **Consul**: A Consul cluster integrated with Nomad for service discovery and DNS resolution.
- **Vault** (Optional): A Vault cluster integrated with Nomad for secrets management.
- **Nomad Pack**: The `nomad-pack` CLI installed locally.

## Getting Started

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

## Configuration Variables

Refer to [`variables.hcl`](file:///Users/achapin/OpenStudio/openstudio-server-nomad-pack/variables.hcl) for the list of configuration parameters and defaults.

## Pack Metadata

- Root pack metadata: [`metadata.hcl`](./metadata.hcl)
- Pack-scoped metadata: [`packs/openstudio-server/metadata.hcl`](./packs/openstudio-server/metadata.hcl)

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `job_name` | `string` | The name of the Nomad job | `"openstudio-server"` |
| `app_version` | `string` | Version tag for OpenStudio Server components | `"latest"` |
| `mongodb_storage_type` | `string` | Nomad volume type for MongoDB persistence (`host`, `csi`, or `ephemeral`) | `"host"` |
| `mongodb_volume_source` | `string` | Nomad volume source name for MongoDB data | `"openstudio-mongodb"` |
| `worker_min_replicas` | `number` | Minimum worker replica count | `1` |
| `worker_max_replicas` | `number` | Maximum worker replica count | `3` |
| `vault_integration_enabled` | `bool` | Enable Nomad Vault stanzas in tasks | `false` |
| `ingress_domain` | `string` | Domain suffix for ingress/service hostnames | `"service.consul"` |
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
| `mongodb_storage_type` | `string` | MongoDB storage type (`ephemeral`, `host`, `csi`) | `"ephemeral"` |
| `mongodb_host_volume` | `string` | Host volume name for MongoDB when `mongodb_storage_type=host` | `"openstudio-mongodb"` |
| `mongodb_csi_volume` | `string` | CSI volume ID for MongoDB when `mongodb_storage_type=csi` | `"openstudio-mongodb"` |
| `redis_image` | `string` | Redis image | `"redis:6.2-alpine"` |
| `redis_storage_type` | `string` | Redis storage type (`ephemeral`, `host`, `csi`) | `"ephemeral"` |
| `redis_host_volume` | `string` | Host volume name for Redis when `redis_storage_type=host` | `"openstudio-redis"` |
| `redis_csi_volume` | `string` | CSI volume ID for Redis when `redis_storage_type=csi` | `"openstudio-redis"` |
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
- `templates/batch-verification.nomad.tpl`: Optional batch connectivity verification job.
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
| ServiceAccount / RBAC | Nomad ACLs / Vault Roles | Planned |
| Helm Hooks | Nomad Lifecycle hooks / Periodic Jobs | Implemented (poststop cleanup tasks) |

## Stateful DB/Redis Storage

By default, MongoDB and Redis run with `ephemeral` storage. To persist data, set each service to `host` or `csi`:

- `mongodb_storage_type`: `host` or `csi`
- `redis_storage_type`: `host` or `csi`

Then set the matching volume name/ID via `mongodb_host_volume`/`mongodb_csi_volume` and `redis_host_volume`/`redis_csi_volume`.

## Consul Service Checks

The pack registers Consul service checks for datastore and API telemetry:

- `openstudio-db`: TCP check on MongoDB (`27017`)
- `openstudio-redis`: TCP check on Redis (`6379`)
- `openstudio-rserve`: TCP check on RServe (`6311`)
- `openstudio-web`: multi-check health telemetry:
  - TCP socket check on port `8080`
  - HTTP liveness check on `/up`
  - HTTP readiness check on `/`

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

## Vault Role Authorization

When `vault_enabled` is `true`, this pack renders task-level Nomad `vault` blocks so Nomad can request Vault tokens automatically using configured roles.

- Use `vault_default_role` to apply one role to all tasks.
- Override specific tasks with `vault_db_role`, `vault_redis_role`, `vault_rserve_role`, and `vault_vector_role`.
- Optionally set `vault_policies`, `vault_namespace`, `vault_change_mode`, `vault_change_signal`, and `vault_env` to control token behavior.

## License

This project is dual-licensed under either MIT or BSD-3-Clause. See:

- [LICENSE](LICENSE)
- [LICENSE-MIT](LICENSE-MIT)
- [LICENSE-BSD-3-CLAUSE](LICENSE-BSD-3-CLAUSE)
