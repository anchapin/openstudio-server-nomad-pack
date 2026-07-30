# Nomad dev agent configuration for macOS native mode.
#
# Used by 'make up' on macOS where host networking issues prevent running
# Nomad inside Docker.  Nomad runs as a native process alongside Docker Desktop.
#
# Key differences from docker/nomad.hcl:
#   - Docker volumes enabled so tasks can use bind mounts (required for
#     dev_shared_data_path to share /mnt/openstudio between web and worker)
#   - No host_volume declarations for MongoDB/Redis (minimal-dev uses
#     ephemeral storage; host volumes require paths that exist on the Mac)

data_dir  = "/tmp/nomad-macos-dev/data"
log_level = "WARN"
bind_addr = "127.0.0.1"

advertise {
  http = "127.0.0.1"
  rpc  = "127.0.0.1"
  serf = "127.0.0.1"
}

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
}

consul {
  address = "127.0.0.1:8500"
}

plugin "docker" {
  config {
    # Enable bind mounts so tasks can share host directories (e.g. /tmp/openstudio-osdata).
    volumes {
      enabled = true
    }
  }
}
