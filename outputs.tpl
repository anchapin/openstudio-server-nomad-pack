OpenStudio Server pack has been deployed successfully to Nomad!

Consul Service URLs:
- Db Service: http://localhost:8500/ui/[[ index (var "datacenters" .) 0 ]]/services/openstudio-db
- Redis Service: http://localhost:8500/ui/[[ index (var "datacenters" .) 0 ]]/services/openstudio-redis

Traefik Router URL:
- Web UI: http://[[ var "job_name" . ]].[[ var "ingress_domain" . ]]
