# Storage Preparation Guide

This guide covers everything you need to set up persistent storage for MongoDB and Redis
**before** running `nomad-pack run`. Choose the storage backend that fits your environment:

| Backend | When to use |
|---------|-------------|
| `host_volume` | Single-node dev or small clusters where data lives on a specific node |
| `csi` | Multi-node clusters where allocations may reschedule across nodes |
| `ephemeral` | Throwaway CI environments — no persistence needed |

---

## Table of Contents

1. [Volume Overview](#1-volume-overview)
2. [Host Volumes](#2-host-volumes)
3. [CSI Plugin Setup](#3-csi-plugin-setup)
4. [Persistent Volume Examples](#4-persistent-volume-examples)
5. [NFS Shared Volume (web and worker)](#5-nfs-shared-volume-web-and-worker)
6. [Volume Permissions and Ownership](#6-volume-permissions-and-ownership)
7. [Teardown and Cleanup](#7-teardown-and-cleanup)

---

## 1. Volume Overview

The pack declares two named volumes:

| Volume name | Default storage type | Used by |
|-------------|---------------------|---------|
| `openstudio-mongodb` | `host_volume` | `db` task group (MongoDB) |
| `openstudio-redis` | `host_volume` | `redis` task group (Redis) |

Override via pack variables:

```hcl
# override.hcl
mongodb_storage_type  = "host_volume"   # "host_volume", "csi", or "ephemeral"
mongodb_volume_source = "openstudio-mongodb"

redis_storage_type    = "host_volume"
redis_volume_source   = "openstudio-redis"
```

---

## 2. Host Volumes

Host volumes bind-mount a directory from the Nomad client's filesystem into the container. They
are the simplest option but tie the allocation to the node where the directory exists.

### 2.1 Create the Directories

**macOS** (Docker Desktop):

```bash
mkdir -p ~/nomad-volumes/mongodb ~/nomad-volumes/redis
```

> **macOS note**: Docker Desktop only bind-mounts paths under `/Users` by default. Use home
> directory paths or add the target directory to Docker → Preferences → Resources → File Sharing.

**Linux**:

```bash
sudo mkdir -p /opt/nomad/volumes/mongodb /opt/nomad/volumes/redis
sudo chown -R 999:999 /opt/nomad/volumes/mongodb   # UID 999 = mongodb image user
sudo chown -R 999:999 /opt/nomad/volumes/redis      # UID 999 = redis image user
```

### 2.2 Register the Volumes in the Nomad Client Config

Add a `host_volume` stanza for each volume inside the `client` block of each Nomad client
agent config that should be eligible for these allocations:

**macOS** (`~/nomad-dev.hcl`):

```hcl
client {
  enabled = true

  host_volume "openstudio-mongodb" {
    path      = "/Users/<your-username>/nomad-volumes/mongodb"
    read_only = false
  }

  host_volume "openstudio-redis" {
    path      = "/Users/<your-username>/nomad-volumes/redis"
    read_only = false
  }
}
```

**Linux** (`/etc/nomad.d/client.hcl`):

```hcl
client {
  enabled = true

  host_volume "openstudio-mongodb" {
    path      = "/opt/nomad/volumes/mongodb"
    read_only = false
  }

  host_volume "openstudio-redis" {
    path      = "/opt/nomad/volumes/redis"
    read_only = false
  }
}
```

Reload the Nomad client after editing:

```bash
sudo systemctl reload nomad   # Linux (systemd)
# or send SIGHUP manually:
sudo kill -HUP $(pgrep nomad)
```

### 2.3 Verify the Volumes Are Available

```bash
nomad node status -verbose | grep -A 10 "Host Volumes"
# Expected:
# Host Volumes
# Name                  ReadOnly  Path
# openstudio-mongodb    false     /opt/nomad/volumes/mongodb
# openstudio-redis      false     /opt/nomad/volumes/redis
```

---

## 3. CSI Plugin Setup

CSI volumes let allocations reschedule to any client node. A CSI plugin must be deployed as a
Nomad **system job** before creating volumes.

> **Note:** The exact plugin you use depends on your infrastructure (AWS EBS, NFS, Longhorn, etc.).
> The example below uses the [democratic-csi](https://github.com/democratic-csi/democratic-csi)
> NFS driver as a representative example. Substitute your own plugin ID and configuration.

### 3.1 Deploy the CSI Plugin System Job

```hcl
# csi-plugin.nomad.hcl
job "plugin-nfs" {
  type = "system"

  group "csi" {
    task "plugin" {
      driver = "docker"

      config {
        image   = "democraticcsi/democratic-csi:latest"
        args    = ["--csi-version=1.5.0", "--csi-name=org.democratic-csi.nfs", "--driver-config-file=/config/driver-config.yaml", "--log-level=info", "--csi-mode=node", "--server-socket=/csi-data/csi.sock"]
        privileged = true
        volumes = [
          "/lib/modules:/lib/modules:ro",
          "/proc:/proc",
          "/sys/fs/cgroup:/sys/fs/cgroup:rw",
        ]
      }

      csi_plugin {
        id        = "nfs"
        type      = "node"
        mount_dir = "/csi-data"
      }

      resources {
        cpu    = 500
        memory = 256
      }
    }
  }
}
```

Submit the plugin job:

```bash
nomad job run csi-plugin.nomad.hcl
```

### 3.2 Verify the Plugin Is Healthy

```bash
nomad plugin csi status nfs
# ID        = nfs
# Type      = node
# Nodes Healthy/Expected = 3/3
```

All client nodes should appear healthy before creating volumes.

### 3.3 Register CSI Volumes

Create a volume registration file for each service:

**MongoDB volume** (`mongodb-csi-volume.hcl`):

```hcl
id        = "openstudio-mongodb"
name      = "openstudio-mongodb"
type      = "csi"
plugin_id = "nfs"

capacity_min = "10GiB"
capacity_max = "50GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

mount_options {
  fs_type     = "ext4"
  mount_flags = ["noatime"]
}
```

**Redis volume** (`redis-csi-volume.hcl`):

```hcl
id        = "openstudio-redis"
name      = "openstudio-redis"
type      = "csi"
plugin_id = "nfs"

capacity_min = "1GiB"
capacity_max = "5GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}
```

Register both volumes:

```bash
nomad volume create mongodb-csi-volume.hcl
nomad volume create redis-csi-volume.hcl
```

### 3.4 Verify CSI Volumes Are Available

```bash
nomad volume status
# ID                   Name                  Type  Scope    Size    Write Allocs  Read Allocs
# openstudio-mongodb   openstudio-mongodb    csi   global   10 GiB  0             0
# openstudio-redis     openstudio-redis      csi   global   1 GiB   0             0
```

Set pack variables to use CSI:

```hcl
# override.hcl
mongodb_storage_type  = "csi"
mongodb_volume_source = "openstudio-mongodb"

redis_storage_type    = "csi"
redis_volume_source   = "openstudio-redis"
```

---

## 4. Persistent Volume Examples

### 4.1 MongoDB — Host Volume Wiring

The pack renders the following volume stanza for MongoDB when `mongodb_storage_type = "host_volume"`:

```hcl
volume "mongodb" {
  type      = "host"
  source    = "openstudio-mongodb"
  read_only = false
}
```

The MongoDB task mounts it at `/data/db`:

```hcl
volume_mount {
  volume      = "mongodb"
  destination = "/data/db"
  read_only   = false
}
```

### 4.2 Redis — Host Volume Wiring

```hcl
volume "redis" {
  type      = "host"
  source    = "openstudio-redis"
  read_only = false
}
```

Mounted at `/data` (the Redis image default RDB/AOF path):

```hcl
volume_mount {
  volume      = "redis"
  destination = "/data"
  read_only   = false
}
```

### 4.3 CSI Volume Wiring (MongoDB example)

```hcl
volume "mongodb" {
  type            = "csi"
  source          = "openstudio-mongodb"
  read_only       = false
  attachment_mode = "file-system"
  access_mode     = "single-node-writer"
}
```

### 4.4 Shared NFS Volume Wiring (web/worker)

When `nfs_shared_volume_enabled = true`, the `web` and `worker` task groups mount the volume
identified by `nfs_volume_source` at `nfs_volume_mount_path`.

---

## 5. NFS Shared Volume (web and worker)

> ⚠️ **Web Replica Constraint — `web_count` MUST remain 1**
>
> NFS provides a **shared filesystem**, but it does **not** guarantee POSIX file-locking across
> multiple simultaneous writers. The OpenStudio Server web process writes uploaded analysis
> artefacts directly to the mounted path with no distributed file-locking scheme.
>
> Setting `web_count = 2` (or higher) with a shared NFS volume causes **split-brain**:
> each web allocation has its own isolated view of open file handles, so files written by
> replica A are invisible to requests routed to replica B.
>
> This mirrors the constraint in the upstream Kubernetes Helm chart — `templates/web/web-hpa.yaml`
> sets `maxReplicas: 1` with the comment *"NFS cannot guarantee file locking using multiple
> clients"*.
>
> **To safely raise `web_count` above 1, one of the following must be implemented first:**
> - A distributed lock manager (e.g. [Redlock](https://redis.io/docs/manual/patterns/distributed-locks/) via Redis) wrapping every filesystem operation in the web process, **or**
> - Stateless file handling: move all persistent artefacts to object storage (e.g. S3/MinIO) and
>   eliminate local-disk writes from the request path.
>
> Until then, always keep `web_count = 1` regardless of whether NFS is enabled.

For production clusters, the recommended NFS path is:

1. mount your NFS export at the OS level on every eligible Nomad client
2. register that mount as a Nomad `host_volume`
3. enable `nfs_shared_volume_enabled` in pack overrides

This avoids running an in-cluster NFS server and works with external NFS providers (for example:
AWS EFS, NetApp, a NAS appliance, or a dedicated NFS VM).

### 5.1 Primary Recommendation: OS-level NFS + host_volume

`/etc/fstab` (Linux clients):

```fstab
<nfs-host>:/exports/openstudio /mnt/openstudio nfs nfsvers=4,sync,hard,intr,rsize=65536,wsize=65536,timeo=14 0 0
```

#### 5.1.1 NFS Mount Options (equivalent to Helm `configmaps/nfs-cm.yaml`)

No Consul KV entry, Nomad `template` stanza, or additional ConfigMap is needed — set NFS mount
options directly in `/etc/fstab` (or a systemd `.mount` unit) on each Nomad client.

Recommended options for OpenStudio simulation workloads:

- `nfsvers=4`: Uses NFSv4 for modern locking/session behavior and broad managed-NFS compatibility.
- `sync`: Confirms writes on stable storage to reduce corruption risk for shared run artifacts.
- `hard`: Retries I/O until the NFS server recovers, avoiding silent data loss on transient outages.
- `intr`: Allows interrupted operations so admin actions can stop blocked tasks during incidents.
- `rsize=65536`: Uses larger read requests to improve throughput for large simulation outputs.
- `wsize=65536`: Uses larger write requests to improve throughput for large simulation outputs.
- `timeo=14`: Sets a moderate RPC timeout to balance retry responsiveness and stability.

Equivalent systemd mount unit (`/etc/systemd/system/mnt-openstudio.mount`):

```ini
[Unit]
Description=OpenStudio shared NFS mount
After=network-online.target
Wants=network-online.target

[Mount]
What=<nfs-host>:/exports/openstudio
Where=/mnt/openstudio
Type=nfs
Options=nfsvers=4,sync,hard,intr,rsize=65536,wsize=65536,timeo=14

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-openstudio.mount
```

Nomad client config (`/etc/nomad.d/client.hcl`):

```hcl
client {
  enabled = true

  host_volume "openstudio-nfs" {
    path      = "/mnt/openstudio"
    read_only = false
  }
}
```

Pack override (`override.hcl`):

```hcl
nfs_shared_volume_enabled = true
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"
```

Single-node dev deployments can skip shared NFS entirely because `web` and `worker` can
co-locate on the same client.

For a copy/paste reference file, see
[`examples/volumes/openstudio-shared-host-volume.hcl`](../examples/volumes/openstudio-shared-host-volume.hcl).

### 5.2 Advanced: CSI NFS

If you require CSI-managed lifecycle instead of a host volume, you can still use CSI NFS:

1. deploy a CSI plugin (see [Section 3](#3-csi-plugin-setup))
2. register an NFS-backed CSI volume
3. set `nfs_volume_source` to that CSI volume ID

Example CSI volume registration:

```hcl
id        = "openstudio-nfs"
name      = "openstudio-nfs"
type      = "csi"
plugin_id = "nfs"

capability {
  access_mode     = "multi-node-multi-writer"
  attachment_mode = "file-system"
}
```

---

## 6. Volume Permissions and Ownership

Incorrect ownership is the most common cause of allocation failure with persistent volumes.

| Service | Container UID:GID | Directory permissions |
|---------|------------------|-----------------------|
| MongoDB (`mongo:4.2` – `mongo:7`) | `999:999` | `750` or `755` |
| Redis (`redis:6.2-alpine` – `redis:7`) | `999:999` | `750` or `755` |

### Setting Ownership Before First Deploy

**Linux (host volume):**

```bash
sudo chown -R 999:999 /opt/nomad/volumes/mongodb
sudo chown -R 999:999 /opt/nomad/volumes/redis
sudo chmod 750 /opt/nomad/volumes/mongodb
sudo chmod 750 /opt/nomad/volumes/redis
```

**macOS (host volume via Docker Desktop):**

Docker Desktop runs containers as the Docker daemon user, which handles UID remapping internally.
On macOS you typically do **not** need to pre-set ownership — the Docker volume bind mount is
transparent. If you see `permission denied` errors, verify the path is in the Docker File Sharing
list.

**CSI volumes:**

CSI volumes are initialised by the plugin. If the plugin does not set ownership automatically,
run a one-shot Nomad batch job that `chown`s the mount point before the first deploy:

```hcl
job "openstudio-volume-init" {
  type = "batch"

  group "init-mongodb" {
    volume "mongodb" {
      type            = "csi"
      source          = "openstudio-mongodb"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    task "chown" {
      driver = "docker"
      config {
        image   = "alpine:3.20"
        command = "chown"
        args    = ["-R", "999:999", "/data"]
      }
      volume_mount {
        volume      = "mongodb"
        destination = "/data"
      }
      resources { cpu = 100; memory = 64 }
    }
  }

  group "init-redis" {
    volume "redis" {
      type            = "csi"
      source          = "openstudio-redis"
      read_only       = false
      attachment_mode = "file-system"
      access_mode     = "single-node-writer"
    }

    task "chown" {
      driver = "docker"
      config {
        image   = "alpine:3.20"
        command = "chown"
        args    = ["-R", "999:999", "/data"]
      }
      volume_mount {
        volume      = "redis"
        destination = "/data"
      }
      resources { cpu = 100; memory = 64 }
    }
  }
}
```

```bash
nomad job run openstudio-volume-init.hcl
nomad job status openstudio-volume-init   # wait for status = dead (batch complete)
```

---

## 7. Teardown and Cleanup

### 7.1 Stop the Pack and Purge Jobs

```bash
nomad-pack destroy .
# or:
nomad job stop -purge openstudio-server
```

### 7.2 Remove Host Volume Data

```bash
# macOS
rm -rf ~/nomad-volumes/mongodb ~/nomad-volumes/redis

# Linux
sudo rm -rf /opt/nomad/volumes/mongodb /opt/nomad/volumes/redis
```

> **Warning:** These commands permanently delete all MongoDB and Redis data. Make a backup first
> if the data has any value (see the [migration guide](./migration-k8s-to-nomad.md) for
> `mongodump` instructions).

### 7.3 Delete CSI Volumes

Deregister volumes only after all allocations using them have stopped:

```bash
nomad volume deregister openstudio-mongodb
nomad volume deregister openstudio-redis
```

If the volumes were dynamically provisioned (not just registered), destroy them instead:

```bash
nomad volume delete openstudio-mongodb
nomad volume delete openstudio-redis
```

### 7.4 Remove CSI Plugin (Optional)

If no other workloads use the plugin:

```bash
nomad job stop -purge plugin-nfs
```

Remove the `host_volume` stanzas from your Nomad client config and reload:

```bash
sudo systemctl reload nomad
```

---

## Further Reading

- [Nomad Host Volumes](https://developer.hashicorp.com/nomad/docs/configuration/client#host_volume-stanza)
- [Nomad CSI Volumes](https://developer.hashicorp.com/nomad/docs/other-specifications/volume)
- [Getting Started: Single-Node Walkthrough](./getting-started-single-node.md)
- [Kubernetes-to-Nomad Migration](./migration-k8s-to-nomad.md) — for migrating existing volume data
