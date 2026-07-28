# Release process:
#   1. Bump `version` in the pack block below to the next semantic version.
#   2. Create a matching git tag: git tag v<version> && git push origin v<version>
#   3. The release.yml workflow triggers on that tag push, reads pack version
#      from this file, and creates a GitHub Release + publishes to the registry.

app {
  url = "https://github.com/anchapin/openstudio-server-nomad-pack"
}

pack {
  name        = "openstudio-server"
  description = "Deploys the full OpenStudio Server stack (web, worker, db, Redis, Rserve) on HashiCorp Nomad with Consul service discovery."
  version     = "0.2.66"
  url         = "https://github.com/anchapin/openstudio-server-nomad-pack"
}
