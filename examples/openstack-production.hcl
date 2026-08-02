# OpenStack production deployment with Swift artifact storage
#
# Use this var-file as a starting point for deploying on OpenStack
# with Swift object storage for analysis artifacts.
#
# Usage:
#   nomad-pack run . --name openstudio-server -var-file examples/openstack-production.hcl

job_name   = "openstudio-server"
datacenters = ["dc1"]

# --- Images ---
web_image            = "nrel/openstudio-server:3.8.0"
web_background_image = "nrel/openstudio-server:3.8.0"
worker_image         = "nrel/openstudio-server:3.8.0"
rserve_image         = "nrel/openstudio-rserve:3.8.0"

# --- Resources (tune for your OpenStack flavors) ---
web_cpu        = 2000
web_memory     = 4096
worker_cpu     = 4000
worker_memory  = 8192
worker_count   = 3

# --- NFS shared volume (disable once Swift is validated) ---
# nfs_shared_volume_enabled = true
# nfs_volume_source         = "openstudio-nfs"
# nfs_volume_mount_path     = "/mnt/openstudio"

# --- Swift / Object-Storage artifact backend ---
# Uncomment this block after provisioning the Swift container.
# See docs/swift-artifact-backend.md for setup and migration guidance.
#
# swift_artifact_storage_enabled = true
# swift_auth_url                 = "https://keystone.example.com:5000/v3"
# swift_username                 = "openstudio-service"
# swift_password                 = ""   # inject via Vault (vault_integration_enabled = true)
# swift_tenant_name              = "openstudio"
# swift_container                = "openstudio-artifacts"
# swift_region                   = "RegionOne"
# swift_auth_version             = "3"

# --- Vault (recommended for credentials) ---
# vault_integration_enabled = true
# vault_kv_app_path         = "secret/data/openstudio/app"
# vault_kv_mongodb_path     = "secret/data/openstudio/mongo"
# vault_kv_redis_path       = "secret/data/openstudio/redis"
