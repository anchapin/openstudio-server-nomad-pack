#!/usr/bin/env bash
# provision-openstack-storage.sh — Idempotent OpenStack storage provisioning for OpenStudio Server
#
# Usage:
#   ./scripts/provision-openstack-storage.sh [OPTIONS]
#
# Options:
#   --nfs-size N        Size (GiB) for Manila NFS share (default: 100)
#   --mongodb-size N    Size (GiB) for Cinder MongoDB volume (default: 50)
#   --cidr X.X.X.X/YY  Nomad client CIDR for NFS ACL (default: 10.0.0.0/24)
#   --skip-cinder       Skip Cinder volume creation
#   --dry-run           Print commands without executing
#   --help              Show this help text
#
# Prerequisites:
#   - openstack CLI installed and authenticated (source your openrc or set OS_* env vars)
#   - "openstack" binary on PATH
#   - Sufficient quota in the target project (shares, gigabytes, volumes)
#
# See docs/openstack-storage-provisioning.md for full operator guide.

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[PASS]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
NFS_SHARE_NAME="openstudio-nfs"
NFS_SIZE=100
MONGODB_VOLUME_NAME="openstudio-mongodb"
MONGODB_SIZE=50
NOMAD_CLIENT_CIDR="10.0.0.0/24"
SKIP_CINDER=false
DRY_RUN=false

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -E '^\#( |$)' | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nfs-size)      NFS_SIZE="$2";           shift 2 ;;
    --mongodb-size)  MONGODB_SIZE="$2";       shift 2 ;;
    --cidr)          NOMAD_CLIENT_CIDR="$2";  shift 2 ;;
    --skip-cinder)   SKIP_CINDER=true;        shift   ;;
    --dry-run)       DRY_RUN=true;            shift   ;;
    --help|-h)       usage ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Dry-run wrapper ───────────────────────────────────────────────────────────
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} $*"
  else
    "$@"
  fi
}

# ── Preflight checks ──────────────────────────────────────────────────────────
preflight() {
  info "Running preflight checks …"

  if ! command -v openstack &>/dev/null; then
    error "openstack CLI not found. Install python-openstackclient and source your openrc."
    exit 1
  fi

  if [[ "$DRY_RUN" != "true" ]]; then
    if ! openstack token issue -f value -c id &>/dev/null; then
      error "OpenStack authentication failed. Source your openrc or set OS_* environment variables."
      exit 1
    fi
  fi

  success "openstack CLI available and authenticated"
}

# ── Quota check ───────────────────────────────────────────────────────────────
check_share_quota() {
  info "Checking Manila share quota …"
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "(dry-run) Skipping quota check"
    return
  fi

  local quota_output
  quota_output=$(openstack share quota show --detail -f value 2>/dev/null || true)

  if [[ -z "$quota_output" ]]; then
    warn "Could not retrieve share quota — proceeding anyway"
    return
  fi

  # Parse gigabytes limit and in-use values if available
  local limit in_use available
  limit=$(echo "$quota_output" | awk '/^gigabytes / {print $2}' | head -1)
  in_use=$(echo "$quota_output" | awk '/^gigabytes / {print $3}' | head -1)

  if [[ -n "$limit" && -n "$in_use" && "$limit" != "-1" ]]; then
    available=$(( limit - in_use ))
    if (( available < NFS_SIZE )); then
      error "Insufficient share gigabyte quota: need ${NFS_SIZE} GiB, available ${available} GiB"
      exit 1
    fi
    success "Share quota OK: ${available} GiB available, requesting ${NFS_SIZE} GiB"
  else
    warn "Share quota is unlimited or unreadable — proceeding"
  fi
}

check_volume_quota() {
  info "Checking Cinder volume quota …"
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "(dry-run) Skipping quota check"
    return
  fi

  local project_id
  project_id=$(openstack token issue -f value -c project_id 2>/dev/null || true)
  if [[ -z "$project_id" ]]; then
    warn "Could not determine project ID — skipping volume quota check"
    return
  fi

  local limit in_use available
  limit=$(openstack quota show "$project_id" -f value -c gigabytes 2>/dev/null || echo "-1")
  in_use=$(openstack volume list --all-projects=false -f value -c Size 2>/dev/null \
           | awk '{s+=$1} END {print s+0}')

  if [[ "$limit" != "-1" && -n "$in_use" ]]; then
    available=$(( limit - in_use ))
    if (( available < MONGODB_SIZE )); then
      error "Insufficient volume quota: need ${MONGODB_SIZE} GiB, available ${available} GiB"
      exit 1
    fi
    success "Volume quota OK: ${available} GiB available, requesting ${MONGODB_SIZE} GiB"
  else
    warn "Volume quota is unlimited or unreadable — proceeding"
  fi
}

# ── Manila NFS share ──────────────────────────────────────────────────────────
provision_nfs_share() {
  info "Provisioning Manila NFS share '${NFS_SHARE_NAME}' (${NFS_SIZE} GiB) …"

  if [[ "$DRY_RUN" != "true" ]]; then
    local existing
    existing=$(openstack share show "$NFS_SHARE_NAME" -f value -c id 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
      success "Share '${NFS_SHARE_NAME}' already exists (id=${existing}) — skipping creation"
      return
    fi
  fi

  run openstack share create \
    --name "$NFS_SHARE_NAME" \
    --description "OpenStudio Server shared filesystem (web + worker NFS)" \
    NFS "$NFS_SIZE"

  if [[ "$DRY_RUN" != "true" ]]; then
    info "Waiting for share to reach 'available' status …"
    local retries=24 status=""
    for (( i=0; i<retries; i++ )); do
      status=$(openstack share show "$NFS_SHARE_NAME" -f value -c status 2>/dev/null || true)
      if [[ "$status" == "available" ]]; then
        success "Share '${NFS_SHARE_NAME}' is available"
        return
      fi
      sleep 5
    done
    error "Share '${NFS_SHARE_NAME}' did not reach 'available' status after $(( retries * 5 ))s (status=${status})"
    exit 1
  fi
}

# ── NFS access rule ───────────────────────────────────────────────────────────
provision_nfs_access() {
  info "Adding NFS access rule for CIDR ${NOMAD_CLIENT_CIDR} …"

  if [[ "$DRY_RUN" != "true" ]]; then
    local existing_rule
    existing_rule=$(openstack share access list "$NFS_SHARE_NAME" -f value \
                    2>/dev/null | awk -v cidr="$NOMAD_CLIENT_CIDR" '$0 ~ cidr {print $1}' | head -1)
    if [[ -n "$existing_rule" ]]; then
      success "Access rule for ${NOMAD_CLIENT_CIDR} already exists (id=${existing_rule}) — skipping"
      return
    fi
  fi

  run openstack share access create \
    --access-level rw \
    "$NFS_SHARE_NAME" ip "$NOMAD_CLIENT_CIDR"

  success "Access rule created for ${NOMAD_CLIENT_CIDR}"
}

# ── Retrieve and display export path ─────────────────────────────────────────
get_export_path() {
  info "Retrieving NFS export path …"

  if [[ "$DRY_RUN" == "true" ]]; then
    warn "(dry-run) Export path: <openstack share show ${NFS_SHARE_NAME} -f value -c export_locations>"
    return
  fi

  local export_path
  export_path=$(openstack share show "$NFS_SHARE_NAME" \
                  -f json -c export_locations 2>/dev/null \
                | python3 -c "
import sys, json
data = json.load(sys.stdin)
locs = data.get('export_locations', [])
if isinstance(locs, list) and locs:
    # Prefer the preferred=True entry when present
    for loc in locs:
        if isinstance(loc, dict) and loc.get('preferred'):
            print(loc.get('path', ''))
            sys.exit(0)
    # Fall back to first entry
    first = locs[0]
    print(first.get('path', first) if isinstance(first, dict) else first)
elif isinstance(locs, str):
    print(locs.strip())
" 2>/dev/null || true)

  if [[ -z "$export_path" ]]; then
    # Fallback: plain text output
    export_path=$(openstack share show "$NFS_SHARE_NAME" -f value -c export_locations \
                  2>/dev/null | head -1 | tr -d '[]"' | awk -F'path=' '{print $2}' \
                  | cut -d',' -f1 | tr -d ' ' || true)
  fi

  if [[ -z "$export_path" ]]; then
    warn "Could not auto-parse export path. Run manually:"
    warn "  openstack share show ${NFS_SHARE_NAME} -f value -c export_locations"
  else
    success "NFS export path: ${export_path}"
    echo ""
    echo -e "${CYAN}━━━ Next step: register as a Nomad host volume ━━━${NC}"
    echo "Add to your Nomad client configuration:"
    echo ""
    echo '  host_volume "openstudio-nfs" {'
    echo "    path      = \"<mount_point>\"  # e.g. /mnt/openstudio-nfs"
    echo "    read_only = false"
    echo "  }"
    echo ""
    echo "Mount the share on each Nomad client node before starting Nomad:"
    echo "  sudo mount -t nfs ${export_path} <mount_point>"
    echo ""
    echo "Or add to /etc/fstab:"
    echo "  ${export_path}  <mount_point>  nfs  defaults,_netdev  0  0"
    echo ""
    echo "Then reference in your pack var-file:"
    echo "  nfs_shared_volume_enabled = true"
    echo "  nfs_volume_source         = \"openstudio-nfs\""
  fi
}

# ── NFS mount readiness test ──────────────────────────────────────────────────
validate_nfs_mount() {
  info "Validating NFS connectivity (requires nfs-utils / nfs-common on this host) …"

  if [[ "$DRY_RUN" == "true" ]]; then
    warn "(dry-run) Skipping NFS mount test"
    return
  fi

  if ! command -v showmount &>/dev/null; then
    warn "'showmount' not found — install nfs-utils (RHEL/CentOS) or nfs-common (Debian/Ubuntu)"
    warn "Skipping NFS mount readiness test"
    return
  fi

  local nfs_host
  nfs_host=$(openstack share show "$NFS_SHARE_NAME" -f value -c export_locations \
             2>/dev/null | head -1 | awk -F: '{print $1}' | tr -d '[:space:][]"' \
             | sed 's/^path=//' || true)

  if [[ -z "$nfs_host" ]]; then
    warn "Could not determine NFS host — skipping showmount check"
    return
  fi

  if showmount -e "$nfs_host" &>/dev/null; then
    success "NFS server ${nfs_host} is reachable and exporting shares"
  else
    warn "showmount -e ${nfs_host} failed — verify network connectivity and NFS firewall rules"
  fi
}

# ── Cinder MongoDB volume ─────────────────────────────────────────────────────
provision_mongodb_volume() {
  if [[ "$SKIP_CINDER" == "true" ]]; then
    info "Skipping Cinder volume creation (--skip-cinder)"
    return
  fi

  info "Provisioning Cinder volume '${MONGODB_VOLUME_NAME}' (${MONGODB_SIZE} GiB) …"

  if [[ "$DRY_RUN" != "true" ]]; then
    local existing
    existing=$(openstack volume show "$MONGODB_VOLUME_NAME" -f value -c id 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
      success "Volume '${MONGODB_VOLUME_NAME}' already exists (id=${existing}) — skipping creation"
      return
    fi
  fi

  run openstack volume create \
    --size "$MONGODB_SIZE" \
    --description "OpenStudio Server MongoDB persistent data" \
    "$MONGODB_VOLUME_NAME"

  if [[ "$DRY_RUN" != "true" ]]; then
    info "Waiting for volume to reach 'available' status …"
    local retries=24 status=""
    for (( i=0; i<retries; i++ )); do
      status=$(openstack volume show "$MONGODB_VOLUME_NAME" -f value -c status 2>/dev/null || true)
      if [[ "$status" == "available" ]]; then
        success "Volume '${MONGODB_VOLUME_NAME}' is available"
        return
      fi
      sleep 5
    done
    error "Volume '${MONGODB_VOLUME_NAME}' did not reach 'available' status after $(( retries * 5 ))s"
    exit 1
  fi
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GREEN}━━━ Provisioning complete ━━━${NC}"
  echo ""
  echo "Resources created / verified:"
  echo "  Manila NFS share : ${NFS_SHARE_NAME} (${NFS_SIZE} GiB)"
  echo "  NFS ACL          : ${NOMAD_CLIENT_CIDR} → rw"
  if [[ "$SKIP_CINDER" != "true" ]]; then
    echo "  Cinder volume    : ${MONGODB_VOLUME_NAME} (${MONGODB_SIZE} GiB)"
  fi
  echo ""
  echo "Next steps:"
  echo "  1. Mount the NFS share on every Nomad client node"
  echo "  2. Register it as a Nomad host_volume in the client config"
  echo "  3. (CSI path) Attach the Cinder volume and register it with the CSI plugin"
  echo "  4. Set volume ownership: sudo chown -R 999:999 <mongodb_mount_point>"
  echo "  5. Add to your pack var-file:"
  echo "       nfs_shared_volume_enabled = true"
  echo "       db_storage_type           = \"host_volume\"  # or \"csi\""
  echo ""
  echo "See docs/openstack-storage-provisioning.md for full operator guide."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${CYAN}OpenStudio Server — OpenStack Storage Provisioner${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY-RUN mode — no resources will be created"
  fi
  echo ""

  preflight
  check_share_quota
  provision_nfs_share
  provision_nfs_access
  get_export_path
  validate_nfs_mount
  check_volume_quota
  provision_mongodb_volume
  print_summary
}

main
