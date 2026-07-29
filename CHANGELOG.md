# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Broadened `integration-test.yml` path filter to include `packs/**`, `scripts/**`, `examples/**`, and `metadata.hcl` so pack-impacting changes always trigger integration validation (#240)
- Added explicit `nomad-pack validate ./packs/openstudio-server` step to pack-validation.yml CI workflow (#228)
- Added a dedicated MongoDB upgrade migration guide with step-by-step instructions for persisted
  data upgrades from `mongo:4.2` to `mongo:6.0.7`, including backup, rollback, and verification
  procedures. (#217)
- Extended `integration-test.yml` e2e job to start a Consul dev agent alongside Nomad and assert
  that all expected Consul service registrations (`openstudio-db`, `openstudio-redis`,
  `openstudio-web`, `openstudio-rserve`) are present after pack deployment, satisfying PRD
  Acceptance Criterion 5 (Consul DNS service resolution). (#227)
- Fixed e2e CI: install dnsmasq on Docker bridge gateway so containers resolve
  `consul.service.consul` via Consul DNS; pass `DOCKER_HOST` explicitly to Nomad dev agent;
  wait for Docker driver fingerprint before submitting jobs; add `Dump Nomad and Docker
  diagnostics` step for future debugging. (#227)
- Fixed e2e CI: add `-advertise=${DOCKER_BRIDGE_IP}` to Consul dev agent so that
  `consul.service.consul` DNS resolves to the Docker-accessible bridge IP instead of
  `127.0.0.1` (loopback is unreachable from inside containers); fix Docker fingerprint
  check to use per-node detail view; increase `db_memory` to 768 MB and `redis_memory`
  to 256 MB in `e2e-test.hcl` to prevent OOM kills of MongoDB 7 and Redis containers. (#227)
- Fixed e2e CI: restart Docker BEFORE starting dnsmasq so `docker0` is stable when
  dnsmasq binds to it; hardcode `unix:///var/run/docker.sock` for Nomad `DOCKER_HOST`
  to avoid TCP-context mismatches; add `nomad alloc status -verbose` for failed db/redis
  allocations in diagnostics step. (#227)

### Fixed

- Added `develop` to `pull_request.branches` in `pack-validation.yml` so pack validation runs on PRs targeting `develop`, not just `main`. PRs to `develop` can no longer merge without passing pack validation. (#245)
- Applied `docker_user` (`user` field) non-root hardening to `web`, `web-background`, and `worker` main task `config` blocks, which were missing it; also added `docker_user` to `db`, `redis`, and `rserve` config blocks for complete enforcement across all service tasks. Added a CI step (`Check docker_user non-root hardening is applied to all main service tasks`) to `pack-validation.yml` to prevent future drift (#246).
- Made `integration-test.yml` fail in e2e stub-image mode when required `openstudio-*` Consul services are not registered before a configurable timeout/retry window, while keeping `nomad` and `nomad-client` checks as hard assertions. (#239)
- Removed all duplicated task groups from `openstudio-server.nomad.tpl` to enforce split-job architecture; eliminates duplicate Consul service registrations (`openstudio-web`, `openstudio-db`, `openstudio-redis`) and double resource consumption when deployed alongside dedicated per-component templates. (#223)
- Fixed `redis.nomad.tpl`: the main Redis task `config` block was missing the
  `image = "[[ var "redis_image" . ]]"` field, causing every Redis allocation to fail
  immediately with "image is empty" at runtime. (#227)

### Changed

- **BREAKING** Bumped `db_image` default from `mongo:4.2` to `mongo:6.0.7` to align with the
  reference Helm chart and remove the end-of-life MongoDB 4.2 image (EOL April 2024, known CVEs).
  Operators with **persisted MongoDB volumes** must upgrade in sequence: 4.2 → 4.4 → 5.0 → 6.0.
  Fresh deployments are unaffected and can start directly on `mongo:6.0.7`.
  See [`docs/upgrading.md`](docs/upgrading.md#mongodb-upgrade-path-for-persisted-42-data) for the
  full migration guide. (Resolves [#124](https://github.com/anchapin/openstudio-server-nomad-pack/issues/124))
- Removed stale manually-maintained variable table from README `## Pack Metadata` section;
  replaced with a link to the auto-generated `docs/variables.md`. (#177)

### Fixed

- Strengthened the `packs/` drift CI gate to compare `variables.hcl` as a full file (not just variable names), so defaults and descriptions cannot silently diverge between root and `packs/openstudio-server/`. (#216)
- Made backup/restore state volume backend configurable via `backup_volume_type` and removed hardcoded host volume type in backup/restore templates. (#214)
- Replaced phantom autoscaling variable names in README variable reference table
- Synced `packs/openstudio-server/variables.hcl`, `metadata.hcl`, and all templates under `packs/openstudio-server/templates/` to match root pack (was 20 patch versions and several variables behind). Added CI drift gate in `pack-validation.yml` that fails if `packs/` diverges from root. (#189)
  (`worker_autoscaling_min`, `worker_autoscaling_max`, `worker_autoscaling_cooldown`) with the
  correct names (`worker_min_replicas`, `worker_max_replicas`, `autoscaler_cooldown`) that match
  `variables.hcl` (resolves #123).
- Updated stale defaults in README: `worker_autoscaling_enabled` `true` → `false`,
  `worker_max_replicas` `3` → `10`, `autoscaler_cooldown` `"2m"` → `"60m"`,
  `autoscaler_prometheus_address` `""` → `"http://prometheus:9090"` (resolves #123).
- Removed `develop` and `master` from `release-version-bump.yml` `on.push.branches` so automated patch releases only fire on merges to `main`, preventing spurious public releases on every `develop` push (#192).
- Updated `CONTRIBUTING.md` release process section to document the `develop → main` promotion flow (#192).

## [0.1.0] - Unreleased

### Added

- Initial Nomad Pack for deploying the full OpenStudio Server stack on HashiCorp Nomad
- Job templates for all stack components: web, worker, db (MongoDB), Redis, and Rserve
- Consul service discovery and DNS resolution integration
- Configurable variables in `variables.hcl` for images, resource limits, ports, and datacenter targets
- `metadata.hcl` enriched with all Nomad Pack registry required fields:
  - `pack.version` (`0.1.0`), `pack.min_nomad_version` (`1.4.0`), `pack.url`
  - `app.version` (`3.6.1`) — the OpenStudio Server release tested against this pack
- Pack validation CI workflow (`.github/workflows/pack-validation.yml`)
- Release process documented in `metadata.hcl` comments

[0.1.0]: https://github.com/anchapin/openstudio-server-nomad-pack/releases/tag/v0.1.0
