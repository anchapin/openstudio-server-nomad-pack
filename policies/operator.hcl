# Nomad ACL Policy: operator
#
# Role: Full deploy/stop/read permissions for the OpenStudio Server pack.
# Grants the ability to run, stop, inspect jobs, and tail allocation logs.
# Intended for cluster operators managing OpenStudio Server deployments.
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
#     -name operator \
#     -description "OpenStudio Server operator role" \
#     - < policies/operator.hcl

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
