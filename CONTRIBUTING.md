# Contributing

Thank you for contributing to **openstudio-server-nomad-pack**!
Please read this guide before opening a PR.

---

## Branch strategy

| Branch | Purpose |
|--------|---------|
| `develop` | Integration branch — **all PRs target `develop`** |
| `main` | Release-only — merged from `develop` when cutting a release |
| `fix/issue-<N>-*` | Bug-fix branches |
| `feat/issue-<N>-*` | Feature branches |

> Never push directly to `main` or `develop`.
> Open a PR against `develop` and let CI validate it first.

---

## Local testing

### Prerequisites

- [`nomad-pack`](https://developer.hashicorp.com/nomad/tutorials/nomad-pack/nomad-pack-intro) CLI installed
- [`act`](https://github.com/nektos/act) (optional, for running GitHub Actions locally)
- Docker (required by `act`)

### Pack validation

> ⚠️ **WARNING — `nomad-pack fmt` corruption risk:** Running `nomad-pack fmt -write packs/openstudio-server/templates/` (or `fmt --write`) on v0.4.2 has a known lexer bug that **silently corrupts template files** by mangling `[[- /* ... */]]` comment markers. Always use `--check` (read-only) and never `--write` or `-write` against this repository's templates.

```bash
# Format-check pack templates (non-destructive)
# NOTE: On nomad-pack v0.4.2, `fmt -write packs/openstudio-server/templates/` can corrupt templates
# and `fmt --check -recursive .` is a silent no-op from the pack root.
nomad-pack fmt --check packs/openstudio-server/templates/

# Render templates to stdout and inspect output
nomad-pack render packs/openstudio-server

# Render with an example var-file override
nomad-pack render -var-file examples/quickstart/minimal-dev.hcl packs/openstudio-server

# Plan against a running Nomad dev agent (replaces `nomad-pack validate` — not a valid command in v0.4.2)
nomad agent -dev -bind=127.0.0.1 -log-level=ERROR &
nomad-pack plan --name openstudio-server packs/openstudio-server
```

### Running CI locally with `act`

```bash
# Run the pack-validation workflow (simulates push to develop)
act push -W .github/workflows/pack-validation.yml

# Run the pack-validation workflow (simulates pull_request to develop or main)
act pull_request -W .github/workflows/pack-validation.yml

# Run all workflows triggered by push
act push
```

### Integration tests

```bash
# Run the Nomad Pack integration test script
bash scripts/test_nomad_pack_integration.sh

# Lint rendered /bin/sh scripts embedded in Nomad templates
./scripts/lint-posix-shell.sh packs/openstudio-server

# Warn on shell parameter expansion patterns that Nomad HCL heredocs can parse
./scripts/check-nomad-heredoc-interpolation.sh
```

---

## POSIX shell and Nomad heredoc pitfalls

Several runtime scripts in this repo execute under **POSIX `/bin/sh`**, not bash.
Treat shell embedded in Nomad templates the same way you would treat a standalone `#!/bin/sh` script.

### POSIX `/bin/sh` only

Avoid bash-only features in container/runtime scripts:

```sh
# BAD: bash array syntax
targets=("db" "queue")

# BAD: bash-only delimiter handling
read -r -d '' payload <<'EOF'
...
EOF

# GOOD: plain POSIX sh
targets="db
queue"
printf '%s\n' "$targets" | while IFS= read -r target; do
  :
done
```

Arithmetic expansion is fine only when values are guaranteed numeric. Validate first if a template variable can render empty:

```sh
# GOOD: default explicitly without ${var:-default} inside a Nomad heredoc
delay="$BASE_DELAY"
if [ -z "$delay" ]; then
  delay=1
fi
delay=$((delay * 2))
```

Run the local lint before opening a PR:

```bash
./scripts/lint-posix-shell.sh packs/openstudio-server
```

### Consul-native service discovery

For worker startup dependency aliases (`db`, `queue`, `rserve`, `web`), the authoritative source is **Consul-native discovery rendered by Nomad templates**.
Do **not** switch worker startup scripts to `getent hosts` for `openstudio-db`, `openstudio-redis`, or `openstudio-rserve` — those names live in Consul's service catalog and are only resolvable through the OS resolver when Consul DNS forwarding has been configured explicitly on the client node.

### Nomad HCL heredoc interpolation

Inside Nomad `data = <<-EOT` blocks, avoid shell parameter expansions such as `${VAR:-default}` and `${VAR:=default}`.
Nomad's HCL parser can interpret the `${...}` sequence before the shell ever runs.

```hcl
# BAD: parsed by HCL before /bin/sh sees it
template {
  data = <<-EOT
  timeout="${WORKER_TIMEOUT:-30}"
  EOT
}

# GOOD: keep the shell logic POSIX-safe and avoid ${...:...} in the heredoc
template {
  data = <<-EOT
  timeout="$WORKER_TIMEOUT"
  if [ -z "$timeout" ]; then
    timeout=30
  fi
  EOT
}
```

The CI warning is grep-based and intentionally non-blocking because template-like text can have false positives:

```bash
./scripts/check-nomad-heredoc-interpolation.sh
```

---

## PR process

1. Fork the repo (external contributors) or create a branch (maintainers).
2. Target **`develop`** — never `main`.
3. Use [Conventional Commits](https://www.conventionalcommits.org/) for every commit:
   - `feat:` new feature
   - `fix:` bug fix
   - `docs:` documentation only
   - `chore:` maintenance, dependency bumps
   - `ci:` CI/CD changes
4. Update `CHANGELOG.md` under the `[Unreleased]` section (see below).
5. If you changed any variable in `packs/openstudio-server/variables.hcl`, regenerate the variable docs (see below).
6. All required CI checks must pass before merge:
   - `pack-validation.yml` — format, render, plan (dry-run for multiple example var-files)
   - `acl-policy-validation.yml` — ACL policy lint
   - `integration-test.yml` — end-to-end stack test (triggered on PRs to `develop` that touch `packs/openstudio-server/templates/**`, `packs/openstudio-server/variables.hcl`, `packs/openstudio-server/metadata.hcl`, `scripts/**`, `examples/**`, or the workflow file itself)

---

## Changelog process

This project follows the [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**For every PR, add an entry to `CHANGELOG.md` under `[Unreleased]`:**

```markdown
## [Unreleased]

### Added
- Short description of new feature or file (#PR-number)

### Changed
- Short description of changed behaviour (#PR-number)

### Fixed
- Short description of bug fix (#PR-number)
```

Use past tense, keep each entry to one line, and reference the PR number.
Entries are consolidated into a versioned section by the release process.

---

## Release process

> **Branch promotion model:** all development merges into `develop`. When a release is ready, `develop` is merged into `main`. Only pushes to `main` trigger the two-step automated release pipeline (`release-version-bump.yml` → `release.yml`). Pushing to `develop` — including merged feature PRs — does **not** create a public release.

Releases are automated via a **two-step pipeline** triggered by a push to `main`:

1. **`release-version-bump.yml`** (Step 1): bumps the patch version in `packs/openstudio-server/metadata.hcl`, commits, and pushes a `v<version>` git tag.
2. **`release.yml`** (Step 2): triggered by the `v*` tag created in Step 1 and publishes the GitHub Release with auto-generated release notes.

To prepare a release:

1. Ensure all intended changes are merged into `develop` and CI is green.
2. Move all `[Unreleased]` entries in `CHANGELOG.md` to a new versioned section (e.g. `[0.3.0] - 2026-07-28`).
3. Update `docs/compatibility.md` with the **upcoming release version** (current `packs/openstudio-server/metadata.hcl` patch + 1) and its compatibility data.
4. Open a PR from `develop` → `main`, merge when CI passes.
5. After merging, the two-step release pipeline runs automatically:
   - **`release-version-bump.yml`** bumps the patch version in `packs/openstudio-server/metadata.hcl`, commits, and pushes a `v<version>` git tag.
   - **`release.yml`** picks up the new tag and publishes the GitHub Release.
   - _Triage:_ If Step 1 fails, check write permissions to `main` and that `scripts/bump_metadata_version.sh` runs cleanly. If Step 2 is missing, confirm the `v*` tag exists in the repo and that the workflow has `contents: write` permission.

> **Note:** For a non-patch increment (minor/major), manually run `scripts/bump_metadata_version.sh` with the appropriate bump type or explicit version before opening the `develop → main` PR:
> ```bash
> # Increment minor version (e.g. 0.2.0 → 0.3.0)
> scripts/bump_metadata_version.sh packs/openstudio-server/metadata.hcl minor
>
> # Set an explicit target version
> scripts/bump_metadata_version.sh packs/openstudio-server/metadata.hcl 0.3.0
> ```

---

## Regenerating `docs/variables.md`

`docs/variables.md` is auto-generated from `packs/openstudio-server/variables.hcl` — **do not edit it manually**.
`packs/openstudio-server/variables.hcl` is the **sole source of truth** for all pack variable definitions.

After changing any variable definition (adding, removing, or modifying any `variable "..."` block
in `packs/openstudio-server/variables.hcl`), regenerate the reference doc:

```bash
./scripts/generate-vars-doc.sh
```

Then commit both updated files (`packs/openstudio-server/variables.hcl` and `docs/variables.md`).

CI validates this with the `Check variables.md is up-to-date` workflow step,
which diffs the committed file against a freshly generated copy and fails on any divergence.

### README variable table

The README **does not** maintain a separate variable table.
The `## Configuration Variables` section links to `docs/variables.md` — that is the only
variable reference in the README.  A CI step (`Check README references docs/variables.md`)
enforces this: it fails if the link is absent or if `docs/variables.md` is missing.

> **Never** paste a variable table into README.md — it will drift and CI will not catch the
> individual cell values.  Update `packs/openstudio-server/variables.hcl`, regenerate `docs/variables.md`, and let the
> auto-generated doc speak for itself.

## Updating compatibility matrix on release

When preparing a release, update `docs/compatibility.md` with:

- the new `pack.version`
- the corresponding OpenStudio Server `app_version`
- minimum supported Nomad and Consul versions
- any notes about compatibility changes

This keeps operators aligned on known-good version combinations.

CI validates this with the `Check compatibility.md is up-to-date` workflow step in `pack-validation.yml`:
- for most runs, it requires the current `pack.version` from `packs/openstudio-server/metadata.hcl` to exist in `docs/compatibility.md`
- for pull requests targeting `main`, it requires the upcoming release version (`pack.version` + patch) to exist

**Release checklist item:** Before opening a `develop` → `main` PR, add a compatibility row for the upcoming auto-bumped release version.
