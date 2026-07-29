# Nomad ACL Policy: cicd
#
# Role: Minimal permissions for a CI/CD service token.
# Allows rendering, planning, running, and stopping jobs in the configured
# deployment namespace. Also grants agent and node read, which Nomad requires
# for job placement and planning. Does not grant log streaming, exec, or
# access to namespaces other than the one configured below.
#
# Namespace defaults to "default" to match the pack default. If your
# deployment uses a different namespace, change the label below or use:
#   bash scripts/apply-acl-policies.sh --namespace <your-namespace>
#
# Apply with:
#   nomad acl policy apply \
#     -name cicd \
#     -description "OpenStudio Server CI/CD service token role" \
#     - < policies/cicd.hcl

namespace "default" {
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
