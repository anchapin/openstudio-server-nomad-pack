# NFS Tuning Guide for High-Concurrency OpenStudio Server

This guide covers NFS client mount option tuning, server/export configuration, and three
ready-to-use profiles for OpenStudio Server deployments on OpenStack Manila (or any
NFS-backed shared filesystem). It targets the scenario where **100+ Nomad worker
allocations** all read/write the same NFS export simultaneously, which causes I/O saturation
without proper tuning.

See [storage.md](./storage.md) for how to register a Nomad host volume and enable
`nfs_shared_volume_enabled` in the pack.

---

## Table of Contents

1. [Why NFS Tuning Matters at Scale](#1-why-nfs-tuning-matters-at-scale)
2. [NFS Client Mount Options](#2-nfs-client-mount-options)
3. [NFS Server / Export Tuning (Manila / Ganesha)](#3-nfs-server--export-tuning-manila--ganesha)
4. [Three Deployment Profiles](#4-three-deployment-profiles)
5. [Benchmark Methodology](#5-benchmark-methodology)
6. [Guardrails and Fallback Policy](#6-guardrails-and-fallback-policy)
7. [Integration: /etc/fstab and Nomad client.hcl](#7-integration-etcfstab-and-nomad-clienthcl)

---

## 1. Why NFS Tuning Matters at Scale

OpenStudio Server uses the shared NFS volume (`/mnt/openstudio`) for:

- Uploading analysis input files from the web task to the shared workspace
- Workers reading input data and writing simulation results concurrently
- The web task reading completed results for the dashboard

At low concurrency (< 10 workers) default mount options are adequate. At 100+ workers:

| Symptom | Root cause |
|---|---|
| High NFS server latency spikes | Small `rsize`/`wsize` forces many round-trips per file |
| Workers stalling on write | Synchronous writes (`sync`) block on every `write()` call |
| Allocation failures with "stale NFS handle" | Soft mounts silently give up on transient network hiccups |
| Nomad health checks timing out | NFS retransmits exceed Consul check deadline |
| Data corruption / partial writes | `async` without journaling on critical result files |

---

## 2. NFS Client Mount Options

### 2.1 Reference

These options are set in `/etc/fstab` (or a systemd `.mount` unit) on each Nomad client node
and take effect when the OS mounts the NFS export. No Nomad pack variable controls these
directly — they are an infrastructure-layer concern.

### 2.2 Option Descriptions

| Option | Recommended value | Effect |
|---|---|---|
| `nfsvers` | `4.1` | NFSv4.1 adds pNFS and session trunking; prefer over `4.0` or `3`. |
| `rsize` | `1048576` (1 MiB) | Read buffer per RPC. Larger values reduce round-trips for large file reads. |
| `wsize` | `1048576` (1 MiB) | Write buffer per RPC. Same rationale as `rsize`. |
| `hard` | *(flag, no value)* | Retries I/O indefinitely until the server responds. Never silently drops writes. |
| `timeo` | `600` (60 s in 0.1 s units) | Time before the client retransmits an unanswered RPC. 60 s tolerates Manila failover. |
| `retrans` | `2` | Number of RPC retransmissions before raising a server-not-responding warning. |
| `noresvport` | *(flag)* | Allows reconnection from a non-privileged port; required by some Manila back-ends. |
| `_netdev` | *(flag)* | Tells systemd to wait for network before mounting; prevents boot hangs. |
| `actimeo` | `0` | Disables attribute caching. Required if multiple writers touch the same file metadata. Use only for result directories; it doubles stat() load. |
| `async` | *(flag)* | Write-back caching on the client side. Significantly higher write throughput, but in-flight data is lost on client crash. Safe only for reproducible scratch data. |

### 2.3 Options to Avoid

| Option | Why to avoid |
|---|---|
| `soft` | Client returns `EIO` after `retrans` failures. Silent data loss during transient Manila failovers. Never use for shared analysis data. |
| `rsize=65536` / `wsize=65536` | The 64 KiB default was tuned for 1990s hardware. At 100+ workers it multiplies round-trips ~16× vs 1 MiB buffers. |
| `nfsvers=3` | NFSv3 has no session state, making reconnection after Manila failover unreliable. Prefer v4.1. |
| `nolock` | Disables NLM (network lock manager). Combined with multiple writers this causes POSIX lock bypass and potential corruption. |
| `intr` | Allows signals to interrupt NFS waits. Can cause partially-written files when workers are killed mid-write. |

---

## 3. NFS Server / Export Tuning (Manila / Ganesha)

### 3.1 Export Options

Manila exposes exports via NFS-Ganesha. The export access rule controls both security and
performance behaviour:

**Default (permissive, dev)**:
```
rw,sync,no_subtree_check,no_root_squash
```

**Recommended (production)**:
```
rw,sync,no_subtree_check,root_squash,sec=sys
```

| Option | Tradeoff |
|---|---|
| `sync` | Server acknowledges writes only after they hit stable storage. Safest; slower for bulk writes. |
| `async` | Server acknowledges before stable storage. Higher throughput; risk of data loss on Ganesha crash. Use only if Manila back-end is backed by a durable storage tier (Ceph, SAN). |
| `no_subtree_check` | Disables per-export directory validation on every access; slightly improves throughput. Standard for OpenStack Manila shares. |
| `root_squash` | Maps UID 0 → `nobody`. Recommended over `no_root_squash` in multi-tenant environments. |
| `no_root_squash` | Required only if Nomad tasks run as root (not the default; OpenStudio containers run as `1000:1000`). |

### 3.2 Ganesha Thread Tuning

For 100+ concurrent clients, the default Ganesha worker thread count (16) becomes a bottleneck.
Add to `/etc/ganesha/ganesha.conf` (or the Manila Ganesha configuration template):

```ini
NFS_Core_Param {
    # One thread per expected concurrent mount × 1.5 headroom
    Nb_Worker = 128;

    # Increase the request queue depth to absorb bursts
    Nb_MaxConcurrentOps = 256;
}

EXPORT_DEFAULTS {
    # Prefer NFSv4.1 for session-based reconnect
    Protocols = 4;
    Transports = TCP;

    # 1 MiB aligned with client rsize/wsize
    MaxRead  = 1048576;
    MaxWrite = 1048576;
}
```

> **OpenStack Manila note**: These settings require operator-level access to the Ganesha
> configuration. On a managed Manila service, open a support ticket to request `Nb_Worker`
> tuning for your share network.

### 3.3 Connection Limits

Each Nomad client opens one persistent TCP session per mount. With 10 Nomad client nodes each
running 10 worker allocations, the server sees **10 client-level TCP sessions** (not 100). NFS
connection limits are therefore per-node, not per-container. The main server-side tuning levers
are:

- `Nb_Worker` (Ganesha thread count) — governs parallelism of RPC dispatch
- TCP backlog on the Ganesha socket (default 128 on most Linux kernels; increase via
  `net.core.somaxconn = 4096` on the NFS server node)

---

## 4. Three Deployment Profiles

The profiles below are `/etc/fstab` entries. Replace `<nfs-host>` and `<export-path>` with
your Manila share endpoint.

### 4a. Conservative (stable, lower throughput)

Use when: initial deployment, debugging, or when data integrity is paramount and throughput
is secondary (small cluster, < 20 concurrent workers).

```fstab
<nfs-host>:<export-path> /mnt/openstudio nfs \
  nfsvers=4.1,rsize=262144,wsize=262144,hard,timeo=600,retrans=2,noresvport,_netdev,sync \
  0 0
```

| Setting | Value | Rationale |
|---|---|---|
| `nfsvers` | `4.1` | Session-based reconnect; works with Manila |
| `rsize`/`wsize` | `262144` (256 KiB) | Safe for all kernel versions; still 4× better than default |
| `hard` | yes | No silent data loss |
| `timeo` | `600` | 60 s — tolerates Manila failover |
| `sync` | yes | Synchronous client-side writes; safest |
| `async` export | no | Use `sync` on the server too |

**Expected throughput**: ~200–400 MB/s aggregate write (limited by `sync` round-trips).

---

### 4b. Balanced — Recommended (NFSv4.1, 1 MiB buffers)

Use when: production deployments with 20–200 concurrent workers on a stable Manila back-end.

```fstab
<nfs-host>:<export-path> /mnt/openstudio nfs \
  nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev \
  0 0
```

| Setting | Value | Rationale |
|---|---|---|
| `nfsvers` | `4.1` | |
| `rsize`/`wsize` | `1048576` (1 MiB) | Maximises RPC payload; single round-trip for most simulation output files |
| `hard` | yes | |
| `timeo` | `600` | |
| `sync` | not set (default) | Client-side write aggregation enabled by kernel; server export still uses `sync` |
| `async` export | no | |

This profile matches what the `docs/storage.md §5.1` recommended `/etc/fstab` entry should
evolve toward. It replaces the previous 64 KiB buffer recommendation.

**Expected throughput**: ~800 MB/s–1.5 GB/s aggregate write (kernel-aggregated writes,
1 MiB RPCs).

---

### 4c. Aggressive (maximum throughput, less safe)

Use when: very high throughput is required (200+ workers), simulation files are reproducible
(re-runnable if lost), and the Manila back-end is on durable storage (Ceph RBD, SAN LUN).

```fstab
<nfs-host>:<export-path> /mnt/openstudio nfs \
  nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev,async \
  0 0
```

Additional server-side change: set the Ganesha export to `async` (acknowledges before disk).

| Setting | Value | Rationale |
|---|---|---|
| `async` (client) | yes | Kernel write-back cache; drastically reduces latency for small sequential writes |
| `async` (server) | yes | Ganesha acknowledges before Ceph/SAN commit; requires durable back-end |
| `actimeo=0` | optional | Add if workers observe stale file metadata; adds stat() overhead |

**Risk**: If the Ganesha server crashes with unflushed data, in-flight simulation results are
lost. Workers must be designed to re-run failed analyses (the OpenStudio Server dispatcher
handles this via the Resque retry mechanism).

**Expected throughput**: >2 GB/s aggregate write on a well-provisioned Ceph back-end.

---

### Profile Comparison

| Profile | rsize/wsize | Client sync | Server async | Throughput | Safety |
|---|---|---|---|---|---|
| Conservative | 256 KiB | yes | no | ~300 MB/s | ★★★★★ |
| **Balanced** *(recommended)* | 1 MiB | no (kernel) | no | ~1 GB/s | ★★★★☆ |
| Aggressive | 1 MiB | no (async) | yes | >2 GB/s | ★★★☆☆ |

---

## 5. Benchmark Methodology

Run these benchmarks **before and after** applying a new profile to establish a measurable
baseline. All commands run on a Nomad client node with the NFS volume mounted.

### 5.1 fio — Sequential and Random I/O

```bash
# Install fio (one-time)
sudo apt-get install -y fio   # Debian/Ubuntu
sudo yum install -y fio       # RHEL/CentOS

# Sequential write — simulates simulation result upload
fio --name=seq-write --directory=/mnt/openstudio --rw=write \
    --bs=1M --size=4G --numjobs=8 --time_based --runtime=60 \
    --group_reporting --output-format=json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); \
      print('write bw:', d['jobs'][0]['write']['bw_bytes']//1024//1024, 'MB/s')"

# Sequential read — simulates web task reading results
fio --name=seq-read --directory=/mnt/openstudio --rw=read \
    --bs=1M --size=4G --numjobs=8 --time_based --runtime=60 \
    --group_reporting

# Random 4K write — worst case (many small metadata updates)
fio --name=rand-write --directory=/mnt/openstudio --rw=randwrite \
    --bs=4k --size=512M --numjobs=32 --time_based --runtime=60 \
    --group_reporting
```

Record: `bw` (bandwidth MB/s), `iops`, `lat` (average and 99th percentile latency).

### 5.2 nfsstat — RPC Statistics

```bash
# Before starting a batch run:
nfsstat -c > nfsstat-before.txt

# After the batch run completes:
nfsstat -c > nfsstat-after.txt

# Key metrics to compare:
#   read/write calls    — total RPC count (lower is better for same data volume)
#   retrans             — retransmissions (should be < 0.1% of total calls)
#   timeout             — RPC timeouts (should be 0 in normal operation)
diff nfsstat-before.txt nfsstat-after.txt
```

### 5.3 iostat — Network Interface Saturation

```bash
# Monitor NFS network utilisation during a load test
iostat -x 2 30

# On the NFS server node, watch the NIC:
sar -n DEV 2 30 | grep -E "eth0|ens3|bond0"
```

### 5.4 OpenStudio Server Built-In Metric

The batch verification job (`enable_batch_verification = true`) reports
`batch_verification_result component=openstudio-web status=pass|fail` but does not measure NFS
throughput directly. Use the `fio` methodology above during a representative analysis batch.

### 5.5 Interpreting Results

| Metric | Conservative profile | Balanced profile | Aggressive profile |
|---|---|---|---|
| Sequential write BW | ~200–400 MB/s | ~800–1500 MB/s | >2000 MB/s |
| 4K random write IOPS | ~500–1000 | ~2000–5000 | ~8000–15000 |
| 99th percentile write latency | 20–50 ms | 5–15 ms | 1–5 ms |
| NFS retrans rate | < 0.05% | < 0.05% | < 0.1% |

If measured throughput is significantly lower than the table above, check:
1. Network bandwidth between Nomad clients and Manila server (use `iperf3`)
2. Manila share bandwidth quota (OpenStack project quota)
3. Ganesha `Nb_Worker` saturation (`journalctl -u nfs-ganesha | grep "worker thread"`)

---

## 6. Guardrails and Fallback Policy

### 6.1 When to Downgrade to Conservative Profile

Switch from Balanced or Aggressive to Conservative when:

- **Retransmission rate > 1%** — indicates network instability or Manila overload; `hard` +
  large `timeo` will mask the problem but `sync` prevents data loss.
- **Manila failover events** — during maintenance windows; `sync` ensures no in-flight data
  is lost when Ganesha restarts.
- **First deployment** — always start Conservative, benchmark, then promote to Balanced after
  validating results match expectations.
- **Cluster < 20 workers** — throughput difference between Conservative and Balanced is
  marginal at low concurrency; Conservative overhead is negligible.

### 6.2 Signals to Watch (Prometheus / Nomad Metrics)

| Signal | Threshold | Action |
|---|---|---|
| NFS `retrans` (nfsstat) | > 0.5% over 5 min | Downgrade to Conservative; investigate network |
| Worker allocation task restart rate | > 5% in 15 min | Check NFS mount health: `ls -la /mnt/openstudio` from client |
| Web task health check failures | any | Verify NFS mount not stale: `stat /mnt/openstudio` |
| `iostat` await on NFS interface > 100 ms | sustained | Increase `timeo` to `900`; open Manila support ticket |

### 6.3 Never Do This

- **Never use `soft` mounts** for the OpenStudio shared volume. Silent `EIO` errors cause
  partial analysis results that are indistinguishable from successful runs.
- **Never use `async` on a back-end without redundant storage** (no RAID, no Ceph
  replication). A single disk failure will corrupt all in-flight simulation data.
- **Never reduce `timeo` below `300`** (30 s) in production. Manila HA failover can take
  20–30 s; a shorter `timeo` causes unnecessary retransmit storms.

---

## 7. Integration: /etc/fstab and Nomad client.hcl

### 7.1 /etc/fstab (Balanced Profile)

Add to `/etc/fstab` on **every Nomad client node** that will run `web` or `worker`
allocations:

```fstab
# OpenStudio Server shared NFS workspace — Balanced profile
# Replace <manila-share-ip> and <export-path> from:
#   openstack share access-list <share-name>
<manila-share-ip>:<export-path> /mnt/openstudio nfs \
  nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev \
  0 0
```

Mount and verify:

```bash
sudo mkdir -p /mnt/openstudio
sudo mount /mnt/openstudio
mountpoint -q /mnt/openstudio && echo "mounted OK"
# Verify correct options were applied:
cat /proc/mounts | grep openstudio
```

### 7.2 systemd .mount Unit (Alternative to fstab)

For servers where `/etc/fstab` is managed by configuration management:

```ini
# /etc/systemd/system/mnt-openstudio.mount
[Unit]
Description=OpenStudio Server shared NFS workspace
After=network-online.target
Wants=network-online.target

[Mount]
What=<manila-share-ip>:<export-path>
Where=/mnt/openstudio
Type=nfs
Options=nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-openstudio.mount
systemctl status mnt-openstudio.mount
```

### 7.3 Nomad client.hcl — host_volume Registration

After the OS-level mount is confirmed working, register it as a Nomad host volume in
`/etc/nomad.d/client.hcl` (or the equivalent Ansible/Terraform-managed config):

```hcl
client {
  # ... existing client config ...

  host_volume "openstudio-nfs" {
    path      = "/mnt/openstudio"
    read_only = false
  }
}
```

Reload Nomad to pick up the new host volume:

```bash
sudo systemctl reload nomad
# Verify the volume is registered:
nomad node status -verbose <node-id> | grep openstudio-nfs
```

### 7.4 Pack Variables (variables.hcl)

With the host volume registered on all client nodes, enable shared NFS in your var-file
(e.g. `examples/openstack.hcl`):

```hcl
nfs_shared_volume_enabled = true
nfs_volume_type           = "host_volume"   # default; no need to set explicitly
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"
```

> **Important:** `web_count` must remain `1` even with NFS enabled. NFS provides a shared
> filesystem but does **not** provide distributed POSIX file locking across multiple web
> allocations. See [storage.md §Web Replica Constraint](./storage.md) for details.

---

## Further Reading

- [storage.md — NFS Shared Volume](./storage.md#5-nfs-shared-volume-web-and-worker)
- [operations-guide.md](./operations-guide.md) — day-2 operations including volume maintenance
- [OpenStack Manila NFS documentation](https://docs.openstack.org/manila/latest/)
- [NFS-Ganesha configuration reference](https://github.com/nfs-ganesha/nfs-ganesha/wiki)
- [Red Hat — Optimizing NFS Performance](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/managing_file_systems/optimizing-nfs_managing-file-systems)
- [fio documentation](https://fio.readthedocs.io/en/latest/)
