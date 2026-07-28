# Lightweight override set for true e2e CI deployment tests.
# Deploys fast-starting stubs while preserving service registration and health checks.

job_name    = "openstudio-server-e2e"
datacenters = ["dc1"]

mongodb_storage_type = "ephemeral"
redis_storage_type   = "ephemeral"

enable_vector_collection  = false
enable_consul_connect     = false
enable_batch_verification = false

vault_integration_enabled = false
vault_enabled             = false
enable_vault_mongo_secrets = false

backup_enabled  = false
restore_enabled = false

web_cpu            = 100
web_memory         = 128
web_background_cpu = 100
web_background_memory = 128
db_cpu             = 200
db_memory          = 256
redis_cpu          = 100
redis_memory       = 128
rserve_cpu         = 100
rserve_memory      = 128
worker_cpu         = 100
worker_memory      = 128

worker_count               = 1
worker_autoscaling_enabled = false
# Override production defaults (min:2, max:20 per Helm HPA) for lightweight e2e CI.
worker_min_replicas        = 1
worker_max_replicas        = 2
worker_kill_timeout        = "9m"

docker_user            = "root"
docker_readonly_rootfs = false
docker_cap_drop        = []

db_image             = "mongo:7-slim"
redis_image          = "redis:7-alpine"
rserve_image         = "alpine:3.18"
web_image            = "alpine:3.18"
web_background_image = "alpine:3.18"
worker_image         = "alpine:3.18"

web_command = "/bin/sh"
web_args = [
  "-c",
  "mkdir -p /srv/www && printf 'ok\\n' > /srv/www/status && exec busybox httpd -f -p 8080 -h /srv/www",
]

web_background_command = "/bin/sh"
web_background_args = [
  "-c",
  "while true; do sleep 30; done",
]

rserve_command = "/bin/sh"
rserve_args = [
  "-c",
  "while true; do nc -l -p 6311 >/dev/null 2>&1; done",
]

worker_command = "/bin/sh"
worker_args = [
  "-c",
  "while true; do sleep 30; done",
]
worker_health_check_command = "exit 0"
