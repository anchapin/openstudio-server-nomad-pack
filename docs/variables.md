# Variable Reference

> **Source of truth:** [`variables.hcl`](../variables.hcl)  
> All defaults listed here are taken directly from that file. If the table and `variables.hcl` ever disagree, `variables.hcl` wins.

## Table of Contents

1. [Core / Identity](#core--identity)
2. [Images](#images)
3. [Web](#web)
4. [Worker](#worker)
5. [Worker Autoscaling](#worker-autoscaling)
6. [MongoDB (DB)](#mongodb-db)
7. [Redis](#redis)
8. [Rserve](#rserve)
9. [Logging](#logging)
10. [Vector Sidecar](#vector-sidecar)
11. [Consul Connect](#consul-connect)
12. [Vault Integration](#vault-integration)
13. [Vault-Backed MongoDB Secrets](#vault-backed-mongodb-secrets)
14. [Docker Runtime Hardening](#docker-runtime-hardening)
15. [Scheduling Helpers](#scheduling-helpers)
16. [Backup & Restore](#backup--restore)
17. [Batch Verification](#batch-verification)
18. [Variable Interactions](#variable-interactions)

---

## Core / Identity

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `job_name` | `string` | `"openstudio-server"` | The name of the Nomad job. | `"openstudio-server-prod"` |
| `app_version` | `string` | `"latest"` | Application version tag used for OpenStudio Server component images. | `"3.7.0"` |
| `region` | `string` | `"global"` | The Nomad region where the job will be deployed. | `"us-east-1"` |
| `datacenters` | `list(string)` | `["dc1"]` | A list of datacenters in the region eligible for task placement. | `["dc1","dc2","dc3"]` |
| `ingress_domain` | `string` | `"service.consul"` | Domain suffix used when constructing service hostnames. | `"internal.example.com"` |

---

## Images

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `web_image` | `string` | `"nrel/openstudio-server:latest"` | Docker image for the OpenStudio Server web container. | `"registry.internal/openstudio-server:3.7.0"` |
| `web_background_image` | `string` | `"nrel/openstudio-server:latest"` | Docker image for the OpenStudio Server web-background container. | `"registry.internal/openstudio-server:3.7.0"` |
| `worker_image` | `string` | `"nrel/openstudio-server:latest"` | Docker image for the OpenStudio Server worker container. | `"registry.internal/openstudio-server:3.7.0"` |
| `db_image` | `string` | `"mongo:4.2"` | MongoDB image. | `"registry.internal/mongo:4.2"` |
| `redis_image` | `string` | `"redis:6.2-alpine"` | Redis image. | `"registry.internal/redis:6.2-alpine"` |
| `rserve_image` | `string` | `"nrel/openstudio-rserve:latest"` | Rserve image. | `"registry.internal/openstudio-rserve:latest"` |
| `vector_image` | `string` | `"timberio/vector:0.30.0-alpine"` | Vector log-collector sidecar image. | `"registry.internal/vector:0.30.0-alpine"` |
| `poststop_cleanup_image` | `string` | `"alpine:3.20"` | Image used by poststop cleanup lifecycle tasks. | `"registry.internal/alpine:3.20"` |
| `verification_image` | `string` | `"busybox:1.36"` | Image used for batch connectivity verification checks. | `"registry.internal/busybox:1.36"` |

---

## Web

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `web_priority` | `number` | `80` | Nomad job priority for the OpenStudio Web UI job. | `90` |
| `web_cpu` | `number` | `500` | CPU shares allocated to the OpenStudio Web task. | `1000` |
| `web_memory` | `number` | `1024` | Memory (MB) allocated to the OpenStudio Web task. | `2048` |
| `web_background_count` | `number` | `1` | Number of web-background tasks to run. | `2` |

---

## Worker

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `worker_count` | `number` | `1` | Number of Nomad worker task group allocations. See [Variable Interactions](#variable-interactions). | `4` |
| `worker_priority` | `number` | `40` | Nomad job priority for calculation workers. | `60` |
| `worker_cpu` | `number` | `2000` | CPU shares allocated to the OpenStudio worker task. | `4000` |
| `worker_memory` | `number` | `4096` | Memory (MB) allocated to the OpenStudio worker task. | `8192` |
| `worker_queues` | `string` | `"requeued,simulations"` | Comma-separated queue list processed by worker tasks. | `"requeued,simulations,batch"` |
| `worker_process_count` | `string` | `"1"` | `COUNT` environment variable passed to worker containers. | `"2"` |
| `worker_update_max_parallel` | `number` | `1` | Maximum number of worker allocations updated in parallel during rolling updates. | `2` |
| `worker_update_health_check` | `string` | `"task_states"` | Health check mode for worker rolling updates (`task_states` or `checks`). | `"checks"` |
| `worker_update_min_healthy_time` | `string` | `"30s"` | How long a worker allocation must remain healthy before promotion. | `"1m"` |
| `worker_update_healthy_deadline` | `string` | `"5m"` | Maximum time for a worker allocation to become healthy. | `"10m"` |
| `worker_update_progress_deadline` | `string` | `"10m"` | Maximum time for the worker rolling update to make progress. | `"20m"` |
| `worker_update_auto_revert` | `bool` | `true` | Automatically revert a worker deployment if the update fails. | `false` |

---

## Worker Autoscaling

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `worker_autoscaling_enabled` | `bool` | `true` | Enable autoscaling for the worker task group. See [Variable Interactions](#variable-interactions). | `false` |
| `worker_autoscaling_min` | `number` | `1` | Minimum worker allocations when autoscaling is enabled. | `2` |
| `worker_autoscaling_max` | `number` | `10` | Maximum worker allocations when autoscaling is enabled. | `20` |
| `worker_autoscaling_cooldown` | `string` | `"2m"` | Cooldown duration between worker autoscaling actions. | `"5m"` |
| `worker_queue_requeued_query` | `string` | `"sum(openstudio_worker_queue_depth{queue=\"requeued\"})"` | Prometheus query for requeued queue backlog depth. | Custom PromQL |
| `worker_queue_requeued_target` | `number` | `1` | Target requeued queue depth per worker allocation. | `2` |
| `worker_queue_simulations_query` | `string` | `"sum(openstudio_worker_queue_depth{queue=\"simulations\"})"` | Prometheus query for simulations queue backlog depth. | Custom PromQL |
| `worker_queue_simulations_target` | `number` | `5` | Target simulations queue depth per worker allocation. | `10` |

---

## MongoDB (DB)

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `db_cpu` | `number` | `500` | CPU shares allocated to the MongoDB task. | `1000` |
| `db_memory` | `number` | `1024` | Memory (MB) allocated to the MongoDB task. | `4096` |
| `db_health_check_interval` | `string` | `"10s"` | Interval between Consul health checks for the MongoDB service. | `"30s"` |
| `db_health_check_timeout` | `string` | `"2s"` | Timeout for Consul health checks for the MongoDB service. | `"5s"` |
| `mongodb_storage_type` | `string` | `"ephemeral"` | MongoDB storage type: `ephemeral`, `host`, or `csi`. Use `host` or `csi` for persistent data. | `"host"` |
| `mongodb_host_volume` | `string` | `"openstudio-mongodb"` | Nomad client `host_volume` name for MongoDB when `mongodb_storage_type = "host"`. | `"mongo-data-vol"` |
| `mongodb_csi_volume` | `string` | `"openstudio-mongodb"` | Nomad CSI volume ID for MongoDB when `mongodb_storage_type = "csi"`. | `"mongo-csi-vol"` |
| `mongodb_backup_uri` | `string` | `"mongodb://openstudio-db.service.consul:27017"` | MongoDB connection URI used by backup and restore jobs. | `"mongodb://user:pass@mongo.internal:27017"` |

---

## Redis

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `redis_cpu` | `number` | `250` | CPU shares allocated to the Redis task. | `500` |
| `redis_memory` | `number` | `512` | Memory (MB) allocated to the Redis task. | `1024` |
| `redis_storage_type` | `string` | `"ephemeral"` | Redis storage type: `ephemeral`, `host`, or `csi`. | `"host"` |
| `redis_host_volume` | `string` | `"openstudio-redis"` | Nomad client `host_volume` name for Redis when `redis_storage_type = "host"`. | `"redis-data-vol"` |
| `redis_csi_volume` | `string` | `"openstudio-redis"` | Nomad CSI volume ID for Redis when `redis_storage_type = "csi"`. | `"redis-csi-vol"` |
| `redis_health_check_interval` | `string` | `"10s"` | Interval between Consul health checks for the Redis service. | `"30s"` |
| `redis_health_check_timeout` | `string` | `"2s"` | Timeout for Consul health checks for the Redis service. | `"5s"` |
| `redis_backup_host` | `string` | `"openstudio-redis.service.consul"` | Redis hostname used by backup and restore jobs. | `"redis.internal"` |
| `redis_backup_port` | `number` | `6379` | Redis port used by backup and restore jobs. | `6380` |

---

## Rserve

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `rserve_cpu` | `number` | `500` | CPU shares allocated to the Rserve task. | `1000` |
| `rserve_memory` | `number` | `1024` | Memory (MB) allocated to the Rserve task. | `2048` |
| `rserve_health_check_interval` | `string` | `"10s"` | Interval between Consul health checks for the Rserve service. | `"30s"` |
| `rserve_health_check_timeout` | `string` | `"2s"` | Timeout for Consul health checks for the Rserve service. | `"5s"` |

---

## Logging

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `log_driver_type` | `string` | `"json-file"` | The Docker logging driver for all containers. | `"journald"` |
| `log_max_size` | `string` | `"10m"` | Maximum size of log files before rotation. | `"50m"` |
| `log_max_files` | `number` | `3` | Maximum number of rotated log files to retain. | `5` |

---

## Vector Sidecar

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `enable_vector_collection` | `bool` | `true` | Enable Vector sidecar for log collection and forwarding. | `false` |

---

## Consul Connect

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `enable_consul_connect` | `bool` | `false` | Enable Consul Connect sidecar proxies for mTLS service-to-service communication. | `true` |

---

## Vault Integration

> **See also:** [docs/vault-policies.md](./vault-policies.md) for full setup instructions.

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `vault_integration_enabled` | `bool` | `false` | Enable Nomad Vault integration stanzas for tasks. | `true` |
| `vault_enabled` | `bool` | `false` | Enable task-level Vault role authorization blocks in Nomad tasks. | `true` |
| `vault_default_role` | `string` | `""` | Default Vault role for all tasks when no task-specific role is set. | `"openstudio-server"` |
| `vault_db_role` | `string` | `""` | Vault role override for the MongoDB task. | `"openstudio-db"` |
| `vault_redis_role` | `string` | `""` | Vault role override for the Redis task. | `"openstudio-redis"` |
| `vault_rserve_role` | `string` | `""` | Vault role override for the Rserve task. | `"openstudio-rserve"` |
| `vault_vector_role` | `string` | `""` | Vault role override for Vector sidecar tasks. | `"openstudio-vector"` |
| `vault_policies` | `list(string)` | `[]` | Additional Vault policies to attach to Nomad-issued Vault tokens. | `["openstudio-kv-read"]` |
| `vault_namespace` | `string` | `""` | Vault Enterprise namespace for task token requests. | `"engineering/openstudio"` |
| `vault_change_mode` | `string` | `"restart"` | How tasks react to Vault token or secret changes (`restart`, `noop`, or `signal`). | `"signal"` |
| `vault_change_signal` | `string` | `"SIGHUP"` | Signal sent to tasks when `vault_change_mode = "signal"`. | `"SIGUSR1"` |
| `vault_env` | `bool` | `true` | Expose Vault token to tasks as environment variables. | `false` |

---

## Vault-Backed MongoDB Secrets

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `enable_vault_mongo_secrets` | `bool` | `false` | Enable dynamic MongoDB credential mapping from Vault into MongoDB task environment variables. See [Variable Interactions](#variable-interactions). | `true` |
| `vault_mongo_secret_path` | `string` | `"secret/data/openstudio/mongodb"` | Vault KV v2 path containing MongoDB credentials. | `"secret/data/prod/openstudio/mongodb"` |
| `vault_mongo_username_key` | `string` | `"username"` | Key in the Vault secret data payload containing the MongoDB username. | `"mongo_user"` |
| `vault_mongo_password_key` | `string` | `"password"` | Key in the Vault secret data payload containing the MongoDB password. | `"mongo_pass"` |

---

## Docker Runtime Hardening

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `docker_user` | `string` | `"1000:1000"` | UID:GID used to run containers (non-root). | `"1001:1001"` |
| `docker_readonly_rootfs` | `bool` | `true` | Enable Docker read-only root filesystem for all containers. | `false` |
| `docker_cap_drop` | `list(string)` | `["ALL"]` | Linux capabilities dropped from Docker containers. | `["NET_RAW","SYS_ADMIN"]` |
| `poststop_cleanup_paths` | `list(string)` | `["/alloc/tmp/analysis", "/alloc/tmp/openstudio/analysis"]` | Directories removed by poststop cleanup lifecycle tasks when allocations stop. | `["/alloc/tmp/analysis"]` |

---

## Scheduling Helpers

These variables accept Nomad `constraint`, `affinity`, and `spread` stanza objects.  
Each entry is a map with the fields accepted by the corresponding Nomad stanza type.

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `db_constraints` | `any` | `[]` | Placement constraints for the `db` task group. | See example below |
| `db_affinities` | `any` | `[]` | Placement affinities for the `db` task group. | See example below |
| `db_spreads` | `any` | `[]` | Spread rules for the `db` task group. | See example below |
| `redis_constraints` | `any` | `[]` | Placement constraints for the `redis` task group. | See example below |
| `redis_affinities` | `any` | `[]` | Placement affinities for the `redis` task group. | See example below |
| `redis_spreads` | `any` | `[]` | Spread rules for the `redis` task group. | See example below |
| `rserve_constraints` | `any` | `[]` | Placement constraints for the `rserve` task group. | See example below |
| `rserve_affinities` | `any` | `[]` | Placement affinities for the `rserve` task group. | See example below |
| `rserve_spreads` | `any` | `[]` | Spread rules for the `rserve` task group. | See example below |

**Example:**

```hcl
db_constraints = [
  { attribute = "${attr.kernel.name}", operator = "=", value = "linux" }
]

db_affinities = [
  { attribute = "${meta.storage_tier}", operator = "=", value = "ssd", weight = 100 }
]

db_spreads = [
  { attribute = "${node.datacenter}", weight = 100 }
]
```

---

## Backup & Restore

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `backup_enabled` | `bool` | `true` | Enable the periodic MongoDB and Redis backup batch job. | `false` |
| `backup_cron` | `string` | `"0 2 * * * *"` | Nomad/cron expression for the periodic backup schedule (6-field: second-first). | `"0 0 1 * * *"` |
| `backup_prohibit_overlap` | `bool` | `true` | Prevent overlapping backup runs. | `false` |
| `backup_nfs_host_volume` | `string` | `"openstudio-backups"` | Nomad host volume name backed by an NFS mount for state backups. | `"nfs-backups"` |
| `backup_mount_path` | `string` | `"/backups"` | Path inside backup tasks where the NFS host volume is mounted. | `"/mnt/backups"` |
| `backup_subdirectory` | `string` | `"openstudio-state"` | Subdirectory under the backup mount where OpenStudio state backups are written. | `"prod/openstudio-state"` |
| `backup_retention_days` | `number` | `14` | Number of days of backup files to retain before deletion. | `30` |
| `restore_enabled` | `bool` | `true` | Enable the on-demand parameterized restore batch job definition. | `false` |

---

## Batch Verification

| Variable | Type | Default | Description | Example Override |
|---|---|---|---|---|
| `enable_batch_verification` | `bool` | `false` | Enable standalone batch connectivity verification job. | `true` |
| `verification_targets` | `list(string)` | `["db=openstudio-db.service.consul:27017","redis=openstudio-redis.service.consul:6379","rserve=openstudio-rserve.service.consul:6311"]` | Connectivity targets in `component=host:port` format. | See example below |

**Example:**

```hcl
enable_batch_verification = true
verification_targets = [
  "db=openstudio-db.service.consul:27017",
  "redis=openstudio-redis.service.consul:6379",
  "rserve=openstudio-rserve.service.consul:6311",
]
```

---

## Variable Interactions

### `worker_count` vs. `worker_autoscaling_enabled`

`worker_count` sets the **static** desired count when `worker_autoscaling_enabled = false`.  
When `worker_autoscaling_enabled = true`, the Nomad Autoscaler policy takes ownership of
the count — `worker_count` serves only as the initial allocation seed and `worker_autoscaling_min`
/ `worker_autoscaling_max` become the binding limits. Setting `worker_count` higher than
`worker_autoscaling_max` results in the autoscaler immediately scaling down.

```
worker_autoscaling_enabled = false  →  worker_count is the fixed allocation count
worker_autoscaling_enabled = true   →  worker_autoscaling_min ≤ actual count ≤ worker_autoscaling_max
```

### `vault_integration_enabled` vs. `vault_enabled`

These two variables serve related but distinct purposes:

| Variable | Effect |
|---|---|
| `vault_integration_enabled` | Adds Vault `token` / `change_mode` stanzas for environment-variable-based token injection. |
| `vault_enabled` | Adds Nomad `vault { role = "..." }` blocks for role-based token acquisition (Nomad ≥ 1.4 style). |

For most modern clusters, enable both. Enabling only `vault_enabled` is sufficient for Nomad ≥ 1.7.

### `enable_vault_mongo_secrets` and plaintext credential variables

When `enable_vault_mongo_secrets = true`, the MongoDB task renders a Nomad `template` block that
pulls `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD` directly from Vault at the
path specified by `vault_mongo_secret_path`. **Do not** hardcode credentials anywhere else in the
pack variables when this feature is active — use Vault as the single source of truth.

This feature requires `vault_integration_enabled = true` (or `vault_enabled = true`) to be set so
that Nomad tasks have a valid Vault token.

### `mongodb_storage_type` / `redis_storage_type` and matching volume variables

Setting the storage type to `host` or `csi` requires the corresponding volume variable to be set:

| Storage type | MongoDB variable | Redis variable |
|---|---|---|
| `host` | `mongodb_host_volume` | `redis_host_volume` |
| `csi` | `mongodb_csi_volume` | `redis_csi_volume` |
| `ephemeral` | *(none required)* | *(none required)* |

The volume must already exist on the Nomad clients before deploying the pack.
