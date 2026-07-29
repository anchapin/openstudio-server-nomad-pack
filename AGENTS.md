# Agent Instructions

## What this repository is

A [Nomad Pack](https://developer.hashicorp.com/nomad/tutorials/nomad-pack/nomad-pack-intro) that deploys the full [OpenStudio Server](https://github.com/NREL/openstudio-server) stack (web, web-background, worker, MongoDB, Redis, Rserve) to a HashiCorp Nomad cluster. It is a lighter-weight alternative to the project's Kubernetes Helm chart. Service discovery uses Consul; HTTP ingress is handled by Traefik (optional); secrets management uses Vault (optional); log collection uses Vector sidecars (enabled by default).

---

## Build / Test / Lint Commands

```bash
# Format-check all HCL files (non-destructive)
nomad-pack fmt --check .

# Render templates to stdout and inspect output
nomad-pack render .
nomad-pack render -var-file examples/minimal-dev.hcl .
nomad-pack render -var "enable_batch_verification=true" .

# Validate rendered job specs against a live Nomad cluster
nomad-pack validate .

# Plan (dry-run) against a running Nomad dev agent
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan . --name openstudio-server
nomad-pack plan . --name openstudio-server-minimal-dev -var-file examples/minimal-dev.hcl
nomad-pack plan . --name openstudio-server-production-ha -var-file examples/production-ha.hcl
nomad-pack plan . --name openstudio-server-airgapped -var-file examples/airgapped.hcl

# Run the integration test script (render + plan across key scenarios)
bash scripts/test_nomad_pack_integration.sh

# Render a specific scenario inline (e.g., verify a single template change)
nomad-pack render . -var "enable_vector_collection=false"
nomad-pack render . -var "web_image=nrel/openstudio-server:3.8.0"

# Test the version-bump helper in isolation
# Uses tests/fixtures/metadata.sample.hcl as an isolated test fixture
./scripts/test_bump_metadata_version.sh

# Check that docs/variables.md is up-to-date with variables.hcl
./scripts/generate-vars-doc.sh docs/variables.generated.md
diff docs/variables.md docs/variables.generated.md

# Regenerate docs/variables.md after editing variables.hcl (required before committing)
./scripts/generate-vars-doc.sh

# Check backup/restore default docs stay aligned with variables.hcl
./scripts/test_backup_restore_docs_defaults.sh

# Operational helpers (not part of CI — run manually against a live cluster)
# Stop all jobs in teardown-safe order before destroying volumes/NFS
./scripts/pre-teardown.sh [--namespace <ns>] [JOB_NAME]
# Run the batch verification job to ping/TCP-check all services
./scripts/run-batch-verification.sh

# Validate ACL policy HCL formatting
nomad fmt -check policies/

# Validate provisioning scripts (bash syntax only)
for script in vagrant/provision/*.sh; do bash -n "$script"; done

# Run all CI workflows locally (requires act + Docker)
act push -W .github/workflows/pack-validation.yml
act push
```

---

## Architecture

### Service topology

```
web ──► redis
web ──► mongodb
web ──► rserve
web ──► worker
worker ──► redis
worker ──► mongodb
```

Each component is a **separate Nomad job** (`<job_name>-web`, `<job_name>-worker`, `<job_name>-db`, `<job_name>-redis`, `<job_name>-rserve`). Consul is used for service discovery between jobs — components resolve each other via `.service.consul` DNS names.

### Template layout

Each Nomad job is a separate `.nomad.tpl` file under `templates/`. The pack renders all of them together via `nomad-pack render`:

| Template | Nomad job rendered | Conditional |
|---|---|---|
| `openstudio-server.nomad.tpl` | Architecture marker file (intentionally renders no job) | always |
| `web.nomad.tpl` | `<job_name>-web` | always |
| `worker.nomad.tpl` | `<job_name>-worker` | always |
| `db.nomad.tpl` | `<job_name>-db` (MongoDB) | always |
| `redis.nomad.tpl` | `<job_name>-redis` | always |
| `rserve.nomad.tpl` | `<job_name>-rserve` | always |
| `system-hooks.nomad.tpl` | `<job_name>-system-hooks` (image pre-pull) | `enable_image_prepull = true` (default) |
| `nomad-autoscaler.nomad.tpl` | autoscaler daemon job | `nomad_autoscaler_enabled = true` |
| `batch-verification.nomad.tpl` | `<job_name>-batch-verify` | `enable_batch_verification = true` |
| `state-backup.nomad.tpl` | `<job_name>-state-backup` (periodic batch) | `backup_enabled = false` (default) |
| `state-restore.nomad.tpl` | `<job_name>-state-restore` (on-demand batch) | `restore_enabled = false` (default) |
| `openstudio_test.nomad.tpl` | `<job_name>-test` (parameterized batch) | always |

`templates/_helpers.tpl` defines reusable named templates called throughout all job templates:

| Helper | Usage |
|---|---|
| `constraints` | Iterates a list of constraint objects |
| `affinities` | Iterates a list of affinity objects |
| `spreads` | Iterates a list of spread objects |
| `openstudio_server.node_class_constraint` | Hard constraint on `${attr.nomad.node.class}` |
| `openstudio_server.compute_node_constraint` | Shorthand for `compute_node_class` variable |
| `openstudio_server.system_node_constraint` | Shorthand for `system_node_class` variable |
| `openstudio_server.arch_constraint` | Hard constraint: `os.name = linux`, `cpu.arch = amd64` |
| `openstudio_server.node_affinity` | Soft affinity with configurable weight |

### Template syntax

Nomad Pack templates use Go template syntax with **`[[` / `]]`** delimiters (not `{{` / `}}`). Standard Go template constructs (`if`, `range`, `define`, `template`) all use these square-bracket delimiters.

- Read a variable: `[[ var "variable_name" . ]]`
- Conditional block: `[[ if var "vault_enabled" . ]] ... [[ end ]]`
- Pass root context to named templates: `[[ template "openstudio_server.arch_constraint" . ]]`
- Pass a constructed dict: `[[ template "openstudio_server.node_affinity" (dict "attribute" "..." "value" "..." "weight" 100) ]]`
- JSON-encode a list variable: `[[ var "datacenters" . | toJson ]]`

### Variable flow

All user-facing variables are defined in `variables.hcl` (root level). `packs/openstudio-server/variables.hcl` is a registry-aligned mirror — keep both files in sync when adding or changing variables.

`docs/variables.md` is **auto-generated** by `scripts/generate-vars-doc.sh` (a Python script that parses `variables.hcl`). CI enforces this with a diff check. Never edit `docs/variables.md` manually.

### Registry vs. root pack

Two pack layouts coexist:
- **Root** (`templates/`, `variables.hcl`, `metadata.hcl`, `outputs.tpl`): used for direct `nomad-pack run .` invocations.
- **Registry** (`packs/openstudio-server/`): registry-aligned layout for Nomad Pack Registry publication. Keep templates and variables in sync with root.

### Consul service discovery

Consul service names registered by this pack:

| Consul service name | Component |
|---|---|
| `openstudio-db` | MongoDB |
| `openstudio-redis` | Redis |
| `openstudio-rserve` | Rserve |
| `openstudio-web` | Web (HTTP on `web_port`) |

Web and worker tasks include a `wait-for-deps` **prestart lifecycle task** (`busybox:1.36`) that polls the Consul health API before the main container starts. The web prestart task waits for `openstudio-db`, `openstudio-redis`, and `openstudio-rserve`; the worker prestart task waits for `openstudio-db` and `openstudio-redis`.

Optional **Consul Connect** mTLS sidecar proxies for all services are enabled via `enable_consul_connect = true`. When enabled, each service task gets a `sidecar_service` proxy block.

### Prestart / lifecycle task pattern

All job templates use a consistent task lifecycle pattern:

1. **`wait-for-deps`** (`prestart`, not sidecar): polls Consul health API using `wget`; fails fast if dependencies don't come up
2. **Main task**: the actual service container
3. **`vector`** sidecar (`prestart`, sidecar = true): collects allocation logs from `/alloc/logs/*.std*` and emits JSON to stdout; enabled by default via `enable_vector_collection = true`
4. **`cleanup-poststop`** (`poststop`): uses `alpine:3.20` to `rm -rf` paths listed in `poststop_cleanup_paths`

### Docker hardening defaults

Every task uses these security defaults (overridable via variables):

| Variable | Default | Effect |
|---|---|---|
| `docker_user` | `"1000:1000"` | Run containers as non-root |
| `docker_readonly_rootfs` | `true` | Read-only root filesystem |
| `docker_cap_drop` | `["ALL"]` | Drop all Linux capabilities |

### Job priority

`web_priority` (default `80`) must always be **greater than** `worker_priority` (default `40`). Inverting them causes the scheduler to evict the web UI during resource contention. This mirrors the Kubernetes Helm chart's `high-priority` (1,000,000) vs. `low-priority` (10,000) PriorityClass relationship.

### Image pre-pull system job

`system-hooks.nomad.tpl` renders a Nomad **system job** (`type = "system"`) that runs on every eligible Docker-enabled node. It pre-pulls all heavy service images using prestart tasks, then keeps a long-running `sleep infinity` sentinel task alive to prevent Docker from evicting the cached layers. Controlled by `enable_image_prepull` (default `true`) and `prepull_kill_timeout` (default `600s`, must be ≥ 10 minutes).

### Worker autoscaling

When `worker_autoscaling_enabled = true`, the worker job gains a `scaling` block with two built-in check strategies:

1. **CPU utilization** (`nomad-apm` source, `avg_cpu` query): enabled via `worker_autoscaling_cpu_enabled = true`. Target set by `worker_cpu_target_utilization` (default `50`). Requires no external metrics stack.
2. **Queue depth** (`prometheus` source): uses configurable Prometheus queries (`worker_queue_requeued_query`, `worker_queue_simulations_query`). Requires a running Prometheus instance at `autoscaler_prometheus_address`.

The Nomad Autoscaler daemon must be deployed separately before enabling autoscaling. The optional daemon stub is in `nomad-autoscaler.nomad.tpl`, enabled by `nomad_autoscaler_enabled = true`.

**`worker_kill_timeout`** (default `5200s`) must be ≥ the longest expected simulation run time. Reducing it below simulation duration causes data loss on node drains and rolling updates.

### web_count constraint

`web_count` **must remain 1**. The web process writes uploaded analysis artefacts to local container filesystem (under `/mnt/openstudio` when NFS is mounted) with no distributed file-locking. Running multiple web replicas causes split-brain: each allocation has an isolated filesystem view, so requests routed to replica B cannot find files written by replica A.

To safely run `web_count > 1`, one of the following must first be implemented in the upstream application:
- A distributed lock manager (e.g., Redlock via Redis) wrapping every filesystem operation, **or**
- Stateless file handling (all persistent artefacts moved to object storage such as S3/MinIO)

### Storage backends

MongoDB and Redis each support three storage modes set via `*_storage_type`:

| Value | Volume type | Use case |
|---|---|---|
| `host_volume` | Nomad host volume (bind-mount) | Single-node dev, small clusters |
| `csi` | Nomad CSI volume | Multi-node clusters where allocations reschedule |
| `ephemeral` | No volume declared | CI environments, throwaway dev |

Volume names default to `openstudio-mongodb` and `openstudio-redis`. MongoDB data mounts at `/data/db`; Redis data mounts at `/data`.

Volume ownership must be set before first deploy: MongoDB and Redis run as UID/GID `999:999` by default (configurable via `db_docker_user` and `redis_docker_user`). The global `docker_user` variable (default `1000:1000`) applies to web, worker, and rserve tasks.

**NFS shared volume** (for web + worker): enabled via `nfs_shared_volume_enabled = true`. Recommended approach is an OS-level NFS mount registered as a Nomad host volume, not a CSI NFS driver. NFS alone does **not** provide distributed file locking — it shares the filesystem but does not make `web_count > 1` safe.

### Backup and restore jobs

`state-backup.nomad.tpl` renders a **periodic batch job** (`type = "batch"` with a `periodic` stanza) that runs `mongodump` and `redis-cli BGSAVE` on the schedule defined by `backup_cron` (default: `0 2 * * * *`). Backups write to a backup state volume (`backup_volume_source`) and rotate files older than `backup_retention_days` (default `14`).

`state-restore.nomad.tpl` renders an **on-demand parameterized batch job** dispatched manually.

Both jobs are disabled by default (`backup_enabled = false`, `restore_enabled = false`). Enable backup only after provisioning and validating the backup volume; enable restore only in environments where operators need manual restore dispatch and have validated restore runbooks.

### Batch verification job

`batch-verification.nomad.tpl` renders a one-shot **batch job** (enabled by `enable_batch_verification = true`) that uses `busybox` to ping and `nc` TCP-connect each service in `verification_targets`. Output lines use the structured log format `batch_verification_result component=... status=pass|fail` and `batch_verification_summary total=... passed=... failed=...`.

### Vault integration

Two independent Vault integration mechanisms exist (both default `false`):

| Variable | Mechanism |
|---|---|
| `vault_integration_enabled` | Injects KV v2 secrets as env vars via `template` stanza + `secrets/env` file. Paths: `vault_kv_mongodb_path`, `vault_kv_redis_path`, `vault_kv_app_path`. Policy name: `vault_policy` (default `"openstudio-server"`). |
| `vault_enabled` | Adds role-based Vault `vault { role = "..." }` blocks to tasks. Uses per-task role overrides (`vault_db_role`, `vault_redis_role`, etc.) falling back to `vault_default_role`. |

Both can be active simultaneously for production deployments. When neither is enabled, credentials are supplied as plaintext variables (`mongo_password`, `redis_password`, `app_secret_key_base`).

Vault KV v2 secret paths follow the convention `secret/data/openstudio/<service>`. The Vault template stanza uses `{{ with secret "..." }}` syntax (standard Go templates, **not** `[[ ]]` delimiters).

### Traefik ingress

The web service registers Consul tags for Traefik's Consul Catalog provider. Set `ingress_domain` to the desired hostname. Enable `ingress_tls_enabled = true` to add `websecure` entrypoint tags. Traefik must be deployed separately and configured to watch the Consul catalog.

### Kubernetes→Nomad concept mapping

This pack is the Nomad equivalent of the `openstudio-server-helm` chart. When implementing features or debugging, use this mapping to find the Nomad analog of a Kubernetes concept:

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

**Worker rolling update (PDB equivalent):** The worker job uses an `update` stanza instead of a K8s PodDisruptionBudget:
```hcl
update {
  max_parallel     = 1
  health_check     = "checks"
  min_healthy_time = "10s"
  healthy_deadline = "5m"
  auto_revert      = true
}
```

**Queue-based autoscaling (KEDA equivalent):** KEDA on Kubernetes queries message brokers directly. On Nomad, the autoscaler reads from Prometheus (which scrapes the broker metrics). Prometheus must be running and scraping queue metrics before `worker_autoscaling_enabled = true` and the Prometheus check strategy can be used.

### Post-deploy output template

`outputs.tpl` is rendered by `nomad-pack run` on successful deployment. It prints Consul service UI URLs and the Traefik web URL. It uses `[[ ]]` delimiters like all other templates. If you add a new service, add its Consul URL here too.

### Deep-dive docs

`docs/` contains operator-facing reference material:

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

---

## Key Conventions

### Branch strategy

- All PRs target **`develop`**; `main` is release-only.
- Branch naming: `feat/issue-<N>-<short-description>` and `fix/issue-<N>-<short-description>`.
- Never push directly to `main` or `develop`.

### Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `chore:`, `ci:`.

### Changelog

Every PR adds an entry to `CHANGELOG.md` under `[Unreleased]` using [Keep a Changelog](https://keepachangelog.com/) format. Use past tense, one line per entry, with PR number reference (`(#N)`). Entries are consolidated into versioned sections during the release process.

### Variable documentation

After editing any variable in `variables.hcl`:
1. Run `./scripts/generate-vars-doc.sh` to regenerate `docs/variables.md`.
2. Commit both `variables.hcl` and `docs/variables.md` together.

CI fails if these files are out of sync (the `Check variables.md is up-to-date` workflow step performs a diff).

### Release process

1. Move all `[Unreleased]` entries in `CHANGELOG.md` to a new versioned section (e.g. `[0.3.0] - YYYY-MM-DD`).
2. Add a new row to `docs/compatibility.md` (pack version, `app_version`, min Nomad, min Consul) for the **upcoming release version** (`pack.version` + patch). CI enforces this: for pull requests targeting `main`, the `Check compatibility.md is up-to-date` step requires that upcoming release version to be present.
3. PR `develop` → `main`, merge when CI passes.
4. Two workflows run automatically after merging to `main`:
   - **Step 1 — `release-version-bump.yml`** (triggers on push to `main`): runs `scripts/bump_metadata_version.sh`, syncs `packs/openstudio-server/metadata.hcl`, commits both metadata files, and pushes a `v<version>` git tag.
   - **Step 2 — `release.yml`** (triggers on the `v*` tag push created in Step 1): reads the version from `metadata.hcl` and publishes the GitHub Release with auto-generated release notes.

   If Step 1 fails, check that the workflow has write permission to push to `main` and that `scripts/bump_metadata_version.sh` exits cleanly against the current `metadata.hcl`. If Step 2 fails (or is skipped), verify that the `v*` tag was actually pushed (check the repo's Tags page) and that the workflow has `contents: write` permission to create releases.

For a non-patch increment (minor/major), manually run `scripts/bump_metadata_version.sh` with the appropriate bump type or explicit version before opening the `develop → main` PR:

```bash
# Increment minor version (e.g. 0.2.0 → 0.3.0)
scripts/bump_metadata_version.sh metadata.hcl minor

# Set an explicit target version
scripts/bump_metadata_version.sh metadata.hcl 0.3.0
```

### ACL policies

`policies/` contains four HCL files:

| File | Role | Purpose |
|---|---|---|
| `operator.hcl` | Operator | Full deploy/stop/read — humans running `nomad-pack run/stop` |
| `readonly.hcl` | Read-only | Log visibility and status — monitoring dashboards |
| `cicd.hcl` | CI/CD service token | Minimal: render, plan, run, stop — automated pipelines |
| `teardown.hcl` | Teardown | Stop lifecycle access for cleanup without deploy or exec |

All policies default to the `default` namespace (matching the pack default `nomad_namespace`). Policy HCL must pass `nomad fmt -check policies/` — enforced by `acl-policy-validation.yml`.

### Example var-files

`examples/` contains ready-to-use override files:

| File | Purpose |
|---|---|
| `minimal-dev.hcl` | Single-node, ephemeral storage, minimal resources, no Vault/autoscaling |
| `production-ha.hcl` | Multi-datacenter, HA resources, Vault, Consul Connect, autoscaling |
| `airgapped.hcl` | Private registry image overrides, journald logging, no Vault |
| `e2e-test.hcl` | End-to-end test configuration |

Use these as starting points when writing new var-files. The `minimal-dev.hcl` pattern is also the baseline for CI plan validation.

### Vagrant local cluster

`Vagrantfile` + `vagrant/provision/` scripts spin up a 4-VM micro-cluster for local end-to-end testing:

| VM | IP | Runs |
|---|---|---|
| `consul` | `192.168.56.10` | Consul server + UI |
| `nomad-server` | `192.168.56.11` | Nomad server |
| `nomad-client` | `192.168.56.12` | Nomad client with Docker |
| `vault` | `192.168.56.13` | Vault dev mode (token: `root`) |

Smoke check commands:
```bash
vagrant ssh consul -c "consul members"
vagrant ssh nomad-server -c "nomad server members"
vagrant ssh nomad-client -c "nomad node status"
vagrant ssh vault -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault status"
```

### Image naming alignment

When bumping the OpenStudio Server version, update all four image variables together (they share the same version tag):
- `web_image` → `nrel/openstudio-server:<version>`
- `web_background_image` → `nrel/openstudio-server:<version>`
- `worker_image` → `nrel/openstudio-server:<version>`
- `rserve_image` → `nrel/openstudio-rserve:<version>`

`redis_image` defaults to `redis:6.2-alpine` (intentionally newer than the Helm chart's `redis:6.0.9`). Align Redis major.minor with the target OpenStudio Server release requirements before deploying.

### Scheduler placement helpers

Per-group constraints, affinities, and spreads are exposed as list-of-object variables (e.g. `db_constraints`, `worker_affinities`, `redis_spreads`). Each object has `attribute`, optional `operator`, `value`, and optional `weight` fields. These are passed to the `constraints`, `affinities`, and `spreads` helper templates in `_helpers.tpl`.

Node class targeting uses the named macros `openstudio_server.compute_node_constraint` and `openstudio_server.system_node_constraint`, driven by `compute_node_class` (default `"compute"`) and `system_node_class` (default `"system"`) variables.

### Registry sync

`packs/openstudio-server/` must mirror the root pack. CI enforces this with a 3-way check (metadata version, variable names, template file contents). To fix drift:

```bash
cp variables.hcl packs/openstudio-server/variables.hcl
cp metadata.hcl packs/openstudio-server/metadata.hcl
cp templates/*.tpl templates/*.nomad.tpl packs/openstudio-server/templates/
```

### CI workflow overview

| Workflow | Trigger | What it checks |
|---|---|---|
| `pack-validation.yml` | push to `develop` or `main`, PR to `develop` or `main`, `workflow_dispatch` | fmt, render, validate, `examples/test-batch.nomad` job spec validation, Vagrantfile syntax, script syntax, version-bump tests, `variables.md` diff, backup/restore default-doc consistency, README links to `docs/variables.md`, `compatibility.md` version gate, Nomad dev-agent plan for all example var-files, `packs/` registry sync, integration test script |
| `acl-policy-validation.yml` | push/PR to `develop` or `main` on `policies/**` or `scripts/apply-acl-policies.sh` changes | `nomad fmt -check policies/` |
| `integration-test.yml` | PR to `develop` (path-filtered) | template render + e2e stack test |
| `release-version-bump.yml` | push to `main` | **Step 1:** auto-bumps patch version in `metadata.hcl`, syncs `packs/openstudio-server/metadata.hcl`, commits both files, creates and pushes `v*` git tag — triggers `release.yml` |
| `release.yml` | push of tag matching `v*` | **Step 2:** reads version from `metadata.hcl`, publishes GitHub Release with auto-generated notes |
