#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release unzip docker.io jq

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" >/etc/apt/sources.list.d/hashicorp.list
apt-get update

systemctl enable docker
systemctl start docker

for service_user in consul nomad vault; do
  if ! id -u "${service_user}" >/dev/null 2>&1; then
    useradd --system --home "/etc/${service_user}.d" --shell /bin/false "${service_user}"
  fi
done

if ! grep -q "192.168.56.10 consul" /etc/hosts; then
  cat <<'EOF' >>/etc/hosts
192.168.56.10 consul
192.168.56.11 nomad-server
192.168.56.12 nomad-client
192.168.56.13 vault
EOF
fi
