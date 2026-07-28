# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Replaced phantom autoscaling variable names in README variable reference table
  (`worker_autoscaling_min`, `worker_autoscaling_max`, `worker_autoscaling_cooldown`) with the
  correct names (`worker_min_replicas`, `worker_max_replicas`, `autoscaler_cooldown`) that match
  `variables.hcl` (resolves #123).
- Updated stale defaults in README: `worker_autoscaling_enabled` `true` → `false`,
  `worker_max_replicas` `3` → `10`, `autoscaler_cooldown` `"2m"` → `"60m"`,
  `autoscaler_prometheus_address` `""` → `"http://prometheus:9090"` (resolves #123).

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
