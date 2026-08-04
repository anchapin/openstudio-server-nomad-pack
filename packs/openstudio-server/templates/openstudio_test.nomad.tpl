[[ if var "enable_openstudio_test" . ]]
job "[[ var "job_name" . ]]-test" {
  region      = "[[ var "region" . ]]"
  datacenters = [[ var "datacenters" . | toJson ]]
  namespace   = "[[ var "nomad_namespace" . ]]"
  type        = "batch"

  parameterized {
    meta_optional = ["TEST_TIMEOUT"]
  }

  reschedule {
    attempts = 0
  }

  group "health-checks" {
    count = 1

    [[ template "openstudio_server.restart_block" (dict "attempts" 0 "mode" "fail") ]]

    task "web-http-check" {
      driver = "docker"

      config {
        image   = "curlimages/curl:[[ var "test_curl_image_tag" . ]]"
        command = "sh"
        args = [
          "-c",
          "curl --silent --fail --max-time [[ var "test_timeout_seconds" . ]] --retry [[ var "test_retry_count" . ]] http://openstudio-web.service.consul:[[ var "test_web_port" . ]]/ && echo 'web-http-check: PASS' || (echo 'web-http-check: FAIL'; exit 1)",
        ]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }

    task "redis-tcp-check" {
      driver = "docker"

      config {
        image   = "busybox:[[ var "test_busybox_image_tag" . ]]"
        command = "sh"
        args = [
          "-c",
          "nc -z -w [[ var "test_timeout_seconds" . ]] openstudio-redis.service.consul [[ var "test_redis_port" . ]] && echo 'redis-tcp-check: PASS' || (echo 'redis-tcp-check: FAIL'; exit 1)",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "mongo-tcp-check" {
      driver = "docker"

      config {
        image   = "busybox:[[ var "test_busybox_image_tag" . ]]"
        command = "sh"
        args = [
          "-c",
          "nc -z -w [[ var "test_timeout_seconds" . ]] openstudio-db.service.consul [[ var "test_mongo_port" . ]] && echo 'mongo-tcp-check: PASS' || (echo 'mongo-tcp-check: FAIL'; exit 1)",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    task "rserve-tcp-check" {
      driver = "docker"

      config {
        image   = "busybox:[[ var "test_busybox_image_tag" . ]]"
        command = "sh"
        args = [
          "-c",
          "nc -z -w [[ var "test_timeout_seconds" . ]] openstudio-rserve.service.consul [[ var "test_rserve_port" . ]] && echo 'rserve-tcp-check: PASS' || (echo 'rserve-tcp-check: FAIL'; exit 1)",
        ]
      }

      resources {
        cpu    = 50
        memory = 32
      }
    }

    [[ if var "enable_runtime_discovery_canary_test" . ]]
    task "runtime-discovery-canary" {
      driver = "docker"

      config {
        image   = "busybox:[[ var "test_busybox_image_tag" . ]]"
        command = "sh"
        args = [
          "-ec",
          <<-EOF
set -eu

MAX_ATTEMPTS=[[ var "web_worker_runtime_service_resolution_attempts" . ]]
BASE_DELAY=[[ var "web_worker_runtime_service_resolution_backoff_seconds" . ]]

if [ "$MAX_ATTEMPTS" -lt 1 ] || [ "$BASE_DELAY" -lt 1 ]; then
  echo "runtime_discovery_canary_invalid_config attempts=${MAX_ATTEMPTS} backoff=${BASE_DELAY}" >&2
  exit 1
fi

resolve_alias() {
  service="$1"
  alias="$2"
  attempt=1
  delay="$BASE_DELAY"
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    ip=""
    if command -v getent >/dev/null 2>&1; then
      ip="$(getent hosts "${service}.service.consul" 2>/dev/null | awk 'NR==1 {print $1}')"
    fi
    if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
      ip="$(nslookup "${service}.service.consul" 2>/dev/null | awk '/^Address [0-9]+: / {print $3; exit} /^Address: / {print $2; exit}')"
    fi
    if [ -n "$ip" ]; then
      echo "${ip} ${alias}" >> /etc/hosts
      echo "runtime_discovery_canary_alias_resolved service=${service} alias=${alias} ip=${ip} attempt=${attempt}"
      return 0
    fi
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    [ "$delay" -gt 8 ] && delay=8
  done
  echo "runtime_discovery_canary_alias_failed service=${service} alias=${alias}" >&2
  return 1
}

resolve_alias "openstudio-db" "db"
resolve_alias "openstudio-redis" "queue"
resolve_alias "openstudio-rserve" "rserve"
resolve_alias "openstudio-web" "web"

nc -z -w [[ var "test_timeout_seconds" . ]] db [[ var "test_mongo_port" . ]]
nc -z -w [[ var "test_timeout_seconds" . ]] queue [[ var "test_redis_port" . ]]
nc -z -w [[ var "test_timeout_seconds" . ]] rserve [[ var "test_rserve_port" . ]]
nc -z -w [[ var "test_timeout_seconds" . ]] web [[ var "test_web_port" . ]]

echo "runtime_discovery_canary: PASS"
EOF
        ]
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
    [[ end ]]
  }
}

[[ end ]]
