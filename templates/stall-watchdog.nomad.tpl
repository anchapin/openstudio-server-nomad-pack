[[ if var "enable_stall_watchdog" . ]]
# stall-watchdog — periodic batch job that detects data points frozen in
# "started" status with no updated_at progress for longer than
# stall_watchdog_max_stall_seconds.  This covers the failure mode where
# EnergyPlus hangs silently inside a worker container without crashing Resque,
# leaving all worker slots occupied with no throughput.
#
# Complements the queue-sweeper (which clears stale resque:analysis:*:queuing
# Redis locks) — these are two distinct stall failure modes.
#
# When stalled DPs are found and stall_watchdog_restart_allocs = true, all
# running worker allocations are stopped.  Nomad reschedules fresh allocations
# automatically and the analysis coordinator jobs re-queue the stalled DPs.
job "[[ var "job_name" . ]]-stall-watchdog" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "batch"

  priority = [[ var "web_priority" . ]]

  periodic {
    cron             = "[[ var "stall_watchdog_cron" . ]]"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "stall-watchdog" {
    count = 1

    [[ template "openstudio_server.restart_block" (dict "attempts" 2 "interval" "5m" "delay" "15s" "mode" "fail") ]]

    network {
      mode = "host"
    }

    task "detect" {
      driver = "docker"

      config {
        image           = "[[ var "stall_watchdog_image" . ]]"
        command         = "python3"
        args            = ["/local/watchdog.py"]
        network_mode    = "host"
        readonly_rootfs = false
      }

      template {
        destination = "local/watchdog.py"
        perms       = "644"
        data        = <<EOH
#!/usr/bin/env python3
"""
Stall watchdog for OpenStudio Server.

Detects data points frozen in 'started' status with no updated_at progress
for longer than MAX_STALL_SECONDS.  When stalled DPs are found, optionally
stops all running worker allocations so Nomad reschedules fresh workers.

Exit codes:
  0  No stalled DPs (or started == 0)
  1  Error
  2  Stalled DPs found (restart_allocs=false) or restarted (restart_allocs=true)
"""
import json
import sys
import re
from datetime import datetime, timezone, timedelta
from urllib.request import urlopen, Request
from urllib.error import URLError

WEB_URL       = "{{ with service "openstudio-web" }}http://{{ (index . 0).Address }}:{{ (index . 0).Port }}{{ else }}http://localhost:[[ var "web_port" . ]]{{ end }}"
NOMAD_ADDR    = "[[ if ne (var "stall_watchdog_nomad_address" .) "" ]][[ var "stall_watchdog_nomad_address" . ]][[ else ]]http://localhost:4646[[ end ]]"
WORKER_JOB    = "[[ if ne (var "stall_watchdog_worker_job" .) "" ]][[ var "stall_watchdog_worker_job" . ]][[ else ]][[ var "job_name" . ]]-worker[[ end ]]"
NAMESPACE     = "[[ var "nomad_namespace" . ]]"
MAX_STALL     = [[ var "stall_watchdog_max_stall_seconds" . ]]
RESTART_ALLOCS = [[ if var "stall_watchdog_restart_allocs" . ]]True[[ else ]]False[[ end ]]

def fetch_json(url, timeout=10):
    req = Request(url, headers={"Accept": "application/json"})
    with urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def fetch_text(url, timeout=15):
    with urlopen(url, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")

def log(msg):
    print(msg, flush=True)

def main():
    log(f"stall_watchdog_start web={WEB_URL} nomad={NOMAD_ADDR} max_stall={MAX_STALL}s restart_allocs={RESTART_ALLOCS}")

    # 1. Quick check: any DPs currently started?
    try:
        status = fetch_json(f"{WEB_URL}/status.json")
    except Exception as e:
        log(f"stall_watchdog_error msg=could_not_reach_web detail={e}")
        sys.exit(1)

    dp = status.get("data_points", {})
    started = dp.get("started", 0)
    completed = dp.get("completed", 0)
    total = dp.get("count", 0)

    log(f"stall_watchdog_status completed={completed} started={started} total={total}")

    if started == 0:
        log("stall_watchdog_clean msg=no_started_dps")
        sys.exit(0)

    # 2. Sample DP IDs from Resque working page (RunSimulateDataPoint jobs)
    now = datetime.now(timezone.utc)
    stall_threshold = now - timedelta(seconds=MAX_STALL)

    try:
        working_html = fetch_text(f"{WEB_URL}/resque/working")
        dp_ids = list(dict.fromkeys(
            re.findall(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", working_html)
        ))
    except Exception as e:
        log(f"stall_watchdog_error msg=could_not_reach_resque detail={e}")
        sys.exit(1)

    log(f"stall_watchdog_sampling dp_ids_found={len(dp_ids)}")

    if not dp_ids:
        log("stall_watchdog_clean msg=no_dp_ids_in_working_page")
        sys.exit(0)

    # 3. Check updated_at on sampled DPs
    stalled = []
    checked = 0
    for dp_id in dp_ids[:20]:  # sample up to 20; stall is systemic so a sample is sufficient
        try:
            dp_data = fetch_json(f"{WEB_URL}/data_points/{dp_id}.json", timeout=5)
            dp_obj = dp_data.get("data_point", dp_data)
            if dp_obj.get("status") != "started":
                continue
            updated_raw = dp_obj.get("updated_at", "")
            if not updated_raw:
                continue
            # Parse ISO timestamp (handles +00:00 and Z suffixes)
            updated_str = str(updated_raw).replace("Z", "+00:00").split(".")[0]
            if "+" not in updated_str and updated_str.endswith(":00"):
                updated_str += "+00:00"
            try:
                updated_at = datetime.fromisoformat(updated_str.replace("+00:00", "")).replace(tzinfo=timezone.utc)
            except ValueError:
                continue
            idle_secs = int((now - updated_at).total_seconds())
            checked += 1
            if updated_at < stall_threshold:
                stalled.append({"id": dp_id, "idle_secs": idle_secs, "updated_at": str(updated_raw)[:19]})
                log(f"stall_watchdog_stalled dp={dp_id} idle={idle_secs}s updated_at={str(updated_raw)[:19]}")
            else:
                log(f"stall_watchdog_active  dp={dp_id} idle={idle_secs}s (< {MAX_STALL}s threshold)")
        except Exception as e:
            log(f"stall_watchdog_skip dp={dp_id} reason={e}")

    log(f"stall_watchdog_sample_summary checked={checked} stalled={len(stalled)}")

    if not stalled:
        log("stall_watchdog_clean msg=no_stalled_dps_in_sample")
        sys.exit(0)

    # 4. Stalled DPs detected
    log(f"stall_watchdog_alert stalled_count={len(stalled)} restart_allocs={RESTART_ALLOCS}")
    # Emit a distinct structured alert for monitoring: Mongo says 'started' but no
    # active Resque worker entry exists — classic Mongo/Redis queue divergence.
    log(f"queue_divergence_alert stale_started={len(stalled)} threshold={MAX_STALL}s action={'restart_workers' if RESTART_ALLOCS else 'alert_only'}")

    if not RESTART_ALLOCS:
        log("stall_watchdog_alert_only msg=restart_allocs_disabled set stall_watchdog_restart_allocs=true to auto-recover")
        sys.exit(2)

    # 5. Stop all running worker allocations
    try:
        allocs_url = f"{NOMAD_ADDR}/v1/job/{WORKER_JOB}/allocations?namespace={NAMESPACE}"
        allocs = fetch_json(allocs_url)
    except Exception as e:
        log(f"stall_watchdog_error msg=could_not_list_allocs detail={e}")
        sys.exit(1)

    running = [a["ID"] for a in allocs if a.get("ClientStatus") == "running"]
    log(f"stall_watchdog_restart running_allocs={len(running)}")

    restarted = 0
    for alloc_id in running:
        try:
            stop_url = f"{NOMAD_ADDR}/v1/allocation/{alloc_id}/stop"
            req = Request(stop_url, data=b"", method="POST")
            with urlopen(req, timeout=10) as r:
                result = json.loads(r.read().decode())
            eval_id = result.get("EvalID", "?")[:8]
            log(f"stall_watchdog_stopped alloc={alloc_id[:8]} eval={eval_id}")
            restarted += 1
        except Exception as e:
            log(f"stall_watchdog_stop_failed alloc={alloc_id[:8]} reason={e}")

    log(f"stall_watchdog_summary stalled_dps={len(stalled)} allocs_stopped={restarted}")
    log("stall_watchdog_recovery msg=nomad_will_reschedule_fresh_workers")
    sys.exit(2)

if __name__ == "__main__":
    main()
EOH
      }

      resources {
        cpu    = [[ var "stall_watchdog_cpu" . ]]
        memory = [[ var "stall_watchdog_memory" . ]]
      }
    }
  }
}
[[ end ]]
