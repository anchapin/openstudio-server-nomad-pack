#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-/etc/traefik/traefik.yml}"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR: Traefik config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

ENDPOINT="$(
  python3 - "${CONFIG_FILE}" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

providers_indent = None
consul_indent = None
endpoint_indent = None

for raw in lines:
    line = raw.rstrip("\n")
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue

    indent = len(line) - len(line.lstrip(" "))
    key = stripped.split(":", 1)[0]

    if key == "providers":
        providers_indent = indent
        consul_indent = None
        endpoint_indent = None
        continue

    if providers_indent is None:
        continue

    if indent <= providers_indent and key != "providers":
        providers_indent = None
        consul_indent = None
        endpoint_indent = None
        continue

    if key == "consulCatalog":
        consul_indent = indent
        endpoint_indent = None
        continue

    if consul_indent is None:
        continue

    if indent <= consul_indent:
        consul_indent = None
        endpoint_indent = None
        continue

    if key == "endpoint":
        endpoint_indent = indent
        continue

    if endpoint_indent is None:
        continue

    if indent <= endpoint_indent:
        endpoint_indent = None
        continue

    if key == "address":
        value = stripped.split(":", 1)[1].strip().strip("'\"")
        if value:
            print(value)
            raise SystemExit(0)

raise SystemExit(1)
PY
)" || {
  echo "ERROR: Could not find providers.consulCatalog.endpoint.address in ${CONFIG_FILE}" >&2
  exit 1
}

if [[ "${ENDPOINT}" == *"://"* ]]; then
  echo "ERROR: Invalid Consul endpoint '${ENDPOINT}' in ${CONFIG_FILE}" >&2
  echo "Use host:port (for example: 127.0.0.1:8500), not a URL scheme." >&2
  exit 1
fi

if [[ ! "${ENDPOINT}" =~ ^[^:]+:[0-9]+$ ]]; then
  echo "ERROR: Invalid Consul endpoint '${ENDPOINT}' in ${CONFIG_FILE}" >&2
  echo "Expected host:port." >&2
  exit 1
fi

echo "OK: providers.consulCatalog.endpoint.address=${ENDPOINT}"
