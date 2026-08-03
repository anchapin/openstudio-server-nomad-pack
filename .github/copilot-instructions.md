# Copilot Instructions

Keep this file aligned with `AGENTS.md`, `README.md`, and `CONTRIBUTING.md`.

## Build, test, and lint commands

Use Nomad Pack v0.4.2 command shape (flags before the pack path).

```bash
# Lint / format checks
nomad-pack fmt --check templates/
nomad fmt -check policies/
for script in vagrant/provision/*.sh; do bash -n "$script"; done

# Render / validate
nomad-pack render .
nomad-pack render -var-file examples/quickstart/minimal-dev.hcl .
nomad-pack render -var "enable_batch_verification=true" .
nomad-pack validate .

# Plan (requires Nomad agent)
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan --name openstudio-server .
nomad-pack plan --name openstudio-server-minimal-dev -var-file examples/quickstart/minimal-dev.hcl .
nomad-pack plan --name openstudio-server-production-ha -var-file examples/advanced/production-ha.hcl .
nomad-pack plan --name openstudio-server-airgapped -var-file examples/advanced/airgapped.hcl .

# Full integration test sweep
bash scripts/test_nomad_pack_integration.sh

# Single-test commands (targeted)
./scripts/test_pre_teardown.sh
./scripts/test_bump_metadata_version.sh

# Variable docs sync
./scripts/generate-vars-doc.sh
./scripts/generate-vars-doc.sh docs/variables.generated.md && diff docs/variables.md docs/variables.generated.md
```

## High-level architecture

This repository is a Nomad Pack for OpenStudio Server. It deploys separate Nomad jobs for web, worker, MongoDB, Redis, and Rserve, with Consul service discovery and optional Traefik/Vault/Autoscaler/Prometheus jobs.

- `templates/openstudio-server.nomad.tpl` is an architecture marker and invariant gate; it intentionally renders no job.
- `web-background` is a second task group inside the `web` job, not a standalone job.
- Core dependency flow is `web -> redis/db/rserve/worker` and `worker -> redis/db`.

### Template-to-job model

- Core: `web.nomad.tpl`, `worker.nomad.tpl`, `db.nomad.tpl`, `redis.nomad.tpl`, `rserve.nomad.tpl`
- Optional: `system-hooks.nomad.tpl`, `batch-verification.nomad.tpl`, `nomad-autoscaler.nomad.tpl`, `prometheus.nomad.tpl`, `queue-sweeper.nomad.tpl`, `stall-watchdog.nomad.tpl`, `traefik.nomad.tpl`, `nomad-batch-worker.nomad.tpl`, `state-backup.nomad.tpl`, `state-restore.nomad.tpl`
- Test helper: `openstudio_test.nomad.tpl`

### Root pack vs registry mirror

Both layouts are active and must stay in sync:

- Root runtime pack: `templates/`, `variables.hcl`, `metadata.hcl`, `outputs.tpl`
- Registry mirror: `packs/openstudio-server/`

When editing templates/variables/metadata/outputs, mirror the same change into `packs/openstudio-server/` (CI enforces this).

## Key conventions

### Template and rendering conventions

- Nomad Pack templates use `[[ ... ]]` delimiters.
- Vault secret rendering blocks inside Nomad templates use `{{ ... }}` (Consul Template syntax), not `[[ ... ]]`.
- Prefer helper templates in `templates/_helpers.tpl` (`constraints`, `affinities`, `spreads`) over duplicating scheduler stanza logic.

### Deployment invariants and safety rails

- `web_count` must remain `1` unless upstream app locking/storage behavior changes.
- `web_priority` must stay higher than `worker_priority`.
- `worker_kill_timeout` must cover worst-case simulation runtime.
- `prepull_kill_timeout` must stay high enough to preserve pre-pulled image cache behavior.

### Storage and placement

- MongoDB and Redis support `host_volume`, `csi`, or `ephemeral` via `*_storage_type`.
- NFS shared volume for web/worker is host-volume based (`nfs_shared_volume_enabled = true` with `nfs_volume_type = "host_volume"`).
- Volume ownership expectations differ by service: DB/Redis defaults are UID:GID `999:999`; web/worker/rserve follow `docker_user`.

### Variable/docs workflow

- `variables.hcl` is the source of truth.
- Do not manually edit `docs/variables.md`; regenerate via `./scripts/generate-vars-doc.sh`.
- Commit `variables.hcl`, `docs/variables.md`, and `docs/variables.generated.md` updates together when variable definitions change.

### Release and branch flow

- PRs target `develop`; `main` is release-only.
- Use Conventional Commits and update `CHANGELOG.md` under `[Unreleased]`.
- `release-version-bump.yml` and `release.yml` automate version bump + tagged release from `main`.

### OpenStack profile paths

Use current example paths:

- `examples/advanced/openstack.hcl`
- `examples/advanced/openstack-production.hcl`
- `examples/advanced/production-ha.hcl`
- `examples/advanced/airgapped.hcl`
- `examples/quickstart/minimal-dev.hcl`
