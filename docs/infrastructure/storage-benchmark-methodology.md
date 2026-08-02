# Storage Saturation Benchmark Methodology

> **Related:** [`scripts/benchmark-storage-saturation.sh`](../scripts/benchmark-storage-saturation.sh) | [`docs/storage.md`](storage.md)

## Purpose

Establish quantified NFS saturation thresholds before deploying OpenStudio Server at scale. This procedure enables operators to:

1. Identify the worker-count tier at which shared storage becomes the bottleneck.
2. Feed measured saturation points into autoscaling ramp policies to prevent runaway scale-out from degrading the cluster.
3. Compare storage backends (host volume, CSI NFS, managed NFS) on the same workload profile.

Without this benchmark, operators must rely on guesswork or post-incident forensics to set concurrency limits. Running it before production deployment allows data-driven capacity planning.

---

## Prerequisites

Run the benchmark on the same Nomad **client nodes** that will execute worker allocations.

### Required tools (on each client node)

| Tool | Version | Install |
|---|---|---|
| `fio` | ≥ 3.x | `apt-get install fio` / `yum install fio` |
| `sysstat` | ≥ 11.x | `apt-get install sysstat` / `yum install sysstat` |
| `nfs-common` / `nfs-utils` | any | `apt-get install nfs-common` / `yum install nfs-utils` |
| `jq` | ≥ 1.5 | `apt-get install jq` / `yum install jq` |
| `procps` | any | usually pre-installed |

### NFS mount

The NFS share used by OpenStudio workers must be mounted at a known path (default: `/mnt/openstudio`). Confirm the mount is active:

```bash
mount | grep /mnt/openstudio
# expected output: server:/export/openstudio on /mnt/openstudio type nfs4 (...)
```

### Permissions

The benchmark script creates and removes temporary fio data files under `<nfs-mount>/.benchmark-<tier>/`. Ensure the benchmark user has write access to the NFS mount.

---

## Load Tiers

The benchmark is structured around four worker-count tiers that mirror realistic deployment sizes:

| Tier | Concurrent workers | Typical use case |
|---|---|---|
| 250 | 250 | Small departmental cluster |
| 500 | 500 | Mid-size research cluster |
| 1000 | 1000 | Large HPC-style deployment |
| 2000 | 2000+ | Maximum scale / saturation probing |

Each tier is run independently. Work upward from the smallest tier and stop if saturation indicators appear before reaching higher tiers.

---

## Metrics Captured Per Tier

The script captures the following metrics during each run. Results are written to `benchmark-results/tier-<N>/`.

### Metrics table

| Category | Metric | Source | File |
|---|---|---|---|
| **NFS client** | ops/sec | `sar -n NFS` | `sar-nfs.txt` |
| **NFS client** | rtt_ms (estimated via fio clat) | `fio` JSON | `fio-randwrite.json` |
| **NFS client** | retrans_count | `nfsstat -c` before/after | `nfsstat-before/after.txt` |
| **Client host** | iowait% | `vmstat` column 15 | `vmstat.txt` |
| **Client host** | disk_util% | `iostat -x` | `iostat.txt` |
| **Client host** | net_throughput_MB/s | `sar -n DEV` | `sar-net.txt` |
| **Storage (fio proxy)** | write_bw_MB/s (4 KB randwrite) | `fio` JSON | `fio-randwrite.json` |
| **Storage (fio proxy)** | read_bw_MB/s (1 MB seqread) | `fio` JSON | `fio-seqread.json` |
| **Summary** | All of the above | script-computed | `summary.json` |

> **Note on storage-server metrics:** Direct storage-server metrics (queue depth, server-side latency, server-side throughput) require access to the NFS server itself (e.g., `/proc/net/rpc/nfsd`, exportfs stats, or the storage platform's monitoring API). These are captured separately. The script focuses on client-observable signals, which are the earliest indicators of saturation.

### I/O pattern rationale

OpenStudio workers produce two dominant I/O patterns:

| Pattern | Description | fio simulation |
|---|---|---|
| **Metadata / result writes** | Small (1–16 KB) random writes of JSON datapoints and OSM fragments | `--rw=randwrite --bs=4k` |
| **Model file reads** | Large (500 KB–5 MB) sequential reads when loading seed OSM/IDF files | `--rw=read --bs=1m` |

The number of parallel fio jobs is set to `tier / 4` (capped at 64) to model the per-node thread concurrency a worker fleet exercises against the shared mount. Adjust `--duration` to match your expected analysis run time.

---

## Saturation Indicators

The benchmark uses the following thresholds to classify a tier as **saturated**. These are conservative defaults derived from NFS performance literature and OpenStudio operational experience.

| Metric | Warning threshold | Saturation threshold | Rationale |
|---|---|---|---|
| `iowait%` | > 20% | **> 40%** | >40% iowait means CPUs are blocked on I/O more than they work; simulation throughput degrades sharply |
| `nfs_retrans` | > 0 | **> 0** | Any NFS retransmission indicates the server is dropping packets under load — a hard saturation signal |
| `nfs_rtt_ms` (fio clat proxy) | > 10 ms | **> 20 ms** | RTT >20 ms causes queue lag to accumulate faster than workers can drain |
| `disk_util%` | > 70% | > 90% | Applies mainly to storage-backed CSI volumes; less relevant for dedicated NFS appliances |
| `write_bw_MB/s` (drop from baseline) | < 50% of tier-250 baseline | < 25% | Sustained bandwidth collapse indicates storage controller saturation |

If **any** saturation threshold is crossed, the `--analyze` mode flags that tier with `YES ⚠`.

---

## Example Results Table

The following values are **illustrative** baselines from a single Nomad client node with a 1 GbE NFS mount to a 10-disk RAID-6 NAS. Your results will vary based on NFS server hardware, network bandwidth, and client node specs.

| Tier | iowait% | disk_util% | net_MB/s | nfs_ops/s | nfs_rtt_ms | retrans | write_bw_MB/s | read_bw_MB/s | Saturated? |
|---|---|---|---|---|---|---|---|---|---|
| 250 | 8.2 | 22.4 | 45.1 | 1240 | 3.4 | 0 | 38.2 | 112.7 | No |
| 500 | 18.7 | 51.3 | 88.6 | 2380 | 7.1 | 0 | 29.4 | 96.3 | No |
| 1000 | 44.1 | 87.2 | 109.3 | 3150 | 22.8 | 14 | 11.2 | 58.9 | **YES ⚠** |
| 2000 | 68.5 | 97.1 | 112.0 | 3200 | 51.4 | 312 | 4.8 | 21.3 | **YES ⚠** |

**Interpretation of this example:** Storage saturation begins between 500 and 1000 concurrent workers. The recommended safe operating ceiling is ≤ 500 concurrent workers for this hardware configuration, with autoscaling hard-capped at that tier.

---

## Running the Benchmark

### Step-by-step

**1. Clone or copy the script to the Nomad client node:**

```bash
scp scripts/benchmark-storage-saturation.sh nomad-client-01:/opt/benchmark/
ssh nomad-client-01
chmod +x /opt/benchmark/benchmark-storage-saturation.sh
```

**2. Run each tier sequentially (allow the NFS mount to cool between runs):**

```bash
for TIER in 250 500 1000 2000; do
  echo "=== Running tier $TIER ==="
  ./benchmark-storage-saturation.sh \
    --tier "$TIER" \
    --nfs-mount /mnt/openstudio \
    --duration 300 \
    --output-dir benchmark-results
  echo "Cooling down for 60s..."
  sleep 60
done
```

> **Duration guidance:** Use `--duration 300` (5 minutes) as a minimum. For production capacity planning, use `--duration 600` (10 minutes) to average out transient spikes.

**3. Review raw results:**

```bash
ls benchmark-results/tier-*/
cat benchmark-results/tier-1000/summary.json
```

**4. Run analysis to identify the saturation point:**

```bash
./benchmark-storage-saturation.sh --analyze --output-dir benchmark-results
```

Example output:
```
=== Storage Saturation Benchmark — Analysis ===

Tier     iowait%      disk_util%   net_MB/s     nfs_ops/s    nfs_rtt_ms     retrans      saturated
----     --------     ----------   --------     ---------    ----------     -------      ---------
250      8.2          22.4         45.1         1240         3.4            0            no
500      18.7         51.3         88.6         2380         7.1            0            no
1000     44.1         87.2         109.3        3150         22.8           14           YES ⚠
2000     68.5         97.1         112.0        3200         51.4           312          YES ⚠

Saturation first observed at tier: 1000 workers
Recommendation: keep concurrent workers below 1000 for this storage backend.
```

---

## Capturing Storage-Server–Side Metrics

The script captures client-observable metrics. For a complete picture, also collect server-side metrics manually during each tier run.

### Linux NFS server (`/proc/net/rpc/nfsd`)

```bash
# On the NFS server, sample every 10s during the benchmark
watch -n 10 'cat /proc/net/rpc/nfsd | grep -E "th|io|net|rpc"'
```

### NetApp / Isilon / EMC

Use the vendor CLI or REST API to capture:
- `throughput_read_MB/s`, `throughput_write_MB/s`
- `latency_read_ms`, `latency_write_ms`
- `ops_per_sec`
- `disk_queue_depth`

### OpenStack Manila (shared file service)

```bash
openstack share show <share-id>   # shows current status
ceilometer statistics -m manila.share.capacity.used
```

---

## Using Results in Autoscaling Policy

Once saturation thresholds are quantified:

1. Set `worker_autoscaling_max` in `variables.hcl` to the **tier below the first saturated tier**.
   For the example above, set `worker_autoscaling_max = 500` (one tier below 1000).

2. Configure the autoscaler ramp rate so that the cluster never exceeds the safe tier in a single
   scale-out event. A conservative ramp adds at most 10% of the current count per interval.

3. Document the results in your deployment's `examples/<environment>.hcl` as comments:

   ```hcl
   # Benchmark result (2024-03-15, client: nomad-client-01, NFS: 1GbE RAID-6 NAS):
   # Saturation at tier 1000; safe ceiling = 500 concurrent workers.
   worker_autoscaling_max = 500
   ```

4. Re-run this benchmark after any storage infrastructure change (NFS server upgrade, network
   bandwidth increase, switch to CSI NFS) to update the documented thresholds.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `fio: No such file or directory` for `--directory` | NFS mount not present or permission denied | Verify mount and write access |
| `sar: cannot open /var/log/sa/saXX` | sysstat not collecting data | `systemctl enable --now sysstat` |
| `nfsstat: no stats found` | NFS client module not loaded | `modprobe nfs && mount -a` |
| Very low write_bw at tier 250 | NFS mount options suboptimal | See [NFS tuning guide](storage.md) — add `rsize=1048576,wsize=1048576,async` |
| Script exits immediately with `NFS mount not found WARNING` | Path is correct but `mount` output differs | Add `--nfs-mount` pointing to the actual mountpoint; script continues |

---

## Artifact Retention

Results in `benchmark-results/` should be committed (or archived) alongside the deployment configuration:

```
benchmark-results/
  tier-250/
    summary.json          ← structured metrics
    fio-randwrite.json    ← fio output (write phase)
    fio-seqread.json      ← fio output (read phase)
    iostat.txt
    vmstat.txt
    sar-nfs.txt
    sar-net.txt
    nfsstat-before.txt
    nfsstat-after.txt
  tier-500/
    ...
```

Add `benchmark-results/` to `.gitignore` if you do not want raw metric files in the repository, but always keep the `summary.json` files for historical comparison.
