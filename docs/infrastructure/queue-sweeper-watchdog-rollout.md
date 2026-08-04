# Queue-Sweeper / Stall-Watchdog Rollout Runbook

Use this runbook when changing `queue-sweeper.nomad.tpl`, watchdog logic, or related variables.

---

## 1. Pre-deploy safety checklist

- [ ] Render succeeds with intended flags:
  ```bash
  nomad-pack render packs/openstudio-server
  nomad-pack render -var "enable_queue_sweeper=true" -var "enable_stall_watchdog=true" -var "queue_sweeper_cron=*/5 * * * *" -var "stall_watchdog_cron=*/5 * * * *" packs/openstudio-server
  ```
- [ ] If both queue sweeper and watchdog are enabled, `queue_sweeper_cron == stall_watchdog_cron` (consolidated scheduler invariant).
- [ ] No legacy standalone watchdog job exists:
  ```bash
  nomad job status <job_name>-stall-watchdog || true
  ```
- [ ] If legacy job exists, purge it before deploy:
  ```bash
  nomad job stop -purge <job_name>-stall-watchdog
  ```

---

## 2. Deploy sequence

```bash
nomad-pack run --name <job_name> -var-file <your-vars.hcl> packs/openstudio-server
```

The deploy scripts now auto-purge known legacy standalone watchdog jobs and retry once when `nomad-pack run` fails on legacy pack metadata queries (`pack.deployment_name` / "Failed To Query For Previously Deployed Jobs").

---

## 3. Forced-run validation (required)

After deploy, force one cycle and validate logs immediately:

```bash
nomad job periodic force <job_name>-queue-sweeper
nomad job status <job_name>-queue-sweeper
```

Then inspect the newest allocation:

```bash
ALLOC_ID=$(nomad job allocs -json <job_name>-queue-sweeper | jq -r '.[0].ID')
nomad alloc logs -stderr "$ALLOC_ID" sweep || true
nomad alloc logs -stderr "$ALLOC_ID" detect || true
```

Expected healthy signals:
- queue-sweeper: `queue_sweeper_start`, `queue_sweeper_summary`
- watchdog: `stall_watchdog_start`, then either `stall_watchdog_clean` or controlled alert output
- transient Consul pressure: `action=skip_cycle` (exit 0, non-fatal)

---

## 4. Alerting and signals to wire

## Required operational signals

1. **Exceeded allowed attempts** (Nomad task restart policy exhaustion)
   - Signal source: Nomad allocation events / task state.
   - Fast check:
     ```bash
     nomad job status <job_name>-queue-sweeper
     ```
   - Trigger condition: repeated non-zero exits causing restart budget exhaustion.

2. **Watchdog non-zero exit spikes**
   - Signal source: `detect` task exit codes from recent periodic allocs.
   - Fast check:
     ```bash
     nomad job allocs -json <job_name>-queue-sweeper | jq -r '.[] | [.ID[0:8], .ClientStatus, (.TaskStates.detect.Events[-1].ExitCode // "n/a")] | @tsv'
     ```

3. **Consul 429 / 5xx rate**
   - Signal source: logs containing:
     - `queue_sweeper_warn msg=consul_transient`
     - `stall_watchdog_warn msg=consul_transient`
   - Prometheus/Loki-style filter should alert on sustained rate increases.
   - Fast local check:
     ```bash
     ./scripts/check-queue-sweeper-consul-transient-rate.sh --job-name <job_name> --namespace <ns>
     ```

Rule-load verification:

```bash
./scripts/check-prometheus-openstudio-rules.sh --prometheus-url http://<prometheus-host>:9090
```

---

## 5. Short-lived periodic alloc forensic workflow

Periodic alloc logs can disappear quickly after GC. Capture evidence immediately:

1. Save current alloc list:
   ```bash
   nomad job allocs -json <job_name>-queue-sweeper > /tmp/<job_name>-queue-sweeper-allocs.json
   ```
2. Pull stdout/stderr for the newest failed alloc:
   ```bash
   ALLOC_ID=$(jq -r 'map(select(.ClientStatus!="running")) | .[0].ID // empty' /tmp/<job_name>-queue-sweeper-allocs.json)
   nomad alloc logs "$ALLOC_ID" > /tmp/${ALLOC_ID}-stdout.log || true
   nomad alloc logs -stderr "$ALLOC_ID" > /tmp/${ALLOC_ID}-stderr.log || true
   nomad alloc status "$ALLOC_ID" > /tmp/${ALLOC_ID}-status.txt || true
   ```
3. If alloc already GC'd, immediately force a replacement run:
   ```bash
   nomad job periodic force <job_name>-queue-sweeper
   ```
   Then repeat capture steps.

Automated evidence capture helper:

```bash
./scripts/capture-periodic-forensics.sh --job-name <job_name> --namespace <ns>
```

---

## 6. Post-deploy invariants

- Only one scheduler source for watchdog logic: `<job_name>-queue-sweeper`
- No `<job_name>-stall-watchdog` standalone job
- `queue_sweeper_cron` and `stall_watchdog_cron` aligned when both features are enabled
- Transient Consul control-plane pressure does not fail the periodic cycle
