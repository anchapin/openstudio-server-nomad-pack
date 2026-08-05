# Copilot Instructions

Keep this file aligned with `AGENTS.md`, `README.md`, and `CONTRIBUTING.md`.

## What this repository is

A [Nomad Pack](https://developer.hashicorp.com/nomad/tutorials/nomad-pack/nomad-pack-intro) that deploys the full [OpenStudio Server](https://github.com/NREL/openstudio-server) stack (web, web-background, worker, MongoDB, Redis, Rserve) to a HashiCorp Nomad cluster. It is a lighter-weight alternative to the project's Kubernetes Helm chart. Service discovery uses Consul; HTTP ingress is handled by Traefik (optional); secrets management uses Vault (optional); log collection uses Vector sidecars (enabled by default).

The pack root for all pack commands is `packs/openstudio-server/`.

---

## Build, test, and lint commands

```bash
# Format-check pack templates (non-destructive)
# NOTE: On nomad-pack v0.4.2, `fmt -write packs/openstudio-server/templates/` can corrupt templates
# and `fmt --check -recursive .` is a silent no-op from the pack root.
nomad-pack fmt --check packs/openstudio-server/templates/

# Render templates to stdout and inspect output
nomad-pack render packs/openstudio-server
nomad-pack render -var-file examples/quickstart/minimal-dev.hcl packs/openstudio-server
nomad-pack render -var "enable_batch_verification=true" packs/openstudio-server

# Plan (dry-run) against a running Nomad dev agent
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan --name openstudio-server packs/openstudio-server
nomad-pack plan --name openstudio-server-minimal-dev -var-file examples/quickstart/minimal-dev.hcl packs/openstudio-server
nomad-pack plan --name openstudio-server-production-ha -var-file examples/advanced/production-ha.hcl packs/openstudio-server
nomad-pack plan --name openstudio-server-airgapped -var-file examples/advanced/airgapped.hcl packs/openstudio-server

# Run the integration test script (render + plan across key scenarios)
bash scripts/test_nomad_pack_integration.sh

# Lint rendered /bin/sh scripts embedded in Nomad templates
./scripts/lint-posix-shell.sh packs/openstudio-server

# Warn on shell parameter expansion patterns that Nomad HCL heredocs can parse
./scripts/check-nomad-heredoc-interpolation.sh

# Single focused tests (fast iteration)
./scripts/test_pre_teardown.sh
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

# Regenerate variable docs after editing variables.hcl (required before committing)
./scripts/generate-vars-doc.sh

# Check docs/variables.md sync (non-destructive)
./scripts/generate-vars-doc.sh docs/variables.generated.md
diff docs/variables.md docs/variables.generated.md

# Common local lifecycle shortcuts (Makefile wrappers)
make up
make deploy
make status
make down

# OpenStack helper wrappers
make os-bootstrap
make os-deploy
make os-status
make os-logs JOB=web
make os-teardown
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

Each Nomad job is a separate `.nomad.tpl` file under `packs/openstudio-server/templates/`. The pack renders all of them together via `nomad-pack render`:

| Template | Nomad job rendered | Conditional |
|---|---|---|
| `openstudio-server.nomad.tpl` | Architecture marker file (intentionally renders no job) | always |
| `web.nomad.tpl` | `<job_name>-web` (task groups: `web`, `web-background`) | always |
| `worker.nomad.tpl` | `<job_name>-worker` | `batch_engine = "internal"` (default) |
| `db.nomad.tpl` | `<job_name>-db` (MongoDB) | always |
| `redis.nomad.tpl` | `<job_name>-redis` | always |
| `rserve.nomad.tpl` | `<job_name>-rserve` | always |
| `system-hooks.nomad.tpl` | `<job_name>-system-hooks` (image pre-pull) | `enable_image_prepull = true` (default) |
| `nomad-autoscaler.nomad.tpl` | autoscaler daemon job | `nomad_autoscaler_enabled = true` |
| `batch-verification.nomad.tpl` | `<job_name>-batch-verify` | `enable_batch_verification = true` |
| `traefik.nomad.tpl` | Traefik ingress job | `deploy_traefik = true` |
| `prometheus.nomad.tpl` | `<job_name>-prometheus` (Prometheus + redis_exporter sidecar) | `prometheus_enabled = true` |
| `queue-health-alert.nomad.tpl` | `<job_name>-queue-health-alert` | `enable_queue_health_alert = true` (default) |
| `queue-sweeper.nomad.tpl` | `<job_name>-queue-sweeper` (task groups: `queue-sweeper`, `stall-watchdog`) | `enable_queue_sweeper` or `enable_stall_watchdog` |
| `stall-watchdog.nomad.tpl` | Architecture marker file (consolidated into `queue-sweeper.nomad.tpl`) | `enable_stall_watchdog = true` |
| `nomad-batch-worker.nomad.tpl` | `<job_name>-nomad-batch-worker` | `batch_engine == "nomad_batch"` |
| `state-backup.nomad.tpl` | `<job_name>-state-backup` (periodic batch) | `backup_enabled = false` (default) |
| `state-restore.nomad.tpl` | `<job_name>-state-restore` (on-demand batch) | `restore_enabled = false` (default) |
| `infra-setup.nomad.tpl` | `<job_name>-infra-setup` (system job for client config) | `enable_infra_setup = false` (default) |
| `openstudio_test.nomad.tpl` | `<job_name>-test` (parameterized batch) | always |

`packs/openstudio-server/templates/_helpers.tpl` defines reusable named templates:

| Helper | Usage |
|---|---|
| `constraints` | Iterates a list of constraint objects |
| `affinities` | Iterates a list of affinity objects |
| `spreads` | Iterates a list of spread objects |
| `openstudio_server.compute_node_constraint` | Shorthand for `compute_node_class` variable |
| `openstudio_server.system_node_constraint` | Shorthand for `system_node_class` variable |
| `openstudio_server.arch_constraint` | Hard constraint: `kernel.name = linux`, `cpu.arch = amd64` |
| `openstudio_server.node_affinity` | Soft affinity with configurable weight |

### Template syntax

Nomad Pack templates use Go template syntax with **`[[` / `]]`** delimiters (not `{{` / `}}`).

- Read a variable: `[[ var "variable_name" . ]]`
- Conditional block: `[[ if var "vault_enabled" . ]] ... [[ end ]]`
- Pass root context to named templates: `[[ template "openstudio_server.arch_constraint" . ]]`
- Pass a constructed dict: `[[ template "openstudio_server.node_affinity" (dict "attribute" "..." "value" "..." "weight" 100) ]]`
- JSON-encode a list variable: `[[ var "datacenters" . | toJson ]]`

### Shell compatibility and heredoc interpolation pitfalls

Many runtime scripts execute under **POSIX `/bin/sh`** inside containers. Do **not** use bash-only syntax (arrays, `read -d`) in template heredocs.

Avoid `${VAR:-default}`, `${VAR:=default}`, and similar `${...:...}` shell parameter expansions inside Nomad `data = <<-EOT` heredocs — Nomad's HCL parser consumes `${...}` before `/bin/sh` runs it.

```hcl
# BAD
data = <<-EOT
timeout="${WORKER_TIMEOUT:-30}"
EOT

# GOOD
data = <<-EOT
timeout="$WORKER_TIMEOUT"
if [ -z "$timeout" ]; then timeout=30; fi
EOT
```

**POSIX character classes** like `[[:space:]]`, `[[:alpha:]]`, `[[:digit:]]` contain `[[` — the Nomad Pack template delimiter — and will cause a pack parse error anywhere in a `.nomad.tpl` file. Use `[ \t]`, `[a-zA-Z]`, `[0-9]` instead.

Always run these guardrail scripts before pushing:

```bash
./scripts/lint-posix-shell.sh packs/openstudio-server
./scripts/check-nomad-heredoc-interpolation.sh
```

### Prestart / lifecycle task pattern

All job templates use a consistent task lifecycle:

1. **`wait-for-deps`** (`prestart`, not sidecar): polls Consul health API using `wget`; fails fast if dependencies don't come up
2. **Main task**: the actual service container
3. **`vector`** sidecar (`prestart`, sidecar = true): collects allocation logs; enabled by default via `enable_vector_collection = true`
4. **`cleanup-poststop`** (`poststop`): `rm -rf` paths listed in `poststop_cleanup_paths`

### Docker hardening defaults

| Variable | Default | Effect |
|---|---|---|
| `docker_user` | `"1000:1000"` | Run containers as non-root |
| `docker_readonly_rootfs` | `true` | Read-only root filesystem |
| `docker_cap_drop` | `["ALL"]` | Drop all Linux capabilities |

MongoDB and Redis run as UID/GID `999:999` by default (`db_docker_user`, `redis_docker_user`).

### Job priority

`web_priority` (default `80`) must always be **greater than** `worker_priority` (default `40`). Inverting them causes the scheduler to evict the web UI during resource contention.

### web_count constraint

`web_count` **must remain 1**. The web process writes uploaded analysis artefacts to local container filesystem with no distributed file-locking. Running multiple web replicas causes split-brain.

### Storage backends

MongoDB and Redis each support three storage modes via `*_storage_type`:

| Value | Volume type | Use case |
|---|---|---|
| `host_volume` | Nomad host volume (bind-mount) | Single-node dev, small clusters |
| `csi` | Nomad CSI volume | Multi-node clusters where allocations reschedule |
| `ephemeral` | No volume declared | CI environments, throwaway dev |

**NFS shared volume** (for web + worker): enabled via `nfs_shared_volume_enabled = true`. NFS alone does **not** provide distributed file locking.

### Consul service discovery

Consul service names registered by this pack:

| Consul service name | Component |
|---|---|
| `openstudio-db` | MongoDB |
| `openstudio-redis` | Redis |
| `openstudio-rserve` | Rserve |
| `openstudio-web` | Web (HTTP on `web_port`) |

Worker startup aliasing (`db`, `queue`, `rserve`, `web`) must stay **Consul-native**. Prefer Nomad template rendering (`{{ range service "..." }}`) for worker `/etc/hosts` patching. Never switch worker startup back to `getent hosts` for Consul-only services — this requires the client node's OS resolver to be configured to forward `.consul` queries to Consul.

Optional **Consul Connect** mTLS sidecar proxies are enabled via `enable_consul_connect = true`.

### Image pre-pull system job

`system-hooks.nomad.tpl` renders a Nomad **system job** (`type = "system"`) that runs on every eligible Docker-enabled node. It pre-pulls all heavy service images using prestart tasks, then keeps a `sleep infinity` sentinel task alive to prevent Docker from evicting the cached layers. Controlled by `enable_image_prepull` (default `true`) and `prepull_kill_timeout` (default `600s`, must be ≥ 10 minutes).

### Worker autoscaling

When `worker_autoscaling_enabled = true`, the worker job gains a `scaling` block with two built-in check strategies:

1. **CPU utilization** (`nomad-apm` source, `avg_cpu` query): `worker_autoscaling_cpu_enabled = true`. Target set by `worker_cpu_target_utilization` (default `50`). Requires no external metrics stack.
2. **Queue depth** (`prometheus` source): uses `worker_queue_requeued_query` / `worker_queue_simulations_query`. Requires Prometheus at `autoscaler_prometheus_address`.

The Nomad Autoscaler daemon must be deployed separately (`nomad_autoscaler_enabled = true`). **`worker_kill_timeout`** (default `5200s`) must be ≥ the longest expected simulation run time — reducing it causes data loss on drains and rolling updates.

### Backup and restore jobs

- `state-backup.nomad.tpl`: **periodic batch job** running `mongodump` + `redis-cli BGSAVE` on schedule `backup_cron` (default `0 2 * * * *`). Rotates files older than `backup_retention_days` (default `14`). Disabled by default (`backup_enabled = false`).
- `state-restore.nomad.tpl`: **on-demand parameterized batch job**, dispatched manually. Disabled by default (`restore_enabled = false`).

### Batch verification job

`batch-verification.nomad.tpl` (enabled by `enable_batch_verification = true`) uses `busybox` to ping and `nc` TCP-connect each service in `verification_targets`. Structured log output: `batch_verification_result component=... status=pass|fail` and `batch_verification_summary total=... passed=... failed=...`.

### Traefik ingress

The web service registers Consul tags for Traefik's Consul Catalog provider. Set `ingress_domain` to the desired hostname. Enable `ingress_tls_enabled = true` to add `websecure` entrypoint tags. Traefik must be deployed separately and configured to watch the Consul catalog.

### Post-deploy output template

`packs/openstudio-server/outputs.tpl` is rendered by `nomad-pack run` on successful deployment — it prints Consul service UI URLs and the Traefik web URL. When adding a new exposed service, add its Consul URL here too.

### Deep-dive docs

| File | Content |
|---|---|
| `docs/modelers/getting-started-single-node.md` | Step-by-step single-node deploy guide |
| `docs/infrastructure/operations-guide.md` | Day-2 operations: scaling, draining, updating |
| `docs/infrastructure/storage.md` | Host volume, CSI, NFS configuration detail |
| `docs/infrastructure/upgrading.md` | Version upgrade procedures |
| `docs/infrastructure/migration-k8s-to-nomad.md` | Helm → Nomad Pack migration guide |
| `docs/infrastructure/vault-policies.md` | Vault policy templates and setup |
| `docs/infrastructure/acl-policies.md` | Nomad ACL policy reference |
| `docs/compatibility.md` | Pack ↔ app version compatibility matrix |
| `docs/variables.md` | Auto-generated variable reference (do not edit manually) |

### Vault integration

Two independent Vault integration mechanisms (both default `false`):

| Variable | Mechanism |
|---|---|
| `vault_integration_enabled` | Injects KV v2 secrets as env vars via `template` stanza. Vault template stanzas use `{{ with secret "..." }}` syntax (standard Go templates, **not** `[[ ]]` delimiters). |
| `vault_enabled` | Adds role-based `vault { role = "..." }` blocks to tasks. |

### Kubernetes→Nomad concept mapping

| Kubernetes / Helm concept | Nomad Pack equivalent |
|---|---|
| `values.yaml` | `packs/openstudio-server/variables.hcl` |
| Deployment / Pod | Job → Task Group → Task (docker driver) |
| Service | `service` stanza (registers in Consul) |
| ConfigMap / Secret | `template` stanza (static, Consul KV, or Vault) |
| HPA / KEDA ScaledObject | Nomad Autoscaler + `scaling` block in worker job |
| PodDisruptionBudget | `update` stanza with `max_parallel`, `health_check`, `auto_revert` |
| DaemonSet | Nomad system job (`type = "system"`) |
| StorageClass / PVC | `volume` stanza + CSI plugin or `host_volume` |
| PriorityClass (high/low) | Job-level `priority` (web=80 > worker=40) |
| Ingress | Traefik via Consul service tags |

---

## Key conventions

### Branches, commits, and PRs

- All PRs target `develop`; `main` is release-only.
- Branch names follow `feat/issue-<N>-...` and `fix/issue-<N>-...`.
- Never push directly to `main` or `develop`.
- Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `ci:`).
- Every PR adds a `[Unreleased]` entry in `CHANGELOG.md` with PR reference (past tense, one line).

### Release flow

1. Move all `[Unreleased]` entries in `CHANGELOG.md` to a new versioned section.
2. Add a new row to `docs/compatibility.md` for the **upcoming** patch version — CI enforces this for PRs targeting `main`.
3. PR `develop` → `main`, merge when CI passes.
4. Two workflows run automatically:
   - **`release-version-bump.yml`**: bumps `packs/openstudio-server/metadata.hcl`, commits, pushes `v*` tag.
   - **`release.yml`**: publishes GitHub Release from that tag.

For non-patch increments, run `scripts/bump_metadata_version.sh packs/openstudio-server/metadata.hcl minor` (or specify explicit version) before opening the PR.

### Variables and docs source of truth

- `packs/openstudio-server/variables.hcl` is the source of truth for pack inputs.
- `docs/variables.md` is **auto-generated** by `./scripts/generate-vars-doc.sh` — never edit it manually.
- After editing `variables.hcl`, run `./scripts/generate-vars-doc.sh` and commit both files together. CI diffs them and fails if out of sync.

### ACL policies

`policies/` contains five HCL files (`operator.hcl`, `readonly.hcl`, `cicd.hcl`, `teardown.hcl`, `batch-dispatcher.hcl`). All must pass `nomad fmt -check policies/` — enforced by `acl-policy-validation.yml`.

### Example var-files

| File | Purpose |
|---|---|
| `examples/quickstart/minimal-dev.hcl` | Single-node, ephemeral storage, no Vault/autoscaling — CI baseline |
| `examples/advanced/production-ha.hcl` | Multi-datacenter, HA, Vault, Consul Connect, autoscaling |
| `examples/advanced/airgapped.hcl` | Private registry image overrides, journald logging, no Vault |
| `examples/advanced/e2e-test.hcl` | End-to-end test configuration |

Use these as starting points when writing new var-files.

### Vagrant local cluster

`Vagrantfile` + `vagrant/provision/` scripts spin up a 4-VM micro-cluster for local end-to-end testing:

| VM | IP | Runs |
|---|---|---|
| `consul` | `192.168.56.10` | Consul server + UI |
| `nomad-server` | `192.168.56.11` | Nomad server |
| `nomad-client` | `192.168.56.12` | Nomad client with Docker |
| `vault` | `192.168.56.13` | Vault dev mode (token: `root`) |

Smoke checks:
```bash
vagrant ssh consul -c "consul members"
vagrant ssh nomad-server -c "nomad server members"
vagrant ssh nomad-client -c "nomad node status"
vagrant ssh vault -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault status"
```

### Scheduler placement helpers

Per-group constraints, affinities, and spreads are list-of-object variables (e.g. `db_constraints`, `worker_affinities`, `redis_spreads`). Each object has `attribute`, optional `operator`, `value`, and optional `weight` fields, passed to helper templates in `_helpers.tpl`.

Node class targeting uses `openstudio_server.compute_node_constraint` (driven by `compute_node_class`, default `"compute"`) and `openstudio_server.system_node_constraint` (driven by `system_node_class`, default `"system"`).

### Image/version alignment

When bumping the OpenStudio Server version, update all four image variables together:
- `web_image`, `web_background_image`, `worker_image` → `nrel/openstudio-server:<version>`
- `rserve_image` → `nrel/openstudio-rserve:<version>`

### CI workflow overview

| Workflow | Trigger | What it checks |
|---|---|---|
| `pack-validation.yml` | push/PR to `develop` or `main` | fmt, render, plan (multiple var-files), job spec validation, script syntax, `variables.md` diff, compatibility version gate |
| `acl-policy-validation.yml` | push/PR on `policies/**` changes | `nomad fmt -check policies/` |
| `integration-test.yml` | PR to `develop` (path-filtered) | template render + e2e stack test |
| `release-version-bump.yml` | push to `main` | Auto-bumps `metadata.hcl`, creates `v*` tag |
| `release.yml` | push of `v*` tag | Publishes GitHub Release |

