# Copilot Instructions

Keep this file aligned with `AGENTS.md`, `README.md`, and `CONTRIBUTING.md`.

## What this repository is

This repository is a **Nomad Pack** that deploys the full OpenStudio Server stack to Nomad:
- OpenStudio web, web-background, worker
- MongoDB, Redis, Rserve
- Optional Traefik, Vault integration, Nomad Autoscaler, backup/restore, and verification jobs

The pack root for all pack commands is:

```bash
packs/openstudio-server/
```

## Build, test, and lint commands

```bash
# IMPORTANT: never use `nomad-pack fmt -write` in this repo (v0.4.2 can corrupt templates)
nomad-pack fmt --check packs/openstudio-server/templates/

# Render templates
nomad-pack render packs/openstudio-server
nomad-pack render -var-file examples/quickstart/minimal-dev.hcl packs/openstudio-server
nomad-pack render -var "enable_batch_verification=true" packs/openstudio-server

# Plan (dry-run) against a local Nomad dev agent
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan --name openstudio-server packs/openstudio-server
nomad-pack plan --name openstudio-server-minimal-dev -var-file examples/quickstart/minimal-dev.hcl packs/openstudio-server

# Full integration script used by CI
bash scripts/test_nomad_pack_integration.sh

# Single focused tests (fast iteration)
./scripts/test_pre_teardown.sh
./scripts/test_validate_traefik_consul_endpoint.sh
./scripts/test_bump_metadata_version.sh
./scripts/test_backup_restore_docs_defaults.sh
./scripts/test_release_version_bump_workflow.sh
./scripts/test_migration_doc_variable_mapping.sh
./scripts/test_openstack_autoscaler_render.sh

# Go terratest module
go test ./tests/terratest/...

# Run one Go test (single test target)
go test ./tests/terratest/... -run '^TestNomadPackIntegrationScenarios$'

# Validate a single Nomad job spec
nomad job validate examples/advanced/test-batch.nomad

# Validate ACL policy formatting
nomad fmt -check policies/

# Validate provisioning scripts
for script in vagrant/provision/*.sh; do bash -n "$script"; done
bash -n vagrant/provision/nomad-client.sh

# Regenerate variable docs after editing variables.hcl
./scripts/generate-vars-doc.sh

# Check docs/variables.md sync (non-destructive)
./scripts/generate-vars-doc.sh docs/variables.generated.md
diff docs/variables.md docs/variables.generated.md
```

## High-level architecture

### Deployment model

- `nomad-pack render` emits multiple Nomad jobs from `packs/openstudio-server/templates/*.nomad.tpl`.
- The runtime stack is split into jobs: `<job_name>-web`, `<job_name>-db`, `<job_name>-redis`, `<job_name>-rserve`.
- `worker` is a separate Nomad job rendered from `worker.nomad.tpl` with `priority = worker_priority` (default 40), lower than `web_priority` (default 80), so the scheduler evicts workers before the web UI during resource contention.
- Service discovery and cross-job connectivity are done through **Consul** (`*.service.consul`).

### Template layout and conditional jobs

Core always-rendered templates:
- `web.nomad.tpl`, `db.nomad.tpl`, `redis.nomad.tpl`, `rserve.nomad.tpl`
- `openstudio-server.nomad.tpl` (architecture marker, no job payload)

Conditional templates:
- `system-hooks.nomad.tpl` (`enable_image_prepull`)
- `nomad-autoscaler.nomad.tpl` (`nomad_autoscaler_enabled`)
- `batch-verification.nomad.tpl` (`enable_batch_verification`)
- `traefik.nomad.tpl` (`deploy_traefik`)
- `prometheus.nomad.tpl` (`prometheus_enabled`)
- `queue-sweeper.nomad.tpl` (`enable_queue_sweeper` or `enable_stall_watchdog`)
- `stall-watchdog.nomad.tpl` (marker; consolidated into queue-sweeper template)
- `nomad-batch-worker.nomad.tpl` (`batch_engine == "nomad_batch"`)
- `state-backup.nomad.tpl` (`backup_enabled`)
- `state-restore.nomad.tpl` (`restore_enabled`)
- `infra-setup.nomad.tpl` (`enable_infra_setup`)

### Reusable template helpers

`packs/openstudio-server/templates/_helpers.tpl` centralizes helper templates:
- `constraints`, `affinities`, `spreads` iterate list-of-object placement inputs
- `openstudio_server.compute_node_constraint` and `openstudio_server.system_node_constraint` enforce node class placement
- `openstudio_server.arch_constraint` enforces Linux/amd64

### Runtime behavior patterns

- All major service groups use a lifecycle pattern:
  1. `wait-for-deps` prestart task (polls Consul health)
  2. main service task
  3. optional `vector` sidecar (`enable_vector_collection`)
  4. `cleanup-poststop` poststop task
- Optional Consul Connect sidecar proxies are enabled via `enable_consul_connect`.
- `outputs.tpl` is the post-deploy output surface for service URLs and should be updated when adding exposed services.

### Storage and state

- MongoDB and Redis support `host_volume`, `csi`, or `ephemeral` storage modes.
- Shared web/worker NFS (`nfs_shared_volume_enabled`) shares files but does not provide distributed locking.
- Backup (`state-backup`) is periodic batch; restore (`state-restore`) is parameterized on-demand batch.

## Key conventions

### Branches, commits, and PRs

- All PRs target `develop`; `main` is release-only.
- Branch names follow `feat/issue-<N>-...` and `fix/issue-<N>-...`.
- Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`).
- Every PR adds a `[Unreleased]` entry in `CHANGELOG.md` with PR reference.

### Release flow

- Release is a two-workflow chain on `main`:
  1. `release-version-bump.yml` bumps `packs/openstudio-server/metadata.hcl` patch version and tags `v*`
  2. `release.yml` publishes GitHub Release from that tag
- For PRs targeting `main`, CI expects `docs/compatibility.md` to already contain the **upcoming** patch version row.

### Variables and docs source of truth

- `packs/openstudio-server/variables.hcl` is the source of truth for pack inputs.
- `docs/variables.md` is generated via `./scripts/generate-vars-doc.sh` and must be committed with variable changes.
- README should reference `docs/variables.md` instead of maintaining a duplicate variable table.

### Template syntax and path conventions

- Nomad Pack templates use `[[ ... ]]` delimiters (not `{{ ... }}`).
- Run all `nomad-pack` commands against `packs/openstudio-server`.

### Scheduling and resiliency invariants

- `web_priority` must remain higher than `worker_priority`.
- `web_count` must remain `1` unless upstream app behavior changes to support safe multi-writer semantics.
- `worker_kill_timeout` must stay above maximum expected simulation duration.

### Image/version alignment

- Keep these image tags aligned when bumping OpenStudio version:
  - `web_image`
  - `web_background_image`
  - `worker_image`
  - `rserve_image`

