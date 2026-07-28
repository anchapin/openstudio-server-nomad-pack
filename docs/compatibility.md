# Compatibility Matrix

This matrix documents known-good version combinations for this Nomad pack.

| Pack Version | OpenStudio Server (`app_version`) | Nomad ≥ | Consul ≥ | Notes |
|---|---|---|---|---|
| `0.2.41` | `3.8.0-1` | `1.4.0` | `1.12.0` | Current release; aligns with the Helm chart `Chart.yaml` `appVersion`. |
| `0.1.0` | `3.6.1` | `1.4.0` | `1.12.0` | Initial release baseline; OpenStudio Server value comes from `CHANGELOG.md`. |

## Maintenance

Update this table whenever a new pack version is released or when supported OpenStudio Server, Nomad, or Consul versions change.
