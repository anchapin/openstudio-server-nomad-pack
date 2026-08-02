# Docs: Infrastructure & Administration

This folder contains guides for **cluster administrators** — software
engineers and systems administrators managing OpenStudio Server deployments
on Nomad.

## Getting Started

| Guide | Description |
|---|---|
| [getting-started-single-node.md](getting-started-single-node.md) | Zero-to-running on a developer laptop (macOS or Linux) |
| [operations-guide.md](operations-guide.md) | Master index: topology, deployment checklist, links to all guides |
| [upgrading.md](upgrading.md) | Version upgrade procedures |

## Storage

| Guide | Description |
|---|---|
| [storage.md](storage.md) | CSI plugins, host volumes, permissions, and teardown |
| [nfs-tuning-guide.md](nfs-tuning-guide.md) | NFS mount options, rsize/wsize, actimeo tuning |
| [openstack-storage-provisioning.md](openstack-storage-provisioning.md) | CSI/NFS volume provisioning on OpenStack Nomad clusters |
| [worker-local-scratch.md](worker-local-scratch.md) | Per-worker ephemeral scratch volume pattern |
| [adr-001-storage-architecture.md](adr-001-storage-architecture.md) | Architecture decision record: storage backend selection |
| [storage-benchmark-methodology.md](storage-benchmark-methodology.md) | Methodology behind the storage saturation benchmark script |

## Scaling & Autoscaling

| Guide | Description |
|---|---|
| [autoscaling-storage-ramp-policy.md](autoscaling-storage-ramp-policy.md) | Ramp guardrails and iowait threshold gates for worker scale-out |
| [rserve-horizontal-scaling.md](rserve-horizontal-scaling.md) | Rserve multi-replica design and constraints |
| [rserve-multi-replica.md](rserve-multi-replica.md) | Multi-replica Rserve routing when `rserve_count > 1` |

## OpenStack

| Guide | Description |
|---|---|
| [openstack-staged-rollout-runbook.md](openstack-staged-rollout-runbook.md) | 4-stage canary → full ramp procedure with gate criteria and rollback |
| [openstack-stabilization-runbook.md](openstack-stabilization-runbook.md) | Remediation steps for OpenStack-specific allocation failures |
| [openstack-remaining-issues-plan.md](openstack-remaining-issues-plan.md) | Current OpenStack stabilization state and recovery plan |
| [scale-program-summary.md](scale-program-summary.md) | Summary of the scale-to-max program (Epic #352) |

## Security & Networking

| Guide | Description |
|---|---|
| [vault-policies.md](vault-policies.md) | Vault policy templates and setup |
| [acl-policies.md](acl-policies.md) | Nomad ACL policy reference |
| [traefik-openstack-decision.md](traefik-openstack-decision.md) | Decision record: Octavia LBaaS vs Traefik in production OpenStack |
| [swift-artifact-backend.md](swift-artifact-backend.md) | Swift container ACL setup and env var reference |
| [infra/traefik-jump-host.md](infra/traefik-jump-host.md) | Traefik v2 on the jump host as a systemd service |

## Migration

| Guide | Description |
|---|---|
| [migration-k8s-to-nomad.md](migration-k8s-to-nomad.md) | Helm chart migration checklist, data migration, rollback |

---

Looking for simulation submission guides?
→ See [`docs/modelers/`](../modelers/)
