[[ if or (var "enable_queue_sweeper" .) (var "enable_stall_watchdog" .) ]]
[[ if and (var "enable_queue_sweeper" .) (var "enable_stall_watchdog" .) (ne (var "queue_sweeper_cron" .) (var "stall_watchdog_cron" .)) ]]
[[ fail (print "INVARIANT VIOLATION: enable_queue_sweeper=true and enable_stall_watchdog=true require queue_sweeper_cron == stall_watchdog_cron in the consolidated scheduler job. Got queue_sweeper_cron='" (var "queue_sweeper_cron" .) "' and stall_watchdog_cron='" (var "stall_watchdog_cron" .) "'.") ]]
[[ end ]]
# queue-sweeper — periodic batch job for Redis queue sweeping and stall watchdog monitoring.
# Consolidates queue-sweeper and stall-watchdog task groups (fix #405).
job "[[ var "job_name" . ]]-queue-sweeper" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "batch"

  priority = [[ var "web_priority" . ]]

  periodic {
    cron             = "[[ if var "enable_queue_sweeper" . ]][[ var "queue_sweeper_cron" . ]][[ else ]][[ var "stall_watchdog_cron" . ]][[ end ]]"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  [[ if var "enable_queue_sweeper" . ]]
  group "queue-sweeper" {
    count = 1

    [[ template "openstudio_server.restart_block" (dict "attempts" 3 "interval" "2m" "delay" "10s" "mode" "fail") ]]

    task "sweep" {
      driver = "docker"

      config {
        image           = "[[ var "queue_sweeper_image" . ]]"
        command         = "/bin/sh"
        args            = ["/local/sweep.sh"]
        readonly_rootfs = false
      }

      # Resolve Redis address via Consul service DNS
      template {
        destination = "local/sweep.sh"
        perms       = "755"
        data        = <<EOH
#!/bin/sh
set -eu

REDIS_HOST="openstudio-redis.service.consul"
REDIS_PORT="6379"
MAX_AGE=[[ var "queue_sweeper_max_lock_age_seconds" . ]]
CONSUL_ADDR="[[ var "consul_address" . ]]"
CONSUL_RETRY_ATTEMPTS=[[ var "queue_sweeper_consul_retry_attempts" . ]]
CONSUL_RETRY_BACKOFF=[[ var "queue_sweeper_consul_retry_backoff_seconds" . ]]

resolve_service_ip_via_consul() {
  service="$1"
  attempt=1
  delay="$CONSUL_RETRY_BACKOFF"
  while [ "$attempt" -le "$CONSUL_RETRY_ATTEMPTS" ]; do
    http_meta="$(mktemp)"
    json="$(wget -qO- -T 2 -S "http://${CONSUL_ADDR}/v1/health/service/${service}?passing=true" 2>"$http_meta" || true)"
    status_code="$(sed -n 's/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' "$http_meta" | tail -n 1)"
    rm -f "$http_meta"
    ip=""
    if [ -n "$json" ] && command -v python3 >/dev/null 2>&1; then
      ip="$(printf '%s' "$json" | python3 -c 'import json,sys
data=json.load(sys.stdin)
for entry in data:
    svc=(entry or {}).get("Service") or {}
    node=(entry or {}).get("Node") or {}
    addr=svc.get("Address") or node.get("Address") or ""
    if addr:
        print(addr)
        break
')"
    fi
    if [ -z "$ip" ] && [ -n "$json" ]; then
      ip="$(printf '%s' "$json" | sed -n 's/.*"ServiceAddress":"\([^"]*\)".*/\1/p' | head -n 1)"
      if [ -z "$ip" ]; then
        ip="$(printf '%s' "$json" | sed -n 's/.*"Address":"\([^"]*\)".*/\1/p' | head -n 1)"
      fi
    fi
    if [ -n "$ip" ]; then
      printf '%s\n' "$ip"
      return 0
    fi
    if [ "$status_code" = "429" ] || { [ -n "$status_code" ] && [ "$status_code" -ge 500 ] && [ "$status_code" -lt 600 ]; }; then
      echo "queue_sweeper_warn msg=consul_transient status=${status_code} attempt=${attempt}/${CONSUL_RETRY_ATTEMPTS}" >&2
    fi
    sleep "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt 8 ] && delay=8
    attempt=$((attempt + 1))
  done
  return 1
}

redis_cmd() {
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"
}

if ! redis_cmd PING >/dev/null 2>&1; then
  REDIS_HOST="$(resolve_service_ip_via_consul "openstudio-redis" || true)"
fi

if [ -z "$REDIS_HOST" ] || ! redis_cmd PING >/dev/null 2>&1; then
  echo "queue_sweeper_warn msg=redis_unreachable action=skip_cycle" >&2
  exit 0
fi

echo "queue_sweeper_start redis=${REDIS_HOST}:${REDIS_PORT} max_age=${MAX_AGE}s"

stale=0
cleared=0

for key in $(redis_cmd --scan --pattern 'resque:analysis:*:queuing' 2>/dev/null); do
  [ -z "$key" ] && continue
  stale=$((stale + 1))

  ttl=$(redis_cmd TTL "$key" 2>/dev/null | tr -d '[:space:]')
  if [ "$ttl" = "-1" ]; then
    # No TTL — check idle time as a proxy for "this lock was never cleared"
    idle=$(redis_cmd OBJECT IDLETIME "$key" 2>/dev/null | tr -d '[:space:]')
    if echo "$idle" | grep -qE '^[0-9]+$' && [ "$idle" -ge "$MAX_AGE" ]; then
      result=$(redis_cmd DEL "$key" 2>/dev/null | tr -d '[:space:]')
      if [ "$result" = "1" ]; then
        echo "queue_sweeper_deleted key=${key} idle=${idle}s"
        cleared=$((cleared + 1))
      else
        echo "queue_sweeper_raced key=${key} (already gone)"
      fi
    else
      echo "queue_sweeper_skipped key=${key} idle=${idle}s (within grace period)"
    fi
  elif [ "$ttl" = "-2" ]; then
    echo "queue_sweeper_raced key=${key} (vanished)"
  else
    echo "queue_sweeper_active key=${key} ttl=${ttl}s (has TTL, skip)"
  fi
done

echo "queue_sweeper_lock_summary found=${stale} cleared=${cleared}"

replayed=0

[[ if var "queue_sweeper_replay_dirty_exit" . ]]
# --- Section 2: Auto-replay PruneDeadWorkerDirtyExit / TermException failures ---
# Workers killed mid-job during scale-down or node drain always produce
# PruneDeadWorkerDirtyExit. These are 100% infra-recoverable and must never require
# manual intervention.

REPLAY_DELAY=[[ var "queue_sweeper_replay_delay_seconds" . ]]
replayed=0
replay_skipped=0

failed_len=$(redis_cmd LLEN resque:failed 2>/dev/null | tr -d '[:space:]')
if [ -z "$failed_len" ]; then
  failed_len=0
fi
echo "queue_sweeper_failed_queue_check len=$failed_len"

if echo "$failed_len" | grep -qE '^[0-9]+$' && [ "$failed_len" -gt 0 ]; then
  all_failed=$(redis_cmd LRANGE resque:failed 0 -1 2>/dev/null)

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue

    is_infra_recoverable=false
    if echo "$entry" | grep -q '"exception":"PruneDeadWorkerDirtyExit"' || \
       echo "$entry" | grep -q '"exception":"Resque::PruneDeadWorkerDirtyExit"' || \
       echo "$entry" | grep -q '"exception":"TermException"'; then
      if echo "$entry" | grep -q '"class":"ResqueJobs::RunSimulateDataPoint"'; then
        is_infra_recoverable=true
      fi
    fi

    if [ "$is_infra_recoverable" != "true" ]; then
      replay_skipped=$((replay_skipped + 1))
      continue
    fi

    dp_id=$(printf '%s' "$entry" | sed -n 's/.*"args":\["\([0-9a-fA-F-]*\)"\].*/\1/p')
    if [ -z "$dp_id" ]; then
      echo "queue_sweeper_replay_skip reason=could_not_extract_dp_id"
      replay_skipped=$((replay_skipped + 1))
      continue
    fi

    payload="{\"class\":\"ResqueJobs::RunSimulateDataPoint\",\"args\":[\"${dp_id}\"]}"
    queue_len=$(redis_cmd RPUSH resque:queue:simulations "$payload" 2>/dev/null | tr -d '[:space:]')

    redis_cmd LREM resque:failed 1 "$entry" >/dev/null 2>&1 || true

    echo "queue_sweeper_replayed dp_id=${dp_id} queue_len=${queue_len}"
    replayed=$((replayed + 1))

    [ "$REPLAY_DELAY" -gt 0 ] && sleep "$REPLAY_DELAY"
  done <<REPLAY_EOF
$all_failed
REPLAY_EOF

  echo "queue_sweeper_replay_summary replayed=${replayed} skipped=${replay_skipped}"
fi
[[ end ]]

echo "queue_sweeper_summary locks_cleared=${cleared} replayed=${replayed}"
EOH
      }

      resources {
        cpu    = [[ var "queue_sweeper_cpu" . ]]
        memory = [[ var "queue_sweeper_memory" . ]]
      }

      env {
        REDIS_URL = "[[ var "web_redis_url" . ]]"
      }
    }
  }

  group "queue-health-alert" {
    count = 1

    [[ template "openstudio_server.restart_block" (dict "attempts" 0 "interval" "5m" "delay" "15s" "mode" "fail") ]]

    network {
      mode = "host"
    }

    task "detect" {
      driver = "docker"

      config {
        image           = "[[ var "stall_watchdog_image" . ]]"
        command         = "python3"
        args            = ["/local/health_alert.py"]
        network_mode    = "host"
        readonly_rootfs = false
      }

      template {
        destination = "local/health_alert.py"
        perms       = "644"
        data        = <<EOH
#!/usr/bin/env python3
"""
Queue effectiveness and worker health alerting.

Emits structured alert log lines and exits:
  0 = clean
  1 = execution error
  2 = alert condition detected
"""
import json
import math
import os
import socket
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

REDIS_SERVICE = "openstudio-redis"
REDIS_HOST = "openstudio-redis.service.consul"
REDIS_PORT = 6379
REDIS_PASSWORD = "[[ var "redis_password" . ]]"
CONSUL_ADDR = "[[ var "consul_address" . ]]"
CONSUL_RETRY_ATTEMPTS = [[ var "queue_sweeper_consul_retry_attempts" . ]]
CONSUL_RETRY_BACKOFF_SECONDS = [[ var "queue_sweeper_consul_retry_backoff_seconds" . ]]
NOMAD_ADDR = "[[ if ne (var "stall_watchdog_nomad_address" .) "" ]][[ var "stall_watchdog_nomad_address" . ]][[ else ]]http://localhost:4646[[ end ]]"
WORKER_JOB = "[[ if ne (var "stall_watchdog_worker_job" .) "" ]][[ var "stall_watchdog_worker_job" . ]][[ else ]][[ var "job_name" . ]]-worker[[ end ]]"
NAMESPACE = "[[ var "nomad_namespace" . ]]"
CRASHLOOP_THRESHOLD = [[ var "alert_crashloop_threshold" . ]]
STUCK_SCHEDULING_MINUTES = [[ var "alert_stuck_scheduling_minutes" . ]]
QUEUE_STAGNATION_MINUTES = [[ var "alert_queue_stagnation_minutes" . ]]
FAILED_DELTA_THRESHOLD = [[ var "alert_crashloop_threshold" . ]]
STATE_KEY = "openstudio:queue_health_alert:state"


class TransientControlPlaneError(Exception):
    pass


def log(message):
    print(message, flush=True)


def utc_now():
    return int(time.time())


def fetch_json(url, timeout=10):
    headers = {"Accept": "application/json"}
    token = os.environ.get("NOMAD_TOKEN", "").strip()
    if token:
        headers["X-Nomad-Token"] = token
    req = Request(url, headers=headers)
    with urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode())


def fetch_json_with_retry(url, timeout=10, attempts=CONSUL_RETRY_ATTEMPTS):
    delay = max(float(CONSUL_RETRY_BACKOFF_SECONDS), 0.1)
    last_exc = None
    for attempt in range(1, max(int(attempts), 1) + 1):
        try:
            return fetch_json(url, timeout=timeout)
        except HTTPError as exc:
            last_exc = exc
            if exc.code not in (429,) and not (500 <= exc.code < 600):
                raise
            log(
                f"queue_health_warn msg=consul_transient status={exc.code} "
                f"url={url} attempt={attempt}/{attempts}"
            )
        except URLError as exc:
            last_exc = exc
        if attempt < max(int(attempts), 1):
            time.sleep(delay)
            delay = min(delay * 2.0, 8.0)
    raise TransientControlPlaneError(
        f"transient_control_plane_unavailable attempts={attempts} url={url} last_error={last_exc}"
    )


def resolve_redis_host():
    try:
        redis_command("PING", host=REDIS_HOST)
        return REDIS_HOST
    except Exception:
        pass

    try:
        data = fetch_json_with_retry(
            f"http://{CONSUL_ADDR}/v1/health/service/{REDIS_SERVICE}?passing=true",
            timeout=5,
            attempts=CONSUL_RETRY_ATTEMPTS,
        )
    except Exception:
        return REDIS_HOST

    for entry in data or []:
        service = (entry or {}).get("Service") or {}
        node = (entry or {}).get("Node") or {}
        address = service.get("Address") or node.get("Address")
        if address:
            return address
    return REDIS_HOST


def read_exact(stream, count):
    data = b""
    while len(data) < count:
        chunk = stream.read(count - len(data))
        if not chunk:
            raise RuntimeError("unexpected EOF from Redis")
        data += chunk
    return data


def parse_redis_value(stream):
    prefix = stream.read(1)
    if not prefix:
        raise RuntimeError("empty Redis response")
    if prefix == b"+":
        return stream.readline().decode().rstrip("\r\n")
    if prefix == b"-":
        raise RuntimeError(stream.readline().decode().rstrip("\r\n"))
    if prefix == b":":
        return int(stream.readline().decode().rstrip("\r\n"))
    if prefix == b"$":
        size = int(stream.readline().decode().rstrip("\r\n"))
        if size == -1:
            return None
        data = read_exact(stream, size)
        read_exact(stream, 2)
        return data.decode()
    if prefix == b"*":
        size = int(stream.readline().decode().rstrip("\r\n"))
        if size == -1:
            return None
        return [parse_redis_value(stream) for _ in range(size)]
    raise RuntimeError(f"unsupported Redis response prefix: {prefix!r}")


def redis_command(*args, host=None):
    target_host = host or RESOLVED_REDIS_HOST
    payload = "".join(
        [f"*{len(args)}\r\n"]
        + [f"$${len(str(arg).encode())}\r\n{arg}\r\n" for arg in args]
    ).encode()
    with socket.create_connection((target_host, REDIS_PORT), timeout=5) as sock:
        stream = sock.makefile("rb")
        if REDIS_PASSWORD:
            auth_payload = (
                f"*2\r\n$4\r\nAUTH\r\n$${len(REDIS_PASSWORD.encode())}\r\n{REDIS_PASSWORD}\r\n"
            ).encode()
            sock.sendall(auth_payload)
            parse_redis_value(stream)
        sock.sendall(payload)
        return parse_redis_value(stream)


def redis_int(command, key):
    value = redis_command(command, key)
    if value is None:
        return 0
    return int(value)


def redis_text(command, key):
    value = redis_command(command, key)
    return "" if value is None else str(value)


def load_state():
    raw = redis_text("GET", STATE_KEY).strip()
    if not raw:
        return {}
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except json.JSONDecodeError:
        log("queue_health_warn msg=state_decode_failed action=reset_state")
    return {}


def save_state(state):
    redis_command("SET", STATE_KEY, json.dumps(state, sort_keys=True), "EX", "86400")


def fetch_alloc_detail(alloc_id):
    return fetch_json(f"{NOMAD_ADDR}/v1/allocation/{quote(alloc_id)}")


def alloc_age_minutes(alloc):
    reference_ns = alloc.get("ModifyTime") or alloc.get("CreateTime") or 0
    if not reference_ns:
        return 0.0
    return max((time.time_ns() - int(reference_ns)) / 1_000_000_000 / 60.0, 0.0)


def short_alloc_id(alloc_id):
    return str(alloc_id)[:8]


def summarize_allocs():
    allocs = fetch_json(
        f"{NOMAD_ADDR}/v1/job/{quote(WORKER_JOB)}/allocations?namespace={quote(NAMESPACE)}"
    )
    details = []
    crashloops = []
    stuck = []
    running = 0

    for alloc in allocs or []:
        if alloc.get("TaskGroup") != "worker":
            continue
        detail = fetch_alloc_detail(alloc.get("ID", ""))
        task_state = ((detail.get("TaskStates") or {}).get("worker") or {})
        client_status = str(detail.get("ClientStatus") or "unknown")
        worker_state = str(task_state.get("State") or client_status)
        restarts = int(task_state.get("Restarts") or 0)
        age_minutes = alloc_age_minutes(detail)
        alloc_summary = {
            "id": detail.get("ID", ""),
            "client_status": client_status,
            "worker_state": worker_state,
            "restarts": restarts,
            "age_minutes": age_minutes,
        }
        details.append(alloc_summary)

        if client_status == "running":
            running += 1
        if restarts >= CRASHLOOP_THRESHOLD:
            crashloops.append(alloc_summary)
        if (
            client_status in ("pending", "starting")
            or worker_state in ("pending", "starting")
        ) and age_minutes >= STUCK_SCHEDULING_MINUTES:
            stuck.append(alloc_summary)

    return details, running, crashloops, stuck


def main():
    global RESOLVED_REDIS_HOST

    try:
        RESOLVED_REDIS_HOST = resolve_redis_host()
        redis_command("PING")
    except Exception as exc:
        log(f"queue_health_error msg=redis_unreachable detail={exc}")
        sys.exit(1)

    try:
        allocs, workers_running, crashloops, stuck = summarize_allocs()
    except Exception as exc:
        log(f"queue_health_error msg=nomad_alloc_inspection_failed detail={exc}")
        sys.exit(1)

    total_allocs = len(allocs)
    simulations_depth = redis_int("LLEN", "resque:queue:simulations")
    failed_depth = redis_int("LLEN", "resque:failed")
    processed_total = int(redis_text("GET", "resque:stat:processed") or "0")
    failed_total = int(redis_text("GET", "resque:stat:failed") or "0")

    now = utc_now()
    state = load_state()
    previous_ts = int(state.get("ts") or 0)
    elapsed_seconds = max(now - previous_ts, 0)
    previous_depth = int(state.get("simulations_depth") or simulations_depth)
    previous_processed = int(state.get("processed_total") or processed_total)
    previous_failed = int(state.get("failed_total") or failed_total)
    depth_delta = simulations_depth - previous_depth
    processed_delta = processed_total - previous_processed
    failed_delta = failed_total - previous_failed
    velocity = 0.0
    if elapsed_seconds > 0:
        velocity = depth_delta / (elapsed_seconds / 60.0)

    stagnation_since = state.get("stagnation_since")
    stagnating = (
        workers_running > 0
        and simulations_depth > 0
        and elapsed_seconds > 0
        and depth_delta >= 0
        and processed_delta <= 0
    )

    if stagnating:
        if not stagnation_since:
            stagnation_since = previous_ts or now
    else:
        stagnation_since = None

    duration_seconds = max(now - int(stagnation_since or now), 0)
    duration_minutes = int(duration_seconds / 60)

    save_state(
        {
            "failed_total": failed_total,
            "processed_total": processed_total,
            "simulations_depth": simulations_depth,
            "stagnation_since": stagnation_since,
            "ts": now,
        }
    )

    alerting = False

    log(
        "queue_health_status "
        f"depth={simulations_depth} failed_depth={failed_depth} "
        f"processed_total={processed_total} failed_total={failed_total} "
        f"workers_running={workers_running} total_allocs={total_allocs} "
        f"velocity={velocity:.2f} processed_delta={processed_delta} failed_delta={failed_delta}"
    )

    if duration_seconds >= QUEUE_STAGNATION_MINUTES * 60 and stagnating:
        alerting = True
        log(
            "queue_stagnation_alert "
            f"depth={simulations_depth} velocity={velocity:.2f} "
            f"duration_min={duration_minutes} threshold_min={QUEUE_STAGNATION_MINUTES} "
            f"workers_running={workers_running} processed_delta={processed_delta}"
        )

    if failed_delta > FAILED_DELTA_THRESHOLD and elapsed_seconds > 0:
        alerting = True
        window_minutes = max(int(math.ceil(elapsed_seconds / 60.0)), 1)
        log(
            "failed_jobs_acceleration_alert "
            f"delta={failed_delta} threshold={FAILED_DELTA_THRESHOLD} "
            f"window_min={window_minutes} failed_total={failed_total}"
        )

    if crashloops:
        alerting = True
        crashloop_rate = len(crashloops) / max(total_allocs, 1)
        log(
            "worker_crashloop_alert "
            f"rate={crashloop_rate:.2f} threshold={CRASHLOOP_THRESHOLD} "
            f"crashloop_allocs={len(crashloops)} total_allocs={total_allocs} "
            f"allocs={','.join(short_alloc_id(a['id']) for a in crashloops[:10])}"
        )

    if stuck:
        alerting = True
        log(
            "worker_stuck_scheduling_alert "
            f"count={len(stuck)} threshold_min={STUCK_SCHEDULING_MINUTES} "
            f"allocs={','.join(short_alloc_id(a['id']) for a in stuck[:10])} "
            f"max_age_min={max(a['age_minutes'] for a in stuck):.1f}"
        )

    log(
        "queue_health_summary "
        f"alerting={'true' if alerting else 'false'} "
        f"depth={simulations_depth} workers_running={workers_running} "
        f"crashloop_allocs={len(crashloops)} stuck_allocs={len(stuck)}"
    )
    sys.exit(2 if alerting else 0)


RESOLVED_REDIS_HOST = REDIS_HOST

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
  [[ end ]]

  [[ if var "enable_stall_watchdog" . ]]
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
stops running worker allocations so Nomad reschedules fresh workers.

Exit codes:
  0  No stalled DPs (or started == 0)
  1  Error
  2  Stalled DPs found while restart_allocs=false (alert-only mode)
"""
import json
import sys
import re
import time
from datetime import datetime, timezone, timedelta
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

CONSUL_ADDR   = "[[ var "consul_address" . ]]"
WEB_URL       = ""
WEB_FALLBACK_URL = "http://openstudio-web.service.consul:[[ var "web_port" . ]]"
NOMAD_ADDR    = "[[ if ne (var "stall_watchdog_nomad_address" .) "" ]][[ var "stall_watchdog_nomad_address" . ]][[ else ]]http://localhost:4646[[ end ]]"
WORKER_JOB    = "[[ if ne (var "stall_watchdog_worker_job" .) "" ]][[ var "stall_watchdog_worker_job" . ]][[ else ]][[ var "job_name" . ]]-worker[[ end ]]"
NAMESPACE     = "[[ var "nomad_namespace" . ]]"
MAX_STALL     = [[ var "stall_watchdog_max_stall_seconds" . ]]
RESTART_ALLOCS = [[ if var "stall_watchdog_restart_allocs" . ]]True[[ else ]]False[[ end ]]
CONSUL_RETRY_ATTEMPTS = [[ var "stall_watchdog_consul_retry_attempts" . ]]
CONSUL_RETRY_BACKOFF_SECONDS = [[ var "stall_watchdog_consul_retry_backoff_seconds" . ]]

class TransientControlPlaneError(Exception):
    pass

def fetch_json(url, timeout=10):
    req = Request(url, headers={"Accept": "application/json"})
    with urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def fetch_text(url, timeout=15):
    with urlopen(url, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")

def fetch_json_with_retry(url, timeout=10, attempts=CONSUL_RETRY_ATTEMPTS):
    delay = max(float(CONSUL_RETRY_BACKOFF_SECONDS), 0.1)
    last_exc = None
    for attempt in range(1, max(attempts, 1) + 1):
        try:
            return fetch_json(url, timeout=timeout)
        except HTTPError as e:
            last_exc = e
            if e.code not in (429,) and not (500 <= e.code < 600):
                raise
            log(f"stall_watchdog_warn msg=consul_transient status={e.code} url={url} attempt={attempt}/{attempts}")
            time.sleep(delay)
            delay = min(delay * 2.0, 8.0)
        except URLError:
            last_exc = None
            time.sleep(delay)
            delay = min(delay * 2.0, 8.0)
    raise TransientControlPlaneError(f"transient_consul_unavailable attempts={attempts} url={url} last_error={last_exc}")

def resolve_web_url():
    # Prefer Consul DNS first to avoid hammering the Consul HTTP health endpoint.
    try:
        fetch_json_with_retry(f"{WEB_FALLBACK_URL}/status.json", timeout=5, attempts=2)
        return WEB_FALLBACK_URL
    except Exception:
        pass

    data = fetch_json_with_retry(f"http://{CONSUL_ADDR}/v1/health/service/openstudio-web?passing=true", timeout=10, attempts=4)
    if not data:
        raise RuntimeError("no passing openstudio-web instances")
    svc = data[0].get("Service", {})
    node = data[0].get("Node", {})
    host = svc.get("Address") or node.get("Address")
    port = svc.get("Port") or [[ var "web_port" . ]]
    if not host:
        raise RuntimeError("openstudio-web has no resolvable address")
    return f"http://{host}:{port}"

def log(msg):
    print(msg, flush=True)

def main():
    global WEB_URL
    try:
        WEB_URL = resolve_web_url()
    except TransientControlPlaneError as e:
        log(f"stall_watchdog_warn msg=consul_transient_unavailable action=skip_cycle detail={e}")
        sys.exit(0)
    except HTTPError as e:
        if e.code == 429 or (500 <= e.code < 600):
            log("stall_watchdog_warn msg=resolve_web_control_plane_transient action=skip_cycle")
            sys.exit(0)
        log(f"stall_watchdog_error msg=could_not_resolve_web detail={e}")
        sys.exit(1)
    except Exception as e:
        log(f"stall_watchdog_error msg=could_not_resolve_web detail={e}")
        sys.exit(1)

    log(f"stall_watchdog_start web={WEB_URL} nomad={NOMAD_ADDR} max_stall={MAX_STALL}s restart_allocs={RESTART_ALLOCS}")

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

    stalled = []
    checked = 0
    for dp_id in dp_ids[:20]:
        try:
            dp_data = fetch_json(f"{WEB_URL}/data_points/{dp_id}.json", timeout=5)
            dp_obj = dp_data.get("data_point", dp_data)
            if dp_obj.get("status") != "started":
                continue
            updated_raw = dp_obj.get("updated_at", "")
            if not updated_raw:
                continue
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

    log(f"stall_watchdog_alert stalled_count={len(stalled)} restart_allocs={RESTART_ALLOCS}")
    log(f"queue_divergence_alert stale_started={len(stalled)} threshold={MAX_STALL}s action={'restart_workers' if RESTART_ALLOCS else 'alert_only'}")

    if not RESTART_ALLOCS:
        log("stall_watchdog_alert_only msg=restart_allocs_disabled set stall_watchdog_restart_allocs=true to auto-recover")
        sys.exit(2)

    try:
        allocs_url = f"{NOMAD_ADDR}/v1/job/{WORKER_JOB}/allocations?namespace={NAMESPACE}"
        allocs = fetch_json(allocs_url)
    except Exception as e:
        log(f"stall_watchdog_error msg=could_not_list_allocs detail={e}")
        sys.exit(1)

    running = [a["ID"] for a in allocs if a.get("ClientStatus") == "running" and a.get("TaskGroup") == "worker"]
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
    if restarted > 0:
        sys.exit(0)
    sys.exit(1)

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
  [[ end ]]
}
[[ end ]]
