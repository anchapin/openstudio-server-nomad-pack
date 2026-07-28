// Scheduling helper templates for task-group placement controls.

[[- define "constraints" -]]
[[- range $constraint := . ]]
  constraint {
    attribute = [[ $constraint.attribute | quote ]]
    [[- if $constraint.operator ]]
    operator  = [[ $constraint.operator | quote ]]
    [[- end ]]
    value     = [[ $constraint.value | quote ]]
  }
[[- end -]]
[[- end -]]

[[- define "affinities" -]]
[[- range $affinity := . ]]
  affinity {
    attribute = [[ $affinity.attribute | quote ]]
    [[- if $affinity.operator ]]
    operator  = [[ $affinity.operator | quote ]]
    [[- end ]]
    value     = [[ $affinity.value | quote ]]
    [[- if $affinity.weight ]]
    weight    = [[ $affinity.weight ]]
    [[- end ]]
  }
[[- end -]]
[[- end -]]

[[- define "spreads" -]]
[[- range $spread := . ]]
  spread {
    attribute = [[ $spread.attribute | quote ]]
    [[- if $spread.weight ]]
    weight    = [[ $spread.weight ]]
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
