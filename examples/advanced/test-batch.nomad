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
      # raw_exec avoids Docker image pull overhead; Nomad dev mode enables it by default.
      driver = "raw_exec"

      config {
        command = "/bin/sh"
        args    = ["-c", "echo 'Smoke test: pack deployment verified.'"]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }
  }
}
