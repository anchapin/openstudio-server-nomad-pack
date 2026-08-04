# OpenStack Storage Provisioning Guide

This guide walks operators through provisioning persistent storage on OpenStack **before** running
`nomad-pack run` for the OpenStudio Server pack. It covers both the automated script path and the
equivalent manual CLI steps.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Quick Start (Automated Script)](#2-quick-start-automated-script)
3. [Manual CLI Workflow](#3-manual-cli-workflow)
   - [3.1 Quota and Capacity Checks](#31-quota-and-capacity-checks)
   - [3.2 Manila NFS Share (web + worker shared filesystem)](#32-manila-nfs-share-web--worker-shared-filesystem)
   - [3.3 NFS ACL — Grant Nomad Clients Access](#33-nfs-acl--grant-nomad-clients-access)
   - [3.4 Retrieve and Validate the NFS Export Path](#34-retrieve-and-validate-the-nfs-export-path)
   - [3.5 Cinder Volume for MongoDB](#35-cinder-volume-for-mongodb)
4. [Mounting NFS on Nomad Client Nodes](#4-mounting-nfs-on-nomad-client-nodes)
5. [Registering Storage as Nomad Host Volumes](#5-registering-storage-as-nomad-host-volumes)
6. [Wiring Storage Identifiers into the Pack Var-File](#6-wiring-storage-identifiers-into-the-pack-var-file)
7. [CSI Path: Cinder Block Volume for MongoDB](#7-csi-path-cinder-block-volume-for-mongodb)
8. [ACL and Export Readiness Validation](#8-acl-and-export-readiness-validation)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Prerequisites

### OpenStack CLI

```bash
# Install (Python 3.8+)
pip install python-openstackclient python-manilaclient

# Verify
openstack --version
```

### Authentication

Source your project's OpenRC file **before** running any `openstack` commands or the provisioning
script:

```bash
source ~/openrc.sh       # downloaded from OpenStack Dashboard → API Access
# or export variables manually:
export OS_AUTH_URL=https://keystone.your-cloud.example.com:5000/v3
export OS_PROJECT_NAME=my-project
export OS_USERNAME=my-user
export OS_PASSWORD=my-password
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_REGION_NAME=RegionOne
export OS_IDENTITY_API_VERSION=3
```

Verify authentication:

```bash
openstack token issue
```

### Network Planning

Identify the CIDR of the subnet used by your Nomad client nodes. All three nodes (web, worker, db)
must be able to reach the Manila NFS server and the Cinder volume attachment point.

```bash
openstack subnet list            # find your Nomad client subnet
openstack network show <net-id>  # confirm CIDR
```

---

## 2. Quick Start (Automated Script)

```bash
# Dry-run — prints all commands without executing
./scripts/provision-openstack-storage.sh --dry-run

# Default provisioning (NFS 100 GiB, MongoDB 50 GiB, CIDR 10.0.0.0/24)
./scripts/provision-openstack-storage.sh --cidr 10.0.1.0/24

# Custom sizes
./scripts/provision-openstack-storage.sh \
  --nfs-size 200 \
  --mongodb-size 100 \
  --cidr 10.0.1.0/24

# Skip Cinder if using host_volume for MongoDB (no CSI)
./scripts/provision-openstack-storage.sh --skip-cinder --cidr 10.0.1.0/24
```

The script is idempotent: re-running it on an already-provisioned environment checks existence and
skips creation steps that have already succeeded.

---

## 3. Manual CLI Workflow

### 3.1 Quota and Capacity Checks

Check available Manila (share) quota:

```bash
openstack share quota show --detail
# Look for:
#   gigabytes   <limit>   <in_use>   <reserved>
```

Check available Cinder quota:

```bash
PROJECT_ID=$(openstack token issue -f value -c project_id)
openstack quota show "$PROJECT_ID" | grep -E 'gigabytes|volumes'
```

If quota is insufficient, contact your cloud admin to raise the project limits.

### 3.2 Manila NFS Share (web + worker shared filesystem)

The web and worker tasks share a common filesystem at `/mnt/openstudio` for uploaded analysis
artefacts. This requires a Manila shared filesystem.

**Check if it already exists:**

```bash
openstack share show openstudio-nfs 2>/dev/null && echo "EXISTS" || echo "NOT FOUND"
```

**Create (if not found):**

```bash
openstack share create \
  --name openstudio-nfs \
  --description "OpenStudio Server shared filesystem (web + worker NFS)" \
  NFS 100
```

**Wait for `available` status:**

```bash
watch -n 5 'openstack share show openstudio-nfs -f value -c status'
# Wait until status = available
```

### 3.3 NFS ACL — Grant Nomad Clients Access

Manila uses IP-based access rules to control which clients can mount a share.

**List existing rules:**

```bash
openstack share access list openstudio-nfs
```

**Add your Nomad client CIDR (if not already present):**

```bash
NOMAD_CIDR="10.0.1.0/24"   # replace with your actual subnet CIDR

openstack share access create \
  --access-level rw \
  openstudio-nfs ip "$NOMAD_CIDR"
```

> **Tip:** Use the most specific CIDR possible. Avoid `0.0.0.0/0` in production — it exposes the
> share to all IP addresses on the network.

### 3.4 Retrieve and Validate the NFS Export Path

After the share reaches `available` and the access rule has been applied:

```bash
openstack share show openstudio-nfs -f value -c export_locations
# Output example:
#   [{"id": "...", "path": "10.0.1.5:/shares/share-abc123", "preferred": true}]
```

Extract the path:

```bash
EXPORT_PATH=$(openstack share show openstudio-nfs \
  -f json -c export_locations \
  | python3 -c "
import sys, json
locs = json.load(sys.stdin)['export_locations']
for loc in locs:
    if isinstance(loc, dict) and loc.get('preferred'):
        print(loc['path']); break
else:
    print(locs[0]['path'] if isinstance(locs[0], dict) else locs[0])
")
echo "NFS export path: $EXPORT_PATH"
```

### 3.5 Cinder Volume for MongoDB

The `db` task (MongoDB) requires a dedicated block storage volume for persistence.

> **Note:** If you are using `db_storage_type = "host_volume"` with a local disk path, skip
> this section. Cinder is needed only for `db_storage_type = "csi"` deployments.

**Check if it already exists:**

```bash
openstack volume show openstudio-mongodb 2>/dev/null && echo "EXISTS" || echo "NOT FOUND"
```

**Create:**

```bash
openstack volume create \
  --size 50 \
  --description "OpenStudio Server MongoDB persistent data" \
  openstudio-mongodb
```

**Wait for `available`:**

```bash
watch -n 5 'openstack volume show openstudio-mongodb -f value -c status'
```

**Note the volume ID** — you will need it to register the Nomad CSI volume:

```bash
MONGODB_VOL_ID=$(openstack volume show openstudio-mongodb -f value -c id)
echo "MongoDB volume ID: $MONGODB_VOL_ID"
```

---

## 4. Mounting NFS on Nomad Client Nodes

Run these steps on **every** Nomad client node that will run the `web` or `worker` task groups.

```bash
# Install NFS client (once per node)
sudo apt-get install -y nfs-common       # Debian / Ubuntu
# sudo yum install -y nfs-utils          # RHEL / CentOS / Rocky

# Create the local mount point
sudo mkdir -p /mnt/openstudio-nfs

# Test-mount (one-off)
sudo mount -t nfs "$EXPORT_PATH" /mnt/openstudio-nfs

# Verify
df -h /mnt/openstudio-nfs
ls /mnt/openstudio-nfs

# Persist across reboots
echo "${EXPORT_PATH}  /mnt/openstudio-nfs  nfs  defaults,_netdev,nofail  0  0" \
  | sudo tee -a /etc/fstab
sudo mount -a
```

> **Permission note:** The `web` and `worker` containers run as UID/GID `1000:1000` by default
> (set by `docker_user`). Ensure the mount point is writable by that UID:
>
> ```bash
> sudo chown -R 1000:1000 /mnt/openstudio-nfs
> ```

---

## 5. Registering Storage as Nomad Host Volumes

Add `host_volume` stanzas to the Nomad **client** configuration on each node that should serve
these volumes. Edit `/etc/nomad.d/client.hcl` (or the path used by your installation):

```hcl
# /etc/nomad.d/client.hcl

# NFS shared volume (web + worker)
host_volume "openstudio-nfs" {
  path      = "/mnt/openstudio-nfs"
  read_only = false
}

# MongoDB data volume (host_volume path for single-node deployments)
# Only needed if db_storage_type = "host_volume"
host_volume "openstudio-mongodb" {
  path      = "/opt/nomad/volumes/mongodb"
  read_only = false
}

# Redis data volume
host_volume "openstudio-redis" {
  path      = "/opt/nomad/volumes/redis"
  read_only = false
}
```

After editing, reload Nomad:

```bash
sudo systemctl reload nomad
# or
nomad node config -update-config /etc/nomad.d/client.hcl
```

Verify the host volumes are registered:

```bash
nomad node status -verbose <node-id> | grep -A 20 "Host Volumes"
```

---

## 6. Wiring Storage Identifiers into the Pack Var-File

Create or extend your pack var-file (e.g., `my-cluster.hcl`) with the storage configuration:

```hcl
# my-cluster.hcl

# ── NFS shared filesystem (web + worker) ─────────────────────────────────────
nfs_shared_volume_enabled = true
nfs_volume_source         = "openstudio-nfs"   # must match host_volume name in Nomad config

# ── MongoDB persistence ───────────────────────────────────────────────────────
# Option A: host_volume (single-node or where Cinder is attached as a formatted disk)
db_storage_type  = "host_volume"
db_volume_source = "openstudio-mongodb"

# Option B: CSI (multi-node, requires Cinder CSI plugin — see Section 7)
# db_storage_type  = "csi"
# db_volume_source = "openstudio-mongodb"

# ── Redis persistence ─────────────────────────────────────────────────────────
redis_storage_type    = "host_volume"
redis_volume_source   = "openstudio-redis"
```

Deploy with:

```bash
nomad-pack run packs/openstudio-server \
  --name openstudio-server \
  -var-file my-cluster.hcl
```

---

## 7. CSI Path: Cinder Block Volume for MongoDB

For multi-node clusters where the MongoDB allocation may reschedule across nodes, use Nomad's CSI
integration with the OpenStack Cinder driver.

### 7.1 Deploy the Cinder CSI Plugin

```bash
# Follow your cloud provider's instructions for deploying cinder-csi-plugin on Nomad.
# Example using the community plugin job:
nomad job run examples/cinder-csi-plugin.nomad   # not included; obtain from plugin vendor
```

### 7.2 Register the Cinder Volume with Nomad

```hcl
# mongodb-csi-volume.hcl
id           = "openstudio-mongodb"
name         = "openstudio-mongodb"
type         = "csi"
plugin_id    = "cinder"
capacity_min = "50GiB"
capacity_max = "50GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

parameters {
  type = "ceph-ssd"   # or your Cinder volume type
}

external_id = "<CINDER_VOLUME_ID>"   # from: openstack volume show openstudio-mongodb -f value -c id
```

```bash
nomad volume register mongodb-csi-volume.hcl
nomad volume status openstudio-mongodb
```

### 7.3 Update the Var-File

```hcl
db_storage_type  = "csi"
db_volume_source = "openstudio-mongodb"
```

---

## 8. ACL and Export Readiness Validation

Run these checks from the Nomad client node after mounting:

```bash
# 1. Confirm NFS is mounted
mount | grep openstudio-nfs

# 2. Write test
touch /mnt/openstudio-nfs/.preflight-ok && echo "Write OK" || echo "Write FAILED"
rm -f /mnt/openstudio-nfs/.preflight-ok

# 3. Verify NFS server exports (requires nfs-utils)
showmount -e <NFS_SERVER_IP>

# 4. Confirm access rule state in Manila
openstack share access list openstudio-nfs
# All rules should show state = active

# 5. MongoDB volume status (CSI path)
nomad volume status openstudio-mongodb

# 6. Existing pack preflight script
./scripts/preflight-storage.sh
```

---

## 9. Troubleshooting

### `mount.nfs: access denied`

The Manila access rule may not be in the `active` state yet, or the client IP is outside the
allowed CIDR.

```bash
# Check rule state
openstack share access list openstudio-nfs
# state should be "active", not "new" or "error"

# Check the client's actual IP as seen by OpenStack
openstack server show <nomad-client-instance-name> -f value -c addresses
```

### `openstack: command not found`

```bash
pip install python-openstackclient python-manilaclient
# Ensure the pip bin directory is on $PATH
export PATH="$HOME/.local/bin:$PATH"
```

### Share stuck in `creating` state

```bash
# Check the Manila log on the control plane or contact your cloud admin
openstack share show openstudio-nfs -f value -c status
```

If the share enters `error` state:

```bash
openstack share delete openstudio-nfs
# Wait ~30s then retry creation
```

### NFS performance is slow

- Increase Manila share size (more GiB = higher throughput on some backends).
- Ensure the NFS mount uses `rsize=1048576,wsize=1048576` options.
- Consider adding `async` export option (requires cloud admin).

### Nomad host volume not appearing

After reloading Nomad, the host volume should appear in node status. If it does not:

```bash
nomad agent-info
journalctl -u nomad -n 50 --no-pager | grep -i volume
```

Ensure the `path` in the `host_volume` stanza exists and is writable before reloading.

### `QUOTA_EXCEEDED` error from Manila or Cinder

Contact your OpenStack project admin to raise the `gigabytes` or `shares` quota. Example admin
command:

```bash
# (admin only)
openstack quota set --shares 20 --gigabytes 500 <project-id>
```

---

## Further Reading

- [Storage Preparation Guide](./storage.md) — full Nomad host volume, CSI, and NFS reference
- [Getting Started: Single-Node Walkthrough](./getting-started-single-node.md)
- [Operations Guide](./operations-guide.md) — day-2 operations, scaling, draining
- [OpenStack Manila documentation](https://docs.openstack.org/manila/latest/user/)
- [OpenStack Cinder documentation](https://docs.openstack.org/cinder/latest/user/)
- [Nomad CSI Volumes](https://developer.hashicorp.com/nomad/docs/other-specifications/volume)
