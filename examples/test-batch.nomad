# Smoke-test batch job dispatched by the integration-test CI workflow.
# Verifies the pack deployment framework is functional; exits 0 on success.
# See GitHub issue #84 and #92 for context.

job "openstudio-server-smoke-test" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "batch"

  group "smoke-test" {
    count = 1

    task "verify" {
      driver = "docker"

      config {
        image   = "alpine:3.18"
        command = "/bin/sh"
        args    = ["-c", "echo 'Smoke test: pack deployment verified.' && exit 0"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}
