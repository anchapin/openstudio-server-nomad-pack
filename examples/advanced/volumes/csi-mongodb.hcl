# CSI Volume spec for MongoDB persistent storage on OpenStack.
#
# Register idempotently with:
#   nomad volume create examples/advanced/volumes/csi-mongodb.hcl
#
# If the volume already exists with a different plugin, deregister first:
#   nomad volume deregister openstudio-mongodb
#   nomad volume create examples/advanced/volumes/csi-mongodb.hcl
#
# Plugin ID must match the CSI plugin deployed for the node class that will
# host the DB job.  On NREL aurora-179d this is a role-scoped hostpath plugin
# (e.g. hostpath-web-plugin0).  Set DB_CSI_PLUGIN_ID in your environment or
# override the plugin_id field below before registering.
#
# Topology: the "hostname" segment is resolved by preflight-storage.sh and
# inject into the volume registration.  When registering manually, replace
# "<web-node-hostname>" with the output of:
#   nomad node status -json | python3 -c '
#     import json,sys
#     for n in json.load(sys.stdin):
#         meta = n.get("Meta") or {}
#         if meta.get("node_role") == "web":
#             print(n.get("Name",""))
#   ' | head -1

id        = "openstudio-mongodb"
name      = "openstudio-mongodb"
type      = "csi"
plugin_id = "hostpath-web-plugin0"    # override with DB_CSI_PLUGIN_ID

capacity_min = "10GiB"
capacity_max = "50GiB"

capability {
  access_mode     = "single-node-writer"
  attachment_mode = "file-system"
}

# Topology constraint — ensures the volume is only accessible (and only
# scheduled) on the node where the CSI plugin node component is running.
# Replace the hostname value with the output of:
#   nomad volume status -json openstudio-mongodb | python3 -c '
#     import json,sys; d=json.load(sys.stdin)
#     for t in (d.get("Topologies") or []):
#         for k,v in (t.get("Segments") or {}).items(): print(k,"=",v)
#   '
#
# This field is populated automatically by scripts/preflight-storage.sh
# when run with --create-missing-csi.  Do not hand-edit topology after
# volume creation — changing it requires deregister + recreate.
topology_request {
  required {
    topology { segments { "topology.hostpath.csi/node" = "" } }
  }
}
