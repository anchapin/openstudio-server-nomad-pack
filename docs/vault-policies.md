# Vault Policy Setup

This document covers the Vault policies required by the OpenStudio Server Nomad Pack, how to enable the Vault–Nomad integration, KV v2 secret path conventions, token TTL guidance, and differences between Nomad ≥ 1.7 and earlier Vault stanza syntax.

## KV v2 Secret Path Conventions

The pack reads secrets from the following default paths (set by `variables.hcl`). All paths are under the KV v2 `secret/` mount.

| Variable | Default path | Contents |
|----------|-------------|---------|
| `vault_kv_mongodb_path` | `secret/data/openstudio/mongodb` | MongoDB `password` key |
| `vault_kv_redis_path` | `secret/data/openstudio/redis` | Redis `password` key |
| `vault_kv_app_path` | `secret/data/openstudio/app` | App `secret_key_base` key |
| `vault_mongo_secret_path` | `secret/data/openstudio/mongodb` | Legacy: MongoDB `username` and `password` keys (used by `enable_vault_mongo_secrets`) |

Write the MongoDB secret before deploying:

```sh
vault kv put secret/openstudio/mongodb \
  username="openstudio" \
  password="changeme"
```

Verify:

```sh
vault kv get secret/openstudio/mongodb
```

## Vault Policies

### MongoDB Policy (`openstudio-mongodb`)

Grants read-only access to the MongoDB credentials path:

```hcl
# vault-policies/openstudio-mongodb.hcl
path "secret/data/openstudio/mongodb" {
  capabilities = ["read"]
}

path "secret/metadata/openstudio/mongodb" {
  capabilities = ["read", "list"]
}
```

Apply:

```sh
vault policy write openstudio-mongodb vault-policies/openstudio-mongodb.hcl
```

### Web / Web-Background Policy (`openstudio-web`)

Grants access to paths consumed by the `web` and `web-background` tasks:

```hcl
# vault-policies/openstudio-web.hcl
path "secret/data/openstudio/app" {
  capabilities = ["read"]
}

path "secret/metadata/openstudio/app" {
  capabilities = ["read", "list"]
}
```

Apply:

```sh
vault policy write openstudio-web vault-policies/openstudio-web.hcl
```

### Worker Policy (`openstudio-worker`)

Grants access to paths consumed by the worker task:

```hcl
# vault-policies/openstudio-worker.hcl
path "secret/data/openstudio/app" {
  capabilities = ["read"]
}

path "secret/data/openstudio/redis" {
  capabilities = ["read"]
}

path "secret/metadata/openstudio/*" {
  capabilities = ["read", "list"]
}
```

Apply:

```sh
vault policy write openstudio-worker vault-policies/openstudio-worker.hcl
```

## Enabling the Nomad Secrets Engine in Vault

The Nomad secrets engine lets Vault generate short-lived Nomad ACL tokens on demand.

```sh
# Enable the Nomad secrets engine
vault secrets enable nomad

# Configure the Vault → Nomad connection
vault write nomad/config/access \
  address="http://<NOMAD_ADDR>:4646" \
  token="<NOMAD_MANAGEMENT_TOKEN>"

# Create a Vault role backed by the cicd Nomad policy
vault write nomad/role/cicd \
  policies="cicd" \
  type="client" \
  ttl="8h" \
  max_ttl="24h"
```

Generate a Nomad token through Vault:

```sh
vault read nomad/creds/cicd
```

## Configuring the Nomad ↔ Vault Integration

Nomad must be configured to trust your Vault cluster before task-level `vault` blocks will work.

```hcl
# nomad-server.hcl
vault {
  enabled          = true
  address          = "http://vault.service.consul:8200"
  task_token_ttl   = "1h"
  create_from_role = "nomad-cluster"   # Vault role used to create child tokens
}
```

Create the `nomad-cluster` Vault role (token role, not AppRole):

```sh
vault write /auth/token/roles/nomad-cluster \
  allowed_policies="openstudio-mongodb,openstudio-web,openstudio-worker" \
  explicit_max_ttl=0 \
  name="nomad-cluster" \
  orphan=true \
  period="259200" \
  renewable=true
```

## Nomad `vault` Block Syntax

### Nomad ≥ 1.7 (labeled `vault` block with `cluster`)

```hcl
job "openstudio" {
  vault "default" {
    cluster = "default"  # matches vault stanza in nomad agent config
  }

  group "web" {
    task "web" {
      vault {
        role    = "openstudio-web"
        env     = true
        change_mode   = "restart"
        change_signal = "SIGHUP"
        policies = ["openstudio-web"]
      }
    }
  }
}
```

### Nomad < 1.7 (legacy `vault` stanza)

```hcl
job "openstudio" {
  group "web" {
    task "web" {
      vault {
        policies      = ["openstudio-web"]
        change_mode   = "restart"
        change_signal = "SIGHUP"
        env           = true
      }
    }
  }
}
```

This pack controls these fields through the following variables:

| Variable | Maps to |
|----------|---------|
| `vault_integration_enabled` | Whether to render KV secret templates (`secrets/env`) for app credentials |
| `vault_enabled` | Whether to render explicit role-based `vault` blocks |
| `vault_default_role` | `role` for all tasks (Nomad ≥ 1.7) |
| `vault_db_role` | `role` override for MongoDB task |
| `vault_redis_role` | `role` override for Redis task |
| `vault_rserve_role` | `role` override for Rserve task |
| `vault_vector_role` | `role` override for Vector sidecar |
| `vault_policies` | Additional `policies` appended to every token |
| `vault_namespace` | Vault Enterprise namespace |
| `vault_change_mode` | `change_mode` (`restart`/`noop`/`signal`) |
| `vault_change_signal` | Signal used when `change_mode = "signal"` |
| `vault_env` | Expose Vault token in task environment |

> For most production deployments, set both `vault_integration_enabled = true` and `vault_enabled = true`.
> If `vault_integration_enabled = true` but `vault_enabled = false`, the pack uses `vault_policy`
> as a fallback policy-only `vault` block so templates can still read KV secrets.

## Token TTL and Renewal Recommendations

| Token type | Recommended TTL | Renewal |
|------------|----------------|---------|
| Nomad task tokens (short-lived workloads) | `1h` | Nomad renews automatically via `task_token_ttl` |
| Nomad task tokens (long-running services) | `72h` with `period` | Set `period` on the token role so Vault auto-renews |
| Nomad secrets engine credentials | `8h` max TTL `24h` | Rotate via CI/CD or Vault agent |
| Human operator tokens | `24h` | Require re-authentication daily |

Configure the Nomad agent's `task_token_ttl` to be shorter than the Vault token's `max_ttl` so that Nomad has time to renew before expiry. For long-running services, prefer a periodic token role over a hard-expiry TTL.

```hcl
# nomad-server.hcl
vault {
  enabled        = true
  address        = "http://vault.service.consul:8200"
  task_token_ttl = "1h"
}
```

## Further Reading

- [Vault KV v2 Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2)
- [Nomad Vault Integration](https://developer.hashicorp.com/nomad/docs/integrations/vault)
- [Vault Nomad Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/nomad)
- [Nomad ACL Policy Setup](acl-policies.md)
