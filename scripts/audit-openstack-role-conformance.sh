#!/usr/bin/env bash
set -euo pipefail

NOMAD_ADDR="${NOMAD_ADDR:-http://10.60.126.125:4646}"

python3 - "${NOMAD_ADDR}" <<'PY'
import json
import sys
import urllib.request

nomad_addr = sys.argv[1].rstrip("/")

expected = {
    "openstudio-server-web": "web",
    "openstudio-server-db": "web",
    "openstudio-server-redis": "web",
    "openstudio-server-rserve": "web",
    "openstudio-server-prometheus": "web",
    "openstudio-server-autoscaler": "web",
    "openstudio-server-worker": "worker",
}

def get_json(path):
    with urllib.request.urlopen(f"{nomad_addr}{path}", timeout=20) as r:
        return json.load(r)

nodes = get_json("/v1/nodes")
node_roles = {}
for n in nodes:
    nid = n.get("ID")
    try:
        detail = get_json(f"/v1/node/{nid}")
    except Exception:
        continue
    node_roles[nid] = (detail.get("Meta") or {}).get("node_role", "")

errors = []
for job_id, role in expected.items():
    try:
        job = get_json(f"/v1/job/{job_id}")
    except Exception:
        errors.append(f"{job_id}: job not found")
        continue

    group_constraints = []
    for tg in job.get("TaskGroups") or []:
        for c in tg.get("Constraints") or []:
            group_constraints.append((c.get("LTarget"), c.get("Operand"), c.get("RTarget")))
    if ("${meta.node_role}", "=", role) not in group_constraints:
        errors.append(f"{job_id}: missing constraint ${{meta.node_role}} = {role}")

    try:
        allocs = get_json(f"/v1/job/{job_id}/allocations")
    except Exception:
        allocs = []
    for a in allocs:
        if a.get("DesiredStatus") != "run":
            continue
        if a.get("ClientStatus") not in ("running", "pending", "starting"):
            continue
        nid = a.get("NodeID", "")
        actual = node_roles.get(nid, "")
        if actual and actual != role:
            errors.append(
                f"{job_id}: alloc {a.get('ID','')[:8]} on node_role={actual} (expected {role})"
            )

if errors:
    print("Role/constraint audit failed:")
    for e in errors:
        print(f"  - {e}")
    raise SystemExit(1)

print("Role/constraint audit passed.")
PY
