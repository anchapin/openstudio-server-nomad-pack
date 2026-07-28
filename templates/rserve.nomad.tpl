job "[[ var "job_name" . ]]-rserve" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  type        = "service"
  meta {
    app_version       = "[[ var "app_version" . ]]"
    ingress_domain    = "[[ var "ingress_domain" . ]]"
    vault_integration = "[[ var "vault_integration_enabled" . ]]"
  }

  group "rserve" {
    count = 1
    [[ template "constraints" (var "rserve_constraints" .) ]]
    [[ template "affinities" (var "rserve_affinities" .) ]]
    [[ template "spreads" (var "rserve_spreads" .) ]]

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
        tags = [
          "ingress.domain=[[ var "ingress_domain" . ]]"
        ]

        check {
          name     = "openstudio-rserve-tcp"
          type     = "tcp"
          interval = "10s"
          timeout  = "2s"
        }
      }

      env {
        APP_VERSION               = "[[ var "app_version" . ]]"
        VAULT_INTEGRATION_ENABLED = "[[ var "vault_integration_enabled" . ]]"
      }

      [[ if var "vault_integration_enabled" . ]]
      vault {}
      [[ end ]]
    }
  }
}
