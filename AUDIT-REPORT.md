# OpenStudio Server Nomad Pack — Codebase & Docs Audit Report

**Date:** 2026-08-02 · **Branch:** `develop` (HEAD `214683f`) · **Pack version:** `0.2.67` / app `3.11.0`
**Toolchain verified against:** `nomad-pack` v0.4.2, `nomad` v2.0.4
**Scope:** all 18 templates in `templates/` + `outputs.tpl`, `variables.hcl`, `docs/*`, `AGENTS.md`, `.github/workflows/*`, `scripts/*.sh`, `examples/*`

---

## 1. Critical Bugs

### 1.1 Queue-sweeper renders an invalid `REDIS_URL` (undefined `redis_port`)
- **File:** `templates/queue-sweeper.nomad.tpl:102`
- **Evidence:** `REDIS_URL = "redis://openstudio-redis.service.consul:[[ var "redis_port" . ]]"` — `redis_port` is **not defined** in `variables.hcl` (0 matches confirmed). Render with `enable_queue_sweeper=true` yields:
  `REDIS_URL = "redis://openstudio-redis.service.consul:"` (empty port).
- **Impact:** With `enable_queue_sweeper=true` (the queue sweeper feature), the sweeper's Redis connection is guaranteed to fail. Every other service uses `web_redis_url` (a defined variable) — the sweeper is the only one that hand-builds the URL with a nonexistent var.
- **Fix:** Use `web_redis_url` like `worker.nomad.tpl:237` / `nomad-batch-worker.nomad.tpl:70`, or add a `redis_port` variable and reference `redis_static_port` when nonzero.

### 1.2 Vault role variables are dead — `vault_enabled=true` renders empty `vault {}` blocks
- **Files:** `templates/worker.nomad.tpl:183-187`, `web.nomad.tpl:135-138`/`498-501`, `db.nomad.tpl:48-58`, `redis/rserve` equivalents; rendered output lines 43, 319, 494, 999, 1238, 1448.
- **Evidence:** `vault_db_role`, `vault_redis_role`, `vault_rserve_role`, `vault_default_role`, `aws_batch_vault_aws_role` have **0 template references**. Rendering with `vault_enabled=true` produces exactly **6 empty `vault {}` blocks** and **0 `role =` lines** (grep on rendered output).
- **Doc contradiction:** `docs/infrastructure/vault-policies.md:155-190` shows expected `vault { role = "openstudio-web" ... }` blocks; line 198 documents `vault_enabled` as "Whether to render explicit role-based `vault` blocks" — neither is implemented.
- **Impact:** `vault_enabled=true` silently produces role-less Vault blocks (token-less tasks), which Nomad accepts but which will fail at Vault auth time. The documented role-based Vault integration is unimplemented.
- **Fix:** Wire `vault_<service>_role` / `vault_default_role` into the `vault { role = ... }` blocks, or remove the role vars + fix the docs.

### 1.3 `nomad-pack fmt` is both broken AND the CI gate is a silent no-op
- **The formatter corrupts templates (v0.4.2 lexer bug):**
  - `nomad-pack fmt -write templates/` rewrites the comment-header workaround `[[- /*` → `[[-/*` in **3 files**: `worker.nomad.tpl`, `rserve.nomad.tpl`, `nomad-batch-worker.nomad.tpl`.
  - After formatting, `nomad-pack render .` fails: `template: openstudio-server/templates/nomad-batch-worker.nomad.tpl:1: illegal number syntax: "-"`.
  - **Reproduced end-to-end** on a sandbox copy: render OK before fmt, fails after fmt. Root repo untouched.
- **The CI gate never checks anything:**
  - `.github/workflows/pack-validation.yml:24` runs `nomad-pack fmt -check -recursive .`.
  - Verified on v0.4.2: `fmt -check -recursive .` prints `No formattable files (.tpl,.hcl) found` and **exits 0** — even though `fmt --check templates/` exits 1 with `! Some files are not formatted`.
  - Root cause: v0.4.2 recursive discovery does not descend into `templates/` from the pack root, so the gate always passes.
- **Impact:** CI silently never validates template formatting; a developer "fixing" the gate by running `fmt -write` would break rendering entirely.
- **Fix:** Pin a fixed nomad-pack version in CI; change the gate to `nomad-pack fmt -check templates/` (verified exit 1 on unformatted); add a render-after-fmt CI step to catch the lexer regression.

### 1.4 Flag-order incompatibility with nomad-pack v0.4.2
- **Evidence:** Go stdlib flags require flags **before** the positional pack path.
  - `nomad-pack render . -var-file X` → **FAILS** ("Flags must be specified before positional arguments").
  - `nomad-pack render -var-file X .` → OK. `render . --var k=v` → OK.
- **Docs/commands with wrong order:** `README.md:62` (`nomad-pack run . -var-file my-deployment.hcl`), `docs/modelers/quickstart.md:54`, `AGENTS.md:26-28` (`nomad-pack plan . --name X -var-file Y`).
- **OK in scripts:** `deploy-openstack.sh:503`, `fresh-redeploy-openstack.sh:601`, `quickstart.sh:136` (flags-first).
- **Fix:** Update README/quickstart/AGENTS.md examples to flags-first form.

---

## 2. Stale / Incorrect Documentation

### 2.1 AGENTS.md template table is missing 4 templates
- **File:** `AGENTS.md:91-102` — lists 12 templates; repo has **16** `.nomad.tpl` files.
- **Missing:** `traefik.nomad.tpl` (gated by `deploy_traefik`, default false), `prometheus.nomad.tpl` (`prometheus_enabled`), `queue-sweeper.nomad.tpl` (`enable_queue_sweeper`), `nomad-batch-worker.nomad.tpl` (`batch_engine == "nomad_batch"`).
- **Impact:** Operators reading AGENTS.md don't know these components exist; default render (7 jobs) is correct but the table is incomplete.

### 2.2 AGENTS.md deep-dive docs table: 7 of 9 paths are wrong
- **File:** `AGENTS.md:283-295`.
- **Actual locations:** `docs/modelers/getting-started-single-node.md`, `docs/infrastructure/{operations-guide,storage,upgrading,migration-k8s-to-nomad,vault-policies,acl-policies}.md`.
- **Listed but nonexistent:** `docs/getting-started-single-node.md`, `docs/operations-guide.md`, `docs/storage.md`, `docs/upgrading.md`, `docs/migration-k8s-to-nomad.md`, `docs/vault-policies.md`, `docs/acl-policies.md`.
- **Only correct:** `docs/compatibility.md`, `docs/variables.md`.

### 2.3 Nomad Pack minimum version is stale (0.1.2 → needs ≥0.4.x)
- **File:** `docs/modelers/getting-started-single-node.md:47, 108, 133` — documents nomad-pack **0.1.2** (`nomad-pack version # nomad-pack v0.1.x`).
- **Reality:** 0.1.2 uses the v1 parser; this pack's `[[ ]]` template syntax requires v0.4.x. The repo already documents v0.4.2-compatible CLI usage elsewhere.

### 2.4 14 dead variables documented as live
- **Defined in `variables.hcl` but referenced in 0 templates** (verified against all 18 templates + outputs.tpl): `autoscaler_cooldown`, `aws_batch_vault_aws_role`, `db_csi_plugin_id`, `redis_csi_plugin_id`, `vault_default_role`, `vault_db_role`, `vault_redis_role`, `vault_rserve_role`, `web_background_autoscaling_cpu_enabled`, `web_background_autoscaling_enabled`, `web_background_count`, `web_background_cpu_target_utilization`, `web_background_max_replicas`, `web_background_min_replicas`.
- **Still consumed by:** `docs/variables.md` (generated), `scripts/deploy-openstack.sh:449-458,714,770,780,788`, `scripts/fresh-redeploy-openstack.sh:127-197`, `scripts/preflight-storage.sh:71-173`, `examples/advanced/openstack.hcl:108,366`, `examples/advanced/openstack-production.hcl:59,64,136-141`, `examples/advanced/production-ha.hcl:30,34-36,52`.
- **Note:** the other 6 `web_background_*` vars **are** live (`web_background_image` at `system-hooks.nomad.tpl:168`/`web.nomad.tpl:551`; `web_background_worker_count/_queues/_mongoid_pool_size/_cpu/_memory` at `web.nomad.tpl:504-509`) — do not remove those.
- **Impact:** `docs/variables.md` advertises knobs that do nothing (silent misconfiguration risk); scripts assert on `web_background_count` (e.g. deploy-openstack.sh forces `count=1`) even though templates ignore it.

### 2.5 `deployment_marker` hardcoded to a specific environment
- **Files:** `web.nomad.tpl:8`, `redis.nomad.tpl:10`, `rserve.nomad.tpl:18`, `db.nomad.tpl:10` — all hardcode `deployment_marker = "openstack-aurora-179d"` instead of reading a variable.
- **Impact:** Every deployment on any cluster is labelled as the openstack-aurora-179d environment; label is cosmetic today but will mislead once multiple deployments coexist.

### 2.6 Compatibility matrix notes reference CI Nomad version inconsistently
- **File:** `docs/compatibility.md` — `0.2.41` row notes "CI uses Nomad 1.7.7"; `0.2.67` row also mentions "CI uses Nomad 1.7.7". The CI workflow file (`integration-test.yml` `NOMAD_VERSION`) is the source of truth; the compatibility table duplicates operational detail that drifts.

---

## 3. Minor / Formatting Issues

### 3.1 `[[- /*` header workaround (3 templates)
- `worker.nomad.tpl`, `rserve.nomad.tpl`, `nomad-batch-worker.nomad.tpl` line 1 use `[[- /*` (space between `-` and `/*`) — a workaround for the nomad-pack v0.4.2 lexer bug that rejects `[[-/*`. **Do not "fix" these to `[[-/*`** — that breaks rendering (see §1.3). The workaround is functional; flag it in code comments so nobody "normalizes" it.

### 3.2 Formatting drift (368-line diff)
- `nomad-pack fmt` produces a ~368-line diff across the templates on a sandbox copy (header workarounds + alignment). The repo templates are intentionally unformatted relative to the tool's style. This is fine **as long as** the CI gate stays a no-op or is re-scoped to `templates/` — see §1.3 for the interaction.

### 3.3 Private mirror image URLs hardcoded in examples
- `examples/advanced/openstack-production.hcl:29-31` and `scripts/attach-docker-volume.sh` reference `pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/...` — an environment-specific mirror. Should be parameterized or documented as an internal example.

### 3.4 `outputs.tpl` lowercase text causes false-positive undef
- `outputs.tpl` contains the literal text `enable_batch_verification=true` (batch-verification note). The dead-var checker must exclude it (it's prose, not a var reference). Cosmetic; keep the exclusion rule documented.

---

## Appendix: Verification Method

- **Static:** `grep -n` / `rtk grep` across all templates, scripts, examples, workflows, docs; Python cross-check of every `[[ var "..." ]]` reference vs `variables.hcl` definitions.
- **Dynamic:** `nomad-pack render .` (default → 7 jobs), render with `enable_queue_sweeper=true` / `vault_enabled=true` / `enable_batch_verification=true`; `nomad-pack plan` against live cluster (fails only on Job Conflict Validation — existing deployment); `nomad-pack fmt` matrix (`--check templates/` exit 1, `-check -recursive .` exit 0, `-write` corrupts headers); sandbox copy for all destructive fmt experiments (root repo clean, `git status` clean at HEAD `214683f`).
- **Scripts:** `bash -n` on all `scripts/*.sh` (pass); `scripts/generate-vars-doc.sh` zero-diff; `test_backup_restore_docs_defaults.sh` + `test_migration_doc_variable_mapping.sh` pass; `variables.md` in sync with `variables.hcl`.
