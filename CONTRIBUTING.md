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

```bash
# Format-check all HCL files (non-destructive)
nomad-pack fmt --check .

# Render templates to stdout and inspect output
nomad-pack render . --var-file=variables.hcl

# Validate the rendered job spec against a live Nomad cluster
nomad-pack validate . --var-file=variables.hcl
```

### Running CI locally with `act`

```bash
# Run the pack-validation workflow
act push -W .github/workflows/pack-validation.yml

# Run all workflows triggered by push
act push
```

### Integration tests

```bash
# Run the Nomad Pack integration test script
bash scripts/test_nomad_pack_integration.sh
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
5. If you changed any variable in `variables.hcl`, regenerate the variable docs (see below).
6. All required CI checks must pass before merge:
   - `pack-validation.yml` — format, render, validate
   - `acl-policy-validation.yml` — ACL policy lint
   - `integration-test.yml` — end-to-end stack test (runs on merge to `develop`)

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

> **Branch promotion model:** all development merges into `develop`. When a release is ready, `develop` is merged into `main`. Only pushes to `main` trigger the automated version-bump and release workflow (`release-version-bump.yml`). Pushing to `develop` — including merged feature PRs — does **not** create a public release.

Releases are automated via `.github/workflows/release-version-bump.yml` and triggered by a push to `main`.

To prepare a release:

1. Ensure all intended changes are merged into `develop` and CI is green.
2. Move all `[Unreleased]` entries in `CHANGELOG.md` to a new versioned section (e.g. `[0.3.0] - 2026-07-28`).
3. Update `docs/compatibility.md` (see section below).
4. Open a PR from `develop` → `main`, merge when CI passes.
5. The `release-version-bump.yml` workflow automatically bumps the patch version in `metadata.hcl`, creates a git tag, and publishes the GitHub Release.

> **Note:** `scripts/bump_metadata_version.sh <new-version>` can still be used to manually set a specific version before opening the `develop → main` PR if a non-patch increment (minor/major) is needed.

---

## Regenerating `docs/variables.md`

`docs/variables.md` is auto-generated from `variables.hcl` — **do not edit it manually**.
`variables.hcl` is the **sole source of truth** for all pack variable definitions.

After changing any variable definition (adding, removing, or modifying any `variable "..."` block
in `variables.hcl`), regenerate the reference doc:

```bash
./scripts/generate-vars-doc.sh
```

Then commit both updated files (`variables.hcl` and `docs/variables.md`).

CI validates this with the `Check variables.md is up-to-date` workflow step,
which diffs the committed file against a freshly generated copy and fails on any divergence.

### README variable table

The README **does not** maintain a separate variable table.
The `## Configuration Variables` section links to `docs/variables.md` — that is the only
variable reference in the README.  A CI step (`Check README references docs/variables.md`)
enforces this: it fails if the link is absent or if `docs/variables.md` is missing.

> **Never** paste a variable table into README.md — it will drift and CI will not catch the
> individual cell values.  Update `variables.hcl`, regenerate `docs/variables.md`, and let the
> auto-generated doc speak for itself.

## Updating compatibility matrix on release

When preparing a release, update `docs/compatibility.md` with:

- the new `pack.version`
- the corresponding OpenStudio Server `app_version`
- minimum supported Nomad and Consul versions
- any notes about compatibility changes

This keeps operators aligned on known-good version combinations.

CI validates this with the `Check compatibility.md is up-to-date` workflow step in `pack-validation.yml`, which extracts `pack.version` from `metadata.hcl` and fails if that version string is absent from `docs/compatibility.md`. This mirrors the `Check variables.md is up-to-date` gate.

**Release checklist item:** After every automated version bump, add a new row to `docs/compatibility.md` before opening the PR to `main`.
