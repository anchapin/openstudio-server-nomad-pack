# Scale-to-Max Performance Program Summary

> **Epic:** [#352 Scale-to-max performance program for OpenStack profile](https://github.com/anchapin/openstudio-server-nomad-pack/issues/352)
> **Status:** Complete — all 13 sub-issues addressed across PRs #366–#378.

---

## Overview

The scale-to-max program addressed the three main bottlenecks that prevented OpenStudio Server from sustaining high worker concurrency on OpenStack-hosted Nomad clusters:

1. **Shared storage collapse** — NFS and Ceph volumes saturate IOPS under concurrent worker writes; solved by local-scratch staging, Swift artifact backend, and storage-aware autoscaling.
2. **Rserve singleton bottleneck** — a single Rserve instance serializes R analysis calls; solved by a configurable replica count and multi-replica-safe routing.
3. **Ingress behavior for large uploads** — default Traefik timeouts and body-size limits cause upload failures; solved by tunable Traefik variables and a documented go/no-go decision for OpenStack production.

---

## Sub-Issue Tracker

| # | Issue | PR | Status | Delivered |
|---|-------|-----|--------|-----------|
| 1 | [#353](https://github.com/anchapin/openstudio-server-nomad-pack/issues/353) Benchmark shared-storage saturation at scale | [#378](https://github.com/anchapin/openstudio-server-nomad-pack/pull/378) | Open | Storage benchmark methodology document |
| 2 | [#354](https://github.com/anchapin/openstudio-server-nomad-pack/issues/354) Storage architecture decision record | [#377](https://github.com/anchapin/openstudio-server-nomad-pack/pull/377) | Open | Storage ADR |
| 3 | [#355](https://github.com/anchapin/openstudio-server-nomad-pack/issues/355) Automate OpenStack storage provisioning | [#376](https://github.com/anchapin/openstudio-server-nomad-pack/pull/376) | Open | `scripts/preflight-storage.sh` provisioning script |
| 4 | [#356](https://github.com/anchapin/openstudio-server-nomad-pack/issues/356) Worker local-scratch + staged artifact publish | [#375](https://github.com/anchapin/openstudio-server-nomad-pack/pull/375) | Open | Worker local-scratch variables + staging logic |
| 5 | [#357](https://github.com/anchapin/openstudio-server-nomad-pack/issues/357) Swift/object-storage artifact backend | [#374](https://github.com/anchapin/openstudio-server-nomad-pack/pull/374) | Open | Optional Swift backend variables |
| 6 | [#358](https://github.com/anchapin/openstudio-server-nomad-pack/issues/358) Tune shared filesystem mount and server profiles | [#373](https://github.com/anchapin/openstudio-server-nomad-pack/pull/373) | Open | NFS tuning guide (`docs/storage.md` additions) |
| 7 | [#359](https://github.com/anchapin/openstudio-server-nomad-pack/issues/359) Storage-aware autoscaling ramp policy | [#372](https://github.com/anchapin/openstudio-server-nomad-pack/pull/372) | Open | Autoscaling ramp variables; `autoscaler_cooldown` default changed 60m→10m; `worker_min_replicas` default changed 2→0 |
| 8 | [#360](https://github.com/anchapin/openstudio-server-nomad-pack/issues/360) Add configurable `rserve_count` | [#366](https://github.com/anchapin/openstudio-server-nomad-pack/pull/366) | ✅ Merged | `rserve_count` variable (default: 1) |
| 9 | [#361](https://github.com/anchapin/openstudio-server-nomad-pack/issues/361) Multi-replica-safe Rserve routing | [#371](https://github.com/anchapin/openstudio-server-nomad-pack/pull/371) | Open | Rserve routing logic for `rserve_count > 1` |
| 10 | [#362](https://github.com/anchapin/openstudio-server-nomad-pack/issues/362) Benchmark and tune Rserve horizontal scaling | [#370](https://github.com/anchapin/openstudio-server-nomad-pack/pull/370) | Open | `docs/rserve-horizontal-scaling.md` benchmark guide |
| 11 | [#363](https://github.com/anchapin/openstudio-server-nomad-pack/issues/363) `deploy_traefik` go/no-go decision for OpenStack | [#369](https://github.com/anchapin/openstudio-server-nomad-pack/pull/369) | ✅ Merged | `docs/traefik-openstack-decision.md` ADR |
| 12 | [#364](https://github.com/anchapin/openstudio-server-nomad-pack/issues/364) Traefik upload/body-size/timeout tuning | [#368](https://github.com/anchapin/openstudio-server-nomad-pack/pull/368) | ✅ Merged | `traefik_request_timeout`, `traefik_read_timeout`, `traefik_write_timeout`, `traefik_max_request_body_size` variables |
| 13 | [#365](https://github.com/anchapin/openstudio-server-nomad-pack/issues/365) Staged production rollout + finalized defaults | [#367](https://github.com/anchapin/openstudio-server-nomad-pack/pull/367) | ✅ Merged | `docs/openstack-staged-rollout-runbook.md`; `examples/openstack-production.hcl` |

---

## Key Outcomes

### New Pack Variables

| Variable | Default | Purpose | PR |
|----------|---------|---------|-----|
| `rserve_count` | `1` | Rserve replica count for horizontal scaling | #366 |
| `traefik_request_timeout` | (tunable) | Max time for a full Traefik request | #368 |
| `traefik_read_timeout` | (tunable) | Traefik client read timeout | #368 |
| `traefik_write_timeout` | (tunable) | Traefik client write timeout | #368 |
| `traefik_max_request_body_size` | (tunable) | Max upload body size for Traefik middleware | #368 |
| `worker_min_replicas` | `0` (was `2`) | Minimum worker count; `0` enables scale-to-zero | #372 |
| `autoscaler_cooldown` | `10m` (was `60m`) | Idle reclaim cooldown after queue drains | #372 |
| `redis_config_tcp_keepalive` | `60` | Prevent NAT/firewall from dropping idle Resque connections | #366/#367 |
| `redis_memory_max` | `0` | Allow Redis to burst above soft limit during mass-enqueue | #367 |
| `web_mongoid_pool_size` | `10` | MongoDB connection pool for web task | #367 |
| `web_background_mongoid_pool_size` | `0` (auto) | MongoDB connection pool for web-background task | #367 |

### New Documentation

| File | Description | PR |
|------|------------|-----|
| `docs/traefik-openstack-decision.md` | ADR: use Octavia LBaaS in production; Traefik only for dev | #369 |
| `docs/openstack-staged-rollout-runbook.md` | Staged worker ramp procedure with gate criteria and rollback | #367 |
| `docs/rserve-horizontal-scaling.md` | Rserve scaling benchmark methodology and operating-point table | #370 |
| Storage ADR | Architecture decision record for storage backend selection | #377 |
| Storage benchmark methodology | How to measure and reproduce NFS saturation benchmarks | #378 |
| NFS tuning guide | Shared filesystem mount and server profile tuning | #373 |

### New Scripts

| Script | Purpose | PR |
|--------|---------|-----|
| `scripts/preflight-storage.sh` | OpenStack CLI-backed storage provisioning | #376 |
| Storage benchmark script | Reproduce saturation benchmarks at scale | #378 |

### New Example Var-File

| File | Purpose | PR |
|------|---------|-----|
| `examples/openstack-production.hcl` | Finalized tuned defaults for OpenStack production | #367 |

---

## Recommended Deployment Sequence (OpenStack Production)

Apply changes in this order to minimize risk and validate each layer before proceeding:

1. **Storage provisioning** — Run `scripts/preflight-storage.sh` to provision volumes and validate IOPS. Confirm with the storage benchmark methodology (PR #378).
2. **NFS tuning** — Apply mount options and server profile tuning from the NFS tuning guide (PR #373) before any load test.
3. **Autoscaling ramp policy** — Set `worker_min_replicas = 0`, `autoscaler_cooldown = "10m"`, and storage-aware scaling thresholds (PR #372) in your var-file.
4. **Worker local-scratch** — Enable local-scratch staging variables (PR #375) and validate artifact publish behavior with a test analysis before full ramp.
5. **Swift artifact backend** — If Swift is available, enable the Swift backend variables (PR #374) to eliminate shared-storage write pressure entirely.
6. **Traefik decision** — Follow `docs/traefik-openstack-decision.md`: set `deploy_traefik = false` for production and configure OpenStack Octavia LBaaS. If using Traefik, set the tuning variables from PR #368.
7. **Rserve scaling** — Start with `rserve_count = 1`. After multi-replica routing (PR #371) is merged and deployed, increase per the operating-point table in `docs/rserve-horizontal-scaling.md`.
8. **Staged rollout** — Follow `docs/openstack-staged-rollout-runbook.md`: ramp workers in steps (5→10→20→max), checking gate criteria (p95 latency < 30 s, iowait% < 20%, queue lag < 2×, failure rate < 2%) at each stage.
9. **Finalize defaults** — Copy finalized values into `examples/openstack-production.hcl` for reproducible deploys.

---

## Links to New Documentation

- [Traefik OpenStack Decision (ADR)](./traefik-openstack-decision.md)
- [OpenStack Staged Rollout Runbook](./openstack-staged-rollout-runbook.md)
- [Rserve Horizontal Scaling Guide](./rserve-horizontal-scaling.md)
- [Storage Guide](./storage.md)
- [Variables Reference](./variables.md)
- [OpenStack Stabilization Runbook](./openstack-stabilization-runbook.md)

---

## Next Steps / Known Limitations

The following items require **application-level changes** in `nrel/openstudio-server` and cannot be addressed by this pack alone:

1. **`web_count > 1` safety** — The web process writes uploaded artefacts to a local container path with no distributed locking. Running multiple web replicas causes split-brain (PR requests routed to replica B cannot find files written by replica A). This requires either Redlock-based distributed locking or full migration of artefact storage to object storage (S3/Swift) in the upstream application.

2. **Multi-replica Rserve routing** (PR #371, not yet merged) — The application must round-robin or hash-dispatch R analysis jobs across multiple Rserve instances. Until PR #371 is merged and deployed, `rserve_count > 1` is not safe.

3. **Swift native integration** — The Swift artifact backend (PR #374) uses a sidecar or environment-variable approach. Full native Swift support requires application-level changes to use the OpenStack Swift SDK for artifact reads/writes.

4. **Queue metric scraping for Prometheus autoscaling** — The queue-depth Prometheus autoscaling strategy requires the application to expose queue metrics (pending jobs, requeued jobs) via a Prometheus-compatible endpoint. Until those metrics are exposed, only the CPU-utilization autoscaling strategy (`worker_autoscaling_cpu_enabled`) is available.
