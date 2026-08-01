# ADR-001: Storage Architecture for High-Scale OpenStudio Server on OpenStack

| Field    | Value                                                       |
|----------|-------------------------------------------------------------|
| Status   | Accepted                                                    |
| Date     | 2026-08-01                                                  |
| Deciders | OpenStudio Server Nomad Pack maintainers                    |
| Issue    | [#354](https://github.com/anchapin/openstudio-server-nomad-pack/issues/354) |

---

## Context

High worker concurrency (100–2000+ simultaneous simulations) imposes demanding I/O requirements
on the shared artifact filesystem used by the OpenStudio Server web and worker processes:

- **Upload ingestion**: large OSW/zip files (50–500 MB) written sequentially by the web process.
- **Simulation outputs**: per-run result directories (10–2000 MB) written by parallel worker processes.
- **Result retrieval**: concurrent download requests from clients polling run status.

The current default — Manila shared filesystem (`nfs_shared_volume_enabled = true`) — works
well at low concurrency but exhibits throughput saturation and high I/O wait above ~100 concurrent
workers on a single Manila share.

Three options were evaluated to determine the primary and fallback storage architecture for
high-scale OpenStack deployments.

Related preparatory work:
- **#355** — OpenStack storage provisioning script (`docs/openstack-storage-provisioning.md`)
- **#357** — Swift object-storage backend variables (`docs/swift-artifact-backend.md`)
- **#358** — NFS tuning guide (`docs/nfs-tuning-guide.md`)

---

## Decision Criteria

| Criterion                  | Weight | Description                                                                        |
|----------------------------|--------|------------------------------------------------------------------------------------|
| Throughput                 | High   | Aggregate read/write MB/s under 500–2000 concurrent workers                        |
| Latency (TTFB)             | Medium | Time-to-first-byte for result downloads; affects dashboard responsiveness           |
| Durability                 | High   | Data survival across node failure, zone outage, and OpenStack host maintenance     |
| Ops complexity             | Medium | Day-2 burden: provisioning, monitoring, failure recovery                           |
| OpenStack integration      | Medium | Native fit with OpenStack APIs; avoids third-party dependencies                    |
| Cost                       | Low    | Relative GB-storage and IOPS cost on a typical OpenStack private cloud              |
| Nomad pack changes required | Low   | Engineering effort to implement; scope of variables.hcl and template changes       |

---

## Options

### Option A — Manila NFS Only (Current Default)

Manila provides a multi-writer NFS share accessible to all Nomad clients. The pack mounts it
as a `host_volume` on each client and exposes it via `nfs_shared_volume_enabled = true`.

**How it works:**
- All workers and the web process read/write the same NFS export.
- The manila share is backed by Cinder or a dedicated storage backend depending on the Manila driver.

**Required pack variables (current defaults):**
```hcl
nfs_shared_volume_enabled = true
nfs_volume_type           = "host_volume"
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"
```

**Nomad/OpenStudio changes required:** None — already shipped.

---

### Option B — Swift Object Storage for Artifacts + Minimal Manila (Recommended Primary)

Artifact files (OSW uploads, simulation outputs, result zips) are stored directly in OpenStack
Swift. The web and worker processes talk to Swift via the S3-compatible API (or native Swift API).
A small Manila share is still required for runtime lock files and temporary staging areas, but
its size and IOPS requirements are dramatically reduced.

**How it works:**
- `web` writes uploads directly to Swift (`PUT` object).
- `worker` writes simulation outputs to Swift and reads inputs from Swift.
- Result downloads are pre-signed Swift URLs (no NFS read path in the hot path).
- Manila share is reduced to a small scratch area (`/mnt/openstudio/tmp`) for in-flight staging.

**Required pack variables (added in #357):**
```hcl
swift_artifact_backend_enabled = true
swift_auth_url                 = "https://keystone.example.com:5000/v3"
swift_username                 = "openstudio-svc"
swift_password                 = "<secret>"         # prefer Vault KV
swift_project_name             = "openstudio"
swift_container_name           = "openstudio-artifacts"
swift_region_name              = "RegionOne"

# Retain minimal Manila for tmp/locks
nfs_shared_volume_enabled = true
nfs_volume_source         = "openstudio-nfs-scratch"
nfs_volume_mount_path     = "/mnt/openstudio/tmp"
```

**Nomad/OpenStudio application changes required:**
- Application must use the Swift SDK (or AWS SDK pointed at the Swift S3 endpoint) for artifact
  reads/writes (see upstream issue for application-side changes).
- Pre-signed URL generation must be enabled in the web process configuration.

---

### Option C — Cinder-Backed Dedicated NFS Tier (Recommended Fallback/HA)

A dedicated NFS server VM (or cluster) is provisioned with Cinder volumes attached directly,
bypassing Manila's multi-tenant overhead. The pack mounts the export as a standard `host_volume`.

**How it works:**
- One or two dedicated NFS VMs are provisioned by `scripts/openstack-storage-provisioning.sh`.
- Cinder volumes (SSD-backed, 500 GiB–2 TiB) are attached to the NFS VMs and exported via NFS.
- NFS clients mount with optimized options (see `docs/nfs-tuning-guide.md`).
- Optional: active/passive HA with Pacemaker + Corosync and a floating IP for failover.

**Required pack variables:**
```hcl
nfs_shared_volume_enabled = true
nfs_volume_type           = "host_volume"
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"
```

**Client-side NFS options** (tuned per `docs/nfs-tuning-guide.md`):
```fstab
<nfs-vm-ip>:/exports/openstudio /mnt/openstudio nfs nfsvers=4.1,proto=tcp,rsize=1048576,wsize=1048576,hard,intr,timeo=600,retrans=5,_netdev 0 0
```

**Nomad/OpenStudio changes required:** None beyond provisioning the NFS VM — pack template is
unchanged from Option A.

---

## Evaluation Matrix

| Criterion               | Option A — Manila NFS | Option B — Swift (Primary) | Option C — Cinder NFS (Fallback) |
|-------------------------|:---------------------:|:--------------------------:|:---------------------------------:|
| Throughput (scale)      | ⚠️ Medium (saturates >100 workers) | ✅ High (object store scales horizontally) | ✅ High (dedicated IOPS, no multi-tenant throttle) |
| Latency (TTFB)          | ✅ Low (local NFS cache) | ⚠️ Medium (HTTP round-trip for first byte) | ✅ Low (local NFS cache) |
| Durability              | ⚠️ Medium (single Manila share, no built-in replication) | ✅ High (Swift 3-replica erasure coding by default) | ✅ High (Cinder volumes with snapshots + HA failover) |
| Ops complexity          | ✅ Low (managed by Manila) | ⚠️ Medium (credential rotation, bucket policy) | ⚠️ Medium (NFS VM maintenance, HA cluster) |
| OpenStack integration   | ✅ Native                | ✅ Native                    | ✅ Native (Cinder + Nova)          |
| Cost                    | ✅ Low                   | ✅ Low (object storage is cheapest per GB) | ⚠️ Medium (dedicated VM + Cinder IOPS) |
| Pack changes required   | ✅ None                  | ⚠️ Medium (#357 done; app changes pending) | ✅ Minimal (provisioning script #355) |

---

## Decision

**Primary: Option B — Swift object storage for artifacts + minimal Manila scratch space.**

At high worker concurrency, Manila's shared NFS backend becomes the primary bottleneck: all
workers compete for IOPS on the same share, and Manila's multi-tenant scheduler adds queuing
overhead. Swift removes the shared filesystem from the hot write path entirely. Result downloads
can be served as pre-signed Swift URLs, eliminating NFS read bandwidth from the web process.

Swift's object store scales horizontally with the OpenStack control plane and requires no
operator-managed NFS infrastructure. The pack variables for Swift integration were shipped in #357;
the remaining work is application-side (web/worker Swift SDK integration).

**Fallback: Option C — Cinder-backed dedicated NFS tier.**

For environments without Swift (private clouds with no object storage configured, air-gapped
deployments), a Cinder-backed dedicated NFS VM provides significantly better throughput than
Manila at the cost of a dedicated VM and optional HA setup. The provisioning script shipped in
#355 automates the VM and Cinder volume setup. The pack template is unchanged from Option A —
only the NFS server endpoint changes.

Option A (Manila only) remains the default for development and low-scale deployments where
simplicity outweighs throughput. It should not be used as the primary architecture above ~100
concurrent workers.

---

## Consequences

### Pack changes (completed)

| PR/Issue | Change                                            |
|----------|---------------------------------------------------|
| #355     | OpenStack storage provisioning script             |
| #357     | Swift object-storage backend variables            |
| #358     | NFS tuning guide and optimized client mount options |
| #359     | Backup/restore jobs updated for Swift containers  |

### Application changes required (not yet implemented)

For Option B (Swift primary), the upstream OpenStudio Server application must:

1. **Replace direct filesystem writes with Swift SDK calls** in the web upload handler.
2. **Replace filesystem reads with Swift SDK calls** in the worker input-fetch path.
3. **Implement pre-signed URL generation** for result download endpoints.
4. **Retain a small scratch path** (`/mnt/openstudio/tmp`) for in-flight staging before Swift upload.

Until application changes are complete, deploy with Option C (Cinder NFS) or Option A (Manila)
as an interim measure.

### Migration path from Option A → Option B (Swift)

1. Provision a Swift container (`openstack container create openstudio-artifacts`).
2. Deploy pack with `swift_artifact_backend_enabled = true` and credentials configured.
3. Run the provided migration batch job to copy existing NFS artifacts to Swift.
4. Validate that new runs write to and read from Swift.
5. Reduce Manila share quota to scratch-only size after validation period (suggested: 2 weeks).

### Migration path from Option A → Option C (Cinder NFS)

1. Run `scripts/openstack-storage-provisioning.sh` to provision the NFS VM and Cinder volumes.
2. Mount the new NFS export on all Nomad clients (`/etc/fstab` + `host_volume` registration).
3. Stop the pack (`nomad-pack destroy .`).
4. `rsync` existing Manila artifacts to the new Cinder-backed NFS share.
5. Update `nfs_volume_source` to point to the new host volume, redeploy.
6. Validate, then release the old Manila share.

---

## Rollback

To revert to Option A (Manila NFS) from either Option B or Option C:

1. Stop the pack (`nomad-pack destroy .`).
2. Remove `swift_artifact_backend_enabled = true` (or the Cinder NFS host volume reference) from
   your override var-file.
3. Ensure the original Manila `host_volume` is still registered on Nomad clients.
4. Redeploy: `nomad-pack run . -var-file <your-override>.hcl`.
5. If data was migrated to Swift or Cinder NFS, `rsync` it back to the Manila share before
   restarting workers.

---

## References

- [`docs/storage.md`](./storage.md) — Volume setup guide (host_volume, CSI, NFS)
- [`docs/nfs-tuning-guide.md`](./nfs-tuning-guide.md) — NFS mount option reference and tuning
- [`docs/swift-artifact-backend.md`](./swift-artifact-backend.md) — Swift backend variable reference
- [`docs/openstack-storage-provisioning.md`](./openstack-storage-provisioning.md) — Cinder NFS VM provisioning
- [Nomad Host Volumes](https://developer.hashicorp.com/nomad/docs/configuration/client#host_volume-stanza)
- [OpenStack Swift S3 API](https://docs.openstack.org/swift/latest/s3_compat.html)
- [OpenStack Manila User Guide](https://docs.openstack.org/manila/latest/user/index.html)
