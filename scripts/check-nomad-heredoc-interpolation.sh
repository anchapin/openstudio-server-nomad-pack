#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_ROOT="${REPO_ROOT}/packs/openstudio-server/templates"

# Pattern 1: Shell parameter expansions with colons inside ${...} — these
# collide with HCL's ${...} interpolation syntax inside heredocs.
# e.g.  ${var:-default}  ${var:+alt}  ${#var}  ${var:0:5}
PATTERN_HCL='\$\{[^}]*:[^}]*\}'

# Pattern 2: POSIX character classes like [[:space:]] [[:alpha:]] etc. —
# these contain "[[" which is the Nomad Pack template delimiter. Inside a
# data = <<-EOT heredoc the Pack renderer will attempt to parse "[[:space:]]"
# as a template action starting at "[[", producing a parse error.
POSIX_CLASSES='alpha|alnum|blank|cntrl|digit|graph|lower|print|punct|space|upper|xdigit'
PATTERN_POSIX="\[\[:(${POSIX_CLASSES}):\]\]"

# Pattern 3: Nomad HCL interpolation of lowercase variables in driver configs.
# Nomad evaluates ${...} inside:
#   - config.args (heredocs or quoted strings)
#   - docker driver mounts[].source
# Lowercase variables like ${jitter}, ${alloc.dir}, ${alloc.id} will fail with
# "Unknown variable" because they are not HCL-defined. Only all-caps env-var
# names (${NOMAD_ALLOC_DIR}, ${NOMAD_META_*}) pass through.
PATTERN_NOMAD_INTERP='\$\{[^}]*[a-z][^}]*\}'

# Known-safe all-caps env vars that Nomad passes through
SAFE_ENV_VARS='NOMAD_ALLOC_DIR|NOMAD_META_|NOMAD_PORT_|NOMAD_ADDR_|NOMAD_REGION|NOMAD_DC_|NOMAD_NAMESPACE|NOMAD_JOB_NAME|NOMAD_GROUP_NAME|NOMAD_TASK_NAME|NOMAD_ALLOC_ID|NOMAD_ALLOC_NAME|NOMAD_ALLOC_INDEX'

rc=0

echo "Scanning Nomad templates for shell parameter expansions that can conflict with HCL heredocs..."
if matches=$(grep -RInE "${PATTERN_HCL}" "${TEMPLATE_ROOT}"); then
  echo "::warning::Possible HCL/shell interpolation conflict detected. Review any \${...:...} usage inside template heredocs before merge."
  printf '%s\n' "${matches}"
  rc=1
else
  echo "OK: No likely HCL heredoc interpolation conflicts (\${...:...}) found in ${TEMPLATE_ROOT}."
fi

echo ""
echo "Scanning Nomad templates for POSIX character classes that contain the [[ Nomad Pack delimiter..."
if matches=$(grep -RInE "${PATTERN_POSIX}" "${TEMPLATE_ROOT}"); then
  echo "::error::POSIX character class found inside a pack template. Classes like [[:space:]] contain"
  echo "  the [[ delimiter and will be parsed as a Nomad Pack template action, causing a parse error."
  echo "  Use [ \\t] or [ ] instead of [[:space:]], [ a-z] instead of [[:alpha:]], etc."
  printf '%s\n' "${matches}"
  rc=1
else
  echo "OK: No POSIX character class conflicts found in ${TEMPLATE_ROOT}."
fi

echo ""
echo "Scanning Nomad templates for Nomad HCL interpolation of lowercase variables in driver configs..."

# Use awk to track context and only flag ${lowercase} inside driver config blocks:
# - Inside "config {" ... "}" blocks (driver config)
# - Inside "mounts = [" ... "]" blocks (docker driver)
# Skip template { data = ... } blocks and constraint attributes
awk -v pattern="${PATTERN_NOMAD_INTERP}" -v safe="${SAFE_ENV_VARS}" '
  function in_driver_cfg() { return (in_config_block && !in_template_block) }
  function is_safe(m) { if (m ~ /\$\$/) return 1; if (m ~ safe) return 1; return 0 }
  {
    line = $0
    if (line ~ /template\s*\{/) in_template_block = 1
    if (in_template_block && line ~ /\}/) in_template_block = 0
    if (line ~ /config\s*\{/) in_config_block = 1
    if (in_config_block && line ~ /^\s*\}/) in_config_block = 0
    if (in_driver_cfg()) {
      while (match(line, pattern)) {
        m = substr(line, RSTART, RLENGTH)
        if (!is_safe(m)) {
          printf "%s:%d: %s\n", FILENAME, FNR, m
          found = 1
        }
        line = substr(line, RSTART + 1)
      }
    }
  }
  END { exit found ? 1 : 0 }
' "${TEMPLATE_ROOT}"/*.nomad.tpl "${TEMPLATE_ROOT}"/_helpers.tpl 2>/dev/null || {
  matches=$(awk -v pattern="${PATTERN_NOMAD_INTERP}" -v safe="${SAFE_ENV_VARS}" '
    function in_driver_cfg() { return (in_config_block && !in_template_block) }
    function is_safe(m) { if (m ~ /\$\$/) return 1; if (m ~ safe) return 1; return 0 }
    {
      line = $0
      if (line ~ /template\s*\{/) in_template_block = 1
      if (in_template_block && line ~ /\}/) in_template_block = 0
      if (line ~ /config\s*\{/) in_config_block = 1
      if (in_config_block && line ~ /^\s*\}/) in_config_block = 0
      if (in_driver_cfg()) {
        while (match(line, pattern)) {
          m = substr(line, RSTART, RLENGTH)
          if (!is_safe(m)) {
            printf "%s:%d: %s\n", FILENAME, FNR, m
            found = 1
          }
          line = substr(line, RSTART + 1)
        }
      }
    }
    END { exit found ? 1 : 0 }
  ' "${TEMPLATE_ROOT}"/*.nomad.tpl "${TEMPLATE_ROOT}"/_helpers.tpl 2>/dev/null)
  echo "::error::Nomad HCL interpolation of lowercase variables detected in driver configs."
  echo "  These will fail with '\''Unknown variable'\'' at job registration or task start."
  echo "  Use \$${VAR} (escaped) or printf/printf-style formatting instead."
  echo "  Safe all-caps env vars (\${NOMAD_ALLOC_DIR}, \${NOMAD_META_*}) are excluded."
  printf '%s\n' "${matches}"
  rc=1
}

if [ $rc -eq 0 ]; then
  echo "OK: No Nomad HCL interpolation conflicts (lowercase \${...}) found in ${TEMPLATE_ROOT}."
fi

exit $rc