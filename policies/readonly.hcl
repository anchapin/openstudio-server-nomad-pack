# Nomad ACL Policy: readonly
#
# Role: Read-only access for monitoring dashboards and support staff.
# Grants visibility into job status, allocation status, and logs without
# the ability to submit or modify any workloads.
#
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  NAMESPACE CONFIGURATION — READ BEFORE APPLYING                        ║
# ║                                                                        ║
# ║  This file targets namespace "openstudio".                             ║
# ║  The pack's nomad_namespace variable defaults to "default".            ║
# ║                                                                        ║
# ║  If you deployed to "default" (or any namespace other than             ║
# ║  "openstudio"), applying this policy as-is grants access to the        ║
# ║  WRONG namespace — the token will be a no-op for your jobs.            ║
# ║                                                                        ║
# ║  Fix: replace "openstudio" with your actual deployment namespace       ║
# ║  before applying. One-liner for all four policy files:                 ║
# ║                                                                        ║
# ║    sed -i 's/namespace "openstudio"/namespace "default"/g' \           ║
# ║      policies/*.hcl                                                    ║
# ║                                                                        ║
# ║  Or use the helper script:                                             ║
# ║    bash scripts/apply-acl-policies.sh --namespace default              ║
# ║                                                                        ║
# ║  See docs/acl-policies.md § "Namespace Configuration" for details.    ║
# ╚══════════════════════════════════════════════════════════════════════════╝
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
