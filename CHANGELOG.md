# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Added `batch_engine` variable (`"internal"` | `"nomad_batch"` | `"aws_batch"`) to select the simulation compute backend; defaults to `"internal"` for full backward compatibility.
- Added Nomad Batch provider variables: `nomad_batch_datacenter`, `nomad_batch_namespace`, `nomad_batch_job_name`, `nomad_batch_worker_image`, `nomad_batch_cpu`, `nomad_batch_memory`, `nomad_batch_worker_command`, `nomad_batch_worker_args`, `nomad_batch_constraints`, `nomad_batch_kill_timeout`, `nomad_batch_identity_ttl`.
- Added AWS Batch provider variables: `aws_region`, `aws_batch_job_queue`, `aws_batch_job_definition`, `aws_batch_vault_aws_role`.
- Added `templates/nomad-batch-worker.nomad.tpl` — a parameterized Nomad batch job (`type = "batch"`) deployed when `batch_engine = "nomad_batch"`. The web dispatcher dispatches one allocation per simulation via `POST /v1/job/<name>/dispatch`.
- Added `OS_EXTERNAL_BATCH`, `BATCH_PROVIDER`, `NOMAD_BATCH_JOB_NAME`, `NOMAD_BATCH_NAMESPACE`, `AWS_DEFAULT_REGION`, `AWS_BATCH_JOB_QUEUE`, and `AWS_BATCH_JOB_DEFINITION` env vars injected into the web task when `batch_engine != "internal"`.
- Added Nomad Workload Identity `identity` block to the web task when `batch_engine = "nomad_batch"`, providing a scoped short-lived `NOMAD_TOKEN` for API dispatch without static credentials.
- Added `policies/batch-dispatcher.hcl` — minimal ACL policy for the web Workload Identity (submit-job, dispatch-job, read-job, list-jobs only).
- Added `nomad-batch-engine` and `aws-batch-engine` scenarios to `scripts/test_nomad_pack_integration.sh`.

### Changed
- `templates/worker.nomad.tpl` — wrapped job definition in `[[ if eq (var "batch_engine" .) "internal" ]]` guard; worker service job is omitted when using an external batch engine.
- `templates/rserve.nomad.tpl` — wrapped job definition in `[[ if eq (var "batch_engine" .) "internal" ]]` guard; Rserve service job is omitted when using an external batch engine.
- `policies/operator.hcl` — updated comment to reference batch-dispatcher use case.

### Added
- Added `user-overrides.hcl` template at the repository root — a modeler-facing file containing only the variables energy modelers need to set (image version, worker count, port, job name), with rich inline comments.
- Added `examples/quickstart/simple.hcl` — a minimal, clean var-file for first-time modeler deployments.
- Added `docs/modelers/quickstart.md` — 3-step quickstart guide for energy modelers.
- Added `docs/modelers/submitting-osw-jobs.md` — guide for submitting OSW files, PAT projects, and REST API calls.
- Added `docs/modelers/README.md` and `docs/infrastructure/README.md` index pages routing users to the right documentation.
- Added `examples/README.md` routing energy modelers to `quickstart/` and admins to `advanced/`.

### Changed
- Reorganized `examples/` into `examples/quickstart/` (modeler-facing) and `examples/advanced/` (admin/HA/OpenStack).
- Reorganized `docs/` into `docs/modelers/` (energy modeler guides) and `docs/infrastructure/` (admin/ops guides).
- Refactored `README.md` as a traffic controller with prominent separate sections for energy modelers and infrastructure admins.
- Updated all CI workflow path references (`pack-validation.yml`, `integration-test.yml`), scripts, and `Makefile` to reflect the new `examples/quickstart/` and `examples/advanced/` paths.



- Fixed worker `patch-hosts.sh` missing `web` hostname entry: the Consul-template that generates `/etc/hosts` for worker containers only injected entries for `db`, `queue`, and `rserve`, but omitted `openstudio-web`. Every simulation subprocess uploads reports and marks the data point complete via `http://web:80/data_points/.../upload_file`; with no `/etc/hosts` entry for `web`, every upload failed silently and every data point was marked `datapoint failure`. Added `{{ range service "openstudio-web" }}echo "{{ .Address }} web"{{ end }}` to the worker template. Docker Compose was unaffected because the overlay network provides built-in DNS for all service names.

- Fixed `traefik_max_request_body_size` default value: was `"500MB"` (a human-readable string) but Traefik's `maxRequestBodyBytes` Consul tag requires a plain integer (bytes). Traefik failed to parse the tag and dropped the entire web service route, returning 404 for all requests. Changed default to `"524288000"` (500 MiB in bytes) and updated description to warn that only integers are accepted.
- Fixed `worker_autoscaling_scale_down_cooldown` being silently ignored: replaced flawed per-check `cooldown` overrides with the correct `cooldown_on_scale_up` field at the policy level (supported since Nomad Autoscaler 0.4.0; deployment uses 0.5.0). Policy-level `cooldown` now governs scale-down (`20m` default) and `cooldown_on_scale_up` governs scale-up (`10m` default).
- Fixed `fresh-redeploy-openstack.sh` bootstrap cooldown override being a no-op: the script was overriding `autoscaler_cooldown`, which is not rendered in any template. It now correctly overrides `worker_autoscaling_scale_up_cooldown` during bootstrap (Phase 2) and restores the var-file value in Phase 3.
- Fixed `worker_queue_requeued_query` default and `openstack.hcl` value: the `+1` trick (`sum(...) + 1`) was intended to prevent a missing-series error but silently breaks when the Redis key doesn't exist — Prometheus propagates empty through arithmetic, so `sum(empty) + 1` returns empty, not 1. This caused the autoscaler to oscillate between scale-up (when Redis had the key) and scale-down (when it didn't), creating thousands of short-lived allocations that were immediately stopped. Replaced with `(sum(...) or vector(0))` which consistently returns 0 when idle, enabling stable scale-to-zero behavior.

- Fixed `openstack-production.hcl` not enabling queue-depth autoscaling: the file only set `worker_autoscaling_cpu_enabled = true` but omitted `worker_autoscaling_queue_enabled`, `prometheus_enabled`, and `nomad_autoscaler_enabled`. With CPU-only scaling, workers only scale when CPU is high on *already-running* workers, not when the simulation queue is large — causing the autoscaler to leave deep queues (300+ simulations) underserved. Enabled all three flags, set `worker_queue_simulations_target = 15` and `worker_queue_requeued_target = 15` (1 worker per 15 queued jobs), and tightened scale-up cooldown from 30m to 5m so a burst queue ramps quickly to `worker_max_replicas`.
- Fixed OpenStack worker scaling stabilization defaults to avoid cooldown lockouts after deploy: aligned `worker_count` with `worker_min_replicas` (2), reduced `worker_autoscaling_scale_down_cooldown` to `5m`, restored queue-depth targets to `15/15`, and lowered the default `worker_max_replicas` guardrail to `200` in `examples/openstack-production.hcl`; updated OpenStack rollout and autoscaling ramp docs with the same guidance.
- Tuned OpenStack high-queue autoscaling profile from live cluster trials: set `worker_max_replicas=160`, `worker_queue_simulations_target=20`, `worker_queue_requeued_target=20`, `worker_autoscaling_scale_up_cooldown=2m`, and `worker_autoscaling_scale_down_cooldown=10m` after iterative load observations (40→60→80→100→120→140→160 workers) to improve ramp speed while preserving allocation stability.
- Tuned analyses-queue throughput via `web-background` scaling in live cluster tests: increasing `web_background_count` from `1` to `2` (with `web_background_worker_count=56` per replica) drained `resque:queue:analyses` from 140 to 0 in ~4 minutes with no allocation failures or restarts, so `examples/openstack-production.hcl` now defaults to `web_background_count=2`.
- Reverted `web_background_count` default back to `1` in `examples/openstack-production.hcl` and runbook guidance after upstream application guidance that horizontal web-background replicas may trigger race conditions in analysis lifecycle processing.

### Added

- Added optional Swift/object-storage artifact backend: `swift_artifact_storage_enabled` master switch and seven supporting variables (`swift_auth_url`, `swift_username`, `swift_password`, `swift_tenant_name`, `swift_container`, `swift_region`, `swift_auth_version`). When enabled, OpenStack Swift credentials and `ARTIFACT_STORAGE_BACKEND=swift` are injected as env vars into web and worker tasks, decoupling heavy artifact writes from shared NFS. See `docs/swift-artifact-backend.md` for migration and rollback guidance. (#357)
- Added `examples/openstack-production.hcl` var-file template for OpenStack deployments with commented-out Swift configuration block.
- Added `docs/swift-artifact-backend.md` covering Swift setup, migration from NFS, rollback procedure, and compatibility requirements.
- Added `worker_local_scratch_enabled`, `worker_local_scratch_size`, `worker_local_scratch_sticky`, and `worker_scratch_path` variables to enable node-local ephemeral disk for worker tasks; when enabled, a conditional `ephemeral_disk` stanza and `WORKER_SCRATCH_PATH` env var are injected into `worker.nomad.tpl` so simulations can stage I/O locally and publish only final artifacts to shared NFS, reducing write amplification at scale (#356)
- Added `docs/worker-local-scratch.md` covering write amplification rationale, Nomad `ephemeral_disk` lifecycle, application responsibilities, recommended OpenStack configuration, cleanup/retry-safe patterns, and interaction with the planned Swift storage backend (#356)
- Added `scripts/provision-openstack-storage.sh`: idempotent OpenStack storage provisioner covering Manila NFS share creation, IP-based ACL rules, NFS export-path retrieval, quota checks, optional Cinder volume provisioning, NFS mount readiness validation, and `--dry-run` mode (#355)
- Added `docs/openstack-storage-provisioning.md`: full operator guide for provisioning Manila NFS and Cinder block volumes on OpenStack, including mounting NFS on Nomad client nodes, registering Nomad host volumes, wiring storage identifiers into pack var-files, CSI volume registration, and troubleshooting (#355)
- Updated `docs/storage.md` with an "OpenStack Provisioning" section referencing the new script and guide (#355)
- Added `docs/adr-001-storage-architecture.md`: Architecture Decision Record comparing Manila NFS, Swift object storage, and Cinder-backed dedicated NFS tier for high-scale OpenStack deployments; selects Swift as primary and Cinder NFS as fallback (#354).
- Updated `docs/storage.md` with an Architecture Decision section at the top linking to ADR-001.
- Added `scripts/benchmark-storage-saturation.sh`: fio-based benchmark script simulating worker I/O patterns (4 KB random writes + 1 MB sequential reads) across four load tiers (250/500/1000/2000 workers); captures iostat, vmstat iowait, sar NFS client stats, nfsstat retransmissions, and writes structured `summary.json` per tier; includes `--analyze` mode to identify the saturation point (#353).
- Added `docs/storage-benchmark-methodology.md`: reproducible benchmark procedure covering prerequisites, load-tier definitions, metrics-to-capture table (NFS client ops/s, rtt_ms, retrans; iowait%, disk_util%, net throughput; storage-server side metrics), saturation indicator thresholds (iowait >40%, retrans >0, NFS RTT >20 ms), illustrative example results table, step-by-step script usage, and guidance on feeding results into the autoscaling ramp policy (#353).

- Completed scale-to-max performance program for OpenStack profile (#352) — all 13 sub-issues addressed across PRs #366–#378; added `docs/scale-program-summary.md` covering delivered variables, documentation, scripts, deployment sequence, and known limitations
- Added `worker_autoscaling_scale_up_cooldown` (default `10m`), `worker_autoscaling_scale_down_cooldown` (default `20m`), and `worker_autoscaling_evaluation_interval` (default `30s`) variables for storage-aware autoscaling ramp control (#359).
- Added `docs/autoscaling-storage-ramp-policy.md` covering NFS storage shock mitigation, ramp policy recommendations, iowait threshold gates, queue depth tuning, and emergency backoff procedures.
- Updated `examples/openstack.hcl` with conservative ramp guardrail defaults for NFS-backed OpenStack deployments.- Added `rserve_count` variable to allow configuring Rserve replica count (default: 1) (#360)
- Added `docs/openstack-staged-rollout-runbook.md` with staged worker ramp procedure, gate criteria (latency, iowait%, queue lag, failure rate), abort/rollback steps, evidence collection checklist, and final recommended OpenStack defaults (#365)
- Added `examples/openstack-production.hcl` with finalized tuned defaults for OpenStack-hosted Nomad clusters and inline rollback guidance (#365)
- Added `traefik_request_timeout`, `traefik_read_timeout`, `traefik_write_timeout`, and `traefik_max_request_body_size` variables for Traefik upload/body-size/timeout tuning; wired into Traefik static config entrypoint timeouts and web service buffering middleware tags (conditional on `deploy_traefik = true`) (#364).- Added `redis_config_tcp_keepalive` variable (default `60` s): passes `--tcp-keepalive` to the Redis container to prevent NAT/firewall dropping idle Resque connections during long-running background initialization steps.
- Added Traefik go/no-go ADR for OpenStack production (`docs/traefik-openstack-decision.md`): recommends `deploy_traefik = false` for production (use OpenStack Octavia LBaaS) and `true` only for dev/Vagrant; updated `examples/openstack.hcl` to record the decision explicitly (#363).
- Added `redis_config_tcp_keepalive` variable (default `60` s): passes `--tcp-keepalive` to the Redis container to prevent NAT/firewall dropping idle Resque connections during long-running background initialization steps.- Added `redis_memory_max` variable (default `0`, disabled): exposes Nomad `memory_max` for the Redis task so operators can allow Redis to burst above its soft limit during mass-enqueue spikes without being OOM-killed.
- Added `docs/rserve-horizontal-scaling.md`: benchmark methodology, Amdahl's Law analysis, recommended `rserve_count` operating points by worker count (1–10 workers: count=1; 10–25: count=2; 25–50: count=3; 50+: count=3–4 with diminishing returns), per-replica resource guidance, and prerequisites (issue #361 multi-replica-safe routing) (#362).
- Updated `examples/openstack.hcl` with `rserve_count` guidance comment and reference to the scaling doc (#362).
- Added `docs/nfs-tuning-guide.md`: comprehensive NFS client/server tuning guide with three deployment profiles (Conservative / Balanced / Aggressive), OpenStack Manila/Ganesha export tuning, benchmark methodology using `fio`/`nfsstat`/`iostat`, and guardrails for high-concurrency (100+ worker) deployments (#358).

### Changed

- Updated `docs/storage.md` §5.1 NFS mount options: promoted `nfsvers=4.1`, increased `rsize`/`wsize` from 64 KiB to 1 MiB, replaced `sync`/`intr`/`timeo=14` with `hard,timeo=600,retrans=2,noresvport,_netdev` (Balanced profile); added §8 NFS Tuning for High Concurrency cross-reference to `nfs-tuning-guide.md` (#358).
- Updated `examples/openstack.hcl`: added inline Balanced-profile `/etc/fstab` snippet and mount option rationale comments for the NFS shared volume block (#358).

- Added `redis_config_tcp_keepalive` variable (default `60` s): passes `--tcp-keepalive` to the Redis container to prevent NAT/firewall dropping idle Resque connections during long-running background initialization steps.
- Added `redis_memory_max` variable (default `0`, disabled): exposes Nomad `memory_max` for the Redis task so operators can allow Redis to burst above its soft limit during mass-enqueue spikes without being OOM-killed.- Added `web_mongoid_pool_size` variable (default `10`): injects `MONGOID_POOL` into the `web` task so Passenger processes never stall waiting for a MongoDB connection; set equal to `MAX_POOL` for large deployments.
- Added `web_background_mongoid_pool_size` variable (default `0`, auto-derived as `web_background_worker_count + 2`): injects `MONGOID_POOL` into the `web-background` task so every Resque child can acquire a MongoDB connection immediately.
- Added `rserve_count` variable (default `1`): sets the number of Rserve task group allocations. Set to a higher value to run multiple Rserve replicas for fault tolerance. Each allocation registers independently in Consul; unhealthy replicas are automatically excluded from routing. See `docs/rserve-multi-replica.md`.
- Added `docs/rserve-multi-replica.md`: documents multi-replica Rserve routing via Consul DNS, health check/failover semantics, `rserve_spreads` configuration, and known limitations. (#361)

### Changed

- Updated `web_background_worker_count` default from `6` to `8` to drain the `background` / `analyses` queues faster out-of-the-box.
- Updated `web_background_cpu` default from `250` MHz to `2000` MHz (8 workers × ~250 MHz each) and `web_background_memory` from `512` MB to `2048` MB (8 workers × ~256 MB each) to match the new default worker count; `web_background_memory_max` default updated from `0` (disabled) to `4096` MB (2× soft limit) to allow burst headroom.
- Updated `examples/openstack.hcl`: scaled `web_background_worker_count` from `42` to `56` (+33%) with proportional resource adjustments (`cpu` 12000→16000 MHz, `memory` 12288→16384 MB, `memory_max` 24576→32768 MB); added `redis_config_tcp_keepalive = 60`, `redis_memory_max = 24576` (1.5× redis_memory), `web_mongoid_pool_size = 154` (matching MAX_POOL), and `web_background_mongoid_pool_size = 58` (56 workers + 2 headroom).


### Changed

- Changed `worker_min_replicas` default from `2` to `0` to allow scale-to-zero when `worker_autoscaling_queue_enabled = true` and the queue is empty; operators who require a standing worker floor should set this explicitly.
- Changed `autoscaler_cooldown` default from `60m` to `10m` so idle workers are reclaimed faster after the queue drains; increase to `60m` or higher in environments prone to rapid scale-up/scale-down oscillation.
- Updated `worker_autoscaling_queue_enabled` description to clarify that CPU-only scaling does not scale workers to zero and that this flag is required for queue-driven scale-to-zero behavior.
- Updated `examples/openstack.hcl`: set `worker_min_replicas = 0` so workers scale to zero when the queue is empty (was `4`, which held a standing floor of idle allocations).

- Added `worker_runtime_image` support to `worker.nomad.tpl`: when set, worker allocations use this short host-local alias instead of `worker_image`, preventing Docker from contacting the upstream registry at alloc start and eliminating Pulp TLS handshake timeouts on worker allocation retries.
- Updated `system-hooks.nomad.tpl` `pull-worker-image` task: when `worker_runtime_image` is set, switches from `docker` driver to `raw_exec` and runs `docker pull <worker_image> && docker tag <worker_image> <worker_runtime_image>` atomically, ensuring the local alias is always available before worker allocations start.
- Set `worker_runtime_image = "openstudio-worker:local"` in `examples/openstack.hcl` to activate the local alias strategy for the Pulp registry environment.
- Added `mongo_user` variable (`MONGO_USER` env var) injected into web, web-background, and worker containers to align with the Helm chart, which sets `MONGO_USER` on all workloads for MongoDB authenticated connections.
- Added `web_background_worker_count` variable (default `6`) injected as the `COUNT` env var into the web-background task to control the number of Resque child worker processes per allocation, matching the Helm chart's configurable worker count.
- Added `init-shared-storage-perms` prestart lifecycle task to the `web-background` group: runs `alpine:3.20` as root (with `CHOWN`+`FOWNER` capabilities) to `mkdir -p` and `chmod 2777` the analysis directory tree on the shared NFS volume before any workers start, mirroring the Helm chart's `init-fix-shared-storage-perms` init container.

### Fixed

- Removed the circular `web-background` prestart dependency on `openstudio-web`; it now waits for `openstudio-rserve` instead, allowing the web job to become healthy on fresh deployments.
- Fixed "Analysis initialization failed: Seed zip ... Destination already exists" error by changing the `web_background_queues` default from `analysis_wrappers` to `background,analyses`. The `analyses` queue contains cleanup/pre-initialization jobs that must run before zip extraction; without those workers running, stale files from a prior failed initialization were never removed, causing the "already exists" error on retry.
- Renamed `APP_SECRET_KEY_BASE` environment variable to `SECRET_KEY_BASE` across web, web-background, and worker tasks to match the Rails standard and the Helm chart; the HCL variable name `app_secret_key_base` is unchanged.
- Fixed web task missing `QUEUES = "analysis_wrappers"` env var, now aligned with the Helm chart's web deployment.

- Docker Compose-based quick-start infrastructure (`docker/docker-compose.yaml`, `docker/nomad.hcl`, `Makefile`, `scripts/quickstart.sh`) that runs Consul and Nomad in containers with host networking — reducing local dev prerequisites from 5 (Docker, nomad-pack, native Nomad, native Consul, CNI plugins) to 2 (Docker + nomad-pack). Both the Makefile and quickstart script use `curl` API calls exclusively — no native `nomad` or `consul` CLI required. Updated `docs/getting-started-single-node.md` with a "Quick Start (5 minutes)" section at the top. (#349)

### Fixed

- Pinned `test_curl_image_tag` default from `latest` to `8.9.1` to remove the only floating container image tag and restore reproducible test job image resolution. (#301)
- Reconciled CI workflow trigger documentation in AGENTS.md and README.md with actual `.github/workflows/` configurations: `pack-validation.yml` runs on push to `develop` **and** `main`; `acl-policy-validation.yml` covers policy and ACL script changes; added missing `release.yml` row to README CI table (#279)
- Renamed backup/restore volume selector variable from `backup_nfs_host_volume` to `backup_volume_source` across templates, examples, and docs to clarify support for both `host_volume` and `csi` backends. (#315)
- Aligned Nomad ACL policy defaults with the pack default namespace by switching policy files from `openstudio` to `default`, and updated ACL docs/script guidance for custom namespace substitution (#309)
- Added an explicit `nomad job validate examples/test-batch.nomad` gate to `pack-validation.yml` so smoke-test batch spec errors fail fast in validation CI instead of surfacing only in slower e2e runs (#305)
- Added `main` branch triggers to `acl-policy-validation.yml` for both push and pull request events so ACL policy changes are validated before and after merge on release branch updates (#306)
- Clarified Vault flag behavior in variables and docs: `vault_integration_enabled` now explicitly documents KV template secret injection, `vault_enabled` documents explicit role-based `vault` blocks, and docs now describe recommended dual-enable and fallback behavior when only one flag is set (#303)
- Synced `packs/openstudio-server/metadata.hcl` during automated release version bumps and added CI checks/docs coverage to prevent future registry metadata drift (#296)
- Fixed `scripts/pre-teardown.sh` to stop all optional teardown-sensitive jobs when present by adding missing `<JOB_NAME>-state-restore`, `<JOB_NAME>-batch-verify`, and `<JOB_NAME>-test` stop calls; also documented the full stop order in `docs/operations-guide.md` and added `scripts/test_pre_teardown.sh` coverage in CI (#297)
- Added missing `openstudio-web` and `openstudio-rserve` service URLs to deployment output, including an unconditional OpenStudio Web UI section so operators can find the primary UI even when Traefik is disabled (#294)
- Increased `web_memory_max` default from `2048` to `4096` and documented that it must exceed `web_memory`, so Nomad web tasks can actually burst beyond their soft memory reservation by default (#295)

## [0.2.67] - 2026-07-29

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

- Added `develop` to `pull_request.branches` in `pack-validation.yml` so pack validation runs on PRs targeting `develop`, not just `main`. PRs to `develop` can no longer merge without passing pack validation. (#245)
- Applied `docker_user` (`user` field) non-root hardening to `web`, `web-background`, and `worker` main task `config` blocks, which were missing it; also added `docker_user` to `db`, `redis`, and `rserve` config blocks for complete enforcement across all service tasks. Added a CI step (`Check docker_user non-root hardening is applied to all main service tasks`) to `pack-validation.yml` to prevent future drift (#246).
- Made `integration-test.yml` fail in e2e stub-image mode when required `openstudio-*` Consul services are not registered before a configurable timeout/retry window, while keeping `nomad` and `nomad-client` checks as hard assertions. (#239)
- Removed all duplicated task groups from `openstudio-server.nomad.tpl` to enforce split-job architecture; eliminates duplicate Consul service registrations (`openstudio-web`, `openstudio-db`, `openstudio-redis`) and double resource consumption when deployed alongside dedicated per-component templates. (#223)
- Fixed `redis.nomad.tpl`: the main Redis task `config` block was missing the
  `image = "[[ var "redis_image" . ]]"` field, causing every Redis allocation to fail
  immediately with "image is empty" at runtime. (#227)
- Strengthened the `packs/` drift CI gate to compare `variables.hcl` as a full file (not just variable names), so defaults and descriptions cannot silently diverge between root and `packs/openstudio-server/`. (#216)
- Made backup/restore state volume backend configurable via `backup_volume_type` and removed hardcoded host volume type in backup/restore templates. (#214)
- Replaced phantom autoscaling variable names in README variable reference table (`worker_autoscaling_min`, `worker_autoscaling_max`, `worker_autoscaling_cooldown`) with the correct names (`worker_min_replicas`, `worker_max_replicas`, `autoscaler_cooldown`) that match `variables.hcl` (resolves #123).
- Synced `packs/openstudio-server/variables.hcl`, `metadata.hcl`, and all templates under `packs/openstudio-server/templates/` to match root pack (was 20 patch versions and several variables behind). Added CI drift gate in `pack-validation.yml` that fails if `packs/` diverges from root. (#189)
- Updated stale defaults in README: `worker_autoscaling_enabled` `true` → `false`,
  `worker_max_replicas` `3` → `10`, `autoscaler_cooldown` `"2m"` → `"60m"`,
  `autoscaler_prometheus_address` `""` → `"http://prometheus:9090"` (resolves #123).
- Removed `develop` and `master` from `release-version-bump.yml` `on.push.branches` so automated patch releases only fire on merges to `main`, preventing spurious public releases on every `develop` push (#192).
- Updated `CONTRIBUTING.md` release process section to document the `develop → main` promotion flow (#192).

## [0.2.41] - 2026-07-28

### Changed

- Pinned `web_image`, `web_background_image`, and `worker_image` to `nrel/openstudio-server:3.8.0-1`,
  aligning with the Helm chart `Chart.yaml` `appVersion`. CI uses Nomad `1.7.7` (`NOMAD_VERSION`
  in `integration-test.yml`).

## [0.2.0] - 2026-07-28

### Added

- Extended pack with optional Traefik ingress integration (`traefik_enabled`, `ingress_domain`,
  `ingress_tls_enabled`) and optional Vault secrets injection (`vault_enabled`,
  `vault_integration_enabled`)
- Added Nomad Autoscaler support for the worker job (`nomad_autoscaler_enabled`,
  `worker_autoscaling_enabled`) with both CPU-utilisation and Prometheus queue-depth strategies
- Added image pre-pull system job (`enable_image_prepull`, `system-hooks.nomad.tpl`) to cache
  heavy images on all eligible nodes before first deploy
- Added periodic state-backup and on-demand state-restore batch jobs
  (`state-backup.nomad.tpl`, `state-restore.nomad.tpl`)
- Added batch verification job (`batch-verification.nomad.tpl`, `enable_batch_verification`)
- Added Vector log-collection sidecar to all service tasks (`enable_vector_collection`)
- Added `poststop` cleanup lifecycle task to all service tasks (`poststop_cleanup_paths`)
- Added Consul Connect mTLS sidecar proxy support (`enable_consul_connect`)
- Added NFS shared-volume support for web and worker (`nfs_shared_volume_enabled`)
- Added CSI volume backend support for MongoDB and Redis (`db_storage_type`, `redis_storage_type`)
- Added Docker hardening defaults: non-root user (`docker_user`), read-only rootfs
  (`docker_readonly_rootfs`), capability drop (`docker_cap_drop`)
- Added `web-background` task group inside the web job for background Rails processing
- Added `openstudio_test.nomad.tpl` parameterised batch job for integration test runs
- Added ACL policy HCL files under `policies/` with CI format validation
- Added Vagrant-based 4-VM local cluster for end-to-end testing (`Vagrantfile`,
  `vagrant/provision/`)
- Added `docs/` operator reference: getting-started guide, operations guide, storage guide,
  upgrade guide, Vault and ACL policy references, compatibility matrix, and auto-generated
  variables reference
- Added example var-files (`examples/minimal-dev.hcl`, `examples/production-ha.hcl`,
  `examples/airgapped.hcl`, `examples/e2e-test.hcl`)
- Added `scripts/generate-vars-doc.sh` for auto-generating `docs/variables.md` from
  `variables.hcl`; CI enforces sync with a diff check
- Added `scripts/test_nomad_pack_integration.sh` integration test runner
- Added `scripts/bump_metadata_version.sh` version-bump helper with isolated fixture tests
- Added `scripts/pre-teardown.sh` helper for safe job stop ordering before volume teardown
- Added `scripts/run-batch-verification.sh` operational helper
- Added registry-aligned mirror under `packs/openstudio-server/` with CI drift enforcement
- Added `outputs.tpl` post-deploy output showing Consul service and Traefik URLs
- Added `release-version-bump.yml` CI workflow for automated patch-version bumps on `main`
- Added `integration-test.yml` CI workflow for e2e stack validation on PRs

## [0.1.0] - 2026-07-28

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

[Unreleased]: https://github.com/anchapin/openstudio-server-nomad-pack/compare/v0.2.67...HEAD
[0.2.67]: https://github.com/anchapin/openstudio-server-nomad-pack/compare/v0.2.41...v0.2.67
[0.2.41]: https://github.com/anchapin/openstudio-server-nomad-pack/compare/v0.2.0...v0.2.41
[0.2.0]: https://github.com/anchapin/openstudio-server-nomad-pack/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/anchapin/openstudio-server-nomad-pack/releases/tag/v0.1.0
