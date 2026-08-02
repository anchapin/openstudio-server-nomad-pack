# Worker Local Scratch — Staged Artifact Publish

## Why local scratch reduces NFS pressure

OpenStudio simulations produce a large number of intermediate files during execution (IDF fragments, EnergyPlus run directory, result CSVs, log files). Without local scratch, every write goes directly to the shared NFS mount. Under load — many concurrent workers, each running a multi-step simulation — this generates **write amplification**: hundreds of small, random writes from every node, all funnelled through the NFS server simultaneously. NFS throughput is bounded by server IOPS, not worker count, so adding workers can actually slow down individual simulations rather than improving throughput.

With local scratch, each worker stages its simulation workspace to a **node-local ephemeral disk**. Only the final simulation artifacts (results, OSW, compressed output) are copied to shared NFS at task completion. Write amplification on the shared filesystem drops proportionally to the ratio of (intermediate I/O) / (final artifact size), typically 10–50× for OpenStudio runs.

## How `ephemeral_disk` works in Nomad

Nomad's [`ephemeral_disk`](https://developer.hashicorp.com/nomad/docs/job-specification/ephemeral_disk) stanza provisions local disk space for a task group from the client node's configured disk. It is:

- **Allocation-scoped**: shared across all tasks in the group at `${NOMAD_ALLOC_DIR}`.
- **Local to the node**: data is never replicated, never shared with other clients.
- **Cleared on GC**: when an allocation is stopped and garbage collected, the disk is freed.
- **Not a volume**: it is not a Nomad CSI or host volume — it is carved from the client's `data_dir`.

The `size` field sets the requested size in MB. Nomad will reject placements where the remaining disk on the client falls below this threshold.

```hcl
ephemeral_disk {
  size    = 10240   # 10 GiB
  sticky  = false   # cleared on reschedule
  migrate = true    # copy data on sticky reschedule
}
```

The allocation directory is available inside containers as `${NOMAD_ALLOC_DIR}` (mapped to `/alloc` by default). The `worker_scratch_path` variable (`/scratch` by default) maps to `${NOMAD_ALLOC_DIR}/scratch` — Nomad automatically creates subdirectories under the alloc dir for tasks.

## Lifecycle

| Event | Behaviour |
|---|---|
| Allocation placed | `ephemeral_disk` storage is reserved on the client node |
| `wait-for-deps` prestart runs | Scratch directory exists but is empty |
| Worker task starts | Application may stage inputs to `WORKER_SCRATCH_PATH` |
| Simulation runs | Intermediate files written to `WORKER_SCRATCH_PATH` |
| Simulation completes | **Application must copy final artifacts to shared NFS before returning** |
| Task exits cleanly | Allocation is GC'd; scratch data is deleted |
| Task fails / restarts | Scratch data persists until GC (may be reused if `sticky = true`) |
| Client drain / reschedule | If `sticky = true` and `migrate = true`, Nomad copies scratch data to the new node |

## Application responsibility

Enabling `worker_local_scratch_enabled = true` **only** provisions the disk and sets the `WORKER_SCRATCH_PATH` environment variable. The **OpenStudio Server application** is responsible for:

1. Detecting `WORKER_SCRATCH_PATH` and using it as the simulation run directory.
2. Running the full simulation within `WORKER_SCRATCH_PATH`.
3. **Copying final artifacts** (results archive, OSW, reports) to the shared NFS path (e.g., `/mnt/openstudio/<analysis_id>/`) before the worker task exits.
4. Handling partial copy failure gracefully (retry the copy, or fall back to marking the run as failed).

If the application exits without copying, results are lost. There is no automatic migration of scratch data to NFS.

## Recommended configuration for OpenStack

```hcl
worker_local_scratch_enabled = true
worker_local_scratch_size    = 10240   # 10 GiB — increase for large models
worker_local_scratch_sticky  = false   # ephemeral; clear on reschedule
worker_scratch_path          = "/scratch"
```

On OpenStack Nova instances, local ephemeral disk is typically fast NVMe or SSD. This configuration gives each worker 10 GiB of fast local I/O, reducing NFS traffic to final-artifact-only writes.

For very large parametric runs (> 5 GiB intermediate workspace), increase `worker_local_scratch_size` proportionally. Monitor Nomad client disk utilisation (`nomad node status -verbose <node-id>`) to ensure the host does not run out of disk space under concurrent allocations.

## Cleanup and retry-safe patterns

- **`sticky = false` (default)**: scratch is discarded on GC. Safe for stateless simulations that can be re-run from scratch inputs. If the worker crashes, Nomad reschedules on any eligible node and starts fresh.
- **`sticky = true`**: Nomad tries to reschedule on the same node. If the node is unavailable, the allocation is placed elsewhere with an empty disk. Use only when staging inputs is expensive and intermediate checkpoint files are useful for resuming.
- **`migrate = true`** (always set when `sticky = true`): tells Nomad to copy the scratch contents to the new node during a live migration (e.g., node drain). Without `migrate = true`, data is lost even on planned drains.
- **Idempotent publish**: the application should write final artifacts to NFS using a temporary name and atomic rename (`mv`) to prevent downstream consumers from reading partial results.

## Interaction with Swift/object storage backend (issue #357)

When the Swift storage backend (issue #357) is implemented, the artifact publish step changes from NFS copy to a Swift `PUT`. The `WORKER_SCRATCH_PATH` workflow is identical — the application runs the simulation in scratch, then uploads to Swift instead of copying to NFS. The `worker_local_scratch_*` variables and `ephemeral_disk` stanza remain unchanged; only the application's publish logic changes.

When both features are active, shared NFS (`nfs_shared_volume_enabled`) can potentially be disabled for worker tasks, as the only shared-FS usage was the artifact publish path.
