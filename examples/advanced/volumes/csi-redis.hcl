# CSI Volume spec for Redis persistent storage on OpenStack.
#
# Register idempotently with:
#   nomad volume create examples/advanced/volumes/csi-redis.hcl
#
# See csi-mongodb.hcl for full instructions and topology guidance.

id        = "openstudio-redis"
name      = "openstudio-redis"
type      = "csi"
plugin_id = "hostpath-web-plugin0"    # override with REDIS_CSI_PLUGIN_ID

capacity_min = "1GiB"
capacity_max = "5GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

# See csi-mongodb.hcl topology_request comment for guidance on the segment value.
topology_request {
  required {
    topology { segments { "topology.hostpath.csi/node" = "" } }
  }
}
