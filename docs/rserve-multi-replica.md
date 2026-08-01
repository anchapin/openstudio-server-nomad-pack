# Multi-Replica Rserve Routing

This document describes how the OpenStudio Server Nomad Pack routes traffic to Rserve when `rserve_count > 1` is configured.

## Overview

Rserve uses a custom binary protocol (not HTTP), so layer-7 load balancers such as Traefik cannot proxy it. Instead, multi-replica routing relies on **Consul service discovery** combined with a randomised selection strategy in the Consul template that patches `/etc/hosts` inside the `web` and `worker` task containers.

## How It Works

### Service registration

Each Rserve allocation registers independently in Consul under the service name `openstudio-rserve`. The registration includes a TCP health check:

```hcl
check {
  name     = "openstudio-rserve-tcp"
  type     = "tcp"
  interval = "<rserve_health_check_interval>"
  timeout  = "<rserve_health_check_timeout>"
}
```

Only allocations that **pass** their health check are returned by `service "openstudio-rserve"` in Consul template queries.

### `/etc/hosts` patching with shuffle

The `web` and `worker` tasks use a Consul template (`local/patch-hosts.sh`) to write a `rserve` hostname entry into `/etc/hosts` at allocation startup:

```gotemplate
{{ with index (shuffle (service "openstudio-rserve")) 0 -}}
echo "{{ .Address }}" >> /etc/hosts
{{ end -}}
```

**`shuffle`** randomises the list of healthy Rserve instances returned by Consul. **`with index ... 0`** selects the first entry from that shuffled list. This means:

- Each `web` or `worker` allocation independently picks one healthy Rserve backend at startup.
- The selection is re-evaluated whenever the Consul template is re-rendered (e.g. after a Nomad reschedule or Consul template reload).
- The result is probabilistic round-robin distribution: across many allocations and restarts, traffic spreads across all healthy Rserve replicas.

## Health Check and Failover Semantics

| Scenario | Behaviour |
|---|---|
| All Rserve replicas healthy | Each web/worker allocation picks a random backend at startup; traffic distributes across replicas. |
| One Rserve replica fails its health check | Consul removes the failing instance from the `openstudio-rserve` service query. New web/worker allocations will never be assigned the failing backend. Existing allocations that already mapped to the failing backend continue to use it until they restart or the Consul template is re-rendered. |
| All Rserve replicas fail | `service "openstudio-rserve"` returns an empty list; `with index ... 0` evaluates to nothing; no `rserve` entry is written. The `wait-for-deps` prestart task prevents `web`/`worker` from starting until at least one healthy Rserve instance is registered. |
| Failed replica recovers | Consul adds the instance back to the service query on the next passing health check. Newly rendered templates can select the recovered instance. |

## Enabling Multi-Replica Rserve

### Minimum configuration

```hcl
rserve_count = 2
```

### Recommended: spread replicas across nodes

Use `rserve_spreads` to prevent all Rserve allocations from landing on the same node:

```hcl
rserve_count = 2

rserve_spreads = [
  {
    attribute = "${node.unique.name}"
    weight    = 100
  }
]
```

Or spread by datacenter in multi-DC clusters:

```hcl
rserve_count = 3

rserve_spreads = [
  {
    attribute = "${node.datacenter}"
    weight    = 100
  }
]
```

### Optional: pin web and Rserve to the same node (single-node dev)

If your workflow requires low-latency local filesystem access between web and Rserve, use `web_rserve_colocation_node` to pin both to the same host. This conflicts with `rserve_count > 1`; use it only for single-node development:

```hcl
rserve_count               = 1
web_rserve_colocation_node = "nomad-client-01"
```

## Limitations and Prerequisites

1. **Consul is required.** Multi-replica routing relies entirely on Consul service discovery. Nomad-native DNS (`nomad.service.consul`) is not used; the Consul catalog must be reachable from within the allocation network.

2. **Static-IP mapping at startup only.** The `/etc/hosts` approach resolves the Rserve backend once at allocation startup (and on Consul template re-renders). It does not provide connection-level load balancing. A long-running `web` or `worker` allocation will continue sending all Rserve requests to the same backend until it restarts.

3. **Rserve binary protocol is not proxied by Traefik or Consul Connect.** Traefik handles HTTP/TCP only at the service-mesh layer; the Rserve binary protocol is not transparently proxied. Setting `enable_consul_connect = true` adds mTLS sidecar proxies but does not distribute Rserve connections across replicas.

4. **`rserve_static_port` must remain `0` (dynamic) when `rserve_count > 1`.** Static port binding (`rserve_static_port = 6311`) causes port conflicts when multiple allocations land on the same node. Leave it at the default `0` for multi-replica deployments.

5. **Volume access.** When `nfs_shared_volume_enabled = true`, all Rserve replicas mount the same NFS share. NFS provides a shared filesystem but does not guarantee POSIX file-locking across simultaneous writers. Applications that write to shared NFS paths from multiple Rserve instances must implement their own locking.

## Example: Two-Replica Rserve

```hcl
# In a var-file or direct variable overrides:
rserve_count = 2

rserve_spreads = [
  {
    attribute = "${node.unique.name}"
    weight    = 100
  }
]

rserve_health_check_interval = "10s"
rserve_health_check_timeout  = "2s"
```

Verify replicas are registered and healthy:

```bash
consul catalog services -tags openstudio-rserve
# or
consul health service openstudio-rserve
```
