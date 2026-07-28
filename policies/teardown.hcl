# Nomad ACL Policy: teardown
#
# Role: Minimal-privilege teardown token for OpenStudio Server cleanup jobs.
# This policy intentionally avoids broad cluster control and only allows:
# - reading/listing jobs in the openstudio namespace
# - allocation lifecycle actions (stop)
#
# Security rationale:
# The Helm chart equivalent used a cluster-admin ClusterRoleBinding for NFS
# disconnect cleanup, which is an anti-pattern. This Nomad policy closes that
# RBAC parity gap with namespace-scoped least privilege.
#
# Apply with:
#   nomad acl policy apply \
#     -name teardown \
#     -description "OpenStudio Server teardown role" \
#     - < policies/teardown.hcl

namespace "default" {
  policy = "deny"
}

namespace "openstudio" {
  policy = "deny"
  capabilities = [
    "read-job",
    "list-jobs",
    "alloc-lifecycle",
  ]
}
