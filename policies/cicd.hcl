# Nomad ACL Policy: cicd
#
# Role: Minimal permissions for a CI/CD service token.
# Allows rendering, planning, running, and stopping jobs matching the
# OpenStudio Server job name. Does not grant access to other namespaces,
# agent details, or log streaming.
#
# Apply with:
#   nomad acl policy apply \
#     -name cicd \
#     -description "OpenStudio Server CI/CD service token role" \
#     - < policies/cicd.hcl

namespace "default" {
  policy = "deny"
}

namespace "openstudio" {
  policy = "write"
  capabilities = [
    "submit-job",
    "dispatch-job",
    "read-job",
    "list-jobs",
    "alloc-lifecycle",
  ]
}

agent {
  policy = "read"
}

node {
  policy = "read"
}
