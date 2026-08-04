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
nomad-pack run -var-file examples/quickstart/simple.hcl packs/openstudio-server
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
| [`advanced/openstack.hcl`](advanced/openstack.hcl) | NREL aurora-179d OpenStack cluster — default var-file used by `scripts/deploy-openstack.sh` (`$OS_VAR_FILE`) |
| [`advanced/openstack-production.hcl`](advanced/openstack-production.hcl) | Portable OpenStack production profile — public images, Consul DNS defaults, node-class constraints; use for production rollouts |
| [`advanced/openstack-site-local.hcl.template`](advanced/openstack-site-local.hcl.template) | **Copy-and-fill template** for site-specific overrides (ingress domain, datacenter, private registry). Not committed as-is — copy to `openstack-site-local.hcl`, fill in your values, and pass as a second `-var-file` |
| [`advanced/airgapped.hcl`](advanced/airgapped.hcl) | Private registry image overrides for air-gapped clusters |
| [`advanced/e2e-test.hcl`](advanced/e2e-test.hcl) | End-to-end integration test configuration |
| [`advanced/test-batch.nomad`](advanced/test-batch.nomad) | Standalone Nomad batch job spec for CI validation |
| [`advanced/volumes/`](advanced/volumes/) | Reference NFS host volume configuration |

**OpenStack deployment pattern** (two-file layered deploy):
```bash
# 1. Copy the site-local template and fill in your values
cp examples/advanced/openstack-site-local.hcl.template openstack-site-local.hcl
# edit openstack-site-local.hcl — set ingress_domain, datacenters, etc.

# 2. Deploy: site-local takes precedence (last -var-file wins)
nomad-pack run \
  -var-file examples/advanced/openstack-production.hcl \
  -var-file openstack-site-local.hcl \
  .
```

`openstack-site-local.hcl` is gitignored — it contains cluster-specific values that differ between deployments.

See [`docs/infrastructure/`](../docs/infrastructure/) for the full
admin documentation.
