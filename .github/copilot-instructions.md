# Copilot Instructions

> **Canonical source of truth:** [`AGENTS.md`](../AGENTS.md). This file is a working guide for Copilot sessions and must stay aligned with `AGENTS.md`, `README.md`, and `CONTRIBUTING.md`.

## Build, test, and lint commands

```bash
# Format-check all HCL files (non-destructive)
nomad-pack fmt --check .
nomad fmt -check policies/
for script in vagrant/provision/*.sh; do bash -n "$script"; done

# Operational helpers (run manually against a live cluster — not part of CI)
./scripts/pre-teardown.sh [--namespace <ns>] [JOB_NAME]  # stop jobs in teardown-safe order
./scripts/run-batch-verification.sh                       # ping/TCP-check all services

# Render templates to stdout and inspect output
nomad-pack render .
nomad-pack render -var-file examples/minimal-dev.hcl .
nomad-pack render -var "enable_batch_verification=true" .
nomad-pack validate .

# Plan/dry-run (requires Nomad agent)
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan . --name openstudio-server
nomad-pack plan . --name openstudio-server-minimal-dev -var-file examples/minimal-dev.hcl
nomad-pack plan . --name openstudio-server-production-ha -var-file examples/production-ha.hcl
nomad-pack plan . --name openstudio-server-airgapped -var-file examples/airgapped.hcl

# Integration tests (render + plan across all key scenarios)
bash scripts/test_nomad_pack_integration.sh

# Targeted single-scenario render (fastest way to verify a template change)
nomad-pack render . -var "enable_vector_collection=false"
nomad-pack render . -var "web_image=nrel/openstudio-server:3.8.0"

# Version-bump helper test (uses tests/fixtures/metadata.sample.hcl as isolated fixture)
./scripts/test_bump_metadata_version.sh

# Check docs/variables.md is up-to-date with variables.hcl
./scripts/generate-vars-doc.sh docs/variables.generated.md && diff docs/variables.md docs/variables.generated.md

# Regenerate docs/variables.md after editing variables.hcl (required before committing)
./scripts/generate-vars-doc.sh

# Run all CI workflows locally (requires act + Docker)
act push -W .github/workflows/pack-validation.yml
act push
```

## High-level architecture

This repo is a **Nomad Pack** that deploys the full OpenStudio Server stack as separate Nomad jobs. Service discovery uses Consul; ingress uses Traefik (optional); secrets management uses Vault (optional); log collection uses Vector sidecars (default on).

### Service topology

```
web ──► redis
web ──► mongodb
web ──► rserve
web ──► worker
worker ──► redis
worker ──► mongodb
```

`web-background` runs as a **second task group inside the `web` job** (`<job_name>-web`), not a separate Nomad job.

### Template → job mapping

| Template | Nomad job rendered | Conditional |
|---|---|---|
| `openstudio-server.nomad.tpl` | Architecture marker — **renders no job** | always |
| `web.nomad.tpl` | `<job_name>-web` (includes web-background task group) | always |
| `worker.nomad.tpl` | `<job_name>-worker` | always |
| `db.nomad.tpl` | `<job_name>-db` (MongoDB) | always |
| `redis.nomad.tpl` | `<job_name>-redis` | always |
| `rserve.nomad.tpl` | `<job_name>-rserve` | always |
| `openstudio_test.nomad.tpl` | `<job_name>-test` (parameterized batch) | always |
| `system-hooks.nomad.tpl` | `<job_name>-system-hooks` (system job, image pre-pull) | `enable_image_prepull = true` (default) |
| `state-backup.nomad.tpl` | `<job_name>-state-backup` (periodic batch) | `backup_enabled = true` (default) |
| `state-restore.nomad.tpl` | `<job_name>-state-restore` (on-demand parameterized batch) | `restore_enabled = true` (default) |
| `batch-verification.nomad.tpl` | `<job_name>-batch-verify` | `enable_batch_verification = true` |
| `nomad-autoscaler.nomad.tpl` | autoscaler daemon job | `nomad_autoscaler_enabled = true` |
| `traefik.nomad.tpl` | Traefik ingress job | `traefik_enabled = true` |

### Helpers (`templates/_helpers.tpl`)

| Helper | Usage |
|---|---|
| `constraints` | Iterates a list of constraint objects |
| `affinities` | Iterates a list of affinity objects |
| `spreads` | Iterates a list of spread objects |
| `openstudio_server.node_class_constraint` | Hard constraint on `${attr.nomad.node.class}` |
| `openstudio_server.compute_node_constraint` | Hard constraint on `compute_node_class` variable |
| `openstudio_server.system_node_constraint` | Hard constraint on `system_node_class` variable |
| `openstudio_server.arch_constraint` | Hard constraint: `os.name = linux`, `cpu.arch = amd64` |
| `openstudio_server.node_affinity` | Soft affinity with configurable weight |

### Registry vs. root pack

Two synchronized layouts coexist:
- **Root** (`templates/`, `variables.hcl`, `metadata.hcl`, `outputs.tpl`): used for `nomad-pack run .`
- **Registry** (`packs/openstudio-server/`): registry-aligned mirror for Pack Registry publication

To fix registry drift:
```bash
cp variables.hcl packs/openstudio-server/variables.hcl
cp metadata.hcl packs/openstudio-server/metadata.hcl
cp templates/*.tpl templates/*.nomad.tpl packs/openstudio-server/templates/
```

CI enforces sync with a 3-way check (metadata version, variable names, template file contents).

### Task lifecycle pattern

Every job follows this consistent structure:
1. **`wait-for-deps`** (`prestart`, not sidecar): `busybox:1.36` polls the Consul health API; fails fast if deps don't come up
2. **Main task**: the actual service container
3. **`vector`** sidecar (`prestart`, `sidecar = true`): collects `/alloc/logs/*.std*`, emits JSON to stdout; controlled by `enable_vector_collection = true`
4. **`cleanup-poststop`** (`poststop`): `alpine:3.20` removes paths in `poststop_cleanup_paths`

### Docker hardening defaults (applied to every task)

| Variable | Default | Effect |
|---|---|---|
| `docker_user` | `"1000:1000"` | Run containers as non-root |
| `docker_readonly_rootfs` | `true` | Read-only root filesystem |
| `docker_cap_drop` | `["ALL"]` | Drop all Linux capabilities |

### Storage backends

MongoDB and Redis each support three modes via `*_storage_type`:

| Value | Volume type | Use case |
|---|---|---|
| `host_volume` | Nomad host volume (bind-mount) | Single-node dev, small clusters |
| `csi` | Nomad CSI volume | Multi-node clusters with rescheduling |
| `ephemeral` | No volume declared | CI, throwaway dev |

MongoDB and Redis both run as UID/GID `999:999` — volume ownership must be set before first deploy.

### Vault integration (two independent mechanisms)

| Variable | Mechanism |
|---|---|
| `vault_integration_enabled` | Injects KV v2 secrets as env vars via `template` stanza + `secrets/env` file. Paths controlled by `vault_kv_*_path` variables. |
| `vault_enabled` | Adds `vault { role = "..." }` blocks to tasks. Uses per-task role overrides (`vault_db_role`, etc.) falling back to `vault_default_role`. |

Both can be active simultaneously. When neither is enabled, credentials are supplied as plaintext variables (`mongo_password`, `redis_password`, `app_secret_key_base`).

**⚠️ Critical:** Vault `template` stanzas inside `.nomad.tpl` files use standard `{{ with secret "..." }}` Go template syntax — **not** the `[[ ]]` pack delimiters.

### CI workflow overview

| Workflow | Trigger | What it checks |
|---|---|---|
| `pack-validation.yml` | push/PR to `develop` or `main` | fmt, render, validate, script syntax, `variables.md` diff, `compatibility.md` version gate, plan for all example var-files, registry sync |
| `acl-policy-validation.yml` | push/PR on `policies/**` | `nomad fmt -check policies/` |
| `integration-test.yml` | PR to `develop` (path-filtered) | template render + e2e stack test |
| `release.yml` | push to `main` | creates GitHub Release from `metadata.hcl` version |
| `release-version-bump.yml` | push to `main` | auto-bumps patch version, creates git tag |

## Key conventions

### Template syntax

Pack templates use **`[[ ]]`** delimiters (not `{{ }}`):

```hcl
[[ var "variable_name" . ]]                         # read a variable
[[ if var "vault_enabled" . ]] ... [[ end ]]         # conditional
[[ template "openstudio_server.arch_constraint" . ]] # named helper (root context)
[[ template "openstudio_server.node_affinity" (dict "attribute" "..." "value" "..." "weight" 100) ]]
[[ var "datacenters" . | toJson ]]                   # JSON-encode a list variable
```

**Exception:** Vault `template` stanzas inside `.nomad.tpl` files use `{{ }}` for Consul Template syntax.

### Hard constraints

- **`web_count` must remain `1`**: the web process writes artefacts to local container filesystem with no distributed locking. Multiple replicas cause split-brain.
- **`web_priority` (default `80`) must be > `worker_priority` (default `40`)**: prevents the scheduler from evicting the web UI under contention.
- **`prepull_kill_timeout` must be ≥ 10 minutes** (`600s`): shorter values cause image cache eviction.
- **`worker_kill_timeout` (default `5200s`) must be ≥ longest expected simulation run time**: shorter values cause data loss on node drains.

### Variable and doc workflow

After editing `variables.hcl`:
1. Run `./scripts/generate-vars-doc.sh` → regenerates `docs/variables.md` (never edit manually)
2. Commit both files together — CI diffs them and fails if out of sync

### Image alignment

When bumping OpenStudio Server version, update all four together:
- `web_image`, `web_background_image`, `worker_image` → `nrel/openstudio-server:<version>`
- `rserve_image` → `nrel/openstudio-rserve:<version>`

### Branch and release flow

- PRs target `develop`; `main` is release-only
- Branch naming: `feat/issue-<N>-<short-description>` / `fix/issue-<N>-<short-description>`
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `ci:`
- Add changelog entry under `[Unreleased]` in `CHANGELOG.md` per PR
- Release prep: move unreleased entries to versioned section + add row to `docs/compatibility.md`

Release automation on `main`:
1. **`release-version-bump.yml`** — auto-bumps patch in `metadata.hcl`, commits, pushes `v*` tag
2. **`release.yml`** — triggers on the tag, publishes GitHub Release

For a non-patch increment, run before opening the PR:
```bash
scripts/bump_metadata_version.sh metadata.hcl minor   # 0.2.0 → 0.3.0
scripts/bump_metadata_version.sh metadata.hcl 0.3.0   # explicit version
```

If Step 1 fails, verify the workflow has write permission to push to `main` and that `scripts/bump_metadata_version.sh` exits cleanly. If Step 2 is skipped, check that the `v*` tag was actually pushed and the workflow has `contents: write` permission.

### Consul service names

| Consul service name | Component |
|---|---|
| `openstudio-db` | MongoDB |
| `openstudio-redis` | Redis |
| `openstudio-rserve` | Rserve |
| `openstudio-web` | Web (HTTP on `web_port`) |

Components resolve each other via `.service.consul` DNS names. Consul Connect mTLS sidecar proxies are optionally enabled via `enable_consul_connect = true`.

### Worker autoscaling

When `worker_autoscaling_enabled = true`, the worker job gains a `scaling` block with two built-in strategies:

1. **CPU utilization** (`nomad-apm` source): enabled via `worker_autoscaling_cpu_enabled = true`. Target set by `worker_cpu_target_utilization` (default `50`). Requires no external metrics stack.
2. **Queue depth** (`prometheus` source): uses configurable Prometheus queries (`worker_queue_requeued_query`, `worker_queue_simulations_query`). Requires Prometheus at `autoscaler_prometheus_address`.

The Nomad Autoscaler daemon must be deployed before enabling autoscaling (`nomad_autoscaler_enabled = true` deploys the optional daemon stub via `nomad-autoscaler.nomad.tpl`).

### Scheduler placement helpers

Per-group constraints, affinities, and spreads are exposed as list-of-object variables (e.g. `db_constraints`, `worker_affinities`, `redis_spreads`). Each object has `attribute`, optional `operator`, `value`, and optional `weight` fields, passed to the `constraints`/`affinities`/`spreads` helpers in `_helpers.tpl`.

### NFS shared volume

Enabled via `nfs_shared_volume_enabled = true`. Recommended as an OS-level NFS mount registered as a Nomad host volume (not a CSI NFS driver). NFS alone does **not** provide distributed file locking — it does not make `web_count > 1` safe.

### Kubernetes → Nomad concept mapping

| Kubernetes / Helm concept | Nomad Pack equivalent |
|---|---|
| `values.yaml` | `variables.hcl` |
| Deployment / Pod | Job → Task Group → Task (docker driver) |
| Service | `service` stanza (registers in Consul) |
| ConfigMap / Secret | `template` stanza (static, Consul KV, or Vault) |
| HPA / KEDA ScaledObject | Nomad Autoscaler + `scaling` block in worker job |
| PodDisruptionBudget | `update` stanza with `max_parallel`, `health_check`, `auto_revert` |
| DaemonSet | Nomad system job (`type = "system"`) |
| Helm hook (pre-delete, etc.) | `prestart` / `poststop` lifecycle tasks or standalone batch jobs |
| StorageClass / PVC | `volume` stanza + CSI plugin or `host_volume` |
| ServiceAccount / RBAC | Nomad ACL policies + Vault roles |
| PriorityClass (high/low) | Job-level `priority` (web=80 > worker=40) |
| Ingress | Traefik via Consul service tags |

### Traefik ingress

The web service registers Consul tags for Traefik's Consul Catalog provider. Set `ingress_domain` to the desired hostname; set `ingress_tls_enabled = true` to add `websecure` entrypoint tags. Traefik must be deployed separately.

### `outputs.tpl`

Rendered by `nomad-pack run` on successful deployment — prints Consul service UI URLs and the Traefik web URL. When adding a new service, add its Consul URL to `outputs.tpl` as well.

### ACL policies (`policies/`)

| File | Role | Purpose |
|---|---|---|
| `operator.hcl` | Operator | Full deploy/stop/read — humans running `nomad-pack run/stop` |
| `readonly.hcl` | Read-only | Log visibility and status — monitoring dashboards |
| `cicd.hcl` | CI/CD service token | Minimal: render, plan, run, stop — automated pipelines |
| `teardown.hcl` | Teardown | Stop lifecycle access for cleanup without deploy or exec |

All policies default to the `default` namespace (matching the pack default `nomad_namespace`). Must pass `nomad fmt -check policies/` (enforced by `acl-policy-validation.yml`).

### Example var-files (`examples/`)

| File | Purpose |
|---|---|
| `minimal-dev.hcl` | Single-node, ephemeral storage, minimal resources, no Vault/autoscaling |
| `production-ha.hcl` | Multi-datacenter, HA resources, Vault, Consul Connect, autoscaling |
| `airgapped.hcl` | Private registry image overrides, journald logging, no Vault |
| `e2e-test.hcl` | End-to-end test configuration |

Use `minimal-dev.hcl` as the baseline for new var-files; it is also used for CI plan validation.

### Vagrant local cluster

`Vagrantfile` + `vagrant/provision/` spin up a 4-VM micro-cluster for local end-to-end testing:

| VM | IP | Runs |
|---|---|---|
| `consul` | `192.168.56.10` | Consul server + UI |
| `nomad-server` | `192.168.56.11` | Nomad server |
| `nomad-client` | `192.168.56.12` | Nomad client with Docker |
| `vault` | `192.168.56.13` | Vault dev mode (token: `root`) |

```bash
vagrant ssh consul -c "consul members"
vagrant ssh nomad-server -c "nomad server members"
vagrant ssh nomad-client -c "nomad node status"
vagrant ssh vault -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault status"
```

### Deep-dive docs (`docs/`)

| File | Content |
|---|---|
| `getting-started-single-node.md` | Step-by-step single-node deploy guide |
| `operations-guide.md` | Day-2 operations: scaling, draining, updating |
| `storage.md` | Host volume, CSI, NFS configuration detail |
| `upgrading.md` | Version upgrade procedures |
| `migration-k8s-to-nomad.md` | Helm → Nomad Pack migration guide |
| `vault-policies.md` | Vault policy templates and setup |
| `acl-policies.md` | Nomad ACL policy reference |
| `compatibility.md` | Pack ↔ app version compatibility matrix |
| `variables.md` | Auto-generated variable reference (do not edit manually) |

## Related configs

- `AGENTS.md` — canonical reference with full architecture details
- `README.md`, `CONTRIBUTING.md`
