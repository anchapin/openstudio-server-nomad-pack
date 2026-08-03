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
    memory = 64
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
  max_parallel      = [[ .max_parallel ]]
  health_check      = "[[ .health_check ]]"
  min_healthy_time  = "[[ .min_healthy_time ]]"
  healthy_deadline  = "[[ .healthy_deadline ]]"
  progress_deadline = "[[ .progress_deadline ]]"
  auto_revert       = [[ .auto_revert ]]
}
[[- end -]]
