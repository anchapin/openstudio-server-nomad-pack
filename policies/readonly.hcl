# Nomad ACL Policy: readonly
#
# Role: Read-only access for monitoring dashboards and support staff.
# Grants visibility into job status, allocation status, and logs without
# the ability to submit or modify any workloads.
#
# Apply with:
#   nomad acl policy apply \
#     -name readonly \
#     -description "OpenStudio Server read-only role" \
#     - < policies/readonly.hcl

namespace "default" {
  policy = "deny"
}

namespace "openstudio" {
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
