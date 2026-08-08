[[/*
  consul-client.nomad.tpl
  Deploys Consul client agents on all Nomad client nodes as a system job.
  This enables service registration and discovery for OpenStudio Server jobs.
  
  Enable with: enable_consul_client = true
  Requires: Consul server running at consul_server_address
*/]]
[[ if var "enable_consul_client" . ]]
job "[[ var "job_name" . ]]-consul-client" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "system"

  group "consul-client" {
    restart {
      attempts = 3
      interval = "2m"
      delay    = "30s"
      mode     = "delay"
    }

    network {
      port "http" {
        to           = 8500
        host_network = true
      }
      port "dns" {
        to           = 8600
        host_network = true
      }
      port "serf_lan" {
        to           = 8301
        host_network = true
      }
      port "serf_wan" {
        to           = 8302
        host_network = true
      }
      port "server" {
        to           = 8300
        host_network = true
      }
    }

    task "consul" {
      driver = "docker"
      user   = "root"

      config {
        image        = "[[ var "consul_client_image" . ]]"
        network_mode = "host"
        privileged   = true
        command      = "agent"
        args = [
          "-client=0.0.0.0",
          "-bind=0.0.0.0",
          "-advertise={{ GetPrivateIP }}",
          "-retry-join=[[ var "consul_server_address" . ]]",
          "-data-dir=/consul/data",
          "-config-dir=/consul/config",
          "-log-level=[[ var "consul_client_log_level" . ]]",
        ]
        mounts = [
          {
            type     = "bind"
            source   = "/etc/consul.d"
            target   = "/consul/config"
            readonly = true
          },
          {
            type     = "volume"
            source   = "consul-data"
            target   = "/consul/data"
            readonly = false
          }
        ]
        cap_add = ["SYS_RESOURCE", "NET_ADMIN", "CAP_DAC_OVERRIDE"]
      }

      volume_mount {
        volume      = "consul-data"
        destination = "/consul/data"
        read_only   = false
      }

      resources {
        cpu    = [[ var "consul_client_cpu" . ]]
        memory = [[ var "consul_client_memory" . ]]
      }

      service {
        name     = "consul"
        provider = "consul"
        port     = "http"

        check {
          name     = "consul-http"
          type     = "http"
          path     = "/v1/agent/self"
          interval = "10s"
          timeout  = "2s"
        }
      }

      env {
        CONSUL_HTTP_ADDR = "127.0.0.1:8500"
      }
    }

    [[ template "openstudio_server.vector_task" . ]]
    [[ template "openstudio_server.cleanup_poststop_task" . ]]

    volume "consul-data" {
      type      = "host"
      source    = "[[ var "consul_client_data_volume" . ]]"
      read_only = false
    }
  }
}
[[ end ]]