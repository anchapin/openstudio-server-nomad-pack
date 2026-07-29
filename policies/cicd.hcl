# Nomad ACL Policy: cicd
#
# Role: Minimal permissions for a CI/CD service token.
# Allows rendering, planning, running, and stopping jobs in the configured
# deployment namespace. Also grants agent and node read, which Nomad requires
# for job placement and planning. Does not grant log streaming, exec, or
# access to namespaces other than the one configured below.
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
