# Nomad ACL Policy: cicd
#
# Role: Minimal permissions for a CI/CD service token.
# Allows rendering, planning, running, and stopping jobs matching the
# OpenStudio Server job name. Does not grant access to other namespaces,
# agent details, or log streaming.
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
