# Queue-Stall Incident Response Runbook

Use this runbook when the OpenStudio worker fleet is no longer draining the Resque
queues, workers are crash-looping after a rollout, or stale `analysis_zip.lock` files
are preventing analyses from starting cleanly.

---

## 1. Scope and prerequisites

Set the shared context first so every command below is copy/paste-ready:

```bash
export NOMAD_ADDR=http://<nomad-server>:4646
export NOMAD_NAMESPACE=default
export NOMAD_DC=dc1
export WEB_URL=http://<openstudio-web-host>
export WORKER_JOB=openstudio-server-worker
export QUEUE_SWEEPER_JOB=openstudio-server-queue-sweeper
export SHARED_ROOT=/mnt/openstudio
mkdir -p artifacts/queue-stall
```

If ACLs are enabled, also export `NOMAD_TOKEN` before running any Nomad command.

---

## 2. Diagnosis

Work through the checks in this order. Do not roll workers until you know whether the
problem is a bad deployment, stale locks, or repeated worker crashes.

### 2.1 Check Resque queue depth and failed count

```bash
curl -s "${WEB_URL}/resque/overview" | tee artifacts/queue-stall/resque-overview.html >/dev/null
```

Open `artifacts/queue-stall/resque-overview.html` in a browser and record:

- `analyses` queue depth
- `background` queue depth
- `Failed` count

**Escalation signal:** queue depth is flat or increasing for 10–15 minutes while workers
are nominally `running`.

### 2.2 Check worker job version distribution

Start with the human-readable allocation list:

```bash
nomad job allocs "${WORKER_JOB}"
```

Then summarize running allocations by Nomad job version:

```bash
nomad job allocs -json "${WORKER_JOB}" | python3 -c $'
import collections, json, sys
counts = collections.Counter()
for alloc in json.load(sys.stdin):
    if alloc.get("ClientStatus") != "running":
        continue
    counts[str(alloc.get("JobVersion", alloc.get("Version", "unknown")))] += 1
for version, count in sorted(counts.items(), key=lambda item: int(item[0])):
    print(f"version={version} running_allocs={count}")
'
```

**Escalation signal:** more than one version remains `running` after a revert or rollout,
or the newest version is the only version crash-looping.

### 2.3 Check for stale `analysis_zip.lock` files

Inspect first:

```bash
find "${SHARED_ROOT}" -type f -name 'analysis_zip.lock' -print \
  | tee artifacts/queue-stall/analysis-zip-locks.txt
```

Count them:

```bash
wc -l < artifacts/queue-stall/analysis-zip-locks.txt
```

If you need age information before deleting anything:

```bash
while IFS= read -r lock_path; do
  ls -l "$lock_path"
done < artifacts/queue-stall/analysis-zip-locks.txt
```

**Escalation signal:** lock files remain present even after the corresponding worker alloc
has stopped or the owning analysis is no longer active.

### 2.4 Read worker stderr for crash-loop indicators

List recent running or recently failed allocations:

```bash
nomad job allocs "${WORKER_JOB}"
```

Inspect stderr from a suspicious allocation:

```bash
nomad alloc logs -stderr <alloc-id> worker | tail -n 200
```

Look for repeated indicators such as:

- `PruneDeadWorkerDirtyExit`
- `TermException`
- OOM / `Killed`
- repeated `analysis_zip.lock` or unzip collisions
- dependency resolution or startup failures that repeat on every restart

### 2.5 Check Nomad allocation restart counts

For one allocation:

```bash
nomad alloc status <alloc-id>
```

For a fleet summary:

```bash
for alloc_id in $(nomad job allocs -json "${WORKER_JOB}" | python3 -c $'
import json, sys
for alloc in json.load(sys.stdin):
    if alloc.get("ClientStatus") in {"running", "pending"}:
        print(alloc["ID"])
'
); do
  printf '=== %s ===\n' "${alloc_id:0:8}"
  nomad alloc status "${alloc_id}" | grep -E 'Restarts|Total Restarts|Recent Events' || true
done | tee artifacts/queue-stall/restart-summary.txt
```

**Escalation signal:** restart counts keep increasing, or alloc status shows the worker is
cycling between `running` and `failed`.

---

## 3. Recovery steps

Use the smallest intervention that addresses the actual fault. In most incidents the
correct order is: roll back the bad worker version, clear stale locks, then drain the old
allocations in controlled batches.

### 3.1 Identify and roll back the bad worker job version

Review history first:

```bash
nomad job history "${WORKER_JOB}"
```

Revert to the last known-good version:

```bash
nomad job revert "${WORKER_JOB}" <good-version>
```

Re-check the active version immediately:

```bash
nomad job status "${WORKER_JOB}"
nomad job allocs "${WORKER_JOB}"
```

> **Important:** a revert updates the job spec, but old allocations may still be running.
> Finish the rollback by draining allocations that are still on the bad version.

### 3.2 Remove stale lock files manually

Only remove locks after you have confirmed the owning allocation is gone or has been
rolled back.

Preview:

```bash
find "${SHARED_ROOT}" -type f -name 'analysis_zip.lock' -print
```

Delete:

```bash
find "${SHARED_ROOT}" -type f -name 'analysis_zip.lock' -delete
```

Confirm:

```bash
find "${SHARED_ROOT}" -type f -name 'analysis_zip.lock' -print | wc -l
```

### 3.3 Remove stale lock files via a one-shot lock-sweeper job

Use this when you need an auditable Nomad batch job rather than an interactive shell on
the shared filesystem host.

Create a JSON job file with Python so you avoid shell/HCL heredoc quoting problems:

```bash
python3 - <<'PY' > artifacts/queue-stall/lock-sweeper.nomad.json
import json
import os

shared_root = os.environ.get("SHARED_ROOT", "/mnt/openstudio")

job = {
    "Job": {
        "ID": "queue-lock-sweeper",
        "Name": "queue-lock-sweeper",
        "Type": "batch",
        "Datacenters": [os.environ.get("NOMAD_DC", "dc1")],
        "Namespace": os.environ.get("NOMAD_NAMESPACE", "default"),
        "TaskGroups": [
            {
                "Name": "sweep",
                "Count": 1,
                "Tasks": [
                    {
                        "Name": "lock-sweeper",
                        "Driver": "docker",
                        "Config": {
                            "image": "alpine:3.20",
                            "command": "sh",
                            "args": [
                                "-lc",
                                f"find {shared_root} -type f -name analysis_zip.lock -print -delete",
                            ],
                            "mounts": [
                                {
                                    "type": "bind",
                                    "source": shared_root,
                                    "target": shared_root,
                                }
                            ],
                        },
                    }
                ],
            }
        ],
    }
}

print(json.dumps(job))
PY

nomad job run artifacts/queue-stall/lock-sweeper.nomad.json
nomad job status queue-lock-sweeper
```

If your shared storage is mounted somewhere other than `/mnt/openstudio`, update
`SHARED_ROOT` and regenerate the job JSON with the correct bind mount/source path.

### 3.4 Drain old worker allocations in batches

After the revert, stop only the allocations that are still on the bad version. Do **not**
blast the entire fleet with `nomad job restart`.

Preview the drain set:

```bash
./scripts/drain-workers.sh --job "${WORKER_JOB}" --target-version <good-version> --dry-run
```

Drain in controlled batches:

```bash
./scripts/drain-workers.sh --job "${WORKER_JOB}" --target-version <good-version>
```

The script uses `POST /v1/allocation/:id/stop` and batches stop requests so large fleets
do not trigger control-plane `429` responses.

### 3.5 Force one queue-sweeper cycle if Redis queue state still looks stale

```bash
nomad job periodic force "${QUEUE_SWEEPER_JOB}"
nomad job status "${QUEUE_SWEEPER_JOB}"
```

Inspect the latest queue-sweeper stderr:

```bash
ALLOC_ID=$(nomad job allocs -json "${QUEUE_SWEEPER_JOB}" | python3 -c $'import json, sys; allocs = json.load(sys.stdin); print(allocs[0]["ID"] if allocs else "")')
nomad alloc logs -stderr "${ALLOC_ID}" sweep
```

Use this after lock cleanup if the failed queue still contains recoverable infra failures
such as `PruneDeadWorkerDirtyExit`.

---

## 4. Validation

Do not close the incident until all four checks below are true.

### 4.1 Queue is shrinking for at least 15 minutes

Capture three 5-minute samples:

```bash
for sample in 1 2 3; do
  printf 'sample=%s time=%s\n' "$sample" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a artifacts/queue-stall/queue-trend.txt
  curl -s "${WEB_URL}/resque/overview" >> artifacts/queue-stall/queue-trend.txt
  sleep 300
done
```

Pass criteria:

- `analyses` queue depth trends down
- `background` queue depth is stable or trending down
- failed count is flat or decreasing after the rollback

### 4.2 All worker allocations are on the target version

```bash
nomad job allocs -json "${WORKER_JOB}" | python3 -c $'
import collections, json, sys
counts = collections.Counter()
for alloc in json.load(sys.stdin):
    if alloc.get("ClientStatus") != "running":
        continue
    counts[str(alloc.get("JobVersion", alloc.get("Version", "unknown")))] += 1
for version, count in sorted(counts.items(), key=lambda item: int(item[0])):
    print(f"version={version} running_allocs={count}")
'
```

Pass criteria: only the intended target version is present.

### 4.3 Stale lock count is zero

```bash
find "${SHARED_ROOT}" -type f -name 'analysis_zip.lock' -print | wc -l
```

Pass criteria: output is `0`.

### 4.4 No workers have been running for 5+ hours

Long-running workers often indicate old allocations that were never drained.

```bash
nomad job allocs -json "${WORKER_JOB}" | python3 -c $'
import json, sys
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
for alloc in json.load(sys.stdin):
    if alloc.get("ClientStatus") != "running":
        continue
    create_time = alloc.get("CreateTime")
    if not create_time:
        continue
    started = datetime.fromtimestamp(create_time / 1_000_000_000, tz=timezone.utc)
    age_hours = (now - started).total_seconds() / 3600
    if age_hours >= 5:
        print(f"alloc={alloc['ID'][:8]} node={alloc.get('NodeName','unknown')} age_hours={age_hours:.2f}")
'
```

Pass criteria: no output.

---

## 5. Common pitfalls

- **`DELETE /v1/allocation/:id` is a no-op for this workflow.** Use
  `POST /v1/allocation/:id/stop` so Nomad creates a new evaluation and reschedules a
  replacement allocation.
- **`nomad job restart` is the wrong tool for a large worker fleet.** It can flood the
  Nomad API and trigger `HTTP 429` responses. Use `./scripts/drain-workers.sh` instead.
- **Avoid Nomad HCL heredocs that interpolate `default` or other shell-expanded values.**
  In incident shells this has caused parse/quoting failures. Generate JSON with Python or
  edit a checked-in file instead.

---

## 6. Exit criteria

The incident is resolved only when all of the following are true:

- queues are shrinking over a 15+ minute window
- failed count is no longer climbing
- every running worker allocation is on the target version
- stale `analysis_zip.lock` count is `0`
- no worker allocation older than 5 hours remains `running`
