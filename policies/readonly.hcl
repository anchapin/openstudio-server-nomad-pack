# Nomad ACL Policy: readonly
#
# Role: Read-only access for monitoring dashboards and support staff.
# Grants visibility into job status, allocation status, and logs without
# the ability to submit or modify any workloads.
#
# Namespace defaults to "default" to match the pack default. If your
# deployment uses a different namespace, change the label below or use:
#   bash scripts/apply-acl-policies.sh --namespace <your-namespace>
#
# Apply with:
#   nomad acl policy apply \
#     -name readonly \
#     -description "OpenStudio Server read-only role" \
#     - < policies/readonly.hcl

namespace "default" {
  policy = "read"
  capabilities = [
    "read-job",
    "list-jobs",
    "read-logs",
    "read-fs",
    "list-scaling-policies",
    "read-scaling-policy",
  ]
}

agent {
  policy = "read"
}

node {
  policy = "read"
}
