#!/usr/bin/env bash
# Attach a 20GB Cinder volume as Docker + containerd data root on CM.Medium/Tiny nodes.
# Moves both /var/lib/docker and containerd root to the Cinder volume (overlay2 on ext4).
# Usage: sudo bash attach-docker-volume.sh
set -euo pipefail
HOSTNAME=$(hostname)
DOCKER_ROOT="/var/lib/docker-local"
CONTAINERD_ROOT="${DOCKER_ROOT}/containerd"

NEW_DEV=""
for dev in /dev/vdb /dev/vdc /dev/vdd; do
  [ -b "$dev" ] || continue
  SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null || echo 0)
  [ "${SIZE}" -gt 19000000000 ] && [ "${SIZE}" -lt 22000000000 ] && NEW_DEV="$dev" && break
done
[ -z "$NEW_DEV" ] && { echo "[${HOSTNAME}] ERROR: no 20GB device found"; lsblk; exit 1; }
echo "[${HOSTNAME}] Using $NEW_DEV ($(lsblk -no SIZE $NEW_DEV))"

TYPE=$(blkid -s TYPE -o value "$NEW_DEV" 2>/dev/null || echo "")
[ "$TYPE" != "ext4" ] && mkfs.ext4 -L docker-data "$NEW_DEV"

systemctl stop nomad docker docker.socket containerd 2>/dev/null || true; sleep 3

# Update Docker daemon.json
[ -f /etc/docker/daemon.json ] || echo '{}' > /etc/docker/daemon.json
python3 -c "
import json
with open('/etc/docker/daemon.json') as f: d=json.load(f)
d['data-root']='${DOCKER_ROOT}'
with open('/etc/docker/daemon.json','w') as f: json.dump(d,f,indent=2)
"

# Mount Cinder volume
mkdir -p "$DOCKER_ROOT" "$CONTAINERD_ROOT" /etc/containerd
UUID=$(blkid -s UUID -o value "$NEW_DEV")
grep -q "$UUID" /etc/fstab || echo "UUID=${UUID}  ${DOCKER_ROOT}  ext4  defaults,nofail  0 2" >> /etc/fstab
mountpoint -q "$DOCKER_ROOT" || mount "$NEW_DEV" "$DOCKER_ROOT"
mkdir -p "$CONTAINERD_ROOT"

# Copy existing Docker data if present
[ -d /var/lib/docker ] && [ "$(ls -A /var/lib/docker 2>/dev/null)" ] && \
  cp -a /var/lib/docker/. "$DOCKER_ROOT/" 2>/dev/null || true

# Configure containerd to use Cinder volume (root must be top-level)
cat > /etc/containerd/config.toml << 'TOML'
root = "/var/lib/docker-local/containerd"
state = "/run/containerd"
[grpc]
  address = "/run/containerd/containerd.sock"
[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
TOML

# Start services and pull image
systemctl start containerd; sleep 3
systemctl start docker; sleep 5
IMAGE="pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-server:179-flock"
docker image inspect "$IMAGE" &>/dev/null || docker pull "$IMAGE"

# Cleanup and maintenance cron
rm -rf /var/lib/docker.old "${DOCKER_ROOT}.old" 2>/dev/null || true
journalctl --vacuum-size=50M 2>/dev/null || true
apt-get clean -y 2>/dev/null || true
cat > /etc/cron.daily/journal-vacuum << 'CRON'
#!/bin/sh
journalctl --vacuum-size=50M; apt-get clean -y 2>/dev/null || true
CRON
chmod 755 /etc/cron.daily/journal-vacuum

systemctl start nomad
echo "[${HOSTNAME}] DONE. Root: $(df -h / | awk 'NR==2{print $5}') Docker vol: $(df -h ${DOCKER_ROOT} | awk 'NR==2{print $3"/"$2" ("$5")"}')"
