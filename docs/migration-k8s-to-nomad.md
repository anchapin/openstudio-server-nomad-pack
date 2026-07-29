# Kubernetes-to-Nomad Migration Guide

This guide helps teams currently running **OpenStudio Server** on Kubernetes via the
[NREL openstudio-server Helm chart](https://github.com/NREL/openstudio-server) migrate to this
Nomad Pack. Follow the steps below to safely migrate workloads, persistent data, and configuration
with minimal downtime.

---

## Table of Contents

1. [Pre-Migration Checklist](#1-pre-migration-checklist)
2. [Helm → Nomad Pack Variable Mapping](#2-helm--nomad-pack-variable-mapping)
3. [MongoDB Data Migration](#3-mongodb-data-migration)
4. [Redis Persistence Migration](#4-redis-persistence-migration)
5. [Deploying the Nomad Pack](#5-deploying-the-nomad-pack)
6. [Post-Migration Smoke Tests](#6-post-migration-smoke-tests)
7. [Rollback Procedure](#7-rollback-procedure)
8. [Known Differences](#8-known-differences)

---

## 1. Pre-Migration Checklist

Complete every item below before starting data migration.

### 1.1 Data Backups

#### MongoDB (`mongodump`)

```bash
# Run inside the MongoDB pod or via a sidecar
MONGO_POD=$(kubectl get pod -n openstudio -l app=openstudio-mongo -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n openstudio "$MONGO_POD" -- \
  mongodump \
    --host 127.0.0.1:27017 \
    --out /tmp/mongo-backup

# Copy the dump out of the cluster
kubectl cp "openstudio/${MONGO_POD}:/tmp/mongo-backup" ./mongo-backup
```

> **Tip:** If MongoDB uses authentication, add `--username` / `--password` / `--authenticationDatabase admin`.

#### Redis (RDB / AOF)

```bash
REDIS_POD=$(kubectl get pod -n openstudio -l app=openstudio-redis -o jsonpath='{.items[0].metadata.name}')

# Trigger a synchronous save and copy the RDB file
kubectl exec -n openstudio "$REDIS_POD" -- redis-cli BGSAVE
kubectl cp "openstudio/${REDIS_POD}:/data/dump.rdb" ./redis-dump.rdb

# If AOF is enabled, copy the AOF file as well
kubectl cp "openstudio/${REDIS_POD}:/data/appendonly.aof" ./appendonly.aof 2>/dev/null || true
```

### 1.2 Consul Service Name Mapping

The table below maps Kubernetes Service names (from the Helm chart) to the Consul service names
registered by this Nomad Pack.

| Kubernetes Service name      | Consul service name             | Port  |
|------------------------------|---------------------------------|-------|
| `openstudio-mongo`           | `openstudio-db`                 | 27017 |
| `openstudio-redis`           | `openstudio-redis`              | 6379  |
| `openstudio-rserve`          | `openstudio-rserve`             | 6311  |
| `openstudio-server-web`      | `openstudio-web`                | 8080  |
| `openstudio-server-worker`   | *(internal; no separate check)* | —     |

> Applications that resolve `openstudio-mongo` via kube-dns must be reconfigured to use
> `openstudio-db.service.consul`.

### 1.3 Image Registry Access Verification

```bash
# On each Nomad client, verify Docker can pull the exact images this pack deploys by default
docker pull nrel/openstudio-server:3.11.0
docker pull mongo:6.0.7
docker pull redis:6.2-alpine
docker pull nrel/openstudio-rserve:3.11.0
```

If you deploy with an override file (recommended), verify pulls against the **rendered** image set
instead of assuming defaults:

```bash
# Print the exact image tags that will be deployed
nomad-pack render -var-file=override.hcl . \
  | awk -F'"' '/image = "/ {print $2}' \
  | sort -u

# Pull the exact rendered tags on each Nomad client
for image in $(nomad-pack render -var-file=override.hcl . | awk -F'"' '/image = "/ {print $2}' | sort -u); do
  docker pull "$image"
done
```

Ensure private registries are authenticated (see `docker_user` variable and Nomad `docker_auth`
configuration).

### 1.4 Network Prerequisites

- **Consul agent** must be running on every Nomad client node and joined to the Consul cluster.
- **CNI plugins** (`bridge`, `loopback`, and optionally `consul-cni`) must be installed on every
  Nomad client if `enable_consul_connect = true`.
- Nomad clients must be able to resolve `*.service.consul` DNS names (typically via
  `/etc/resolv.conf` pointing to the Consul DNS port, default `8600`).
- Nomad host volumes (or a CSI driver) must be provisioned before deploying the pack.

---

## 2. Helm → Nomad Pack Variable Mapping

The table below maps common `values.yaml` keys from the NREL Helm chart to their equivalent
Nomad Pack variable names (`variables.hcl`).

| Helm `values.yaml` key                        | Nomad Pack variable              | Notes |
|-----------------------------------------------|----------------------------------|-------|
| `replicaCount` (workers)                      | `worker_count`                   | Static count; for autoscaling use `worker_autoscaling_enabled` |
| `autoscaling.minReplicas`                      | `worker_autoscaling_min`         | |
| `autoscaling.maxReplicas`                      | `worker_autoscaling_max`         | |
| `image.repository` + `image.tag` (web)        | `web_image`                      | Full `repo:tag` string |
| `image.repository` + `image.tag` (worker)     | `worker_image`                   | Full `repo:tag` string |
| `mongodb.image`                                | `db_image`                       | |
| `redis.image`                                  | `redis_image`                    | |
| `rserve.image`                                 | `rserve_image`                   | |
| `resources.requests.cpu` (web)                | `web_cpu`                        | MHz in Nomad; e.g. `500` |
| `resources.requests.memory` (web)             | `web_memory`                     | MiB in Nomad; e.g. `1024` |
| `resources.requests.cpu` (worker)             | `worker_cpu`                     | |
| `resources.requests.memory` (worker)          | `worker_memory`                  | |
| `resources.requests.cpu` (mongo)              | `db_cpu`                         | |
| `resources.requests.memory` (mongo)           | `db_memory`                      | |
| `resources.requests.cpu` (redis)              | `redis_cpu`                      | |
| `resources.requests.memory` (redis)           | `redis_memory`                   | |
| `persistence.storageClass` (mongo)            | `db_storage_type`           | `host_volume` or `csi` |
| `persistence.existingClaim` / PVC name (mongo)| `db_volume_source`          | |
| `persistence.storageClass` (redis)            | `redis_storage_type`             | `host_volume` or `csi` |
| `persistence.existingClaim` / PVC name (redis)| `redis_volume_source`            | |
| `configmaps/nfs-cm.yaml`                      | OS-level NFS mount options on Nomad clients | Configure in `/etc/fstab` or a systemd `.mount` unit; no Consul KV, Nomad `template`, or extra ConfigMap |
| `ingress.hosts[0].host`                       | `ingress_domain`                 | |
| `nameOverride` / `fullnameOverride`           | `job_name`                       | |
| `appVersion` / `image.tag`                    | `app_version`                    | |
| `worker.queues`                               | `worker_queues`                  | List of queue names |
| `worker.processCount`                         | `worker_process_count`           | |
| N/A (Vault not in Helm chart)                 | `vault_enabled`, `vault_default_role`, etc. | See [docs/vault-policies.md](./vault-policies.md) |

---

## 3. MongoDB Data Migration

### 3.1 Prepare the Nomad Host Volume or CSI Volume

**Host volume example** (`/etc/nomad.d/client.hcl` on the Nomad client):

```hcl
host_volume "openstudio-mongodb" {
  path      = "/opt/nomad/volumes/mongodb"
  read_only = false
}
```

Create the directory and set permissions:

```bash
sudo mkdir -p /opt/nomad/volumes/mongodb
sudo chown -R 999:999 /opt/nomad/volumes/mongodb  # UID/GID for the mongo image
```

**CSI volume example** (register before deploying the pack):

```hcl
# mongodb-csi-volume.hcl
id        = "openstudio-mongodb"
name      = "openstudio-mongodb"
type      = "csi"
plugin_id = "your-csi-plugin"

capacity_min = "10GiB"
capacity_max = "50GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
```

```bash
nomad volume create mongodb-csi-volume.hcl
```

### 3.2 Restore the Dump into the Volume

Mount the volume on the Nomad client and run `mongorestore` directly, or deploy a temporary Nomad
batch job.

**Direct restore on the Nomad client** (host volume):

```bash
# Copy the backup to the host volume path
scp -r ./mongo-backup nomad-client:/opt/nomad/volumes/mongodb/mongo-backup

# Run mongorestore via Docker, mounting the same host volume
docker run --rm \
  -v /opt/nomad/volumes/mongodb:/data \
  mongo:6 \
  mongorestore --dir /data/mongo-backup --drop
```

**Nomad batch job restore** (works with both `host_volume` and `csi`):

```hcl
job "openstudio-mongo-restore" {
  type = "batch"

  group "restore" {
    volume "mongodb" {
      type   = "host"          # or "csi"
      source = "openstudio-mongodb"
    }

    task "mongorestore" {
      driver = "docker"

      config {
        image   = "mongo:6"
        command = "mongorestore"
        args    = ["--dir", "/data/mongo-backup", "--drop"]
      }

      volume_mount {
        volume      = "mongodb"
        destination = "/data"
      }

      # The backup directory must already exist inside the volume
      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
```

```bash
# Upload backup into the volume before running the restore job
# Then:
nomad job run openstudio-mongo-restore.hcl
nomad job status openstudio-mongo-restore
```

---

## 4. Redis Persistence Migration

### 4.1 Prepare the Redis Volume

Follow the same host volume or CSI procedure as MongoDB (section 3.1), substituting paths and
ownership for the Redis user (UID `999` in the official Redis image).

### 4.2 Copy the RDB / AOF File

**Host volume:**

```bash
scp ./redis-dump.rdb nomad-client:/opt/nomad/volumes/redis/dump.rdb
# If AOF:
scp ./appendonly.aof nomad-client:/opt/nomad/volumes/redis/appendonly.aof

sudo chown 999:999 /opt/nomad/volumes/redis/dump.rdb
```

**CSI volume:** Use an intermediate copy job similar to the MongoDB batch job pattern, mounting the
CSI volume and writing files via a shell task.

### 4.3 Configure Pack Variables

```hcl
# override.hcl
redis_storage_type  = "host_volume"  # or "csi"
redis_volume_source = "openstudio-redis"
```

Redis will load the RDB file automatically on startup from the mounted volume path.

---

## 5. Deploying the Nomad Pack

Once volumes are provisioned and data is restored:

```bash
# Render to verify template output
nomad-pack render \
  -var-file=override.hcl \
  .

# Deploy
nomad-pack run \
  -var-file=override.hcl \
  .
```

Monitor allocation status:

```bash
nomad job status openstudio-server
nomad alloc logs <alloc-id>
```

---

## 6. Post-Migration Smoke Tests

Verify all six services are healthy after deployment.

```bash
# 1. Check all Nomad allocations are running
nomad job status openstudio-server | grep -E "Running|Complete|Failed"

# 2. Verify Consul service registrations
consul catalog services | sort

# 3. Check health of each registered service
for svc in openstudio-db openstudio-redis openstudio-rserve openstudio-web; do
  echo "=== $svc ==="
  consul health service "$svc" | jq '.[].Checks[].Status'
done

# 4. TCP connectivity checks
nc -zv openstudio-db.service.consul 27017    && echo "MongoDB OK"
nc -zv openstudio-redis.service.consul 6379   && echo "Redis OK"
nc -zv openstudio-rserve.service.consul 6311  && echo "Rserve OK"
nc -zv openstudio-web.service.consul 8080     && echo "Web OK"

# 5. HTTP liveness and readiness
curl -sf http://openstudio-web.service.consul:8080/up  && echo "Liveness OK"
curl -sf http://openstudio-web.service.consul:8080/    && echo "Readiness OK"

# 6. Optional: run the built-in batch verification job
nomad-pack run -var "enable_batch_verification=true" .
nomad job status openstudio-server-batch-verify
```

All six services are healthy when:
- All `consul health service` checks report `"passing"`.
- All TCP checks succeed.
- HTTP `/up` returns `200`.

---

## 7. Rollback Procedure

> **Important:** Keep the Kubernetes deployment **scaled down but not deleted** for the entire
> migration window. Do not delete the Kubernetes namespace or PVCs until the Nomad deployment is
> confirmed healthy and stable.

### 7.1 Scale Down Kubernetes (before migration)

```bash
# Scale all workloads to 0 — do NOT delete
kubectl scale deployment -n openstudio --all --replicas=0
kubectl scale statefulset -n openstudio --all --replicas=0
```

### 7.2 Stop the Nomad Deployment

If post-migration smoke tests fail, immediately stop the Nomad jobs:

```bash
nomad-pack destroy .
# or individually:
nomad job stop -purge openstudio-server
```

### 7.3 Restore the Kubernetes Deployment

Scale the Kubernetes workloads back up:

```bash
kubectl scale deployment -n openstudio --all --replicas=1
kubectl scale statefulset -n openstudio --all --replicas=1

# Verify pods come back healthy
kubectl get pods -n openstudio -w
```

If data was modified after cutover, restore MongoDB from the backup taken in section 1.1 before
scaling up the Kubernetes workloads.

### 7.4 When to Permanently Decommission Kubernetes

Only delete the Kubernetes resources after:
- The Nomad deployment has been running successfully for at least **72 hours**.
- All post-migration smoke tests pass consistently.
- Backups taken from the Nomad environment have been verified.

```bash
# Final cleanup — only when confident
kubectl delete namespace openstudio
```

---

## 8. Known Differences

| Area | Kubernetes (Helm chart) | Nomad Pack | Notes |
|------|------------------------|------------|-------|
| **Service discovery** | kube-dns (`<svc>.<ns>.svc.cluster.local`) | Consul DNS (`<svc>.service.consul`) | Applications must use Consul DNS or Nomad template `{{ range service "..." }}` |
| **Secrets management** | Kubernetes Secrets / external-secrets | Vault (optional) via Nomad task `vault` blocks | See [docs/vault-policies.md](./vault-policies.md) |
| **RBAC** | Kubernetes RBAC (ServiceAccounts, Roles, RoleBindings) | Nomad ACLs + Consul ACLs + Vault policies | No direct equivalent; see [docs/acl-policies.md](./acl-policies.md) |
| **Autoscaling** | HorizontalPodAutoscaler | Nomad Autoscaler (`worker_autoscaling_enabled`) | Requires [Nomad Autoscaler](https://developer.hashicorp.com/nomad/tools/autoscaling) daemon; for Helm Cluster Autoscaler annotation equivalence, see [Cloud node pool autoscaling](./operations-guide.md#cloud-node-pool-autoscaling) |
| **Storage** | PersistentVolumeClaims | Host volumes or CSI volumes | No dynamic provisioning by default with host volumes |
| **Ingress** | Kubernetes Ingress / Ingress Controller | Consul Connect / external load balancer | Configure `ingress_domain` variable |
| **Health checks** | Kubernetes liveness/readiness probes | Consul service checks + Nomad `check_restart` | Managed in pack templates |
| **Rolling updates** | Deployment `rollingUpdate` strategy | Nomad `update` block (`worker_update_*` variables) | |
| **Logging** | stdout → log aggregation sidecar | Nomad `log_driver_type` + optional Vector sidecar | Set `enable_vector_collection = true` for structured log shipping |
| **Lifecycle hooks** | `initContainers`, `postStart`, `preStop` | Nomad `lifecycle` blocks (`prestart`, `poststop`) | |
| **Namespace isolation** | Kubernetes namespaces | Nomad namespaces (optional) | Set via Nomad CLI flag, not a pack variable |
