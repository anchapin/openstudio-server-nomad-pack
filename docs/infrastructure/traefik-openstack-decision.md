# ADR: Traefik Go/No-Go Decision for OpenStack Production

**Status:** Accepted  
**Date:** 2026-08-01  
**Issue:** [#363](https://github.com/anchapin/openstudio-server-nomad-pack/issues/363)

---

## Context

OpenStudio Server on OpenStack (NREL aurora-179d) handles large parametric analysis
workloads. The web UI accepts analysis ZIP uploads that can reach **up to 500 MB** and
runs simulations that execute for tens of minutes per analysis file. The production
OpenStack environment has specific ingress requirements:

| Requirement | Constraint |
|---|---|
| **TLS termination** | Must be handled before traffic reaches the web container; certificate management must integrate with NREL PKI |
| **Large payload uploads** | Analysis ZIPs up to ~500 MB; standard proxy defaults (1–64 MB) will reject them |
| **Long-running requests** | Simulation enqueue requests can hold open HTTP connections for 2–5 minutes |
| **High connection concurrency** | Up to 10,000 worker allocations generating callbacks to web; Passenger pool = 154 |
| **HA / failover** | Single ingress failure must not cause a total loss of web access |
| **Airgapped image registry** | All images must be pulled from `pulp-dev.hpc.nlr.gov`; no Docker Hub access at runtime |
| **Operator observability** | Ingress access logs must be available without SSH to compute nodes |

The pack ships an **optional in-pack Traefik job** (`deploy_traefik = true`) that reads
routing rules from Consul service tags. The existing `examples/advanced/openstack.hcl` sets
`ingress_domain = "10.60.126.125"` (jump-host IP) but does not currently set
`deploy_traefik`.

### Current in-pack Traefik capabilities (`templates/traefik.nomad.tpl`)

- Traefik v3, single task group, count = 1
- Binds static HTTP/HTTPS/dashboard ports from variables
- Reads Consul Catalog for routing rules via service tags
- `traefik_api_insecure` flag for dev dashboard access
- No automatic certificate provisioning (ACME/Let's Encrypt) configured
- No upload-size or timeout tuning in the current template
- Allocated 200 MHz CPU / 128 MB RAM

### OpenStack LBaaS alternative

OpenStack Octavia (LBaaS v2) provides a managed L4/L7 load balancer that:

- Lives outside the Nomad cluster — survives Nomad/Consul failures independently
- Terminates TLS using certificates loaded via Barbican (NREL PKI integration)
- Supports configurable connection/request timeouts and payload sizes at the LB layer
- Provides HA via ACTIVE/STANDBY amphora pairs — no single point of failure
- Is already part of the OpenStack control-plane managed by the NREL HPC team
- Access logs are available via OpenStack CLI / Horizon without touching compute nodes

---

## Options Considered

### Option A — Enable in-pack Traefik (`deploy_traefik = true`) for production

**Pros:**
- Self-contained: everything declared in the Nomad Pack, no external provisioning
- Consul Catalog discovery automatically updates routing when web allocations reschedule
- Dashboard provides real-time routing visibility
- Easy for dev/test environments — single `nomad-pack run` deploys the entire stack

**Cons:**
- **Single point of failure**: `count = 1` — Traefik failure takes down all web access
  until Nomad reschedules (typically 30–90 s). Increasing count requires sticky-session
  or shared state configuration.
- **No TLS certificate management**: The current template has no ACME or Barbican
  integration. Adding Let's Encrypt ACME is inappropriate for an airgapped environment;
  wiring in Barbican requires non-trivial Traefik plugin work.
- **Image availability**: `traefik:v3` is not currently mirrored in the Pulp registry.
  Adding it to the mirror pipeline is an extra operational step.
- **Resource competition**: Traefik runs on the same Nomad nodes as web/infra services,
  consuming scheduler slots during scale events.
- **Upload size and timeout tuning**: Not yet configured in `traefik.nomad.tpl`
  (no `maxRequestBodyBytes`, no `respondingTimeouts`). Without explicit tuning,
  500 MB uploads will be rejected and long-running simulation requests will time out.
- **Operational model mismatch**: The NREL HPC team manages external load balancers
  centrally; in-pack Traefik requires Nomad operators to own certificate rotation,
  health-check tuning, and ingress observability.

---

### Option B — External ingress only (OpenStack Octavia LBaaS / HAProxy)

**Pros:**
- Managed HA out of the box (ACTIVE/STANDBY amphora)
- TLS termination via Barbican integrates with NREL PKI without additional pack work
- Configurable payload limits and timeouts at the LB layer (no template changes needed)
- Not dependent on Nomad cluster health — ingress survives Nomad/Consul disruptions
- Already a standard NREL HPC infrastructure component

**Cons:**
- Requires OpenStack provisioning steps outside the Nomad Pack
- Routing is static (points at fixed web node IP + port); does not auto-update when
  the web allocation reschedules to a different node
- No Consul-native service discovery — operators must update the LB backend pool
  manually (or via Terraform/Ansible) after any web node change
- Additional operational knowledge required from HPC infra team

---

### Option C — Hybrid: external LB for production, in-pack Traefik for dev/staging ✅ **RECOMMENDED**

**Description:**

| Environment | Ingress | `deploy_traefik` |
|---|---|---|
| Production (OpenStack aurora-179d) | OpenStack Octavia LBaaS | `false` |
| Staging / pre-prod (OpenStack) | OpenStack Octavia LBaaS (smaller listener) | `false` |
| Local dev (`minimal-dev.hcl`) | In-pack Traefik | `true` (opt-in) |
| Vagrant (`vagrant/provision/`) | In-pack Traefik | `true` (opt-in) |
| CI (`e2e-test.hcl`) | In-pack Traefik or host-network direct | `false` |

**Pros:**
- Production gets HA, NREL-PKI TLS, and large-payload support via Octavia without
  any new pack development work
- Dev/test retains the convenience of a single-command deploy with in-pack Traefik
- No blocking dependency on mirroring `traefik:v3` into the Pulp registry for
  production deployments
- Aligns with the NREL HPC team's existing LB management workflow
- `deploy_traefik = false` (the current default) is safe for production immediately

**Cons:**
- Two different ingress paths to document and test
- Web allocation reschedules in production require a manual (or automated) backend
  pool update in Octavia — add this to the operations runbook

---

## Decision

**Option C (Hybrid) is adopted.**

For the **OpenStack production profile** (`examples/advanced/openstack.hcl`):

```hcl
# Do NOT enable in-pack Traefik for production.
# Use OpenStack Octavia LBaaS (or HAProxy) for ingress instead.
# See docs/traefik-openstack-decision.md for rationale.
deploy_traefik = false
```

For **local dev / Vagrant**:

```hcl
# Optional: enable in-pack Traefik for local convenience.
deploy_traefik = true
traefik_http_port       = 8080
traefik_https_port      = 8443
traefik_dashboard_port  = 8081
traefik_api_insecure    = true
ingress_domain          = "localhost"
```

---

## Rationale

1. **HA**: `count = 1` in the current Traefik template is not acceptable for
   production. Octavia provides ACTIVE/STANDBY without changes to the pack.

2. **TLS**: The airgapped environment cannot use ACME/Let's Encrypt. NREL PKI
   certificates are already managed via Barbican + Octavia. Implementing Barbican
   integration in the Traefik template would require significant pack work with
   no clear upstream support path.

3. **Large payloads**: Octavia (HAProxy amphora) supports configurable
   `client_data_timeout`, `connection_limit`, and LB-level body-size settings via
   OpenStack CLI. The current `traefik.nomad.tpl` has no `maxRequestBodyBytes` or
   `respondingTimeouts` configuration. Uploading 500 MB through untuned Traefik
   would silently fail with a 413 or timeout error.

4. **Image availability**: `traefik:v3` is not currently in the Pulp mirror.
   Mirroring a new image requires HPC team approval and pipeline work. Octavia
   removes this dependency entirely.

5. **Operational alignment**: The NREL HPC team already provisions and monitors
   Octavia load balancers via Terraform. Adding in-pack Traefik introduces a
   parallel ingress management surface that the team does not currently own.

---

## Consequences

### Immediate (no code changes required beyond this PR)

- `examples/advanced/openstack.hcl` records `deploy_traefik = false` explicitly with a
  comment directing operators to provision Octavia.
- `deploy_traefik = false` is already the pack default — production is safe today.

### Follow-on actions (tracked as separate issues)

| Action | Owner | Priority |
|---|---|---|
| Provision Octavia listener + pool pointing at web node port `web_port` (default 8080) | HPC infra team | High |
| Configure Octavia TLS termination via Barbican certificate container | HPC infra team | High |
| Set Octavia `client_data_timeout = 0` (no body size limit) and `connection_timeout = 300s` for large uploads | HPC infra team | High |
| Add Octavia backend pool update step to web-node replacement runbook | Pack operators | Medium |
| Mirror `traefik:v3` into Pulp registry for dev/staging convenience | HPC infra team | Low |
| Add `maxRequestBodyBytes` and `respondingTimeouts` to `traefik.nomad.tpl` for dev parity | Pack maintainers | Low |

---

## Configuration Guidance

### Production — Octavia LBaaS setup (reference commands)

```bash
# Create listener (TLS-terminated, certificate from Barbican)
openstack loadbalancer listener create \
  --name openstudio-https \
  --protocol TERMINATED_HTTPS \
  --protocol-port 443 \
  --default-tls-container-ref <barbican_container_ref> \
  --connection-limit 10000 \
  <lb-id>

# Create pool pointing at Nomad web node
openstack loadbalancer pool create \
  --name openstudio-pool \
  --lb-algorithm ROUND_ROBIN \
  --listener openstudio-https \
  --protocol HTTP

# Add web node as pool member (repeat after web reschedules)
openstack loadbalancer member create \
  --subnet-id <subnet-id> \
  --address <web_node_ip> \
  --protocol-port 8080 \
  openstudio-pool
```

### Dev / Vagrant — in-pack Traefik

Add to your local var-file (do **not** commit to `openstack.hcl`):

```hcl
deploy_traefik         = true
traefik_http_port      = 8080
traefik_https_port     = 8443
traefik_dashboard_port = 8081
traefik_api_insecure   = true
ingress_tls_enabled    = false
ingress_domain         = "localhost"
```

Then access the Traefik dashboard at `http://localhost:8081/dashboard/`.

---

## References

- [OpenStack Octavia documentation](https://docs.openstack.org/octavia/latest/)
- [Traefik Nomad Pack template](../templates/traefik.nomad.tpl)
- [Pack variables reference](variables.md)
- [Operations guide](operations-guide.md)
- [Getting started — single node](getting-started-single-node.md)
- GitHub Issue [#363](https://github.com/anchapin/openstudio-server-nomad-pack/issues/363)
