// Scheduling helper templates for task-group placement controls.
//
// ─── Namespaced macros (openstudio_server.*) ─────────────────────────────────
//
// openstudio_server.node_class_constraint
//   Emits a hard constraint targeting the ${attr.nomad.node.class} attribute.
//   Call with a string value:
//     [[ template "openstudio_server.node_class_constraint" "compute" ]]
//
// openstudio_server.arch_constraint
//   Emits hard constraints for kernel.name = linux and cpu.arch = amd64.
//   Call with the root context:
//     [[ template "openstudio_server.arch_constraint" . ]]
//
// openstudio_server.node_affinity
//   Emits a soft affinity stanza. Call with a map containing keys
//   attribute, value, and (optionally) weight:
//     [[ template "openstudio_server.node_affinity" (dict "attribute" "${attr.nomad.node.class}" "value" "compute" "weight" 100) ]]
//
// ─────────────────────────────────────────────────────────────────────────────

[[- define "constraints" -]]
[[- range $constraint := . ]]
constraint {
  attribute = [[ $constraint.attribute | quote ]]
  [[- if $constraint.operator ]]
  operator = [[ $constraint.operator | quote ]]
  [[- end ]]
  value = [[ $constraint.value | quote ]]
}
[[- end -]]
[[- end -]]

[[- define "affinities" -]]
[[- range $affinity := . ]]
affinity {
  attribute = [[ $affinity.attribute | quote ]]
  [[- if $affinity.operator ]]
  operator = [[ $affinity.operator | quote ]]
  [[- end ]]
  value = [[ $affinity.value | quote ]]
  [[- if $affinity.weight ]]
  weight = [[ $affinity.weight ]]
  [[- end ]]
}
[[- end -]]
[[- end -]]

[[- define "spreads" -]]
[[- range $spread := . ]]
spread {
  attribute = [[ $spread.attribute | quote ]]
  [[- if $spread.weight ]]
  weight = [[ $spread.weight ]]
  [[- end ]]
  [[- if $spread.targets ]]
  [[- range $target := $spread.targets ]]
  target [[ $target.value | quote ]] {
    percent = [[ $target.percent ]]
  }
  [[- end ]]
  [[- end ]]
}
[[- end -]]
[[- end -]]

[[- define "openstudio_server.node_class_constraint" -]]

constraint {
  attribute = "${attr.nomad.node.class}"
  value     = "[[ . ]]"
}
[[- end -]]

[[- define "openstudio_server.arch_constraint" -]]

constraint {
  attribute = "${attr.kernel.name}"
  value     = "linux"
}

constraint {
  attribute = "${attr.cpu.arch}"
  value     = "amd64"
}
[[- end -]]

[[- define "openstudio_server.node_affinity" -]]

affinity {
  attribute = "[[ .attribute ]]"
  value     = "[[ .value ]]"
  weight    = [[ if .weight ]][[ .weight ]][[- else ]]50[[- end ]]
}
[[- end -]]

[[- define "openstudio_server.vector_task" -]]
[[ if var "enable_vector_collection" . ]]
task "vector" {
  driver = "docker"

  lifecycle {
    hook    = "prestart"
    sidecar = true
  }

  config {
    image      = "[[ var "vector_image" . ]]"
    force_pull = false
    args       = ["--config", "local/vector.toml"]
  }

  template {
    data        = <<EOH
[sources.alloc_logs]
type = "file"
include = ["/alloc/logs/*.std*"]

[sinks.console]
type = "console"
inputs = ["alloc_logs"]
encoding.codec = "json"
EOH
    destination = "local/vector.toml"
  }

  resources {
    cpu    = 100
    memory = [[ var "vector_memory_mb" . ]]
  }
}
[[ end -]]
[[- end -]]

[[- define "openstudio_server.cleanup_poststop_task" -]]
task "cleanup-poststop" {
  driver = "docker"

  lifecycle {
    hook = "poststop"
  }

  config {
    image   = "[[ var "poststop_cleanup_image" . ]]"
    command = "sh"
    args = [
      "-ec",
      <<EOT
set -eu
[[ range var "poststop_cleanup_paths" . -]]
rm -rf "[[ . ]]"
[[ end -]]
EOT
    ]
  }
}
[[- end -]]

[[- define "openstudio_server.worker_preflight_task" -]]
task "preflight" {
  lifecycle {
    hook    = "prestart"
    sidecar = false
  }

  driver = "docker"

  config {
    image        = "[[ var "verification_image" .root ]]"
    network_mode = "host"
    command      = "sh"
    args = [
      "-ec",
      <<-EOT
set -eu

MAX_ATTEMPTS=[[ var "worker_preflight_max_attempts" .root ]]
SLEEP_SECONDS=[[ var "worker_preflight_sleep_seconds" .root ]]
CONNECT_TIMEOUT=[[ var "worker_preflight_connect_timeout_seconds" .root ]]
CONSUL_ADDR="[[ var "consul_address" .root ]]"
PROCEED_ON_TIMEOUT="[[ if var "worker_wait_for_deps_proceed_on_timeout" .root ]]true[[ else ]]false[[ end ]]"

if [ "$MAX_ATTEMPTS" -lt 1 ]; then
  echo "preflight_check service=all status=fail reason=invalid_max_attempts value=$MAX_ATTEMPTS" >&2
  exit 1
fi

if [ "$SLEEP_SECONDS" -lt 1 ]; then
  echo "preflight_check service=all status=fail reason=invalid_sleep_seconds value=$SLEEP_SECONDS" >&2
  exit 1
fi

if [ "$CONNECT_TIMEOUT" -lt 1 ]; then
  echo "preflight_check service=all status=fail reason=invalid_connect_timeout value=$CONNECT_TIMEOUT" >&2
  exit 1
fi

service_is_passing() {
  service="$1"
  wget -qO- -T "$CONNECT_TIMEOUT" \
    "http://$CONSUL_ADDR/v1/health/service/$service?passing=true" \
    2>/dev/null | tr -d '[:space:]' | grep -q "\"Service\":\"$service\""
}

lookup_service_address() {
  service="$1"
  response=$(wget -qO- -T "$CONNECT_TIMEOUT" "http://$CONSUL_ADDR/v1/catalog/service/$service" 2>/dev/null || true)
  address=$(printf '%s\n' "$response" | grep -o '"ServiceAddress":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -z "$address" ]; then
    address=$(printf '%s\n' "$response" | grep -o '"Address":"[^"]*"' | head -1 | cut -d'"' -f4)
  fi
  if [ -n "$address" ]; then
    printf '%s\n' "$address"
    return 0
  fi
  return 1
}

check_service() {
  service="$1"
  port="$2"
  attempt=1
  last_reason="unknown"
  last_address=""
  reported_address="unknown"

  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if ! service_is_passing "$service"; then
      last_reason="healthcheck_not_passing"
      echo "preflight_check service=$service status=fail reason=$last_reason attempt=$attempt" >&2
    else
      address=$(lookup_service_address "$service" || true)
      if [ -z "$address" ]; then
        last_reason="dns_unresolved"
        echo "preflight_check service=$service status=fail reason=$last_reason attempt=$attempt" >&2
      elif nc -z -w "$CONNECT_TIMEOUT" "$address" "$port" >/dev/null 2>&1; then
        echo "preflight_check service=$service status=pass reason=dns_and_tcp_ok address=$address port=$port attempt=$attempt"
        return 0
      else
        last_reason="tcp_connect_failed"
        last_address="$address"
        echo "preflight_check service=$service status=fail reason=$last_reason address=$address port=$port attempt=$attempt" >&2
      fi
    fi

    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      break
    fi

    sleep "$SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done

  if [ -n "$last_address" ]; then
    reported_address="$last_address"
  fi

  echo "preflight_check service=$service status=fail reason=$last_reason address=$reported_address port=$port attempts=$MAX_ATTEMPTS proceeding=$PROCEED_ON_TIMEOUT" >&2
  if [ "$PROCEED_ON_TIMEOUT" = "true" ]; then
    return 0
  fi
  return 1
}

check_service "openstudio-db" "27017"
check_service "openstudio-redis" "6379"
check_service "openstudio-rserve" "6311"
EOT
    ]
  }

  resources {
    cpu    = 50
    memory = 32
  }
}
[[- end -]]

[[- define "openstudio_server.wait_for_deps_task" -]]
task "wait-for-deps" {
  lifecycle {
    hook    = "prestart"
    sidecar = false
  }

  driver = "docker"

  config {
    image        = "[[ var "verification_image" .root ]]"
    network_mode = "host"
    command      = "sh"
    args = [
      "-ec",
      <<-EOT
set -eu

MAX_ATTEMPTS=[[ var "wait_for_deps_max_attempts" .root ]]
SLEEP_SECONDS=[[ var "wait_for_deps_sleep_seconds" .root ]]
CONNECT_TIMEOUT=[[ var "wait_for_deps_connect_timeout_seconds" .root ]]
CONSUL_ADDR="[[ var "consul_address" .root ]]"
PROCEED_ON_TIMEOUT="[[ if .proceed_on_timeout ]]true[[ else ]]false[[ end ]]"

if [ "$MAX_ATTEMPTS" -lt 1 ]; then
  echo "wait_for_deps_invalid_max_attempts value=$MAX_ATTEMPTS" >&2
  exit 1
fi

if [ "$SLEEP_SECONDS" -lt 1 ]; then
  echo "wait_for_deps_invalid_sleep value=$SLEEP_SECONDS" >&2
  exit 1
fi

if [ "$CONNECT_TIMEOUT" -lt 1 ]; then
  echo "wait_for_deps_invalid_connect_timeout value=$CONNECT_TIMEOUT" >&2
  exit 1
fi

check_service() {
  service="$1"
  attempt=1
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    if wget -qO- -T "$CONNECT_TIMEOUT" \
        "http://$CONSUL_ADDR/v1/health/service/$service?passing=true" \
        2>/dev/null | tr -d '[:space:]' | grep -q "\"Service\":\"$service\""; then
      echo "wait_for_deps_ready service=$service attempt=$attempt"
      return 0
    fi
    echo "wait_for_deps_retry service=$service attempt=$attempt" >&2
    sleep "$SLEEP_SECONDS"
    attempt=$((attempt + 1))
  done

  echo "wait_for_deps_timeout service=$service attempts=$MAX_ATTEMPTS proceeding=$PROCEED_ON_TIMEOUT" >&2
  if [ "$PROCEED_ON_TIMEOUT" = "true" ]; then
    return 0
  fi
  return 1
}

check_service "openstudio-db"
check_service "openstudio-redis"
[[ if .include_rserve -]]
check_service "openstudio-rserve"
[[ end -]]
EOT
    ]
  }

  resources {
    cpu    = 50
    memory = 32
  }
}
[[- end -]]

[[- define "openstudio_server.vault_block" -]]
[[ if var "vault_enabled" .root ]]
vault {
  [[ if .role ]]
  role = "[[ .role ]]"
  [[ else if var "vault_default_role" .root ]]
  role = "[[ var "vault_default_role" .root ]]"
  [[ end ]]
  [[ if var "vault_policies" .root ]]
  policies = [[ var "vault_policies" .root | toJson ]]
  [[ end ]]
  [[ if var "vault_namespace" .root ]]
  namespace = "[[ var "vault_namespace" .root ]]"
  [[ end ]]
  change_mode = "[[ var "vault_change_mode" .root ]]"
  [[ if var "vault_change_signal" .root ]]
  change_signal = "[[ var "vault_change_signal" .root ]]"
  [[ end ]]
  [[ if not .no_env ]]
  env = [[ var "vault_env" .root ]]
  [[ end ]]
}
[[ end -]]
[[- end -]]

[[- define "openstudio_server.vault_integration_block" -]]
[[ if var "vault_integration_enabled" . ]]
[[ if not (var "vault_enabled" .) ]]
vault {
  [[ if var "vault_default_role" . ]]
  role = "[[ var "vault_default_role" . ]]"
  [[ end ]]
  policies      = ["[[ var "vault_policy" . ]]"]
  change_mode   = "restart"
  change_signal = "SIGTERM"
}
[[ end ]]
[[ end -]]
[[- end -]]

[[- define "openstudio_server.restart_block" -]]
restart {
  attempts = [[ .attempts ]]
  [[ if .interval -]]
  interval = "[[ .interval ]]"
  [[- end ]]
  [[ if .delay -]]
  delay = "[[ .delay ]]"
  [[- end ]]
  mode = "[[ .mode ]]"
}
[[- end -]]

[[- define "openstudio_server.update_block" -]]
update {
  max_parallel = [[ .max_parallel ]]
  [[ with .canary ]]
  [[ if gt . 0 ]]
  canary       = [[ . ]]
  auto_promote = [[ if $.auto_promote ]]true[[ else ]]false[[ end ]]
  [[ end ]]
  [[ end ]]
  [[ with .stagger ]]
  [[ if ne . "" ]]
  stagger = "[[ . ]]"
  [[ end ]]
  [[ end ]]
  health_check      = "[[ .health_check ]]"
  min_healthy_time  = "[[ .min_healthy_time ]]"
  healthy_deadline  = "[[ .healthy_deadline ]]"
  progress_deadline = "[[ .progress_deadline ]]"
  auto_revert       = [[ .auto_revert ]]
}
[[- end -]]
