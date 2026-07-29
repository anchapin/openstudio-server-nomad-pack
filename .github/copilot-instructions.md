# Copilot Instructions

> **Canonical source of truth:** [`AGENTS.md`](../AGENTS.md). This file is a working guide for Copilot sessions and must stay aligned with `AGENTS.md`, `README.md`, and `CONTRIBUTING.md`.

## Build, test, and lint commands

```bash
# Format-check all HCL files (non-destructive)
nomad-pack fmt --check .
nomad fmt -check policies/
for script in vagrant/provision/*.sh; do bash -n "$script"; done

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

## Related configs

- `AGENTS.md` — canonical reference with full architecture details
- `README.md`, `CONTRIBUTING.md`
