# Nomad ACL Policy Setup

This document describes the minimum ACL capabilities required to deploy and manage the OpenStudio Server Nomad Pack, provides ready-to-apply HCL policy files for three standard roles, and shows how to create policies and generate tokens.

## Namespace Configuration

> ⚠️ **Read this before applying any policy.**

The policy files in `policies/` hardcode the namespace `"openstudio"`. The pack's `nomad_namespace` variable **defaults to `"default"`**. If you deployed to the `default` namespace (the quickstart default) and apply the policies without updating them, the tokens will grant permissions on the **wrong namespace** and will be completely ineffective for your jobs.

### Determine your deployment namespace

Check the namespace you used when deploying the pack:

```sh
# If you used the defaults, it is "default"
nomad namespace list
```

### Update all policy files to match

**Option A — sed one-liner** (fastest):

```sh
# Replace "openstudio" with your actual namespace in all four policy files
sed -i 's/namespace "openstudio"/namespace "YOUR_NAMESPACE"/g' policies/*.hcl

# Example: deploying to the default namespace
sed -i 's/namespace "openstudio"/namespace "default"/g' policies/*.hcl
```

> **macOS note:** BSD `sed` requires an empty string after `-i`: `sed -i '' 's/.../.../g' policies/*.hcl`

**Option B — helper script** (recommended for automation):

```sh
# Apply all policies for a given namespace in one step
bash scripts/apply-acl-policies.sh --namespace default

# Preview what would be applied without touching the cluster
bash scripts/apply-acl-policies.sh --namespace default --dry-run

# Apply only specific roles
bash scripts/apply-acl-policies.sh --namespace default --roles operator,cicd
```

The helper script substitutes the namespace at apply-time and never modifies the source files.

### Why policies use `"openstudio"` as the default

The `"openstudio"` namespace is the recommended production namespace for this pack. The pack's `nomad_namespace` variable defaults to `"default"` for quickstart convenience, but production deployments should use a dedicated namespace. See the [Getting Started guide](getting-started-single-node.md) for namespace creation steps.

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

All roles are scoped to the `openstudio` namespace by default (deny-all on `default`). **Update the namespace label to match your deployment before applying** — see [Namespace Configuration](#namespace-configuration) above. At minimum, workload-facing roles require:

- `read-job` / `list-jobs` — enumerate and inspect pack jobs
- `agent: read`, `node: read` — resolve allocation placement

The `operator` role additionally requires `submit-job`, `alloc-lifecycle`, log/fs access, and optionally CSI/scaling capabilities. The `cicd` role is a subset of `operator` without log streaming or exec access.

## Applying Policies

> ⚠️ **Ensure the namespace in the policy files matches your deployment namespace before running these commands.** See [Namespace Configuration](#namespace-configuration) above, or use `bash scripts/apply-acl-policies.sh --namespace <your-namespace>` to handle the substitution automatically.

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

The HCL files in `policies/` default to the `openstudio` namespace. Use the helper script or the `sed` one-liner described in [Namespace Configuration](#namespace-configuration) to update all files at once. Alternatively, change the `namespace` block label manually in a single file:

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
