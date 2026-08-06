# Agent Instructions — openstudio-server-nomad-pack

## What this repo is

A **Nomad Pack** deploying the full **OpenStudio Server** stack (web, web-background, worker, MongoDB, Redis, Rserve) to HashiCorp Nomad. Lighter-weight alternative to the Kubernetes Helm chart. Service discovery via Consul; optional Traefik ingress, Vault secrets, Vector log sidecars (enabled by default).

**Pack path:** Always use `packs/openstudio-server/` for `nomad-pack` commands.

---

## Critical Commands

```bash
# Format-check (non-destructive — --write CORRUPTS templates on v0.4.2)
nomad-pack fmt --check packs/openstudio-server/templates/

# Render & inspect
nomad-pack render packs/openstudio-server
nomad-pack render -var-file examples/quickstart/minimal-dev.hcl packs/openstudio-server

# Plan (dry-run) — requires running Nomad dev agent
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan --name openstudio-server packs/openstudio-server

# Lint POSIX shell in templates (run before pushing)
./scripts/lint-posix-shell.sh packs/openstudio-server
./scripts/check-nomad-heredoc-interpolation.sh

# Regenerate variable docs after editing variables.hcl (required before commit)
./scripts/generate-vars-doc.sh

# Run CI locally (requires act + Docker)
act push -W .github/workflows/pack-validation.yml

# Quick local lifecycle (Makefile wrappers)
make up && make deploy && make status && make down
```

---

## Architecture Essentials

### Service Topology
```
web ──► redis, mongodb, rserve, worker
worker ──► redis, mongodb
```
Each component = separate Nomad job (`<job_name>-web`, `-worker`, `-db`, `-redis`, `-rserve`). Consul DNS (`.service.consul`) for discovery.

### Template Layout (packs/openstudio-server/templates/)
| Template | Job | Conditional |
|---|---|---|
| `web.nomad.tpl` | `<job_name>-web` (groups: web, web-background) | always |
| `worker.nomad.tpl` | `<job_name>-worker` | `batch_engine = "internal"` |
| `db.nomad.tpl` | `<job_name>-db` (MongoDB) | always |
| `redis.nomad.tpl` | `<job_name>-redis` | always |
| `rserve.nomad.tpl` | `<job_name>-rserve` | always |
| `system-hooks.nomad.tpl` | `<job_name>-system-hooks` (image pre-pull) | `enable_image_prepull = true` |
| `queue-sweeper.nomad.tpl` | `<job_name>-queue-sweeper` (groups: queue-sweeper, stall-watchdog) | `enable_queue_sweeper` or `enable_stall_watchdog` |
| `state-backup.nomad.tpl` | `<job_name>-state-backup` (periodic batch) | `backup_enabled = false` |
| `state-restore.nomad.tpl` | `<job_name>-state-restore` (on-demand batch) | `restore_enabled = false` |

**Key helpers in `_helpers.tpl`**: `constraints`, `affinities`, `spreads`, `node_class_constraint`, `wait_for_deps_task` (web), `worker_preflight_task`, `vector_task`, `cleanup_poststop_task`, `vault_block`, `restart_block`, `update_block` (canary-capable).

### Template Syntax
- **Delimiters: `[[` / `]]`** (not `{{` / `}}`)
- `[[ var "name" . ]]` — read variable
- `[[ if var "flag" . ]]...[[ end ]]` — conditional
- `[[ template "helper_name" . ]]` — call helper with root context
- `[[ template "helper_name" (dict "key" "val") ]]` — call with dict

---

## Pitfalls Agents Miss

### 1. POSIX `/bin/sh` Only in Templates
Runtime scripts run under `/bin/sh`, **not bash**. No arrays, no `read -d`, no `${VAR:-default}` in heredocs.

```sh
# BAD
targets=("db" "queue")
timeout="${WORKER_TIMEOUT:-30}"

# GOOD
targets="db
queue"
printf '%s\n' "$targets" | while IFS= read -r target; do :; done
timeout="$WORKER_TIMEOUT"
if [ -z "$timeout" ]; then timeout=30; fi
```

### 2. POSIX Character Classes = Parse Errors
`[[:space:]]`, `[[:alpha:]]`, `[[:digit:]]` contain `[[` — triggers pack parser.
```sh
# BAD
sed 's/[[:space:]]//g'

# GOOD
sed 's/[ \t]//g'
sed 's/[a-zA-Z]//g'
sed 's/[0-9]//g'
```

### 3. Consul-Native Discovery Only
Worker startup aliases (`db`, `queue`, `rserve`, `web`) **must** use Consul Template watches (host-side). Never `getent hosts` inside containers — `127.0.0.1` is container loopback, not host Consul.

```hcl
update_alias db '{{ with service "openstudio-db" }}{{ (index . 0).Address }}{{ end }}'
```

### 4. `web_count` Must Stay 1
Web writes artefacts to local filesystem (`/mnt/openstudio`) with no distributed locking. Multiple replicas = split-brain. Requires upstream app changes (Redlock or S3) to safely increase.

### 5. Job Priority Invariant
`web_priority` (80) > `worker_priority` (40) **always**. Inversion causes web eviction under contention.

### 6. Vault Template Delimiters
Vault `template` stanzas use **standard Go `{{ }}`**, not pack `[[ ]]`.

### 7. CSI Topology Pin Required
For `csi` storage, set `db_csi_topology_node_id` / `redis_csi_topology_node_id` to pin allocation to volume owner node. Without this, reschedule fails: `csi_hook failed … does not exist in volumes list`.

### 8. Queue-Sweeper + Stall-Watchdog Cron Must Match
When both enabled, `queue_sweeper_cron == stall_watchdog_cron` enforced at render time via `[[ fail ]]`.

---

## Variable Flow

- **Source of truth:** `packs/openstudio-server/variables.hcl`
- **Auto-generated:** `docs/variables.md` via `./scripts/generate-vars-doc.sh`
- **Never edit** `docs/variables.md` manually — CI diff-fails on drift
- **Commit both** `variables.hcl` and `docs/variables.md` together

---

## Storage Backends (MongoDB/Redis)

| Mode | Volume Type | Use Case |
|---|---|---|
| `host_volume` (default) | Nomad host volume (bind-mount) | Single-node dev, small clusters |
| `csi` | Nomad CSI volume | Multi-node, rescheduling |
| `ephemeral` | No volume | CI, throwaway |

- Volume names: `openstudio-mongodb` (mounts `/data/db`), `openstudio-redis` (mounts `/data`)
- DB/Redis run as UID/GID `999:999` (configurable via `db_docker_user`, `redis_docker_user`)
- Global `docker_user` default `1000:1000` applies to web, worker, rserve

---

## Docker Hardening Defaults (Overridable)
| Variable | Default | Effect |
|---|---|---|
| `docker_user` | `"1000:1000"` | Non-root |
| `docker_readonly_rootfs` | `true` | Read-only rootfs |
| `docker_cap_drop` | `["ALL"]` | Drop all capabilities |

---

## Worker Autoscaling Prerequisites

1. **Nomad Autoscaler daemon must be deployed first** (separate pack) — silent ignore otherwise
2. CPU check uses `nomad-apm` (no Prometheus needed), enabled via `worker_autoscaling_cpu_enabled = true`
3. Queue-depth check requires Prometheus at `autoscaler_prometheus_address`
4. `worker_kill_timeout` (default `5200s`) ≥ longest simulation run time — reducing causes data loss on drains/updates

---

## Backup/Restore Jobs

- **Backup:** Periodic batch (`state-backup.nomad.tpl`), cron `backup_cron` (default `0 2 * * * *`), rotates after `backup_retention_days` (14). Disabled by default (`backup_enabled = false`).
- **Restore:** On-demand parameterized batch (`state-restore.nomad.tpl`). Disabled by default (`restore_enabled = false`).
- Enable backup **only after** provisioning/validating backup volume. Enable restore **only** with validated runbooks.

---

## Key Conventions

| Rule | Detail |
|---|---|
| **Branch target** | All PRs → `develop`; `main` is release-only |
| **Branch naming** | `feat/issue-<N>-...` or `fix/issue-<N>-...` |
| **Commits** | Conventional: `feat:`, `fix:`, `docs:`, `chore:`, `ci:` |
| **Changelog** | Every PR adds entry under `[Unreleased]` (past tense, one line, `(#N)`) |
| **Local overrides** | `user-overrides.hcl`, `*.override.hcl` are gitignored — never commit |
| **Release** | `develop` → `main` PR triggers 2-step auto-release (version bump + tag + GitHub Release) |
| **Image bump** | Update all 4 images together: `web_image`, `web_background_image`, `worker_image` → `nrel/openstudio-server:<version>`, `rserve_image` → `nrel/openstudio-rserve:<version>` |

---

## CI Workflows (Must Pass)

| Workflow | Trigger | Key Checks |
|---|---|---|
| `pack-validation.yml` | push/PR to `develop`/`main` | fmt, render, render-matrix (12 scenarios), POSIX shell lint, heredoc scan, DNS guardrails, job spec validate, plan dry-runs |
| `acl-policy-validation.yml` | push/PR on `policies/**` | `nomad fmt -check policies/` |
| `integration-test.yml` | PR to `develop` (path-filtered) | Terratest render/plan + live e2e stack test |
| `release-version-bump.yml` | push to `main` | Auto-bump patch version, commit, push `v*` tag |
| `release.yml` | push `v*` tag | Publish GitHub Release |

---

## Operational Scripts (Manual, Live Cluster)

```bash
./scripts/pre-teardown.sh [--namespace <ns>] [JOB_NAME]   # Stop jobs in safe order
./scripts/run-batch-verification.sh                        # Ping/TCP check all services
./scripts/drain-workers.sh [--dry-run]                     # Batch drain worker allocations
./scripts/verify-prepull.sh                                # Confirm pre-pull sentinel on all nodes
./scripts/requeue-stuck-datapoints.sh [--dry-run]          # Staggered re-enqueue stuck datapoints
./scripts/check-csi-topology.sh                            # Detect CSI topology pin drift
```

---

## Reference Docs

| File | Purpose |
|---|---|
| `docs/modelers/getting-started-single-node.md` | Single-node deploy guide |
| `docs/infrastructure/operations-guide.md` | Day-2 ops: scaling, draining, updating |
| `docs/infrastructure/storage.md` | Host volume, CSI, NFS detail |
| `docs/infrastructure/vault-policies.md` | Vault policy templates/setup |
| `docs/infrastructure/acl-policies.md` | Nomad ACL policy reference |
| `docs/compatibility.md` | Pack ↔ app version matrix |
| `docs/variables.md` | Auto-generated variable reference |

---

## Example Var-Files (Starting Points)

| File | Use Case |
|---|---|
| `examples/quickstart/minimal-dev.hcl` | Single-node, ephemeral, minimal resources, no Vault/autoscaling |
| `examples/advanced/production-ha.hcl` | Multi-DC, HA, Vault, Consul Connect, autoscaling |
| `examples/advanced/airgapped.hcl` | Private registry, journald logging, no Vault |
| `examples/advanced/e2e-test.hcl` | End-to-end test config |

---

## Vagrant Local Cluster (4 VMs)

```bash
vagrant up  # consul(10), nomad-server(11), nomad-client(12), vault(13)
# Smoke checks:
vagrant ssh consul -c "consul members"
vagrant ssh nomad-server -c "nomad server members"
vagrant ssh nomad-client -c "nomad node status"
vagrant ssh vault -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault status"
```