OpenStudio Server pack has been deployed successfully to Nomad!

OpenStudio Web UI:
- Direct: http://<host>:[[ var "web_port" . ]]
- Consul: http://localhost:8500/ui/[[ index (var "datacenters" .) 0 ]]/services/openstudio-web

Consul Service URLs:
- Db Service: http://localhost:8500/ui/[[ if gt (len (var "datacenters" .)) 0 ]][[ index (var "datacenters" .) 0 ]][[ else ]]dc1[[ end ]]/services/openstudio-db
- Redis Service: http://localhost:8500/ui/[[ if gt (len (var "datacenters" .)) 0 ]][[ index (var "datacenters" .) 0 ]][[ else ]]dc1[[ end ]]/services/openstudio-redis
- Rserve Service: http://localhost:8500/ui/[[ if gt (len (var "datacenters" .)) 0 ]][[ index (var "datacenters" .) 0 ]][[ else ]]dc1[[ end ]]/services/openstudio-rserve

[[ if var "deploy_traefik" . ]]
Traefik Router URL:
- Web UI: http[[ if var "ingress_tls_enabled" . ]]s[[ end ]]://[[ var "ingress_domain" . ]]

[[ end ]]
Batch Verification:
- Enable job: nomad-pack run -var "enable_batch_verification=true" packs/openstudio-server
- Metrics lines: batch_verification_result / batch_verification_summary
