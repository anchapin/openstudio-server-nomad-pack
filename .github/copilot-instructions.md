# Copilot Instructions

> This file is the primary working guide for Copilot sessions. Keep it aligned with `AGENTS.md`, `README.md`, and `CONTRIBUTING.md`. Check `NEXT_SESSION.md` for the current active focus area when starting a new session.

## Known bugs and caveats (as of pack v0.2.67 / nomad-pack v0.4.2)

> See `AUDIT-REPORT.md` for full details. Do not close these without fixing the root cause.

- **`redis_port` undefined** (`queue-sweeper.nomad.tpl:102`): `enable_queue_sweeper=true` produces an empty Redis URL. Use `web_redis_url` instead of hand-building the URL. *(Critical — feature is broken out of the box.)*
- **`vault_enabled=true` renders empty `vault {}` blocks**: `vault_db_role`, `vault_redis_role`, `vault_rserve_role`, `vault_default_role` are defined in `variables.hcl` but referenced **nowhere** in any template. Role-based Vault integration is unimplemented. Do not document it as working.
- **`nomad-pack fmt` (v0.4.2) corrupts templates**: Running `fmt -write templates/` mangles the `[[- /*` comment-header workaround and breaks `render`. Do **not** run `nomad-pack fmt -write` on `templates/`. The CI `fmt -check -recursive .` gate is also a no-op (exits 0, finds no files). Use `nomad-pack fmt -check templates/` for a real check.
- **Flag order matters** (v0.4.2): flags must come **before** the pack path. `nomad-pack render . -var-file X` fails; `nomad-pack render -var-file X .` works. All README/AGENTS.md examples with trailing flags are wrong — use flags-first form.
- **Dead variables** (define in `variables.hcl`, used in 0 templates): `autoscaler_cooldown`, `aws_batch_vault_aws_role`, `db_csi_plugin_id`, `redis_csi_plugin_id`, `vault_*_role` variables, `web_background_autoscaling_*`, `web_background_count`, `web_background_max/min_replicas`. Setting these does nothing.
- **`deployment_marker` is hardcoded** to `"openstack-aurora-179d"` in `web.nomad.tpl`, `redis.nomad.tpl`, `rserve.nomad.tpl`, `db.nomad.tpl`. It is not driven by a variable.
- **`docs/` path table in AGENTS.md is wrong**: actual paths use `docs/modelers/` and `docs/infrastructure/` subdirectories, not `docs/` directly. `docs/variables.md` and `docs/compatibility.md` are the only files at the root docs level.

## Build, test, and lint commands

```bash
# Format-check all HCL files (non-destructive)
# NOTE: use -check templates/ not -check -recursive . (recursive is a v0.4.2 no-op)
nomad-pack fmt -check templates/
nomad fmt -check policies/
for script in vagrant/provision/*.sh; do bash -n "$script"; done

# Operational helpers (run manually against a live cluster — not part of CI)
./scripts/pre-teardown.sh [--namespace <ns>] [JOB_NAME]  # stop jobs in teardown-safe order
./scripts/run-batch-verification.sh                       # ping/TCP-check all services

# Render templates to stdout and inspect output
# IMPORTANT: flags must come BEFORE the pack path (nomad-pack v0.4.2 requirement)
nomad-pack render .
nomad-pack render -var-file examples/quickstart/minimal-dev.hcl .
nomad-pack render -var "enable_batch_verification=true" .
nomad-pack validate .

# Plan/dry-run (requires Nomad agent)
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan --name openstudio-server .
nomad-pack plan --name openstudio-server-minimal-dev -var-file examples/quickstart/minimal-dev.hcl .
nomad-pack plan --name openstudio-server-production-ha -var-file examples/advanced/production-ha.hcl .
nomad-pack plan --name openstudio-server-airgapped -var-file examples/advanced/airgapped.hcl .

# Integration tests (render + plan across all key scenarios)
bash scripts/test_nomad_pack_integration.sh

# Targeted single-scenario render (fastest way to verify a template change)
nomad-pack render -var "enable_vector_collection=false" .
nomad-pack render -var "web_image=nrel/openstudio-server:3.8.0" .

# Version-bump helper test (uses tests/fixtures/metadata.sample.hcl as isolated fixture)
./scripts/test_bump_metadata_version.sh

# Check docs/variables.md is up-to-date with variables.hcl
./scripts/generate-vars-doc.sh docs/variables.generated.md && diff docs/variables.md docs/variables.generated.md

# Regenerate docs/variables.md after editing variables.hcl (required before committing)
./scripts/generate-vars-doc.sh

# Check backup/restore default docs stay aligned with variables.hcl
./scripts/test_backup_restore_docs_defaults.sh

# Run all CI workflows locally (requires act + Docker)
act push -W .github/workflows/pack-validation.yml
act pull_request -W .github/workflows/pack-validation.yml  # simulates PR trigger
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
| `state-backup.nomad.tpl` | `<job_name>-state-backup` (periodic batch) | `backup_enabled = false` (default) |
| `state-restore.nomad.tpl` | `<job_name>-state-restore` (on-demand parameterized batch) | `restore_enabled = false` (default) |
| `batch-verification.nomad.tpl` | `<job_name>-batch-verify` | `enable_batch_verification = true` |
| `nomad-autoscaler.nomad.tpl` | autoscaler daemon job | `nomad_autoscaler_enabled = true` |
| `traefik.nomad.tpl` | Traefik ingress job | `deploy_traefik = true` |
| `prometheus.nomad.tpl` | `<job_name>-prometheus` (Prometheus + redis_exporter sidecar) | `prometheus_enabled = false` (default) |
| `queue-sweeper.nomad.tpl` | `<job_name>-queue-sweeper` (periodic batch, clears stale Redis locks) | `enable_queue_sweeper = false` (default) |
| `stall-watchdog.nomad.tpl` | `<job_name>-stall-watchdog` (periodic batch, restarts stalled worker allocs) | `enable_stall_watchdog = true` |
| `nomad-batch-worker.nomad.tpl` | `<job_name>-nomad-batch-worker` (Nomad-native batch execution mode) | `batch_engine == "nomad_batch"` |

### Helpers (`templates/_helpers.tpl`)

| Helper | Usage |
|---|---|
| `constraints` | Iterates a list of constraint objects |
| `affinities` | Iterates a list of affinity objects |
| `spreads` | Iterates a list of spread objects |
| `openstudio_server.node_class_constraint` | Hard constraint on `${attr.nomad.node.class}` |
| `openstudio_server.compute_node_constraint` | Hard constraint on `compute_node_class` variable |
| `openstudio_server.system_node_constraint` | Hard constraint on `system_node_class` variable |
| `openstudio_server.arch_constraint` | Hard constraint: `kernel.name = linux`, `cpu.arch = amd64` |
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

Volume names default to `openstudio-mongodb` and `openstudio-redis`. MongoDB data mounts at `/data/db`; Redis data mounts at `/data`.

MongoDB and Redis both run as UID/GID `999:999` (configurable via `db_docker_user` and `redis_docker_user`) — volume ownership must be set before first deploy. The global `docker_user` (default `1000:1000`) applies to web, worker, and rserve tasks only.

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
| `pack-validation.yml` | push/PR to `develop` or `main`, `workflow_dispatch` | fmt, render, validate, `examples/test-batch.nomad` job spec validation, Vagrantfile syntax, script syntax, version-bump tests, `variables.md` diff, backup/restore default-doc consistency, README links to `docs/variables.md`, `compatibility.md` version gate, Nomad dev-agent plan for all example var-files, registry sync, integration test script |
| `acl-policy-validation.yml` | push/PR on `policies/**` | `nomad fmt -check policies/` |
| `integration-test.yml` | PR to `develop` on `templates/**`, `variables.hcl`, `packs/**`, `scripts/**`, `examples/**`, `metadata.hcl` | template render + e2e stack test using `examples/advanced/e2e-test.hcl` |
| `release.yml` | push of tag matching `v*` | reads version from `metadata.hcl`, publishes GitHub Release |
| `release-version-bump.yml` | push to `main` | auto-bumps patch version, syncs `packs/openstudio-server/metadata.hcl`, commits both files, creates and pushes `v*` git tag |

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

- **`web_count` must remain `1`**: the web process writes uploaded analysis artefacts to the local container filesystem (under `/mnt/openstudio` when NFS is mounted) with no distributed file-locking. Requests routed to replica B cannot find files written by replica A. Safe `web_count > 1` requires either Redlock-based distributed locking or fully stateless file handling (S3/MinIO).
- **`web_priority` (default `80`) must be > `worker_priority` (default `40`)**: prevents the scheduler from evicting the web UI under contention.
- **`prepull_kill_timeout` must be ≥ 10 minutes** (`600s`): shorter values cause image cache eviction.
- **`worker_kill_timeout` (default `5200s`) must be ≥ longest expected simulation run time**: shorter values cause data loss on node drains.

### Variable and doc workflow

After editing `variables.hcl`:
1. Run `./scripts/generate-vars-doc.sh` → regenerates `docs/variables.md` (never edit manually)
2. Commit both files together — CI diffs them and fails if out of sync

The README **does not** maintain a variable table — the `## Configuration Variables` section links to `docs/variables.md` only. Never paste a variable table into `README.md`; a CI step enforces the link exists.

> **Note:** `docs/variables.generated.md` is a CI scratch file used by the `Check variables.md is up-to-date` workflow step (it generates to this path and diffs against `docs/variables.md`). It is committed to the repo but should not be edited manually — regenerate with `./scripts/generate-vars-doc.sh docs/variables.generated.md`.

### Image alignment

When bumping OpenStudio Server version, update all four together:
- `web_image`, `web_background_image`, `worker_image` → `nrel/openstudio-server:<version>`
- `rserve_image` → `nrel/openstudio-rserve:<version>`

`redis_image` defaults to `redis:6.2-alpine` — align Redis major.minor with the target OpenStudio Server release requirements before deploying.

### Branch and release flow

- PRs target `develop`; `main` is release-only
- Branch naming: `feat/issue-<N>-<short-description>` / `fix/issue-<N>-<short-description>`
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `ci:`
- Add changelog entry under `[Unreleased]` in `CHANGELOG.md` per PR
- Release prep: move unreleased entries to versioned section + add row to `docs/compatibility.md`
- **`compatibility.md` version gate:** for PRs to `main`, CI requires the **upcoming** release version (`current pack.version` + patch) to exist in the table — add this row before opening the `develop → main` PR

Release automation on `main`:
1. **`release-version-bump.yml`** — auto-bumps patch in `metadata.hcl`, syncs `packs/openstudio-server/metadata.hcl`, commits both files, pushes `v*` tag
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

The worker job uses an `update` stanza (equivalent to a Kubernetes PodDisruptionBudget):
```hcl
update {
  max_parallel     = 1
  health_check     = "checks"
  min_healthy_time = "10s"
  healthy_deadline = "5m"
  auto_revert      = true
}
```

For the Prometheus queue-depth strategy, Prometheus must be running and scraping queue metrics **before** enabling `worker_autoscaling_enabled = true`. The CPU strategy (`nomad-apm`) requires no external metrics stack.

### In-pack Prometheus (`prometheus.nomad.tpl`)

`prometheus_enabled = true` deploys a Prometheus service job (`<job_name>-prometheus`) that includes a `redis-exporter` sidecar (default image `oliver006/redis_exporter:v1.62.0`). The exporter tracks `resque:queue:simulations` and `resque:queue:requeued` key lengths and exposes them as `openstudio_worker_queue_depth` metrics. The Prometheus instance registers as `openstudio-prometheus` in Consul; the autoscaler's `autoscaler_prometheus_address` defaults to `http://openstudio-prometheus.service.consul:9090`. Enable this before setting `worker_autoscaling_enabled = true` with a Prometheus check strategy.

### Queue-sweeper (`queue-sweeper.nomad.tpl`)

`enable_queue_sweeper = true` deploys a periodic batch job (`<job_name>-queue-sweeper`) that runs on the schedule set by `queue_sweeper_cron` (default: every 2 minutes). It scans Redis for `resque:analysis:*:queuing` keys that have no TTL and have been idle longer than `queue_sweeper_max_lock_age_seconds` (default `120`), then deletes them. This automates the same lock-clearing that `scripts/clear-stale-queuing-locks.sh` does manually. The task uses `readonly_rootfs = false` (required for redis-cli temp files) and resolves Redis via Consul service DNS.

### Stall-watchdog (`stall-watchdog.nomad.tpl`)

`enable_stall_watchdog = true` deploys a periodic batch job (`<job_name>-stall-watchdog`) that detects data points frozen in `started` status with no `updated_at` progress for longer than `stall_watchdog_max_stall_seconds` (default `3600`). This covers the failure mode where EnergyPlus hangs silently inside a worker container without crashing Resque — leaving all worker slots occupied with zero throughput.

**This is distinct from the queue-sweeper:**

| Component | Failure mode | What it clears |
|---|---|---|
| `queue-sweeper` | Resque `resque:analysis:*:queuing` Redis lock with no TTL | Redis locks that block job dispatch |
| `stall-watchdog` | EnergyPlus hangs silently inside worker; DP stuck in `started` | Running worker allocations (Nomad reschedules fresh) |

Key variables:
- `stall_watchdog_cron` (default: every 15 minutes)
- `stall_watchdog_max_stall_seconds` (default `3600`)
- `stall_watchdog_restart_allocs` — set `true` to auto-stop stalled worker allocs; `false` (default) for alert-only
- `stall_watchdog_nomad_address` — Nomad API address reachable from inside the container (default `http://localhost:4646` with `network_mode = host`; override in NAT/multi-region environments)
- `stall_watchdog_worker_job` — override if your worker job name differs from `<job_name>-worker`
- `stall_watchdog_image` — must include Python 3 stdlib (`python:3.12-alpine` is the default)

Exit codes: `0` (no stalled DPs), `1` (error), `2` (stalled DPs found). Use exit code `2` as a PagerDuty/alert gate when `restart_allocs = false`.

The watchdog samples up to 20 DP UUIDs from the Resque `/working` page, checks `updated_at` via the web API, and (if `restart_allocs = true`) calls `POST /v1/allocation/<id>/stop` on every running worker alloc. Nomad reschedules fresh worker allocations automatically.

### Compute backend (`batch_engine`)

`batch_engine` controls which execution backend runs simulations. Default is `"internal"`.

| Value | Behavior |
|---|---|
| `"internal"` | Workers run as long-lived Nomad service jobs on this cluster (standard mode) |
| `"nomad_batch"` | Web dispatcher submits one parameterized Nomad batch allocation per simulation run via `POST /v1/job/<name>/dispatch`. The `worker` and `rserve` service jobs are **omitted** (scale-to-zero). |
| `"aws_batch"` | Routes simulation submissions to an external AWS Batch queue. Worker and rserve service jobs are omitted. |

**`nomad_batch` mode:** `nomad-batch-worker.nomad.tpl` renders a parameterized job (`type = "batch"` + `parameterized` stanza). The web dispatcher POSTs a JSON payload `{"analysis_id": "<uuid>", "datapoint_id": "<uuid>"}` and the values become `NOMAD_META_analysis_id` / `NOMAD_META_datapoint_id` env vars inside the task. The dispatcher reads `NOMAD_ADDR` + `NOMAD_TOKEN` from its Workload Identity. Key variables:
- `nomad_batch_job_name` — the dispatched job name the web dispatcher calls
- `nomad_batch_datacenter` / `nomad_batch_namespace` — target a separate datacenter or namespace
- `nomad_batch_worker_image`, `nomad_batch_cpu`, `nomad_batch_memory`
- `nomad_batch_kill_timeout` — must be ≥ longest expected simulation run time (same constraint as `worker_kill_timeout`)
- `nomad_batch_constraints` — placement constraints list (same object shape as other `*_constraints` variables)

When `batch_engine != "internal"`, do not set `worker_autoscaling_enabled = true` — there is no long-lived worker job to autoscale.

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

### Backup and restore jobs

`state-backup.nomad.tpl` renders a **periodic batch job** that runs `mongodump` and `redis-cli BGSAVE` on the schedule in `backup_cron` (default `0 2 * * * *`). Backups write to `backup_volume_source` and rotate files older than `backup_retention_days` (default `14`). Both jobs are disabled by default (`backup_enabled = false`, `restore_enabled = false`). `state-restore.nomad.tpl` is an on-demand parameterized batch job dispatched manually.

### Batch verification job

`batch-verification.nomad.tpl` (enabled by `enable_batch_verification = true`) uses `busybox` to ping/TCP-connect each service in `verification_targets`. Structured log output: `batch_verification_result component=... status=pass|fail` and `batch_verification_summary total=... passed=... failed=...`.

### `infra-setup.nomad`

`infra-setup.nomad` (repo root, **not** a pack template) is a standalone Nomad system job used for one-time cluster configuration. It runs on every client node and:

1. Adds the Consul stanza to the Nomad client config so services register with the central Consul server
2. Configures Docker `data-root` to local storage for reliable layer extraction
3. Reloads Nomad client and Docker to apply the changes

```bash
export NOMAD_ADDR=http://localhost:4646
nomad run infra-setup.nomad   # apply on all nodes
nomad stop -purge infra-setup # teardown when done
```

**Required before deploying on a fresh OpenStack cluster** (`make os-run` handles this automatically). The `make os-teardown` target also purges it.

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
| `openstack.hcl` | NREL aurora-179d OpenStack cluster (cc.medium 4 vCPU nodes, ~9,000 usable vCPU) |
| `openstack-production.hcl` | Tuned production overrides for OpenStack — Vault, NFS, autoscaler, staged rollout defaults |

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
| `nfs-tuning-guide.md` | NFS mount options, rsize/wsize, actimeo tuning |
| `upgrading.md` | Version upgrade procedures |
| `migration-k8s-to-nomad.md` | Helm → Nomad Pack migration guide |
| `vault-policies.md` | Vault policy templates and setup |
| `acl-policies.md` | Nomad ACL policy reference |
| `compatibility.md` | Pack ↔ app version compatibility matrix |
| `variables.md` | Auto-generated variable reference (do not edit manually) |
| `openstack-staged-rollout-runbook.md` | 4-stage canary → full ramp procedure with gate criteria and rollback |
| `openstack-stabilization-runbook.md` | Remediation steps for OpenStack-specific allocation failures |
| `openstack-storage-provisioning.md` | CSI/NFS volume provisioning on OpenStack Nomad clusters |
| `rserve-horizontal-scaling.md` | Rserve multi-replica design and constraints |
| `rserve-multi-replica.md` | Multi-replica Rserve routing (load balancing when `rserve_count > 1`) |
| `autoscaling-storage-ramp-policy.md` | Ramp guardrails and iowait threshold gates for worker scale-out |
| `swift-artifact-backend.md` | Swift container ACL setup and env var reference |
| `traefik-openstack-decision.md` | Decision record: use Octavia LBaaS instead of Traefik in production OpenStack |
| `scale-program-summary.md` | Summary of Epic #352 scale-to-max program (13 sub-issues, PRs #366–#378) |
| `storage-benchmark-methodology.md` | Methodology behind `scripts/benchmark-storage-saturation.sh` |
| `openstack-remaining-issues-plan.md` | Current OpenStack stabilization state and recovery plan |
| `adr-001-storage-architecture.md` | Architecture decision record: storage backend selection |
| `worker-local-scratch.md` | Per-worker ephemeral scratch volume pattern |

### Local dev environment

`docker/docker-compose.yaml` runs Consul and Nomad as Docker containers with `network_mode: host` so task containers share the host network. The Makefile wraps all common operations:

```bash
make up           # Start Consul + Nomad (macOS: runs Consul natively via brew; Linux: Docker)
make deploy       # Deploy pack with examples/quickstart/minimal-dev.hcl
make open         # Open http://localhost:<web_port> in browser
make down         # Stop jobs + remove containers + volumes
make restart      # Full restart (clean infra: down + up)
make status       # Show job/node/service status via API
make web          # Tail web task alloc logs
make logs         # Tail Nomad agent logs (Docker only)
make logs-consul  # Tail Consul agent logs (or /tmp/consul-dev.log on macOS)
make redeploy     # stop + deploy
make stop         # Stop and purge all OpenStudio Server jobs
make ps           # Show running containers
make check        # Verify prerequisites (docker, nomad-pack, nomad on macOS)
```

**macOS caveat:** `make up` runs Consul natively (`consul agent -dev`) because Docker Desktop host networking cannot expose container ports to the Mac loopback reliably. Nomad is also run natively on macOS using `docker/nomad-macos.hcl`. The `make up` target will auto-stop Homebrew-managed MongoDB (`27017`) and Redis (`6379`) if they are running to avoid port conflicts.

One-command alternative:
```bash
bash scripts/quickstart.sh            # start infra + deploy + verify
bash scripts/quickstart.sh --teardown # stop + clean
bash scripts/quickstart.sh --status   # show status
```

### Pre-deploy storage preflight

Before deploying to any cluster with `host_volume` or `csi` storage, validate volumes are present:

```bash
# Validates that all required volumes (from the var-file) exist on ready/eligible nodes
./scripts/preflight-storage.sh --var-file examples/advanced/openstack.hcl

# Auto-create missing CSI volumes (requires a healthy CSI plugin)
./scripts/preflight-storage.sh --var-file examples/advanced/openstack-production.hcl \
  --create-missing-csi --csi-plugin-id nfs
```

The script reads `db_storage_type`, `redis_storage_type`, and `nfs_shared_volume_enabled` from the var-file and verifies: CSI plugin health (controller count ≥ 1), volume registration, and host volume advertisement by ≥ 1 ready/eligible node.

### OpenStack cluster operations

The Makefile has a full `os-*` target set for the NREL aurora-179d OpenStack deployment:

```bash
make os-run        # full bootstrap + deploy (Consul → infra-setup → pack)
make os-bootstrap  # configure all Nomad clients only (no pack deploy)
make os-deploy     # deploy pack only (after bootstrap)
make os-status     # show job/node/service status
make os-ui         # open SSH tunnels + launch Nomad/Consul UIs in browser
make os-tunnel     # open SSH tunnels only (foreground)
make os-stop       # stop pack jobs
make os-teardown   # stop pack + infra-setup system job
make os-logs       # tail web job logs (override: make os-logs JOB=worker)
make os-redeploy   # stop + redeploy the pack
```

The OpenStack staged rollout uses four worker-ramp stages (canary: 2 workers → ramp-25: 5 → ramp-50: 10 → full: 20+). Each stage requires a 30–120 min soak and explicit gate criteria before advancing. See `docs/infrastructure/openstack-staged-rollout-runbook.md`.

### Airgapped image mirroring

For air-gapped clusters (no internet access), mirror all referenced images to an internal Pulp registry before deploying:

```bash
PULP_REGISTRY=pulp-dev.example.com \
PULP_PROJECT=pulp-container-project \
PULP_USERNAME=user PULP_PASSWORD=pass \
bash scripts/mirror-images-to-pulp.sh --var-file examples/advanced/airgapped.hcl

# Force re-push even if destination tag exists
bash scripts/mirror-images-to-pulp.sh --force --var-file examples/advanced/airgapped.hcl
```

The script reads image variables from the var-file, pulls each from Docker Hub, retags to `<PULP_REGISTRY>/<PULP_PROJECT>/<image>`, and pushes. Use with `airgapped.hcl` which overrides all image variables to point at the internal registry.

### Operational troubleshooting scripts

```bash
# Detect and optionally delete stale resque:analysis:*:queuing Redis locks
# (locks with no TTL idle for > 120s that block job dispatch)
./scripts/clear-stale-queuing-locks.sh --dry-run              # preview only
./scripts/clear-stale-queuing-locks.sh --max-age 300          # custom idle threshold
./scripts/clear-stale-queuing-locks.sh --nomad-addr http://... # target cluster

# Detect data points stuck in "started" state (hung EnergyPlus processes holding
# Resque worker slots with no updated_at progress for longer than --max-stall seconds)
./scripts/detect-stalled-datapoints.sh --dry-run                     # report only
./scripts/detect-stalled-datapoints.sh --max-stall 3600              # 60-min threshold (default)
./scripts/detect-stalled-datapoints.sh --restart-allocs              # detect + auto-restart worker allocs
./scripts/detect-stalled-datapoints.sh \
  --max-stall 3600 --restart-allocs \
  --nomad-addr http://10.60.126.125:4646 \
  --web-url http://10.60.126.125                                      # full production invocation

# Attach a persistent Docker volume to a running allocation (storage rescue)
./scripts/attach-docker-volume.sh

# Bootstrap a fresh Nomad client node (179d OpenStack)
./scripts/bootstrap-179d-node.sh

# Fix Consul agent failures across all nodes
./scripts/fix-consul-all-nodes.sh

# Full OpenStack deploy (SSH tunnel + Consul bootstrap + Nomad client infra + pack)
./scripts/deploy-openstack.sh

# Tear down and redeploy fresh on OpenStack (useful after storage/config changes)
./scripts/fresh-redeploy-openstack.sh

# Idempotent OpenStack storage provisioning (CSI volumes + NFS host volumes)
./scripts/provision-openstack-storage.sh

# Deploy hostpath CSI node/controller role plugins (required before CSI volumes work)
./scripts/deploy-hostpath-csi-role-plugins.sh

# Apply all Nomad ACL policies (substitutes namespace, then applies)
bash scripts/apply-acl-policies.sh --namespace default
bash scripts/apply-acl-policies.sh --dry-run  # preview only
```

`clear-stale-queuing-locks.sh` exits `0` (no stale keys), `1` (error), or `2` (stale keys found in `--dry-run` mode — useful as an alert gate in CI or cron).

`detect-stalled-datapoints.sh` exits `0` (no stalled DPs), `1` (error), or `2` (stalled DPs found). It detects data points stuck in `started` status with no `updated_at` progress — a distinct failure mode from queuing locks where EnergyPlus hangs silently without crashing Resque. Run with `--restart-allocs` to auto-recover. Recommended cron schedule: every 15 minutes with `--max-stall 3600`. Without `--restart-allocs`, exit code `2` is suitable as a PagerDuty/alert gate.

### Worker local scratch

When `worker_local_scratch_enabled = true`, each worker allocation gets a node-local `ephemeral_disk` (default `10240` MB = 10 GiB) accessible at `worker_scratch_path` (`/scratch` by default, maps to `${NOMAD_ALLOC_DIR}/scratch`). This prevents NFS write amplification: intermediate simulation files go to local disk; only final artifacts are written to shared NFS.

**Application responsibility:** the OpenStudio Server app must detect `WORKER_SCRATCH_PATH`, run the simulation within it, and **copy final artifacts to shared NFS before the task exits**. If the app exits without copying, results are lost — the pack does not migrate scratch data automatically.

Key variables: `worker_local_scratch_enabled`, `worker_local_scratch_size` (MB), `worker_local_scratch_sticky` (when `true`, Nomad tries to reschedule onto the same node to reuse data — useful for resuming interrupted runs).

### Rserve horizontal scaling

`rserve_count` can be set above `1` to handle high-concurrency R call load, but **multi-replica-safe connection-level load balancing is not yet implemented** (tracked in issue **#361**). Keep `rserve_count = 1` until #361 is merged. Each Rserve replica runs a single-threaded R session — parallelism comes from replica count, not threads within a replica. Use `rserve_spreads` to distribute replicas across nodes when scaling.

### Swift object-storage artifact backend

`swift_artifact_storage_enabled = true` injects OpenStack Swift credentials and `ARTIFACT_STORAGE_BACKEND=swift` into web and worker tasks, routing artifact I/O through the Swift API instead of NFS. **The application binary must have Swift support compiled in** — this pack only injects env vars.

| Scenario | Backend |
|---|---|
| Single-node dev / CI | NFS (default) |
| Multi-node, artifacts must survive rescheduling | Swift |
| Large result files (> 1 GB per run) | Swift |
| Air-gapped / on-prem OpenStack | Swift |

Required variables: `swift_auth_url`, `swift_username`, `swift_password`, `swift_tenant_name`, `swift_container`, `swift_region`. See `docs/infrastructure/swift-artifact-backend.md` for Swift container ACL setup.

### Storage-aware autoscaling ramp policy

Rapid worker scale-out can cause **storage shock** — NFS I/O saturation from many new workers simultaneously opening simulation files. Symptoms: `iowait` > 40% on NFS client nodes, simulation slowdown, Redis/MongoDB health check timeouts, spurious scale-down by the autoscaler health deadline.

Prevent storage shock by setting conservative `autoscaling_cooldown` and per-evaluation worker add limits in the autoscaler policy. See `docs/infrastructure/autoscaling-storage-ramp-policy.md` for the recommended ramp guardrails and iowait threshold gates.

### NFS volume setup (`examples/volumes/`)

`examples/volumes/openstudio-shared-host-volume.hcl` contains the 3-step reference configuration for NFS shared volume setup:

1. **`/etc/fstab`** — mount the NFS export on every eligible Nomad client (`nfsvers=4,sync,hard,intr`)
2. **`client.hcl`** stanza — register a `host_volume "openstudio-nfs"` pointing at the mount path
3. **Pack override snippet** — `nfs_shared_volume_enabled = true`, `nfs_volume_source = "openstudio-nfs"`, `nfs_volume_mount_path = "/mnt/openstudio"`

### Traefik on jump host (`docs/infrastructure/infra/traefik-jump-host.md`)

For the NREL aurora-179d OpenStack cluster, Traefik v2.11.2 runs as a **systemd service on the jump host** (`10.60.126.125`), not as a Nomad job. It uses the Consul Catalog provider (`exposedByDefault: false`) to discover services and route external HTTP traffic. OpenStudio Server UI: `http://10.60.126.125/`; Traefik dashboard: `http://10.60.126.125:8080/dashboard/`.

### Additional CI test scripts

Beyond the main integration test, CI runs several focused shell scripts:

| Script | What it checks |
|---|---|
| `scripts/test_bump_metadata_version.sh` | Version bump helper using `tests/fixtures/metadata.sample.hcl` as isolated fixture |
| `scripts/test_backup_restore_docs_defaults.sh` | `backup_enabled`/`restore_enabled` defaults in `variables.hcl` match documented defaults in README + AGENTS.md |
| `scripts/test_migration_doc_variable_mapping.sh` | `docs/infrastructure/migration-k8s-to-nomad.md` references `worker_min_replicas`/`worker_max_replicas` (not the removed `worker_autoscaling_min/max`) |
| `scripts/test_pre_teardown.sh` | `pre-teardown.sh` stop order using a mock `nomad` binary in `tests/fixtures/mockbin-pre-teardown/` |
| `scripts/test_release_version_bump_workflow.sh` | `release-version-bump.yml` workflow contains the required registry sync step |

Run any single test directly: `./scripts/test_bump_metadata_version.sh`, `./scripts/test_migration_doc_variable_mapping.sh`, etc.

## Related configs

- `AGENTS.md` — canonical reference with full architecture details
- `README.md`, `CONTRIBUTING.md`

## Scale-to-max performance program (Epic #352)

The scale-to-max epic addressed three bottlenecks for high-concurrency OpenStack deployments across 13 sub-issues (PRs #366–#378). Understanding these helps explain why certain defaults are set the way they are.

### Three bottlenecks addressed

1. **Shared storage collapse** — NFS/Ceph IOPS saturation under concurrent worker writes → solved by worker local-scratch, Swift artifact backend, and storage-aware autoscaling ramp policy
2. **Rserve singleton bottleneck** — single Rserve serializes all R analysis calls → `rserve_count` variable added; multi-replica routing (issue #361 / PR #371) still open
3. **Traefik ingress limits** — default timeouts and body-size limits reject large uploads → tuning variables added; production OpenStack uses Octavia LBaaS instead (see below)

### Variables changed by the scale program

| Variable | New default | Previous | Why |
|---|---|---|---|
| `worker_min_replicas` | `0` | `2` | Enables scale-to-zero when queue is empty |
| `autoscaler_cooldown` | `10m` | `60m` | Faster idle reclaim after queue drains |
| `traefik_request_timeout` | (tunable) | — | New; handles long simulation-enqueue requests (2–5 min) |
| `traefik_max_request_body_size` | (tunable) | — | New; analysis ZIPs up to ~500 MB |
| `redis_config_tcp_keepalive` | `60` | — | Prevents NAT/firewall from dropping idle Resque connections |
| `redis_memory_max` | `0` (no cap) | — | Allows Redis to burst during mass-enqueue |
| `web_mongoid_pool_size` | `10` | — | MongoDB connection pool for web task |

### Traefik go/no-go for OpenStack production

**Decision (`docs/infrastructure/traefik-openstack-decision.md`):** set `deploy_traefik = false` for production OpenStack. Use **OpenStack Octavia LBaaS** instead — it terminates TLS via NREL PKI/Barbican, supports HA ACTIVE/STANDBY amphoras, and handles large payloads and long-running connections at the LB layer without touching the Nomad cluster. The in-pack Traefik job is for development/single-node only.

### Recommended OpenStack deployment sequence

1. **Storage preflight** — `scripts/preflight-storage.sh --var-file examples/advanced/openstack-production.hcl`
2. **NFS tuning** — apply mount options from `docs/infrastructure/nfs-tuning-guide.md` (`rsize/wsize=1048576`, `async`)
3. **Storage benchmark** — `scripts/benchmark-storage-saturation.sh --tier 250/500/1000/2000` to find safe worker ceiling; set `worker_autoscaling_max` to the tier below first saturation
4. **Autoscaling ramp** — `worker_min_replicas = 0`, `autoscaler_cooldown = "10m"`, conservative ramp rate per `docs/infrastructure/autoscaling-storage-ramp-policy.md`
5. **Worker local-scratch** — enable `worker_local_scratch_enabled = true` and validate artifact publish behavior with a test analysis
6. **Swift backend** (if available) — `swift_artifact_storage_enabled = true` to eliminate shared-storage write pressure entirely
7. **Staged rollout** — follow `docs/infrastructure/openstack-staged-rollout-runbook.md` (5→10→20→max workers, gate criteria: p95 latency < 30s, iowait < 20%, queue lag < 2×, failure rate < 2%)

### Known application-level limitations (cannot be fixed in the pack)

- **`web_count > 1`** — requires distributed locking (Redlock) or object-storage artifact backend in the upstream app
- **`rserve_count > 1`** — requires multi-replica R dispatch in the app (PR #371, not yet merged)
- **Swift native integration** — requires Swift SDK usage in the app; the pack only injects env vars
- **Queue-depth Prometheus autoscaling** — requires the app to expose Prometheus queue metrics; until then only `worker_autoscaling_cpu_enabled` works

## Storage saturation benchmark

`scripts/benchmark-storage-saturation.sh` quantifies the NFS worker-count ceiling before production deployment. Run on a Nomad **client node** with the NFS share mounted.

```bash
# Run each tier sequentially (allow 60s cooldown between tiers)
for TIER in 250 500 1000 2000; do
  ./scripts/benchmark-storage-saturation.sh \
    --tier "$TIER" --nfs-mount /mnt/openstudio \
    --duration 300 --output-dir benchmark-results
  sleep 60
done

# Analyze results and identify first saturation tier
./scripts/benchmark-storage-saturation.sh --analyze --output-dir benchmark-results
```

**Saturation thresholds** (any one triggers `YES ⚠`):

| Metric | Saturated when |
|---|---|
| `iowait%` | > 40% |
| `nfs_retrans` | > 0 (any retransmission) |
| `nfs_rtt_ms` (fio clat proxy) | > 20 ms |
| `write_bw_MB/s` vs tier-250 baseline | < 25% |

**Prerequisites:** `fio ≥ 3.x`, `sysstat`, `nfs-common`/`nfs-utils`, `jq`, `vmstat`. Results written to `benchmark-results/tier-<N>/summary.json`. Set `worker_autoscaling_max` to the tier **below** first saturation. Document the result in your var-file as a comment for future reference.
