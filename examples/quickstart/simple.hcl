# Simple deployment — for energy modelers
#
# This is the recommended starting point if you are an energy modeler
# deploying OpenStudio Server for the first time.
#
# Usage:
#   nomad-pack run -var-file examples/quickstart/simple.hcl packs/openstudio-server
#
# To customize further (worker count, port, job name), copy user-overrides.hcl.example
# from the repository root and add your changes there.

# ------------------------------------------------------------
# OpenStudio Server version — update all four together
# ------------------------------------------------------------
web_image            = "nrel/openstudio-server:3.8.0"
web_background_image = "nrel/openstudio-server:3.8.0"
worker_image         = "nrel/openstudio-server:3.8.0"
rserve_image         = "nrel/openstudio-rserve:3.8.0"

# ------------------------------------------------------------
# Workers — how many parallel simulations to run at once
# ------------------------------------------------------------
worker_count = 2

# ------------------------------------------------------------
# Storage — ephemeral is fine for initial testing.
# For persistent data across restarts, ask your cluster admin
# to provision host volumes and switch to "host_volume" here.
# ------------------------------------------------------------
db_storage_type    = "ephemeral"
redis_storage_type = "ephemeral"

# ------------------------------------------------------------
# Security hardening — safe defaults for a trusted cluster
# ------------------------------------------------------------
vault_integration_enabled = false
vault_enabled             = false
enable_consul_connect     = false
