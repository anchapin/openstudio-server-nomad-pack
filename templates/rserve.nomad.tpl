job "[[ var "job_name" . ]]-rserve" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  type        = "service"

  group "rserve" {
    count = 1

    network {
      port "rserve" {
        to = 6311
      }
    }

    task "rserve" {
      driver = "docker"

      config {
        image = "[[ var "rserve_image" . ]]"
        ports = ["rserve"]
      }

      service {
        name = "openstudio-rserve"
        port = "rserve"
        provider = "consul"

        check {
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
