# Nomad dev agent configuration for containerized operation.
#
# This config pairs with docker-compose.yaml.  Nomad uses host networking
# so that:
#   - Consul at 127.0.0.1:8500 is reachable (matches wait-for-deps templates)
#   - The Docker driver can launch sibling containers via /var/run/docker.sock
#   - nomad CLI / nomad-pack on the host reach the API at 127.0.0.1:4646

data_dir  = "/opt/nomad/data"
log_level = "WARN"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true

  host_volume "openstudio-mongodb" {
    path      = "/opt/nomad/volumes/mongodb"
    read_only = false
  }

  host_volume "openstudio-redis" {
    path      = "/opt/nomad/volumes/redis"
    read_only = false
  }
}

consul {
  address = "127.0.0.1:8500"
}

plugin "docker" {
  config {
    volumes { enabled = true }

    # Nomad will auto-configure Docker containers to use Consul DNS for
    # .consul service resolution when the consul stanza is set above.
    # No manual dns / dns_servers override is needed.
  }
}
