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
