# Nomad ACL Policy: batch-dispatcher
#
# Role: Scoped dispatch permissions for the OpenStudio Server web container
# Workload Identity when batch_engine = "nomad_batch".
#
# The web task receives a short-lived Nomad Workload Identity token (via the
# `identity` block in web.nomad.tpl).  That token must be backed by a policy
# that allows it to dispatch parameterized batch simulation jobs.
#
# This policy intentionally grants minimal rights:
#   - submit-job / dispatch-job: send simulation jobs to the batch namespace
#   - read-job: poll dispatch status and retrieve allocation IDs
#   - list-jobs: list parameterized job allocations
#
# It does NOT grant read-logs, alloc-exec, or any write operations beyond
# job dispatch.  Mount as a separate token policy so the Workload Identity
# cannot be escalated to full operator rights.
#
# Namespace defaults to "default".  Override for a dedicated batch namespace:
#   bash scripts/apply-acl-policies.sh --namespace batch
#
# Apply with:
#   nomad acl policy apply \
#     -name batch-dispatcher \
#     -description "OpenStudio Server web Workload Identity — batch dispatch" \
#     - < policies/batch-dispatcher.hcl

namespace "default" {
  capabilities = [
    "submit-job",
    "dispatch-job",
    "read-job",
    "list-jobs",
  ]
}

agent {
  policy = "read"
}

node {
  policy = "read"
}
