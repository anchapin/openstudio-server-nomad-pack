# Copilot Instructions

Keep this file aligned with `AGENTS.md`, `README.md`, and `CONTRIBUTING.md`.

## What this repository is

A [Nomad Pack](https://developer.hashicorp.com/nomad/tutorials/nomad-pack/nomad-pack-intro) that deploys the full [OpenStudio Server](https://github.com/NREL/openstudio-server) stack (web, web-background, worker, MongoDB, Redis, Rserve) to a HashiCorp Nomad cluster. It is a lighter-weight alternative to the project's Kubernetes Helm chart. Service discovery uses Consul; HTTP ingress is handled by Traefik (optional); secrets management uses Vault (optional); log collection uses Vector sidecars (enabled by default).

## Build, test, and lint commands

Use Nomad Pack v0.4.2 command shape (flags before the pack path).

```bash
# Format-check pack templates (non-destructive)
# NOTE: `fmt -write templates/` can corrupt templates; `fmt --check -recursive .` is a silent no-op from the pack root.
nomad-pack fmt --check templates/
nomad fmt -check policies/
for script in vagrant/provision/*.sh; do bash -n "$script"; done

# Render / validate (targeted single-variable check)
nomad-pack render .
nomad-pack render -var-file examples/quickstart/minimal-dev.hcl .
nomad-pack render -var "enable_batch_verification=true" .
nomad-pack render -var "enable_vector_collection=false" .
nomad-pack render -var "web_image=nrel/openstudio-server:3.8.0" .
nomad-pack validate .

# Plan (requires Nomad agent)
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan --name openstudio-server .
nomad-pack plan --name openstudio-server-minimal-dev -var-file examples/quickstart/minimal-dev.hcl .
nomad-pack plan --name openstudio-server-production-ha -var-file examples/advanced/production-ha.hcl .
nomad-pack plan --name openstudio-server-airgapped -var-file examples/advanced/airgapped.hcl .

# Full integration test sweep
bash scripts/test_nomad_pack_integration.sh

# Individual test scripts
./scripts/test_pre_teardown.sh
./scripts/test_bump_metadata_version.sh           # Uses tests/fixtures/metadata.sample.hcl as isolated fixture
./scripts/test_backup_restore_docs_defaults.sh

# Variable docs sync
./scripts/generate-vars-doc.sh                    # Regenerate docs/variables.md after editing variables.hcl
./scripts/generate-vars-doc.sh docs/variables.generated.md && diff docs/variables.md docs/variables.generated.md

# Operational helpers (manual, against a live cluster)
./scripts/pre-teardown.sh [--namespace <ns>] [JOB_NAME]
./scripts/run-batch-verification.sh

# Run all CI workflows locally (requires act + Docker)
act push -W .github/workflows/pack-validation.yml
act push
```

## High-level architecture

### Service topology

```
web ──► redis
web ──► mongodb
web ──► rserve
web ──► worker
worker ──► redis
worker ──► mongodb
```

Each component is a **separate Nomad job** (`<job_name>-web`, `<job_name>-worker`, `<job_name>-db`, `<job_name>-redis`, `<job_name>-rserve`). Consul is used for service discovery — components resolve each other via `.service.consul` DNS names.

- `templates/openstudio-server.nomad.tpl` is an architecture marker; it intentionally renders no job.
- `web-background` is a second task group inside the `web` job, not a standalone job.

### Template-to-job model

| Template | Nomad job rendered | Conditional |
|---|---|---|
| `openstudio-server.nomad.tpl` | Architecture marker (no job) | always |
| `web.nomad.tpl` | `<job_name>-web` | always |
| `worker.nomad.tpl` | `<job_name>-worker` | always |
| `db.nomad.tpl` | `<job_name>-db` (MongoDB) | always |
| `redis.nomad.tpl` | `<job_name>-redis` | always |
| `rserve.nomad.tpl` | `<job_name>-rserve` | always |
| `system-hooks.nomad.tpl` | image pre-pull system job | `enable_image_prepull = true` (default) |
| `nomad-autoscaler.nomad.tpl` | autoscaler daemon | `nomad_autoscaler_enabled = true` |
| `batch-verification.nomad.tpl` | one-shot batch verify | `enable_batch_verification = true` |
| `traefik.nomad.tpl` | Traefik ingress | `deploy_traefik = true` |
| `prometheus.nomad.tpl` | Prometheus + redis_exporter | `prometheus_enabled = true` |
| `queue-sweeper.nomad.tpl` | queue sweeper | `enable_queue_sweeper = true` |
| `stall-watchdog.nomad.tpl` | stall watchdog | `enable_stall_watchdog = true` |
| `nomad-batch-worker.nomad.tpl` | batch worker | `batch_engine == "nomad_batch"` |
| `state-backup.nomad.tpl` | periodic backup batch job | `backup_enabled = false` (default) |
| `state-restore.nomad.tpl` | on-demand restore batch job | `restore_enabled = false` (default) |
| `openstudio_test.nomad.tpl` | parameterized test job | always |

### Root pack vs registry mirror

Both layouts are active and must stay in sync:

- Root runtime pack: `templates/`, `variables.hcl`, `metadata.hcl`, `outputs.tpl`
- Registry mirror: `packs/openstudio-server/`

When editing templates/variables/metadata/outputs, mirror the same change into `packs/openstudio-server/` (CI enforces this with a 3-way check).

### Task lifecycle pattern

All job templates use this consistent pattern:

1. **`wait-for-deps`** (`prestart`, not sidecar): polls Consul health API using `wget`; fails fast if dependencies don't come up.
2. **Main task**: the actual service container.
3. **`vector`** sidecar (`prestart`, sidecar = true): collects allocation logs from `/alloc/logs/*.std*`; enabled by `enable_vector_collection = true` (default).
4. **`cleanup-poststop`** (`poststop`): `alpine:3.20` runs `rm -rf` on `poststop_cleanup_paths`.

## Key conventions

### Template syntax

Nomad Pack templates use Go template syntax with **`[[` / `]]`** delimiters (not `{{` / `}}`).

- Read a variable: `[[ var "variable_name" . ]]`
- Conditional: `[[ if var "vault_enabled" . ]] ... [[ end ]]`
- Named template with root context: `[[ template "openstudio_server.arch_constraint" . ]]`
- Named template with dict: `[[ template "openstudio_server.node_affinity" (dict "attribute" "..." "value" "..." "weight" 100) ]]`
- JSON-encode a list: `[[ var "datacenters" . | toJson ]]`
- **Vault `template` stanzas** inside `.nomad.tpl` files use `{{ with secret "..." }}` (Consul Template / Go standard syntax, NOT `[[ ]]`).

### `_helpers.tpl` named templates

Prefer these over duplicating scheduler stanza logic:

| Helper | Usage |
|---|---|
| `constraints` | Iterates a list of constraint objects |
| `affinities` | Iterates a list of affinity objects |
| `spreads` | Iterates a list of spread objects |
| `openstudio_server.compute_node_constraint` | Shorthand for `compute_node_class` variable |
| `openstudio_server.system_node_constraint` | Shorthand for `system_node_class` variable |
| `openstudio_server.arch_constraint` | Hard constraint: `kernel.name = linux`, `cpu.arch = amd64` |
| `openstudio_server.node_affinity` | Soft affinity with configurable weight |

### Deployment invariants and safety rails

- **`web_count` must remain `1`**: The web process writes artefacts to local container filesystem with no distributed file-locking. Multiple replicas cause split-brain.
- **`web_priority` (default `80`) must always be greater than `worker_priority` (default `40`)**: inverting causes the scheduler to evict the web UI during resource contention.
- **`worker_kill_timeout` (default `5200s`) must be ≥ longest expected simulation run time**: reducing it causes data loss on drains.
- **`prepull_kill_timeout` (default `600s`) must stay ≥ 10 minutes**: to preserve pre-pulled image cache behavior.

### Docker hardening defaults

| Variable | Default | Effect |
|---|---|---|
| `docker_user` | `"1000:1000"` | Run containers as non-root |
| `docker_readonly_rootfs` | `true` | Read-only root filesystem |
| `docker_cap_drop` | `["ALL"]` | Drop all Linux capabilities |

Volume ownership differs by service: DB/Redis default to UID:GID `999:999` (`db_docker_user`, `redis_docker_user`); web/worker/rserve use `docker_user`.

### Storage backends

MongoDB and Redis each support three storage modes via `*_storage_type`:

| Value | Use case |
|---|---|
| `host_volume` | Single-node dev, small clusters |
| `csi` | Multi-node clusters where allocations reschedule |
| `ephemeral` | CI environments, throwaway dev |

NFS shared volume for web + worker: enabled via `nfs_shared_volume_enabled = true`. Recommended as an OS-level NFS mount registered as a Nomad host volume (not a CSI NFS driver). NFS does **not** provide distributed file locking and does not make `web_count > 1` safe.

### Vault integration

Two independent mechanisms exist (both default `false`):

| Variable | Mechanism |
|---|---|
| `vault_integration_enabled` | Injects KV v2 secrets as env vars via `template` stanza. Paths: `vault_kv_mongodb_path`, `vault_kv_redis_path`, `vault_kv_app_path`. |
| `vault_enabled` | Adds role-based `vault { role = "..." }` blocks to tasks. Per-task overrides (`vault_db_role`, etc.) fall back to `vault_default_role`. |

Both can be active simultaneously. When neither is enabled, credentials are plaintext variables (`mongo_password`, `redis_password`, `app_secret_key_base`).

### Variable/docs workflow

- `variables.hcl` is the source of truth. Do not manually edit `docs/variables.md`.
- After editing any variable: run `./scripts/generate-vars-doc.sh`, then commit `variables.hcl`, `docs/variables.md`, and `docs/variables.generated.md` together.
- CI fails if these files are out of sync.

### Release and branch flow

- PRs target `develop`; `main` is release-only.
- Branch naming: `feat/issue-<N>-<short-description>` and `fix/issue-<N>-<short-description>`.
- Use Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`).
- Update `CHANGELOG.md` under `[Unreleased]` in every PR.
- Before a release PR to `main`: add a row to `docs/compatibility.md` for the upcoming version (CI enforces this).
- `release-version-bump.yml` auto-bumps patch version and creates the `v*` tag; `release.yml` publishes the GitHub Release.
- For minor/major bumps: `scripts/bump_metadata_version.sh metadata.hcl minor` or `scripts/bump_metadata_version.sh metadata.hcl 0.3.0`.

### Image naming alignment

When bumping the OpenStudio Server version, update all four image variables together:
- `web_image`, `web_background_image`, `worker_image` → `nrel/openstudio-server:<version>`
- `rserve_image` → `nrel/openstudio-rserve:<version>`

### ACL policies (`policies/`)

| File | Role |
|---|---|
| `operator.hcl` | Full deploy/stop/read |
| `readonly.hcl` | Log visibility and status |
| `cicd.hcl` | Minimal: render, plan, run, stop |
| `teardown.hcl` | Stop lifecycle only |
| `batch-dispatcher.hcl` | Dispatch parameterized batch jobs (`batch_engine = "nomad_batch"`) |
### Example var-files (`examples/`)

| File | Purpose |
|---|---|
| `examples/quickstart/minimal-dev.hcl` | Single-node, ephemeral storage, no Vault/autoscaling (CI baseline) |
| `examples/advanced/production-ha.hcl` | Multi-datacenter, HA, Vault, Consul Connect, autoscaling |
| `examples/advanced/airgapped.hcl` | Private registry image overrides, journald logging |
| `examples/advanced/openstack.hcl` / `openstack-production.hcl` | OpenStack-specific profiles |

### Kubernetes → Nomad concept mapping

| Kubernetes / Helm concept | Nomad Pack equivalent |
|---|---|
| `values.yaml` | `variables.hcl` |
| Deployment / Pod | Job → Task Group → Task (docker driver) |
| Service | `service` stanza (Consul) |
| ConfigMap / Secret | `template` stanza (static, Consul KV, or Vault) |
| HPA / KEDA ScaledObject | Nomad Autoscaler + `scaling` block |
| PodDisruptionBudget | `update` stanza with `max_parallel`, `health_check`, `auto_revert` |
| DaemonSet | Nomad system job (`type = "system"`) |
| Helm hook | `prestart` / `poststop` lifecycle tasks or standalone batch jobs |
| StorageClass / PVC | `volume` stanza + CSI plugin or `host_volume` |
| PriorityClass (high/low) | Job-level `priority` (web=80 > worker=40) |
| Ingress | Traefik via Consul service tags |

### CI workflow overview

| Workflow | Trigger | What it checks |
|---|---|---|
| `pack-validation.yml` | push/PR to `develop`/`main` | fmt, render, plan (multi-scenario), variable/compatibility doc sync, registry sync |
| `acl-policy-validation.yml` | push/PR on `policies/**` | `nomad fmt -check policies/` |
| `integration-test.yml` | PR to `develop` (path-filtered) | template render + e2e stack test |
| `release-version-bump.yml` | push to `main` | auto-bump patch version, sync registry metadata, create `v*` tag |
| `release.yml` | push of `v*` tag | publish GitHub Release |
