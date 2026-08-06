# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Added `backup_include_fs` (default `false`), `backup_fs_volume_type`, `backup_fs_volume_source`, `backup_fs_mount_path`, and `backup_fs_subdirectory` variables plus an `artefacts-backup` task in `state-backup.nomad.tpl`. When enabled, the periodic backup job mounts the shared OpenStudio data volume (typically `openstudio-nfs`, the same volume web/worker mount via `nfs_shared_volume_enabled`) read-only, tars `server/analyses` into the backup volume, and applies the same `backup_retention_days` rotation as the Mongo/Redis dumps. Closes the gap where analyses artefacts were backed up nowhere (Mongo+Redis only).
- Added `docker_cap_add` variable (default `[]`) wired into the `web`, `web-background`, and `worker` docker task configs. It re-adds Linux capabilities after the global `docker_cap_drop = ["ALL"]` and is the supported container security model: the stock OpenStudio Server image requires root + writable rootfs (its `rails-entrypoint` chmods/mkdirs root-owned paths and rewrites `/opt/nginx/conf/nginx.conf` in place), so non-root `docker_user`/`readonly_rootfs` hardening is not achievable without a patched image. Verified minimal cap set for nginx/Passenger/rake: `CHOWN, FOWNER, DAC_OVERRIDE, SETUID, SETGID, NET_BIND_SERVICE`. Removed the ineffective `fix-web-perms`/`fix-web-background-perms` prestart tasks (they chown inside their own container and have no effect on the application container). Documented in `docs/infrastructure/operations-guide.md` under "Container Security Model".
- Added `enable_orphan_dp_auto_reset` (default `true`), `orphan_dp_stale_hours` (default `2`), `enable_resque_mongodb_reconcile` (default `true`), and `resque_mongodb_reconcile_max_requeue` (default `500`) variables, plus a `sweep-state` task in the `queue-sweeper` group of `queue-sweeper.nomad.tpl`. The task runs in the openstudio-server image (`web_image`) using the bundled `mongo` and `redis` gems (no CLI tools needed) and reconciles two infra-recoverable failure classes: (1) data points stuck in `started` longer than `orphan_dp_stale_hours` are reset to `queued` (clearing `run_start_time`/`status_message`) and re-enqueued into `resque:queue:simulations`; (2) data points in Mongo `status='queued'` missing from the Resque simulations queue are re-enqueued (`LPUSH`), capped at `resque_mongodb_reconcile_max_requeue` per cycle to avoid bulk-push silent drops. Service discovery mirrors `sweep.sh` (Consul DNS name first, then Consul HTTP health-API fallback); store-unreachable cycles exit 0 (skip), hard errors exit 1 (restart policy).
- Added `alert_queuing_gate_enabled` variable (default `true`) and queuing-gate-deadlock detection to `queue-health-alert.nomad.tpl`. When at least one analysis is enqueued (a `resque:analysis:*:queuing` lock exists), the `analysis_wrappers` queue that web workers drain to enqueue data-point jobs is empty, the simulations queue is empty, and workers are still registered, no new data-point jobs can be produced; the check now emits `queue_stagnation_alert type=queuing_gate_deadlock` with the affected analysis IDs and count, and exits non-zero so the periodic job failure surfaces in Nomad/Vector alert routing.
- Added `consul_http_max_conns_per_client` variable (default `1500`) and Step 7 to `infra-setup.nomad.tpl`. The Consul default of 100 connections per client IP is far too low for large worker fleets where each node runs 280+ workers × 4 template watches = 1,120+ concurrent Consul connections per local agent. Without this, Consul returns HTTP 429 to the Nomad template engine, blocking worker startups and starving Traefik of catalog routes. The infra-setup system job now idempotently appends `limits { http_max_conns_per_client = ... }` to `/etc/consul.d/consul.hcl` and restarts Consul if the setting is missing.
- Added `web_nginx_tmpdir_in_alloc` variable (default `true`) and `nginx-tmpdir` prestart lifecycle task to the web task group in `web.nomad.tpl`. The prestart task uses `raw_exec` to create and chown `$NOMAD_ALLOC_DIR/tmp/nginx-body-temp` before the web container starts, then a Docker bind mount redirects `/opt/nginx/client_body_temp` to that alloc-local path. This prevents nginx request body temp files from filling the Docker overlay2 filesystem on the host node (root cause of the disk-full 502/404 incidents on 2026-08-05).
- Added `worker_autoscaling_max_scale_delta` variable (default `200`) and `max_scale_delta` to the worker autoscaler policy in `worker.nomad.tpl`. Limits the maximum number of workers the autoscaler can add/remove in one evaluation cycle. Prevents mass scale-up from flooding Consul agents with thousands of simultaneous template-watch connections (thundering herd), which was the root cause of Consul 429 saturation on 2026-08-05.
- Added `worker_update_health_check` variable (default `task_states`) to make the worker canary deployment health strategy configurable. Batch-style workers complete their job and exit before the `checks` health strategy's `min_healthy_time` window, preventing canary promotion; `task_states` only requires the task to be in the running state for `min_healthy_time`.
- Added `web_disk_mb` variable (default `10240` MB) and `ephemeral_disk` blocks to the `web` and `web-background` task groups. The default Nomad ephemeral disk (300 MB) fills rapidly when many workers concurrently POST result files through nginx `client_body_temp` and Rack/Paperclip `/tmp`; 10 GB prevents the disk-full condition that caused nginx 500s and Traefik to return 404 to the browser.
- Added `vector_memory_max_mb` variable (default `1024` MB) and `memory_max` to the Vector sidecar resources block, providing a hard burst cap above the soft `vector_memory_mb` limit to prevent OOM kills during log spikes.
- Added `traefik_consul_refresh_interval` variable (default `10s`) and `--providers.consulcatalog.refreshinterval` / `--providers.consulcatalog.requireConsistent=true` args to Traefik job template. Lower interval and consistent reads ensure Traefik detects web backend recovery faster after an outage, preventing the stale "no backends → 404" state.
- Added `worker_preflight_jitter_max_seconds` variable (default `120`) and random initial sleep to the worker preflight task. With large worker fleets (e.g. 4,000+ workers) starting simultaneously, synchronized Consul health check requests cause HTTP 429 thundering-herd; random jitter in [1, jitter_max] seconds spreads the request wave. Default raised from 30s to 120s to accommodate 5,000+ worker fleets.
- Changed worker patch-hosts template to use `service "name" "any"` filter instead of `service "name"` (passing-only). The `"any"` filter returns services regardless of Consul health check status, allowing the Nomad template to render and worker tasks to start even when services are temporarily unhealthy or when Consul 429 rate-limiting prevents passing-filter queries from resolving; the existing stale-entry fallback in `update_alias` handles true service unavailability.
- Updated `traefik_consul_catalog_address` variable description to document the Consul 429 risk when local Consul agents are saturated by worker template traffic; set `traefik_consul_catalog_address = "192.168.100.87:8500"` in `openstack-production.hcl` to point Traefik at the Consul server (isolated from worker template traffic) instead of the local agent (shared with all workers on the Traefik node, which can be rate-limited with large fleets).

### Fixed
- Fixed `openstudio-server-queue-health-alert` job conflict error on fresh redeployment. `pre-teardown.sh` did not stop the `<job_name>-queue-health-alert` periodic batch job, leaving it as an unmanaged job in Nomad. When `nomad-pack` then attempted to deploy `queue-health-alert.nomad.tpl` in Phase 2, it raised "job … already exists and is not managed by nomad pack". Added `<job_name>-queue-health-alert` to the optional-jobs teardown list in `pre-teardown.sh`, to `PACK_JOB_SUFFIXES` in `fresh-redeploy-openstack.sh`, and extended `test_pre_teardown.sh` to assert the stop call is issued.

- Lowered the `worker_autoscaling_max_scale_delta` **pack default** from `200` to `10`. The pass-through queue strategy conflates backlog with demand (a deep queue maps to thousands of desired workers), so a large operator-set `worker_max_replicas` combined with a wide delta let the autoscaler ramp the fleet to 5,500 workers on 2026-08-06 from a ~38k simulation backlog. A bounded delta plus the existing scale-up cooldown rate-limits any future scale-up regardless of `worker_max_replicas`; operators needing large fleets can still raise the delta explicitly.
- Raised `vector_memory_mb` **pack default** from `256` to `512` MB so all new deployments (not just OpenStack production) get sufficient Vector sidecar memory. The 256 MB default caused OOM cascade twice during the 2026-08-05 recovery when bulk MongoDB `updateMany` log bursts exhausted Vector's restart attempts and brought down MongoDB as a sibling task failure.
- Raised `vector_memory_mb` from 256 MB to 512 MB in `examples/advanced/openstack-production.hcl` to prevent the Vector log sidecar from being OOM-killed during high-volume MongoDB operations (bulk `updateMany` log bursts exceeded the 256 MB limit, killing the sidecar and causing MongoDB to be torn down as a sibling task failure).
- Raised `worker_preflight_max_attempts` to 15 and `worker_preflight_sleep_seconds` to 5 in `openstack-production.hcl`; set `worker_wait_for_deps_proceed_on_timeout = true` to prevent thundering-herd Consul 429 rate-limiting during large-scale simultaneous worker startup from cascading into allocation failures.
- Added explicit `worker_preflight_jitter_max_seconds = 120` to `openstack-production.hcl` to make the production jitter window version-independent of the pack default.
- Fixed stale description for `worker_preflight_jitter_max_seconds` variable: updated from "Default 30 / 4,000-worker fleet" to "Default 120 / 5,600-worker fleet".
- Fixed `scripts/requeue-stuck-datapoints.sh` reading the entire DP ID file as a single concatenated string: `tr -d '[:space:]'` stripped all whitespace including newlines; changed to `tr -d '\r'` to only strip Windows-style carriage returns, preserving newline delimiters between UUIDs.
- Fixed `fresh-redeploy-openstack.sh` aborting before `nomad-pack run` when NFS data was wiped: `preflight-storage.sh` NFS subdirectory check now receives `--skip-nfs-subdir-check` after an NFS wipe so it does not fail with a false-negative (`server/assets/analyses` and `server/R` are intentionally absent and will be re-created by `init-shared-storage-perms` on the upcoming deploy).
- Fixed `preflight-storage.sh` NFS host-volume check being silently skipped when `nfs_volume_type = "host_volume"` is explicitly set in a var-file (e.g. `openstack.hcl`): the internal fallback default was `"host"` while `variables.hcl` defines `"host_volume"` as the canonical value; both the default and the comparison now use `"host_volume"`.

### Documentation
- Extended `docs/infrastructure/runbooks/queue-stall.md` with Section 7: Consul 429 thundering-herd recovery — symptom identification, scale-down to break the rate-limit loop, deploying the fix with `count=50` + `auto_revert=false`, autoscaler count restoration, and re-enqueueing DPs missing from Resque after a mass orphan reset.
- Fixed `--skip-nfs-subdir-check` condition in `fresh-redeploy-openstack.sh` to include the `nfs_volume_type == "host_volume"` guard, matching the exact predicate used for the NFS wipe step (prevents the flag from being passed for CSI NFS configs where no wipe occurs).
- Fixed `pre-teardown.sh` and `fresh-redeploy-openstack.sh` not including `lock-sweeper` in their job stop / pack-jobs-found inventories; the lock-sweeper periodic batch job could remain running during teardown if it was the only active job.
- Fixed typo in `scripts/bootstrap-179d-node.sh`: Nomad client `host_volume "openstudio-nfs"` path was `opensstudio` (double `s`) instead of `openstudio`, causing the NFS volume to fail to mount in all containers and analyses to complete immediately with 0 datapoints.
- Fixed `init-shared-storage-perms` task in `web.nomad.tpl`: added `mkdir -p server/R` and `chmod 2777` alongside the existing `server/assets/analyses` setup. Rserve writes LHS sample plot PNGs to `server/R/` and silently failed when the directory was absent, causing every analysis to complete with 0 datapoints.
- Extended `scripts/preflight-storage.sh` host-volume check: now collects the registered host volume path from all eligible nodes and fails if paths are inconsistent across the cluster (which would surface bootstrap typos before a deploy), and verifies that required NFS subdirectories (`server/assets/analyses`, `server/R`) exist via the Nomad FS API on a live allocation.

- Fixed `nomad-batch-worker.nomad.tpl`: replaced `wget http://${CONSUL_ADDR}/v1/health/service/...` polling loop with `{{ with service }}` Consul Template watches and an idempotent `update_alias` helper (same pattern as web and worker). The original `wget` call failed silently from inside a bridge-networked Docker container where `127.0.0.1` resolves to the container's own loopback, not the host Consul agent; batch simulations connected to dependency services only by chance or fallback DNS.
- Fixed `openstudio_test.nomad.tpl` `runtime-discovery-canary` task: added `network_mode = "host"` to the Docker config so the `wget http://${CONSUL_ADDR}/...` connectivity test can reach the host's Consul agent at `127.0.0.1:8500` (bridge-networked containers cannot see the host loopback).
- Enhanced `scripts/check-nomad-heredoc-interpolation.sh` to also detect POSIX character classes (`[[:space:]]`, `[[:alpha:]]`, etc.) in `.nomad.tpl` files; these contain `[[` — the Nomad Pack template delimiter — and cause a pack parse error identical to the `${...:...}` HCL interpolation pitfall. Script now exits non-zero on either violation (previously it was advisory-only).
- Documented POSIX character class `[[` delimiter pitfall in `CONTRIBUTING.md` and `AGENTS.md` alongside the existing `${...:...}` HCL heredoc interpolation guidance.
- Fixed `web` and `web-background` task groups: `patch-hosts.sh` was calling `wget http://127.0.0.1:8500/v1/catalog/service/...` from inside the Docker bridge-networked container where `127.0.0.1` is the container's own loopback (not the host Consul agent). This silently failed — `response` was empty, no `/etc/hosts` entry was written, and Resque looped for ~3.5 minutes before giving up with `getaddrinfo: Temporary failure in name resolution`. Fix: rewrote both `patch-hosts.sh` data blocks to use `{{ with service "..." }}{{ (index . 0).Address }}{{ end }}` Consul Template watches, exactly like the worker template, so IPs are resolved by Nomad's template engine on the host (which has full Consul access) and embedded directly into the rendered script. The container never needs to reach Consul at all. `resolve_alias` (web/web-background) now does atomic per-alias updates and preserves the existing stale entry on Consul lookup failure instead of leaving the alias unresolved; `patch-hosts.sh` (worker) now uses an `update_alias` function with the same stale-entry fallback instead of a bulk heredoc append; `change_script` for all three task groups simplified to just `sh /local/patch-hosts.sh` since the script handles deduplication internally. Also fixes `[[:space:]]` POSIX character class which contained `[[` (Nomad Pack template delimiter) by replacing with `[ \t]` — same root cause as the `${}` HCL heredoc interpolation pitfall documented in #442.
- Fixed `fresh-redeploy-openstack.sh` core-readiness timeout race: `wait_for_core_services` 600s deadline was equal to Nomad's `progress_deadline` and started slightly later, causing the script to give up moments before the web deployment succeeded on fresh CSI volumes (MongoDB init + Rails startup). Script timeout made configurable via `OS_CORE_WAIT_TIMEOUT_SECONDS` (default 900s); `web_update_progress_deadline` default increased from `10m` to `15m` to give enough headroom.
- Fixed `tests/terratest/integration_test.go` worker DNS resolution assertions: updated to match the `update_alias` + `{{ with service }}` Consul Template pattern introduced by the atomic per-alias `/etc/hosts` refactor, so CI no longer fails on the stale `{{ range $svc := service }}` expectations (#454).

### Added
- Added a pack-managed `lock-sweeper.nomad.tpl` periodic batch job, `enable_lock_sweeper` feature flag, lock-sweeper variables, and operations guidance so orphaned `analysis_zip.lock` cleanup is version-controlled instead of maintained as an ad hoc production job (#432).
- Added configurable worker canary rollout controls, a dependency-aware worker readiness health gate, and a canary promote/revert runbook so bad worker deployments fail back to the last stable version instead of rolling fleet-wide (#435).
- Added worker `preflight` startup checks that verify Consul health, Consul catalog address resolution, and TCP reachability for MongoDB, Redis, and Rserve before the worker container starts; failures now emit structured `preflight_check` logs and fail the allocation cleanly instead of allowing silent worker crash loops (#433).
- Added queue-health alerting for simulations queue stagnation, failed-job acceleration, worker crash-loop restart thresholds, and stuck worker scheduling, plus alert-routing guidance for Prometheus/Alertmanager, Vector/Loki, and Nomad periodic job failures (#437).
- Added a pack-managed `queue-health-alert.nomad.tpl` periodic batch job, new queue-health alert threshold variables, and on-call routing documentation for Nomad/Vector→Slack/PagerDuty/email integration so the ad hoc production queue alert can be replaced with a maintained operational asset (#438).
- Added worker startup DNS/service resolution render guardrails in `scripts/test_worker_startup_dns_resolution.sh`, plus a matching Terratest assertion, to catch Consul-based worker dependency resolution regressions before merge (#447).
- Added `docs/infrastructure/runbooks/queue-stall.md`, linked it from the operations
  guide, and added `scripts/drain-workers.sh` for batched worker allocation drains during
  queue-stall recovery (#444).
- Added a "Worker Effectiveness Monitoring" section to `docs/infrastructure/operations-guide.md` documenting Nomad, Resque, structured-log, Prometheus, and Grafana views that distinguish starting, crash-looping, initialization-blocked, and throughput-producing workers (#443).
- Added Resque processed/failed counters (`resque:stat:processed`, `resque:stat:failed`) to the in-pack Redis exporter scrape so Prometheus can graph worker completions/minute and failure rate instead of only raw queue depth (#443).
- Added POSIX `/bin/sh` lint and Nomad heredoc interpolation guardrails to CI and contributor guidance (#445).
- Added Prometheus ingress alert rules for Traefik route availability, 404 surge, and backend health to `monitoring/prometheus-alert-rules.yml`: `TraefikRouterMissing` (fires when `openstudio-server@consulcatalog` router is absent), `TraefikIngressHighErrorRate` (fires on sustained router-level 404 rate > 10 %), and `TraefikBackendUnhealthy` (fires when Traefik has no healthy server for openstudio-web) (#412).
- Added "Ingress Alerts" runbook section to `docs/infrastructure/operations-guide.md` with response steps for each new alert and instructions for loading/reloading alert rules in Prometheus (#412).
- Added item 10 ("Prometheus ingress alerts loaded") to `docs/infrastructure/pre-run-checklist.md` with a validation command and pass criteria (#412).
- Added `scripts/check-csi-topology.sh` for automated CSI topology pin drift detection: reads `db_csi_topology_node_id` / `redis_csi_topology_node_id` from the running Nomad job spec, compares against the actual CSI volume topology, emits a structured warning and exits non-zero on drift; accepts `--auto-remediate` to re-run `preflight-storage.sh --rebind-stale --emit-topology-vars` and print updated var overrides (#416).
- Added `--csi-topology-key` flag and `DB_CSI_TOPOLOGY_KEY` / `REDIS_CSI_TOPOLOGY_KEY` env vars to `scripts/preflight-storage.sh` to handle non-hostpath CSI plugins; defaults to `topology.hostpath.csi/node` for backward compatibility; resolved values that are not 36-char hyphenated UUIDs are warned and skipped rather than emitting an unsatisfiable node constraint (#415).
- Added Node Replacement runbook section to `docs/infrastructure/operations-guide.md` covering CSI topology pin staleness detection and automated/manual remediation (#417).
- Added matrix strategy `render-matrix` job to `.github/workflows/pack-validation.yml` to automate `nomad-pack render` verification across key configuration scenarios (default, minimal-dev, simple, production-ha, airgapped, openstack-production, e2e-test, batch-verification, nomad-batch-engine, aws-batch-engine, vector-disabled) (#408).
- Added `db_csi_topology_node_id` and `redis_csi_topology_node_id` pack variables: when set and `db_storage_type`/`redis_storage_type` is `"csi"`, inject a hard `constraint { attribute = "${node.unique.id}" }` into the DB and Redis job groups, pinning allocations to the node that owns the CSI volume and preventing the `"csi_hook failed … does not exist in volumes list"` scheduling error.
- Added `examples/advanced/openstack-site-local.hcl.template`: copy-and-fill template for site-specific OpenStack overrides (ingress domain, datacenter name, Consul-unreachable addresses, private registry). Operators copy to `openstack-site-local.hcl`, fill in values, and pass as a second `-var-file` alongside `openstack-production.hcl`. Keeps cluster-specific IP addresses out of version control.
- Added `scripts/provision-worker-nodes.sh`: idempotent helper to provision new `azimuth.compute1-179d-250disk` OpenStack instances and bootstrap them into the Nomad cluster. Includes quota pre-flight check, auto-detected start index, dry-run mode, and a `--bootstrap-only --ips` path for re-bootstrapping existing nodes. Capacity reference: each node adds up to 45 workers (80 GB RAM / 1,750 MB each); 7,296 vCPUs of quota headroom permit ~117 more nodes → ~10,620 workers cluster-wide.
- Added `scripts/verify-prepull.sh`: pre-run smoke-check that queries Nomad for all `system-hooks` alloc states and confirms the `image-cache-ready` sentinel task is `running` on every eligible worker node. Exits non-zero if any node is missing the sentinel, indicating the pre-pull did not complete. Supports `--timeout` for polling mode and `--quiet` for CI use.
- Added `scripts/requeue-stuck-datapoints.sh`: safe, staggered re-enqueue helper for data points stuck at `na` or `started`. Enforces single-arg Resque payload format (`args: [dp_id]`), uses `</dev/null` on all `nomad alloc exec` loop calls to prevent stdin consumption, and defaults to 10-second delay between pushes. Supports `--dry-run`, `--clear-queue`, and `--delay`.
- Added `docs/infrastructure/pre-run-checklist.md`: operator checklist covering disk headroom, pre-pull completeness, deployment state, failed queue depth, stale started DPs, worker count verification, stable baseline image check, and connectivity smoke test — encoding lessons from the 2026-08-03 incident.
- Added `queue_sweeper_replay_dirty_exit` variable (default `true`): enables auto-replay of `PruneDeadWorkerDirtyExit` and `TermException` failures from `resque:failed` in the queue-sweeper. Replayed jobs use the correct single-arg format (`args: [dp_id]`). Previously required ~1,847 manual replays.
- Added conditional rendering feature flags for optional pack components: `enable_openstudio_test` (default `true`) gates the `openstudio_test.nomad.tpl` parameterized test job, completing coverage so that all 13 optional templates are now controlled by boolean feature flags (#404).
- Added `queue_sweeper_replay_delay_seconds` variable (default `10`): stagger interval between individual re-enqueues when auto-replaying failed jobs. Prevents bulk-push silent drops under high load.
- Added Terratest integration suite (`tests/terratest`) for rendering and planning Nomad Pack template scenarios, migrating integration tests from shell scripts (#407).
- Relocated loose root-level `infra-setup.nomad` file into `templates/infra-setup.nomad.tpl` and `packs/openstudio-server/templates/infra-setup.nomad.tpl` controlled by new `enable_infra_setup` boolean variable (default `false`) (#403).

### Changed
- Extended `scripts/drain-workers.sh` with supported bulk-drain flags (`--job`, `--batch`, `--sleep`, `--rounds`, `--dry-run`, `--nomad-addr`), per-round structured progress, final running-version summaries, CI syntax validation, and operations-guide usage documentation (#436).
- Removed local state overrides file `user-overrides.hcl` from git tracking and renamed it to `user-overrides.hcl.example`, updating `.gitignore` to ignore local override files (`user-overrides.hcl`, `*.override.hcl`) (#402).
- Reverted worker back to its own Nomad job (`<job_name>-worker`, `worker.nomad.tpl`) with `priority = worker_priority` (default 40), restoring the scheduler-priority separation from the web job (`priority = web_priority`, default 80). The consolidation introduced in #405 silently elevated workers to web-priority, breaking the eviction contract (workers should be evicted before the web UI under resource contention) and orphaning the `worker_priority` variable. The `stall-watchdog` consolidation into `queue-sweeper` from #405 is retained.

- Hardened OpenStack production placement defaults in `examples/advanced/openstack-production.hcl`: added explicit role/disk constraints for `db`, `redis`, `rserve`, `worker`, and `nomad-autoscaler` groups so stateful services stay on web-role infrastructure nodes and workers stay isolated on worker-role nodes.
- Extended `queue-sweeper.nomad.tpl` sweep.sh to auto-replay `PruneDeadWorkerDirtyExit` and `TermException` failures from `resque:failed`. Replays use single-arg format (`args: [dp_id]`) and staggered timing. Final summary now reports both `locks_cleared` and `replayed` counts. Controlled by new `queue_sweeper_replay_dirty_exit` and `queue_sweeper_replay_delay_seconds` variables.
- Extended `stall-watchdog.nomad.tpl` Python script to emit `queue_divergence_alert stale_started=<N> threshold=<S>s action=<restart_workers|alert_only>` structured log when DPs are found stuck in `started` state with no active Resque worker entry (Mongo/Redis queue divergence). Alert fires alongside the existing `stall_watchdog_alert` to allow monitoring systems to distinguish between EnergyPlus hang and queue state divergence.
- Added disk sizing recommendation and `client.reserved.disk` guidance to `docs/infrastructure/storage.md` (new section: *Disk Sizing for Large Simulation Runs*).
- Added *Disk Reservation*, *Scaling Workers When a Deployment Is Stuck*, and *Pending Application-Level Fixes* sections to `docs/infrastructure/operations-guide.md` encoding lessons from the 2026-08-03 incident.
- Refactored `examples/advanced/openstack-production.hcl` to be fully portable across OpenStack deployments: replaced NREL-internal Pulp registry images (`pulp-dev.hpc.nlr.gov/...`, `179-flock` dev tag) with public DockerHub images at stable `3.10.0` tag; removed hardcoded IP addresses for `autoscaler_nomad_address`, `autoscaler_prometheus_address`, and `stall_watchdog_nomad_address` (variable defaults use Consul DNS); replaced named-node hostname pin (`nomad-client-259`) with portable `attr.nomad.node.class = "system"` constraint for Prometheus placement; commented out `ingress_domain` with instructions to supply it via `openstack-site-local.hcl`. Updated runbook, README, and examples/README to use the two-file layered deploy pattern.
- Refactored `.nomad.tpl` templates by adding `openstudio_server.vector_task`, `openstudio_server.cleanup_poststop_task`, `openstudio_server.vault_block`, `openstudio_server.vault_integration_block`, `openstudio_server.restart_block`, and `openstudio_server.update_block` helpers in `templates/_helpers.tpl` and DRYing out repetitive stanzas across template files. (#406)
- Lowered `worker_memory` in `examples/advanced/openstack-production.hcl` from `1750` to `1250` MB based on observed p99 container RSS of ~1,080 MiB on a fully-loaded node (45 workers sampled); 16 % headroom above observed max; increases scheduler capacity from 45 to 64 allocs/node (119 nodes × 64 × 3 processes = **22,848 concurrent simulations**, up from 16,065). `worker_memory_max` remains 4,000 MB (OOM kill ceiling unchanged). Live cluster updated.
- Raised `worker_process_count` in `examples/advanced/openstack-production.hcl` from `"2"` to `"3"`, increasing concurrent simulations per alloc by 50 % (10,710 → 16,065 cluster-wide) with no change to memory reservation. Live cluster updated.
- Lowered `worker_queue_simulations_target` in `examples/advanced/openstack-production.hcl` from `20` to `6` so the autoscaler targets ~1 worker per 6 queued simulations (cluster capacity of ~5,355 workers saturates at ~32,000 queued simulations rather than 107,000).

### Fixed
- Fixed worker startup dependency aliasing to render `db`, `queue`, and `rserve` directly from Consul-native Nomad template lookups, removed `getent hosts` fallback usage for Consul-only service names, and documented the constraint for contributors (#434).
- Fixed `preflight-storage.sh --rebind-stale` to check for active CSI volume allocation claims before deregistering; emits an actionable error listing the alloc IDs and the exact `scripts/pre-teardown.sh` command to run instead of silently failing with a 500 error (#413).
- Fixed pre-existing `nomad-pack fmt --check` failures in `templates/db.nomad.tpl` and `templates/prometheus.nomad.tpl`; both files now pass the fmt gate on nomad-pack v0.4.2 and CI validates all templates via `nomad-pack fmt --check templates/` (#414).
- Fixed OpenStack bootstrap and provisioning guardrails for disk exhaustion: `scripts/bootstrap-179d-node.sh` now configures `client.reserved.disk = 20480` by default, and `scripts/provision-worker-nodes.sh` now supports `--root-disk-gb` / `ROOT_DISK_GB` so replacement nodes can be provisioned with larger root volumes when project quota allows.
- Fixed `system-hooks.nomad.tpl` pre-pull task groups using `mode=fail, attempts=3`: three TLS handshake timeouts under concurrent cluster-wide registry load permanently bricked nodes (the alloc stayed dead with no further retries, blocking all worker placement on that node forever). Changed both `prepull-worker-images` and `prepull-core-images` groups to `mode=delay, delay=30s, interval=1h` with the new `prepull_restart_attempts` variable (default `10`). Added `prepull_restart_attempts` variable to `variables.hcl`.
- Fixed `scripts/deploy-openstack.sh` Phase 3 permanently carrying pre-pull not-ready node exclusions into production: Phase 2 correctly restricts workers to pre-pulled nodes (topology + pre-pull-not-ready), but Phase 3 re-passed the same combined list, permanently locking workers off the majority of the cluster after bootstrap. Phase 3 now only retains CSI topology node exclusions (DB/Redis pinning); pre-pull exclusions are cleared so workers can spread to all eligible nodes. Also fixed Phase 3 never being triggered when bootstrap autoscaling bounds matched production bounds — added a third trigger condition (`worker_excluded_node_ids_json != topology_only_exclusion_json`) so Phase 3 always fires when there are pre-pull exclusions to drop, regardless of whether the autoscaling bounds changed.
- Fixed `release.yml` creating releases on wrong commit: `tag_name` was sourced from `metadata.hcl` at checkout time rather than the triggering tag; changed to `github.ref_name` and removed now-unused "Read pack version" step.
- Fixed `Makefile` `deploy` target: `nomad-pack render` was called with `--auto-approve`, an invalid flag for the `render` subcommand that caused silent no-op deploys.
- Fixed `worker_process_count` type mismatch in `examples/advanced/openstack-production.hcl`: value was unquoted integer `2` but variable type is `string`; changed to `"2"`.
- Fixed `scripts/preflight-storage.sh` relative `VAR_FILE` path: script failed when invoked outside repo root; now anchored to `REPO_ROOT` via `BASH_SOURCE[0]` like all other scripts.
- Fixed `integration-test.yml` not running E2E tests on PRs targeting `main`: added `main` to `pull_request.branches` so release PRs are validated before merge.
- Fixed invalid PromQL in worker autoscaling queries: three layered bugs caused the autoscaler to always see queue depth as 0. (1) `max_over_time((...)[window])` applied a range bracket to an aggregated sub-expression, rejected by Prometheus as "ranges only allowed for vector selectors" — fixed by moving `[window]` inside `max_over_time` directly on the bare metric selector. (2) `A or vector(0)` with a labeled metric vector `A` returns 2 streams (labeled + unlabeled `{}`), rejected by the Nomad autoscaler APM as "query returned 2 metric streams, only 1 is expected" — fixed by wrapping in `sum(...)` which collapses to exactly 1 stream while preserving scale-to-zero behavior. (3) `worker_queue_requeued_query` and `worker_queue_simulations_query` variable defaults contained `sum(...)` wrappers and `or vector(0)` clauses that are now owned by the template; updated defaults to bare vector selectors as required.
- Fixed inconsistent `actions/checkout` pin in `acl-policy-validation.yml`: upgraded stale SHA to `11bd71901bbe5b1630ceea73d27597364c9af683` (v4.2.2) matching all other workflows.
- Fixed stale `nomad-pack validate .` command in `CONTRIBUTING.md` and `AGENTS.md` (`validate` is not a valid subcommand in v0.4.2); replaced with `nomad-pack plan`.
- Fixed stale `docker_user` hardening check in `.github/workflows/pack-validation.yml`: after consolidating the worker task group into `web.nomad.tpl` (#405), `templates/worker.nomad.tpl` is an architecture marker file that intentionally renders no job, so the check no longer requires `docker_user` in it (the worker task inside `web.nomad.tpl` remains covered).
- Fixed worker rolling updates after consolidation (#405): the worker task group inside `web.nomad.tpl` inherited the web job's `update` stanza (`web_update_progress_deadline`, default `10m`), but the worker task's `kill_timeout` (default `5200s`) exceeds that deadline, causing Nomad job submission to fail with "KillTimeout longer than the group's ProgressDeadline" (HTTP 500). The worker group now declares its own per-group `update` stanza using the `worker_update_*` variables (progress_deadline default `2h`), preserving the pre-consolidation update policy. Per-group update stanzas require Nomad ≥ 1.7.0; min Nomad raised in `docs/compatibility.md`.
- Fixed duplicate `### Added` / `### Changed` / `### Fixed` headings in `CHANGELOG.md [Unreleased]`; consolidated into one of each per Keep a Changelog format.
- Removed dead `openstudio_server.compute_node_constraint` and `openstudio_server.system_node_constraint` helper macros from `templates/_helpers.tpl`: defined but never called by any template. Removed corresponding `compute_node_class` and `system_node_class` variables from `variables.hcl` and the `packs/` registry mirror.
- Removed stale `benchmark-results/` gitignore patterns (no such directory in repo).
- Updated `nomad-pack` command examples across docs, examples, and CI workflows to use flags-before-pack-path syntax required by nomad-pack v0.4.2 (e.g., `nomad-pack run -var-file X .` instead of `nomad-pack run . -var-file X`) (#390).
- Updated contributor/agent docs to use `nomad-pack fmt --check templates/` and explicitly warn that, on nomad-pack v0.4.2, `fmt -write templates/` can corrupt templates while `fmt --check -recursive .` is a silent no-op from pack root (#389).

- Removed the circular `web-background` prestart dependency on `openstudio-web`; it now waits for `openstudio-rserve` instead, allowing the web job to become healthy on fresh deployments.
- Fixed "Analysis initialization failed: Seed zip ... Destination already exists" error by changing the `web_background_queues` default from `analysis_wrappers` to `background,analyses`. The `analyses` queue contains cleanup/pre-initialization jobs that must run before zip extraction; without those workers running, stale files from a prior failed initialization were never removed, causing the "already exists" error on retry.
- Renamed `APP_SECRET_KEY_BASE` environment variable to `SECRET_KEY_BASE` across web, web-background, and worker tasks to match the Rails standard and the Helm chart; the HCL variable name `app_secret_key_base` is unchanged.
- Fixed web task missing `QUEUES = "analysis_wrappers"` env var, now aligned with the Helm chart's web deployment.

- Docker Compose-based quick-start infrastructure (`docker/docker-compose.yaml`, `docker/nomad.hcl`, `Makefile`, `scripts/quickstart.sh`) that runs Consul and Nomad in containers with host networking — reducing local dev prerequisites from 5 (Docker, nomad-pack, native Nomad, native Consul, CNI plugins) to 2 (Docker + nomad-pack). Both the Makefile and quickstart script use `curl` API calls exclusively — no native `nomad` or `consul` CLI required. Updated `docs/getting-started-single-node.md` with a "Quick Start (5 minutes)" section at the top. (#349)

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
- Made templates fmt-clean and render-stable under nomad-pack v0.4.2: converted `[[- /*` / `*/ -]]` trim-comment markers — which v0.4.2 `fmt -write` rewrites into lexer-invalid output that breaks `nomad-pack render .` with "illegal number syntax" — to plain `[[/* */]]` comments, then formatted all templates and synced the `packs/` registry mirror (#383)
- Fixed the CI fmt gate being a silent no-op: `nomad-pack fmt -check -recursive .` always exits 0 under v0.4.2 (recursive discovery never descends from the pack root), so unformatted templates went undetected; the gate now runs `nomad-pack fmt --check templates/` and is followed by a render-after-fmt guard step that catches formatter regressions (#383)
- Pinned `version: 0.4.2` in all `hashicorp/setup-nomad-pack` steps (the action's default `latest` is a moving target) and echoed the CLI version in CI logs (#383)

### Added
- Added `prometheus_alert_rules_enabled` variable (default `true`) to embed Prometheus alert rules into the in-pack Prometheus job when `prometheus_enabled = true`. Adds three rules: `OpenStudioSimulationsQueueBacklog` (simulations queue non-empty > 30 min), `OpenStudioRequeuedQueueBacklog` (requeued queue non-empty > 20 min), and `OpenStudioFailedJobs` (Resque failed queue non-empty > 5 min).
- Added `prometheus_alert_simulations_queue_minutes`, `prometheus_alert_requeued_queue_minutes`, and `prometheus_alert_failed_jobs_minutes` variables to tune alert thresholds.
- Added `scripts/detect-stalled-datapoints.sh` — detects data points frozen in `started` status with no `updated_at` progress. Complements queue-sweeper (which handles Redis lock stalls) for the distinct failure mode where EnergyPlus hangs silently without crashing Resque. Supports `--restart-allocs` for automatic recovery. Exit code `2` = stalled DPs found (suitable as alert gate in cron/CI).
- Added `resque:failed` to redis-exporter `--check-keys` so the Resque failed queue depth is available as a Prometheus metric.
- Added `enable_queue_sweeper = true` with `queue_sweeper_cron = "*/2 * * * *"` and `queue_sweeper_max_lock_age_seconds = 120` to `examples/advanced/openstack-production.hcl`.
- Added `templates/stall-watchdog.nomad.tpl` — a periodic batch Nomad job (`enable_stall_watchdog`, default `false`) that runs every 15 minutes, detects data points frozen in `started` status via the OpenStudio Server API, and optionally stops stalled worker allocations (`stall_watchdog_restart_allocs = true`) so Nomad reschedules fresh workers. Implemented in Python using only stdlib (`urllib`, `json`, `datetime`) to avoid extra dependencies. Emits structured log lines (`stall_watchdog_*`) compatible with Vector log collection.
- Added `enable_stall_watchdog`, `stall_watchdog_cron`, `stall_watchdog_max_stall_seconds`, `stall_watchdog_restart_allocs`, `stall_watchdog_nomad_address`, `stall_watchdog_worker_job`, `stall_watchdog_image`, `stall_watchdog_cpu`, and `stall_watchdog_memory` variables.
- Enabled `enable_stall_watchdog = true` with `stall_watchdog_nomad_address = "http://192.168.100.87:4646"` in `examples/advanced/openstack-production.hcl`.

- Added `batch_engine` variable (`"internal"` | `"nomad_batch"` | `"aws_batch"`) to select the simulation compute backend; defaults to `"internal"` for full backward compatibility.
- Added Nomad Batch provider variables: `nomad_batch_datacenter`, `nomad_batch_namespace`, `nomad_batch_job_name`, `nomad_batch_worker_image`, `nomad_batch_cpu`, `nomad_batch_memory`, `nomad_batch_worker_command`, `nomad_batch_worker_args`, `nomad_batch_constraints`, `nomad_batch_kill_timeout`, `nomad_batch_identity_ttl`.
- Added `templates/nomad-batch-worker.nomad.tpl` — a parameterized Nomad batch job (`type = "batch"`) deployed when `batch_engine = "nomad_batch"`. The web dispatcher dispatches one allocation per simulation via `POST /v1/job/<name>/dispatch`.
- Added `OS_EXTERNAL_BATCH`, `BATCH_PROVIDER`, `NOMAD_BATCH_JOB_NAME`, `NOMAD_BATCH_NAMESPACE`, `AWS_DEFAULT_REGION`, `AWS_BATCH_JOB_QUEUE`, and `AWS_BATCH_JOB_DEFINITION` env vars injected into the web task when `batch_engine != "internal"`.
- Added Nomad Workload Identity `identity` block to the web task when `batch_engine = "nomad_batch"`, providing a scoped short-lived `NOMAD_TOKEN` for API dispatch without static credentials.
- Added `policies/batch-dispatcher.hcl` — minimal ACL policy for the web Workload Identity (submit-job, dispatch-job, read-job, list-jobs only).
- Added `nomad-batch-engine` and `aws-batch-engine` scenarios to `scripts/test_nomad_pack_integration.sh`.

- Added `user-overrides.hcl` template at the repository root — a modeler-facing file containing only the variables energy modelers need to set (image version, worker count, port, job name), with rich inline comments.
- Added `examples/quickstart/simple.hcl` — a minimal, clean var-file for first-time modeler deployments.
- Added `docs/modelers/quickstart.md` — 3-step quickstart guide for energy modelers.
- Added `docs/modelers/submitting-osw-jobs.md` — guide for submitting OSW files, PAT projects, and REST API calls.
- Added `docs/modelers/README.md` and `docs/infrastructure/README.md` index pages routing users to the right documentation.
- Added `examples/README.md` routing energy modelers to `quickstart/` and admins to `advanced/`.

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
- `templates/worker.nomad.tpl` — wrapped job definition in `[[ if eq (var "batch_engine" .) "internal" ]]` guard; worker service job is omitted when using an external batch engine.
- `templates/rserve.nomad.tpl` — wrapped job definition in `[[ if eq (var "batch_engine" .) "internal" ]]` guard; Rserve service job is omitted when using an external batch engine.
- `policies/operator.hcl` — updated comment to reference batch-dispatcher use case.

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

- Updated `docs/storage.md` §5.1 NFS mount options: promoted `nfsvers=4.1`, increased `rsize`/`wsize` from 64 KiB to 1 MiB, replaced `sync`/`intr`/`timeo=14` with `hard,timeo=600,retrans=2,noresvport,_netdev` (Balanced profile); added §8 NFS Tuning for High Concurrency cross-reference to `nfs-tuning-guide.md` (#358).
- Updated `examples/openstack.hcl`: added inline Balanced-profile `/etc/fstab` snippet and mount option rationale comments for the NFS shared volume block (#358).

- Added `redis_config_tcp_keepalive` variable (default `60` s): passes `--tcp-keepalive` to the Redis container to prevent NAT/firewall dropping idle Resque connections during long-running background initialization steps.
- Added `redis_memory_max` variable (default `0`, disabled): exposes Nomad `memory_max` for the Redis task so operators can allow Redis to burst above its soft limit during mass-enqueue spikes without being OOM-killed.- Added `web_mongoid_pool_size` variable (default `10`): injects `MONGOID_POOL` into the `web` task so Passenger processes never stall waiting for a MongoDB connection; set equal to `MAX_POOL` for large deployments.
- Added `web_background_mongoid_pool_size` variable (default `0`, auto-derived as `web_background_worker_count + 2`): injects `MONGOID_POOL` into the `web-background` task so every Resque child can acquire a MongoDB connection immediately.
- Added `rserve_count` variable (default `1`): sets the number of Rserve task group allocations. Set to a higher value to run multiple Rserve replicas for fault tolerance. Each allocation registers independently in Consul; unhealthy replicas are automatically excluded from routing. See `docs/rserve-multi-replica.md`.
- Added `docs/rserve-multi-replica.md`: documents multi-replica Rserve routing via Consul DNS, health check/failover semantics, `rserve_spreads` configuration, and known limitations. (#361)

- Updated `web_background_worker_count` default from `6` to `8` to drain the `background` / `analyses` queues faster out-of-the-box.
- Updated `web_background_cpu` default from `250` MHz to `2000` MHz (8 workers × ~250 MHz each) and `web_background_memory` from `512` MB to `2048` MB (8 workers × ~256 MB each) to match the new default worker count; `web_background_memory_max` default updated from `0` (disabled) to `4096` MB (2× soft limit) to allow burst headroom.
- Updated `examples/openstack.hcl`: scaled `web_background_worker_count` from `42` to `56` (+33%) with proportional resource adjustments (`cpu` 12000→16000 MHz, `memory` 12288→16384 MB, `memory_max` 24576→32768 MB); added `redis_config_tcp_keepalive = 60`, `redis_memory_max = 24576` (1.5× redis_memory), `web_mongoid_pool_size = 154` (matching MAX_POOL), and `web_background_mongoid_pool_size = 58` (56 workers + 2 headroom).

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
