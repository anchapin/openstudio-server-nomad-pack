[[/*
  nomad-batch-worker.nomad.tpl
  ─────────────────────────────────────────────────────────────────────────────
  Renders a *parameterized* Nomad batch job that the OpenStudio Server web
  dispatcher submits one allocation per simulation run.  The job is only
  deployed when batch_engine = "nomad_batch".

  Dispatch payload (JSON):
    {
      "analysis_id":  "<uuid>",
      "datapoint_id": "<uuid>"
    }

  The web dispatcher reads NOMAD_ADDR + NOMAD_TOKEN from its Workload Identity
  and POSTs to /v1/job/<nomad_batch_job_name>/dispatch.

  Template syntax: [[ ]] pack delimiters (NOT {{ }}).
*/]]
[[ if eq (var "batch_engine" .) "nomad_batch" ]]
job "[[ var "job_name" . ]]-[[ var "nomad_batch_job_name" . ]]" {
  region = "[[ var "region" . ]]"
  [[ if ne (var "nomad_batch_datacenter" .) "" ]]
  datacenters = ["[[ var "nomad_batch_datacenter" . ]]"]
  [[ else ]]
  datacenters = [[ var "datacenters" . | toJson ]]
  [[ end ]]
  namespace = "[[ if ne (var "nomad_batch_namespace" .) "" ]][[ var "nomad_batch_namespace" . ]][[ else ]][[ var "nomad_namespace" . ]][[ end ]]"
  type      = "batch"
  priority  = [[ var "worker_priority" . ]]

  # Parameterized stanza — the dispatcher dispatches one allocation per
  # simulation datapoint by calling POST /v1/job/<name>/dispatch with a JSON
  # payload carrying analysis_id and datapoint_id.
  parameterized {
    payload       = "required"
    meta_required = ["analysis_id", "datapoint_id"]
  }

  group "worker" {
    count = 1

    [[ template "constraints" (var "nomad_batch_constraints" .) ]]
    [[ template "openstudio_server.arch_constraint" . ]]

    task "worker" {
      driver = "docker"

      kill_timeout = "[[ var "nomad_batch_kill_timeout" . ]]"

      config {
        image           = "[[ if ne (var "nomad_batch_worker_image" .) "" ]][[ var "nomad_batch_worker_image" . ]][[ else ]][[ var "worker_image" . ]][[ end ]]"
        readonly_rootfs = false
        cap_drop        = [[ var "docker_cap_drop" . | toJson ]]
        [[ if ne (var "nomad_batch_worker_command" .) "" ]]
        command = "[[ var "nomad_batch_worker_command" . ]]"
        [[ end ]]
        [[ if var "nomad_batch_worker_args" . ]]
        args = [[ var "nomad_batch_worker_args" . | toJson ]]
        [[ end ]]
      }

      env {
        MONGO_USER = "[[ var "mongo_user" . ]]"
        QUEUES     = "simulations"
        # Dispatcher-injected identifiers — decoded from dispatch payload at runtime.
        ANALYSIS_ID                 = "${NOMAD_META_analysis_id}"
        DATAPOINT_ID                = "${NOMAD_META_datapoint_id}"
        OS_SERVER_NUMBER_OF_WORKERS = "1"
        [[ if var "web_redis_url" . ]]
        REDIS_URL = "[[ var "web_redis_url" . ]]"
        [[ end ]]
        [[ if not (var "vault_integration_enabled" .) ]]
        MONGO_PASSWORD  = "[[ var "mongo_password" . ]]"
        REDIS_PASSWORD  = "[[ var "redis_password" . ]]"
        SECRET_KEY_BASE = "[[ var "app_secret_key_base" . ]]"
        [[ end ]]
      }

      [[ if var "vault_integration_enabled" . ]]
      template {
        destination     = "secrets/env"
        env             = true
        left_delimiter  = "{{"
        right_delimiter = "}}"
        data            = <<-EOT
{{ with secret "[[ var "vault_kv_mongodb_path" . ]]" }}
MONGO_PASSWORD  = {{ .Data.data.password | toJSON }}
{{ end }}
{{ with secret "[[ var "vault_kv_redis_path" . ]]" }}
REDIS_PASSWORD  = {{ .Data.data.password | toJSON }}
{{ end }}
{{ with secret "[[ var "vault_kv_app_path" . ]]" }}
SECRET_KEY_BASE = {{ .Data.data.secret_key_base | toJSON }}
{{ end }}
EOT
      }
      [[ end ]]

      resources {
        cpu    = [[ var "nomad_batch_cpu" . ]]
        memory = [[ var "nomad_batch_memory" . ]]
      }

      # Consul-hosted service addresses are resolved once via DNS lookups.
      template {
        destination     = "local/patch-hosts.sh"
        left_delimiter  = "{{"
        right_delimiter = "}}"
        data            = <<-EOT
#!/bin/sh
set -eu

CONSUL_ADDR="[[ var "consul_address" . ]]"

resolve_service_ip() {
  service="$1"
  max_attempts=60
  attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    json="$(wget -qO- -T 2 "http://${CONSUL_ADDR}/v1/health/service/${service}?passing=true" || true)"
    ip=""
    if [ -n "$json" ] && command -v python3 >/dev/null 2>&1; then
      ip="$(printf '%s' "$json" | python3 -c 'import json,sys
data=json.load(sys.stdin)
for entry in data:
    svc=(entry or {}).get("Service") or {}
    node=(entry or {}).get("Node") or {}
    addr=svc.get("Address") or node.get("Address") or ""
    if addr:
        print(addr)
        break
')"
    fi
    if [ -z "$ip" ] && [ -n "$json" ]; then
      ip="$(printf '%s' "$json" | sed -n 's/.*"ServiceAddress":"\([^"]*\)".*/\1/p' | head -n 1)"
      if [ -z "$ip" ]; then
        ip="$(printf '%s' "$json" | sed -n 's/.*"Address":"\([^"]*\)".*/\1/p' | head -n 1)"
      fi
    fi
    if [ -n "$ip" ]; then
      printf '%s\n' "$ip"
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

echo "$(resolve_service_ip "openstudio-db") db" >> /etc/hosts
echo "$(resolve_service_ip "openstudio-redis") queue" >> /etc/hosts
EOT
        change_mode     = "noop"
      }
    }
  }
}
[[ end ]]
