# Nomad ACL Policy Setup

This document describes the minimum ACL capabilities required to deploy and manage the OpenStudio Server Nomad Pack, provides ready-to-apply HCL policy files for three standard roles, and shows how to create policies and generate tokens.

## Prerequisites

ACL must be enabled on the Nomad cluster before applying policies:

```hcl
# server.hcl (Nomad server configuration)
acl {
  enabled = true
}
```

Bootstrap the ACL system once and save the management token:

```sh
nomad acl bootstrap
```

## Role Overview

| Role | HCL file | Purpose |
|------|----------|---------|
| `operator` | [`policies/operator.hcl`](../policies/operator.hcl) | Full deploy/stop/read — cluster operators running `nomad-pack run/stop` |
| `readonly` | [`policies/readonly.hcl`](../policies/readonly.hcl) | Status and log visibility — monitoring dashboards and support staff |
| `cicd` | [`policies/cicd.hcl`](../policies/cicd.hcl) | Minimal service token — automated pipelines that render, plan, run, and stop jobs |
| `teardown` | [`policies/teardown.hcl`](../policies/teardown.hcl) | Teardown-only token — stop lifecycle access for cleanup without deploy or exec privileges |

## Minimum Required Capabilities

All roles are scoped to the `openstudio` namespace (deny-all on `default`). At minimum, workload-facing roles require:

- `read-job` / `list-jobs` — enumerate and inspect pack jobs
- `agent: read`, `node: read` — resolve allocation placement

The `operator` role additionally requires `submit-job`, `alloc-lifecycle`, log/fs access, and optionally CSI/scaling capabilities. The `cicd` role is a subset of `operator` without log streaming or exec access.

## Applying Policies

Replace `<namespace>` if your cluster uses a namespace other than `openstudio`.

```sh
# Operator
nomad acl policy apply \
  -name operator \
  -description "OpenStudio Server operator role" \
  - < policies/operator.hcl

# Read-only
nomad acl policy apply \
  -name readonly \
  -description "OpenStudio Server read-only role" \
  - < policies/readonly.hcl

# CI/CD service token
nomad acl policy apply \
  -name cicd \
  -description "OpenStudio Server CI/CD service token role" \
  - < policies/cicd.hcl

# Teardown token
nomad acl policy apply \
  -name teardown \
  -description "OpenStudio Server teardown role" \
  - < policies/teardown.hcl
```

Verify the policies were registered:

```sh
nomad acl policy list
```

## Generating Tokens

Create a token bound to one or more policies and save the `SecretID` to a secure location:

```sh
# Operator token (interactive users)
nomad acl token create \
  -name "operator-token" \
  -policy operator

# Read-only token (monitoring / dashboards)
nomad acl token create \
  -name "readonly-token" \
  -policy readonly

# CI/CD service token (pipelines — set a TTL appropriate for your rotation policy)
nomad acl token create \
  -name "cicd-token" \
  -policy cicd \
  -ttl 8h
```

### Teardown Token

Use a dedicated teardown token for cleanup workflows instead of broad admin access:

```sh
nomad acl policy apply \
  -name teardown \
  -description "OpenStudio Server teardown role" \
  - < policies/teardown.hcl

nomad acl token create \
  -name "teardown-token" \
  -policy teardown
```

This is the least-privilege Nomad equivalent for teardown automation. Unlike the Helm `cluster-admin` ServiceAccount binding anti-pattern, it is namespace-scoped and uses `policy = "deny"` with an explicit allowlist of only `read-job`, `list-jobs`, and `alloc-lifecycle`. This ensures a teardown token cannot deploy new workloads (`submit-job`), dispatch parameterized jobs, or exec into containers.

Export the `SecretID` for use with the CLI or API:

```sh
export NOMAD_TOKEN="<SecretID>"
```

## Scoping Policies to a Specific Namespace

The HCL files in `policies/` default to the `openstudio` namespace. To target a different namespace, change the `namespace` block label **before** applying:

```hcl
# policies/operator.hcl (modified)
namespace "my-custom-namespace" {
  policy = "write"
  capabilities = [
    "submit-job",
    "read-job",
    "list-jobs",
    "read-logs",
    "alloc-lifecycle",
  ]
}
```

Then re-apply:

```sh
nomad acl policy apply \
  -name operator-custom-ns \
  -description "Operator role for my-custom-namespace" \
  - < policies/operator.hcl
```

## Verifying Token Permissions

```sh
nomad acl token self        # inspect the token currently in NOMAD_TOKEN
nomad acl token info <id>   # inspect any token by accessor ID
```

## Further Reading

- [Nomad ACL Overview](https://developer.hashicorp.com/nomad/tutorials/access-control/access-control)
- [Vault Policy Setup](vault-policies.md)
