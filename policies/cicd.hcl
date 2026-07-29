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
# ║  This file uses the placeholder OPENSTUDIO_NAMESPACE.                  ║
# ║  Replace it with your actual deployment namespace before applying.     ║
# ║  The pack's nomad_namespace variable defaults to "default".            ║
# ║                                                                        ║
# ║  One-liner (single file):                                              ║
# ║    sed 's/OPENSTUDIO_NAMESPACE/myns/g' policies/cicd.hcl \            ║
# ║      | nomad acl policy apply -name cicd \                            ║
# ║          -description "OpenStudio Server CI/CD service token role" -   ║
# ║                                                                        ║
# ║  Or use the helper script for all policy files at once:               ║
# ║    bash scripts/apply-acl-policies.sh --namespace myns                 ║
# ║                                                                        ║
# ║  See docs/acl-policies.md § "Namespace Configuration" for details.    ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# Apply with:
#   sed 's/OPENSTUDIO_NAMESPACE/<your-namespace>/g' policies/cicd.hcl \
#     | nomad acl policy apply \
#         -name cicd \
#         -description "OpenStudio Server CI/CD service token role" \
#         -

namespace "OPENSTUDIO_NAMESPACE" {
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
