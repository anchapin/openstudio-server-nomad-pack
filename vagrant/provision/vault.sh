#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get install -y vault

install -o vault -g vault -m 0750 -d /etc/vault.d
install -o vault -g vault -m 0750 -d /opt/vault

cat <<'EOF' >/etc/vault.d/vault.env
VAULT_ADDR=http://0.0.0.0:8200
VAULT_DEV_ROOT_TOKEN_ID=root
VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200
VAULT_API_ADDR=http://192.168.56.13:8200
EOF

chown -R vault:vault /etc/vault.d /opt/vault

cat <<'EOF' >/etc/systemd/system/vault.service
[Unit]
Description=HashiCorp Vault (dev mode)
Documentation=https://developer.hashicorp.com/vault/docs
After=network-online.target
Wants=network-online.target

[Service]
User=vault
Group=vault
EnvironmentFile=/etc/vault.d/vault.env
ExecStart=/usr/bin/vault server -dev
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vault
systemctl restart vault
