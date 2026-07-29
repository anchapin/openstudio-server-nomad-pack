# Nomad ACL Policy: operator
#
# Role: Full deploy/stop/read permissions for the OpenStudio Server pack.
# Grants the ability to run, stop, inspect jobs, and tail allocation logs.
# Intended for cluster operators managing OpenStudio Server deployments.
#
# Namespace defaults to "default" to match the pack default. If your
# deployment uses a different namespace, change the label below or use:
#   bash scripts/apply-acl-policies.sh --namespace <your-namespace>
#
# Apply with:
#   nomad acl policy apply \
#     -name operator \
#     -description "OpenStudio Server operator role" \
#     - < policies/operator.hcl

namespace "default" {
  policy = "write"
  capabilities = [
    "submit-job",
    "dispatch-job",
    "read-job",
    "list-jobs",
    "read-logs",
    "read-fs",
    "alloc-exec",
    "alloc-node-exec",
    "alloc-lifecycle",
    "csi-write-volume",
    "csi-read-volume",
    "list-scaling-policies",
    "read-scaling-policy",
    "scale-job",
    "sentinel-override",
  ]
}

agent {
  policy = "read"
}

node {
  policy = "read"
}
