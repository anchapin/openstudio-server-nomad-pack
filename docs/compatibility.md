# Compatibility Matrix

This matrix documents known-good version combinations for this Nomad pack.

| Pack Version | OpenStudio Server (`app_version`) | Nomad ≥ | Consul ≥ | Notes |
|---|---|---|---|---|
| `0.2.68` | `3.11.0` | `1.7.0` | `1.12.0` | Upcoming release; worker group consolidated into `web.nomad.tpl` (#405) requires per-group `update` stanzas (Nomad ≥ 1.7.0). |
| `0.2.67` | `3.11.0` | `1.4.0` | `1.12.0` | Current release; `web_image` pinned to `nrel/openstudio-server:179-flock`. CI uses Nomad `1.7.7`. |
| `0.2.66` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.65` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.64` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.63` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.62` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.61` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.60` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.59` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.58` | `3.11.0` | `1.4.0` | `1.12.0` | |
| `0.2.57` | `3.11.0` | `1.4.0` | `1.12.0` | `web_image` pinned to `nrel/openstudio-server:179-flock` starting this release. |
| `0.2.56` | `latest` | `1.4.0` | `1.12.0` | `web_image` default was `nrel/openstudio-server:latest`. |
| `0.2.55` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.54` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.53` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.52` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.51` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.50` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.49` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.48` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.47` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.46` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.45` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.44` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.43` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.42` | `latest` | `1.4.0` | `1.12.0` | |
| `0.2.41` | `3.8.0-1` | `1.4.0` | `1.12.0` | Aligns with the Helm chart `Chart.yaml` `appVersion`. CI uses Nomad `1.7.7` (`NOMAD_VERSION` in integration-test.yml). |
| `0.1.0` | `3.6.1` | `1.4.0` | `1.12.0` | Initial release baseline; OpenStudio Server value comes from `CHANGELOG.md`. |

## Maintenance

Update this table whenever a new pack version is released or when supported OpenStudio Server, Nomad, or Consul versions change.

A CI step in `pack-validation.yml` (`Check compatibility.md is up-to-date`) enforces:
- for most runs: a row must exist for the current `pack.version` in `metadata.hcl`
- for pull requests targeting `main`: a row must exist for the upcoming release version (`pack.version` + patch)

This avoids release-process drift caused by the automated `main` version bump.
