# Examples

This directory contains ready-to-use variable override files for the
OpenStudio Server Nomad Pack.

---

## 🏢 For Energy Modelers → `quickstart/`

Start here if you are deploying OpenStudio Server to run building
energy simulations.

| File | Description |
|---|---|
| [`quickstart/simple.hcl`](quickstart/simple.hcl) | Minimal, clean starting point — set your image version and worker count |
| [`quickstart/minimal-dev.hcl`](quickstart/minimal-dev.hcl) | Local macOS developer environment with Docker Desktop workarounds |

**Quickstart:**
```bash
# Edit simple.hcl to set your OpenStudio Server version, then:
nomad-pack run . -var-file examples/quickstart/simple.hcl
```

See [`docs/modelers/quickstart.md`](../docs/modelers/quickstart.md) for the
full step-by-step guide.

---

## ⚙️ For Infrastructure Admins → `advanced/`

These var-files expose the full feature set for production, OpenStack,
air-gapped, and high-availability deployments.

| File | Description |
|---|---|
| [`advanced/production-ha.hcl`](advanced/production-ha.hcl) | Multi-datacenter HA with Vault, Consul Connect, autoscaling |
| [`advanced/openstack.hcl`](advanced/openstack.hcl) | NREL aurora-179d OpenStack cluster |
| [`advanced/openstack-production.hcl`](advanced/openstack-production.hcl) | Production OpenStack with Vault, NFS, autoscaler |
| [`advanced/airgapped.hcl`](advanced/airgapped.hcl) | Private registry image overrides for air-gapped clusters |
| [`advanced/e2e-test.hcl`](advanced/e2e-test.hcl) | End-to-end integration test configuration |
| [`advanced/test-batch.nomad`](advanced/test-batch.nomad) | Standalone Nomad batch job spec for CI validation |
| [`advanced/volumes/`](advanced/volumes/) | Reference NFS host volume configuration |

See [`docs/infrastructure/`](../docs/infrastructure/) for the full
admin documentation.
