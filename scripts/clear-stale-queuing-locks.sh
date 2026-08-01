#!/usr/bin/env bash
# clear-stale-queuing-locks.sh
#
# Detect and optionally clear stale resque:analysis:*:queuing locks in Redis.
#
# A lock is considered stale if:
#   1. It has no TTL (TTL == -1, meaning it was SET without EXPIRE), AND
#   2. It has been present for longer than MAX_LOCK_AGE_SECONDS (checked via
#      OBJECT IDLETIME — the number of seconds since the key was last touched).
#
# Usage:
#   ./scripts/clear-stale-queuing-locks.sh [--dry-run] [--max-age <seconds>]
#     [--nomad-addr <addr>] [--namespace <ns>]
#
# Options:
#   --dry-run            Print stale keys but do not delete them (default: delete)
#   --max-age <seconds>  Minimum idle seconds before a key is considered stale
#                        (default: 120)
#   --nomad-addr <addr>  Nomad API address (default: $NOMAD_ADDR or http://10.60.126.125:4646)
#   --namespace <ns>     Nomad namespace (default: $NOMAD_NAMESPACE or default)
#
# Exit codes:
#   0  No stale keys found (or all cleared)
#   1  Error
#   2  Stale keys found in --dry-run mode (useful for alerting)

set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:-http://10.60.126.125:4646}"
NOMAD_NAMESPACE="${NOMAD_NAMESPACE:-default}"
DRY_RUN=false
MAX_AGE=120  # seconds idle before treating a TTL=-1 key as stale

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true;         shift ;;
    --max-age)       MAX_AGE="$2";         shift 2 ;;
    --nomad-addr)    NOMAD_ADDR="$2";      shift 2 ;;
    --namespace)     NOMAD_NAMESPACE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

export NOMAD_ADDR NOMAD_NAMESPACE

# Find the running Redis allocation
REDIS_ALLOC=$(nomad job allocs -json openstudio-server-redis \
  | python3 -c 'import json,sys; a=json.load(sys.stdin); print(next((x["ID"] for x in a if x.get("ClientStatus")=="running"),""))')

if [[ -z "$REDIS_ALLOC" ]]; then
  echo "ERROR: No running Redis allocation found" >&2
  exit 1
fi

redis_exec() {
  nomad alloc exec -task redis "$REDIS_ALLOC" sh -lc "$*"
}

echo "==> Scanning for resque:analysis:*:queuing locks"
echo "    Nomad addr:  $NOMAD_ADDR"
echo "    Redis alloc: $REDIS_ALLOC"
echo "    Max idle age: ${MAX_AGE}s before considered stale"
echo "    Dry run: $DRY_RUN"
echo

# Collect all queuing keys and classify them
STALE_KEYS=()
ACTIVE_KEYS=()

while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  ttl=$(redis_exec "redis-cli TTL '$key'" 2>/dev/null | tr -d '[:space:]')
  if [[ "$ttl" == "-1" ]]; then
    # No TTL set — check idle time as a proxy for "stuck"
    idle=$(redis_exec "redis-cli OBJECT IDLETIME '$key'" 2>/dev/null | tr -d '[:space:]')
    if [[ "$idle" =~ ^[0-9]+$ ]] && (( idle >= MAX_AGE )); then
      STALE_KEYS+=("$key (idle=${idle}s, no TTL)")
    else
      ACTIVE_KEYS+=("$key (idle=${idle}s, no TTL — within grace period)")
    fi
  elif [[ "$ttl" == "-2" ]]; then
    # Key vanished between scan and TTL check — already gone
    :
  else
    # Has a TTL — lock is actively managed
    ACTIVE_KEYS+=("$key (TTL=${ttl}s)")
  fi
done < <(redis_exec "redis-cli --scan --pattern 'resque:analysis:*:queuing'" 2>/dev/null)

if [[ ${#ACTIVE_KEYS[@]} -gt 0 ]]; then
  echo "  Active (healthy) queuing locks:"
  for k in "${ACTIVE_KEYS[@]}"; do echo "    $k"; done
fi

if [[ ${#STALE_KEYS[@]} -eq 0 ]]; then
  echo "  No stale queuing locks found."
  exit 0
fi

echo
echo "  Stale queuing locks (${#STALE_KEYS[@]}):"
for k in "${STALE_KEYS[@]}"; do echo "    $k"; done

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "  --dry-run mode: no keys deleted."
  exit 2
fi

echo
echo "==> Deleting stale queuing locks"
DELETED=0
for entry in "${STALE_KEYS[@]}"; do
  # Extract just the key name (before the first space)
  key="${entry%% *}"
  result=$(redis_exec "redis-cli DEL '$key'" 2>/dev/null | tr -d '[:space:]')
  if [[ "$result" == "1" ]]; then
    echo "  Deleted: $key"
    (( DELETED++ )) || true
  else
    echo "  Already gone (raced): $key"
  fi
done

echo
echo "==> Done. Deleted ${DELETED} stale lock(s)."
