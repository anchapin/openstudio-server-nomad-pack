# Copilot Instructions

Use [`AGENTS.md`](../AGENTS.md) as the canonical source of truth for repository guidance.  
This file is a concise working guide for Copilot sessions and should stay aligned with `AGENTS.md`, `README.md`, and `CONTRIBUTING.md`.

## Build, test, and lint commands

```bash
# Lint/format checks
nomad-pack fmt --check .
nomad fmt -check policies/
for script in vagrant/provision/*.sh; do bash -n "$script"; done

# Render and validate
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

# Tests
bash scripts/test_nomad_pack_integration.sh
./scripts/test_bump_metadata_version.sh

# Single test/scenario examples
nomad-pack render . -var "enable_vector_collection=false"
nomad-pack render . -var "web_image=nrel/openstudio-server:3.8.0"
./scripts/test_bump_metadata_version.sh

# Keep generated docs in sync after variable changes
./scripts/generate-vars-doc.sh
./scripts/generate-vars-doc.sh docs/variables.generated.md && diff docs/variables.md docs/variables.generated.md
```

## High-level architecture

- This repo is a **Nomad Pack** that deploys OpenStudio Server as **separate Nomad jobs** (`web`, `worker`, `db`, `redis`, `rserve`) plus optional jobs (`system-hooks`, `nomad-autoscaler`, `batch-verification`, `state-backup`, `state-restore`, `traefik`).
- Templates live in `templates/*.nomad.tpl` and are rendered together by `nomad-pack`. `templates/openstudio-server.nomad.tpl` is an architecture marker and intentionally renders no job.
- Two synchronized pack layouts exist:
  - root pack (`templates/`, `variables.hcl`, `metadata.hcl`, `outputs.tpl`) for direct `nomad-pack run .`
  - registry-aligned mirror under `packs/openstudio-server/` (must stay in sync with root)
- Service discovery is through **Consul** (`openstudio-db`, `openstudio-redis`, `openstudio-rserve`, `openstudio-web`), and `web`/`worker` use `wait-for-deps` prestart tasks before launching main containers.
- Shared template helpers in `templates/_helpers.tpl` generate repeated `constraint`, `affinity`, and `spread` blocks and node-class constraints.
- Most jobs follow a lifecycle pattern: `wait-for-deps` (prestart), main task, optional `vector` sidecar, `cleanup-poststop`.

## Key conventions

- **Template syntax** uses Nomad Pack `[[ ... ]]` delimiters (not `{{ ... }}`) for pack templates.
- **Do not edit `docs/variables.md` manually**; it is generated from `variables.hcl` via `./scripts/generate-vars-doc.sh`.
- Keep `variables.hcl`, `metadata.hcl`, and `templates/*` synchronized with `packs/openstudio-server/*` mirrors.
- `web_count` must remain `1` unless upstream file-handling/locking behavior changes.
- Keep `web_priority > worker_priority` to avoid evicting the web UI first under contention.
- Branch and release flow:
  - PRs target `develop`; `main` is release-only.
  - Use `feat/issue-<N>-*` / `fix/issue-<N>-*` branch naming and Conventional Commits.
  - Add changelog entries under `[Unreleased]` in `CHANGELOG.md`.
  - On release prep, move unreleased notes and add a matching `docs/compatibility.md` row for the pack version.

## Related assistant configs reviewed

- `AGENTS.md` (primary repository instruction set)
- `README.md`
- `CONTRIBUTING.md`
