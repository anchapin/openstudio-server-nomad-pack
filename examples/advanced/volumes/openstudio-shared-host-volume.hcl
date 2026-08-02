# Single-node deployments can skip shared NFS entirely:
# nfs_shared_volume_enabled = false

# ------------------------------------------------------------------------------
# 1) fstab entry: mount the shared NFS export on every eligible Nomad client
# ------------------------------------------------------------------------------
# /etc/fstab
# <nfs-host>:/exports/openstudio /mnt/openstudio nfs nfsvers=4,sync,hard,intr 0 0

# ------------------------------------------------------------------------------
# 2) Nomad client.hcl stanza: register host_volume name used by nfs_volume_source
# ------------------------------------------------------------------------------
client {
  enabled = true

  host_volume "openstudio-nfs" {
    path      = "/mnt/openstudio"
    read_only = false
  }
}

# ------------------------------------------------------------------------------
# 3) Pack override snippet: enable shared mount in web/worker task groups
# ------------------------------------------------------------------------------
# override.hcl
nfs_shared_volume_enabled = true
nfs_volume_source         = "openstudio-nfs"
nfs_volume_mount_path     = "/mnt/openstudio"
