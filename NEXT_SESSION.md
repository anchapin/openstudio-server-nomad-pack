# Next Session: Finish OpenStack Nomad Pack Deployment

## Context

We are testing `openstudio-server-nomad-pack` on an existing OpenStack Nomad cluster in the
`aurora-179d` project on `vs-api.hpc.nrel.gov`. Credentials are in `~/.zshrc`.

## Cluster access

```
Local Mac → SSH jump: ubuntu@10.60.105.39 (openstudio-mcp-cli, has internet)
         → Nomad server: ubuntu@10.60.126.125 (nomad-server, 192.168.100.87)
         → Clients: ubuntu@192.168.100.x (double jump via both hops)
SSH key: ~/.ssh/id_rsa for all nodes
```

The **SSH tunnel must be open** before using Nomad CLI:
```bash
ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -fNT \
  -L 127.0.0.1:4646:127.0.0.1:4646 \
  -J ubuntu@10.60.105.39 ubuntu@10.60.126.125
export NOMAD_ADDR=http://127.0.0.1:4646
```

Or use: `make os-tunnel` (opens both Nomad 4646 and Consul 8500 tunnels).

## What has been done

1. **Consul server** installed on `nomad-server` (192.168.100.87:8500), running as single-node cluster
2. **Docker installed** on all 34 client nodes from static binary at `/nfs/opensstudio/batch/docker.tgz`
   - Data-root configured to NFS: `/nfs/opensstudio/batch/docker-data/<hostname>/`
   - DNS configured in `/etc/docker/daemon.json`: `10.60.1.241`, `10.60.3.241` (NREL internal)
3. **`/etc/resolv.conf`** replaced with static file on all nodes pointing to NREL internal DNS
   - `nameserver 10.60.1.241` / `nameserver 10.60.3.241`
   - systemd-resolved stub was broken; static file bypasses it
4. **OpenStack subnet DNS** updated: `openstack subnet set --dns-nameserver 10.60.1.241 --dns-nameserver 10.60.3.241 nomad-subnet`
5. **3 BLOCK nodes fixed** (33, 59, 62): their SNAT routing was broken; fixed by detach+re-attach of floating IPs via OpenStack API
6. **Docker pulls confirmed working** on at least 20/34 nodes (tested `busybox:1.36`)
7. **`infra-setup.nomad`** system job updated to install Docker from NFS + configure Consul + DNS
8. **Pack deployed**: all 6 service jobs registered (`openstudio-server-{db,redis,rserve,web,worker,test}`)

## ⚠️ CURRENT BLOCKER: Jobs are pending with zero allocs

**Root cause identified**: The `service { provider = "consul" }` block in the Nomad job templates
causes Nomad v2+ to automatically inject a task-group constraint:

```hcl
constraint {
  attribute = "${attr.consul.version}"
  operator  = "semver"
  value     = ">= 1.7.0"
}
```

**Consul client is NOT installed on any of the 34 client nodes** — only on the server.
Without a local Consul agent running on each client, the `attr.consul.version` attribute is
never set, so **no node satisfies the constraint** and Nomad places zero allocations.

Verify this is the issue:
```bash
export NOMAD_ADDR=http://127.0.0.1:4646
nomad job inspect openstudio-server-db | python3 -c "
import sys, json
d = json.load(sys.stdin)
for tg in d['Job']['TaskGroups']:
    print('Constraints:', tg.get('Constraints'))
"
# Should show: attr.consul.version >= 1.7.0
```

## Fix options (choose one)

### Option A (Recommended): Install Consul client agent on all 34 nodes

The Consul binary is already on the server. Copy it to NFS and install on all clients:

```bash
# On nomad-server: copy consul binary to NFS
ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no \
  -J ubuntu@10.60.105.39 ubuntu@10.60.126.125 \
  "sudo cp /usr/local/bin/consul /nfs/opensstudio/batch/consul"

# Then run infra-setup.nomad again (it has been updated to handle this),
# OR do it in parallel via direct SSH:
export NOMAD_ADDR=http://127.0.0.1:4646
NODES=$(nomad node status -json | python3 -c "
import sys, json; nodes = json.load(sys.stdin)
for n in nodes: print(n['Address'], n['Name'])
")

CONSUL_SERVER_IP="192.168.100.87"
TMPDIR=$(mktemp -d)
while read ip name; do
  (
    ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
      -J ubuntu@10.60.105.39,ubuntu@10.60.126.125 \
      ubuntu@${ip} << 'ENDSSH'
# Install consul from NFS
sudo cp /nfs/opensstudio/batch/consul /usr/local/bin/consul
sudo chmod +x /usr/local/bin/consul

# Create consul client config
sudo mkdir -p /etc/consul.d
sudo tee /etc/consul.d/client.hcl > /dev/null <<HCL
server           = false
datacenter       = "dc1"
data_dir         = "/opt/consul"
bind_addr        = "{{ GetInterfaceIP \"ens3\" }}"
client_addr      = "0.0.0.0"
retry_join       = ["192.168.100.87"]
HCL

# Create systemd service
sudo tee /etc/systemd/system/consul.service > /dev/null <<UNIT
[Unit]
Description=Consul Agent
After=network-online.target
[Service]
ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

sudo mkdir -p /opt/consul
sudo systemctl daemon-reload
sudo systemctl enable consul
sudo systemctl start consul
sleep 3
consul members 2>/dev/null | head -3 && echo "[$(hostname)] Consul started OK" || echo "[$(hostname)] Consul start FAILED"
ENDSSH
  ) > "$TMPDIR/$name" 2>&1 &
done <<< "$NODES"
wait
cat "$TMPDIR"/*
rm -rf "$TMPDIR"
```

Wait ~60s for Nomad to detect Consul agents, then verify:
```bash
nomad node status -json | python3 -c "
import sys, json
nodes = json.load(sys.stdin)
has_consul = sum(1 for n in nodes if n.get('Attributes', {}).get('consul.version'))
print(f'{has_consul}/{len(nodes)} nodes have consul.version attribute')
"
```

### Option B (Quick workaround): Change service provider to "nomad" in templates

Edit all templates to use `provider = "nomad"` instead of `provider = "consul"`.
This avoids the Consul constraint but loses Consul service registration (wait-for-deps
health checks via Consul HTTP API will also need adjustment).

This is not recommended long-term but would let you test the stack without Consul agents.

## After fixing the Consul constraint: deploy workflow

```bash
export NOMAD_ADDR=http://127.0.0.1:4646
cd /Users/achapin/OpenStudio/openstudio-server-nomad-pack

# Stop and redeploy after Consul agents are running on all nodes
for job in openstudio-server-web openstudio-server-worker openstudio-server-rserve \
           openstudio-server-db openstudio-server-redis openstudio-server-test; do
  nomad job stop -purge -detach "$job" 2>/dev/null
done
sleep 5

nomad-pack run --name openstudio-server --var-file examples/openstack.hcl .
```

Monitor deployment (images pull on first run — nrel/openstudio-server:179-flock is ~5 GB):
```bash
# Watch allocation status
watch -n 5 'nomad status 2>/dev/null | head -20'

# Check a specific job
nomad job status openstudio-server-db
nomad job status openstudio-server-web

# Tail logs for web task
ALLOC=$(nomad job allocs openstudio-server-web 2>/dev/null | grep running | head -1 | awk '{print $1}')
nomad alloc logs -f "$ALLOC" web
```

## Expected deployment sequence

1. `openstudio-server-db` → MongoDB pulls (~700MB), starts, registers as `openstudio-db` in Consul
2. `openstudio-server-redis` → Redis pulls (~30MB), starts, registers as `openstudio-redis`
3. `openstudio-server-rserve` → Rserve pulls (~3.5GB), starts, registers as `openstudio-rserve`
4. `openstudio-server-web` → wait-for-deps prestart polls Consul for db/redis/rserve health → web starts
5. `openstudio-server-worker` → wait-for-deps polls for db/redis → workers start

## Accessing the web UI

The web UI runs on `web_port` (default 8080). Tunnel via SSH:
```bash
# Find which node web is running on
ALLOC=$(nomad job allocs openstudio-server-web 2>/dev/null | grep running | head -1)
NODE_IP=$(echo "$ALLOC" | awk '{print $2}' | xargs -I{} nomad node status {} 2>/dev/null | grep Address | awk '{print $3}')

# Open a tunnel to the web node
ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -fNT \
  -L 127.0.0.1:8080:${NODE_IP}:8080 \
  -J ubuntu@10.60.105.39 ubuntu@10.60.126.125
open http://localhost:8080
```

Or use `make os-ui` if that target is wired up in the Makefile.

## Cluster state summary (as of end of session)

| Component | State |
|---|---|
| Nomad server | Running (v2.0.4) at 10.60.126.125 |
| Consul server | Running (v1.17.3) at 192.168.100.87:8500 |
| Consul clients | **NOT installed** on any of the 34 clients ← fix this first |
| Docker | Installed on all 34 nodes, data-root → NFS, DNS configured |
| DNS (/etc/resolv.conf) | Set to 10.60.1.241/10.60.3.241 on all nodes (static file) |
| Pack jobs | Deployed but pending (0 allocs) due to consul.version constraint |
| NFS | Mounted at /nfs/opensstudio/batch on all nodes |
| Docker NFS dirs | /nfs/opensstudio/batch/docker-data/<hostname>/ exists per node |
| OpenStudio shared dir | /nfs/opensstudio/batch/openstudio/ exists, chmod 777 |
| infra-setup job | Running (system job) |

## Key files

- `examples/openstack.hcl` — var-file for this deployment
- `infra-setup.nomad` — system job for client bootstrap (Docker + Consul config)
- `scripts/deploy-openstack.sh` — full lifecycle automation
- `Makefile` — `os-*` targets (os-run, os-tunnel, os-deploy, os-status, etc.)

## Do NOT touch

The **K8s/Azimuth cluster** (`openstudio-server-july27v1-*` nodes) is actively running
openstudio-server-helm and must not be modified. It shares the same OpenStack project.

## Networking notes

- Security group `nomad-sg`: all egress open, all ingress open — not the issue
- Router `nomad-router`: has external gateway with SNAT enabled to `external` network
- 3 nodes (33, 59, 62) had broken SNAT; fixed by FIP detach+reattach in this session
- TCP 443 (HTTPS) works to internet; DNS UDP/TCP 53 to 8.8.8.8 is blocked at provider level
- NREL internal DNS (10.60.1.241, 10.60.3.241) reachable and resolves Docker Hub names
- ~14 nodes showed SSH timeout in parallel tests but are believed healthy (Consul agent install will confirm)
