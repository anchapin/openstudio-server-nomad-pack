# openstudio-server-nomad-pack

A [Nomad Pack](https://github.com/hashicorp/nomad-pack) for deploying [OpenStudio Server](https://github.com/NREL/openstudio-server) to [HashiCorp Nomad](https://www.nomadproject.io/) clusters. This pack is designed as a lighter-weight alternative to the Kubernetes Helm chart.

## Prerequisites

- **Nomad Cluster**: A running Nomad cluster (v1.0+) with the Docker task driver enabled.
- **Consul**: A Consul cluster integrated with Nomad for service discovery and DNS resolution.
- **Vault** (Optional): A Vault cluster integrated with Nomad for secrets management.
- **Nomad Pack**: The `nomad-pack` CLI installed locally.

## Getting Started

1. Ensure your Nomad cluster is running and Consul is active.
2. Render and run the pack:
   ```bash
   nomad-pack render .
   nomad-pack run .
   ```

The pack currently renders separate jobs for:
- `<job_name>-db` (MongoDB, registered in Consul as `openstudio-db`)
- `<job_name>-rserve`
- `<job_name>` (OpenStudio placeholder job with Redis scaffold)

## Local Integration Testing (Vagrant + Consul/Nomad/Vault)

This repository includes a local multi-VM playground for validating Nomad Pack changes against a real micro-cluster.

### Prerequisites

- Vagrant
- VirtualBox (or another provider compatible with this `Vagrantfile`)

### Bring up the environment

```bash
vagrant up
```

This creates:

- `consul` (`192.168.56.10`) running a Consul server + UI
- `nomad-server` (`192.168.56.11`) running a Nomad server
- `nomad-client` (`192.168.56.12`) running a Nomad client with Docker
- `vault` (`192.168.56.13`) running Vault in dev mode (`root` token)

### Smoke checks

```bash
vagrant ssh consul -c "consul members"
vagrant ssh nomad-server -c "nomad server members"
vagrant ssh nomad-client -c "nomad node status"
vagrant ssh vault -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault status"
```

### Tear down

```bash
vagrant destroy -f
```

## Configuration Variables

Refer to [`variables.hcl`](file:///Users/achapin/OpenStudio/openstudio-server-nomad-pack/variables.hcl) for the list of configuration parameters and defaults.

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `job_name` | `string` | The name of the Nomad job | `"openstudio-server"` |
| `app_version` | `string` | Version tag for OpenStudio Server components | `"latest"` |
| `mongodb_storage_type` | `string` | Nomad volume type for MongoDB persistence (`host`, `csi`, or `ephemeral`) | `"host"` |
| `mongodb_volume_source` | `string` | Nomad volume source name for MongoDB data | `"openstudio-mongodb"` |
| `worker_min_replicas` | `number` | Minimum worker replica count | `1` |
| `worker_max_replicas` | `number` | Maximum worker replica count | `3` |
| `vault_integration_enabled` | `bool` | Enable Nomad Vault stanzas in tasks | `false` |
| `ingress_domain` | `string` | Domain suffix for ingress/service hostnames | `"service.consul"` |
| `region` | `string` | The Nomad region to deploy into | `"global"` |
| `datacenters` | `list(string)` | Eligible datacenters | `["dc1"]` |
| `web_image` | `string` | Docker image for OpenStudio Web | `"nrel/openstudio-server:latest"` |
| `worker_image` | `string` | Docker image for OpenStudio Worker | `"nrel/openstudio-server:latest"` |
| `worker_count` | `number` | Number of Nomad worker allocations | `1` |
| `worker_priority` | `number` | Nomad priority for calculation workers | `40` |
| `worker_queues` | `string` | Queue list for worker processing | `"requeued,simulations"` |
| `worker_process_count` | `string` | Worker container `COUNT` env value | `"1"` |
| `db_image` | `string` | MongoDB image | `"mongo:4.2"` |
| `mongodb_storage_type` | `string` | MongoDB storage type (`ephemeral`, `host`, `csi`) | `"ephemeral"` |
| `mongodb_host_volume` | `string` | Host volume name for MongoDB when `mongodb_storage_type=host` | `"openstudio-mongodb"` |
| `mongodb_csi_volume` | `string` | CSI volume ID for MongoDB when `mongodb_storage_type=csi` | `"openstudio-mongodb"` |
| `redis_image` | `string` | Redis image | `"redis:6.2-alpine"` |
| `redis_storage_type` | `string` | Redis storage type (`ephemeral`, `host`, `csi`) | `"ephemeral"` |
| `redis_host_volume` | `string` | Host volume name for Redis when `redis_storage_type=host` | `"openstudio-redis"` |
| `redis_csi_volume` | `string` | CSI volume ID for Redis when `redis_storage_type=csi` | `"openstudio-redis"` |
| `rserve_image` | `string` | Rserve image | `"nrel/rserve:latest"` |
| `db_constraints` | `any` | Constraint blocks for the `db` group | `[]` |
| `db_affinities` | `any` | Affinity blocks for the `db` group | `[]` |
| `db_spreads` | `any` | Spread blocks for the `db` group | `[]` |
| `redis_constraints` | `any` | Constraint blocks for the `redis` group | `[]` |
| `redis_affinities` | `any` | Affinity blocks for the `redis` group | `[]` |
| `redis_spreads` | `any` | Spread blocks for the `redis` group | `[]` |
| `rserve_constraints` | `any` | Constraint blocks for the `rserve` group | `[]` |
| `rserve_affinities` | `any` | Affinity blocks for the `rserve` group | `[]` |
| `rserve_spreads` | `any` | Spread blocks for the `rserve` group | `[]` |

## Scheduling Helpers

`templates/_helpers.tpl` defines reusable scheduling helpers for `constraint`, `affinity`, and `spread` stanzas.  
To target host environments, set group-level scheduling inputs, for example:

```hcl
db_constraints = [
  {
    attribute = "${attr.kernel.name}"
    operator  = "="
    value     = "linux"
  }
]

redis_affinities = [
  {
    attribute = "${attr.cpu.arch}"
    operator  = "="
    value     = "amd64"
    weight    = 80
  }
]
```

## Included Job Templates

- `templates/openstudio-server.nomad.tpl`: Core OpenStudio Server scaffolding and MongoDB (`openstudio-db`) service.
- `templates/redis.nomad.tpl`: Redis cache service (`openstudio-redis`) on port `6379`.
- `templates/rserve.nomad.tpl`: Rserve service (`openstudio-rserve`) on port `6311`.

## Helm to Nomad Parity & Differences

| Kubernetes / Helm | Nomad Equivalent | Status |
| --- | --- | --- |
| Helm chart | Nomad Pack | Scaffolded |
| `values.yaml` | `variables.hcl` | Scaffolded |
| Deployment/Pod | Job & Task Groups | Scaffolded (Web, DB, Redis, Worker, Rserve) |
| Container | Task (`docker` driver) | Scaffolded |
| Service | Consul `service` registration | Scaffolded |
| HPA / KEDA ScaledObject | Nomad Autoscaler | Planned |
| StorageClass / PVC | Nomad CSI volumes / `host_volume` | Implemented (DB/Redis) |
| ServiceAccount / RBAC | Nomad ACLs / Vault Roles | Planned |
| Helm Hooks | Nomad Lifecycle hooks / Periodic Jobs | Planned |

## Stateful DB/Redis Storage

By default, MongoDB and Redis run with `ephemeral` storage. To persist data, set each service to `host` or `csi`:

- `mongodb_storage_type`: `host` or `csi`
- `redis_storage_type`: `host` or `csi`

Then set the matching volume name/ID via `mongodb_host_volume`/`mongodb_csi_volume` and `redis_host_volume`/`redis_csi_volume`.
