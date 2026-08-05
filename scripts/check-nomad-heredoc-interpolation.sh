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
# Any occurrence of "[[ " (start of a pack action) immediately followed by
# a colon (POSIX class) is the tell.  Match the most common classes:
POSIX_CLASSES='alpha|alnum|blank|cntrl|digit|graph|lower|print|punct|space|upper|xdigit'
PATTERN_POSIX="\[\[:(${POSIX_CLASSES}):\]\]"

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

exit $rc
