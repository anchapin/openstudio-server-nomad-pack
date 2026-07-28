#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get install -y consul

install -o consul -g consul -m 0750 -d /opt/consul
install -o consul -g consul -m 0750 -d /etc/consul.d

cat <<'EOF' >/etc/consul.d/consul.hcl
datacenter = "dc1"
data_dir = "/opt/consul"
server = true
bootstrap_expect = 1
bind_addr = "192.168.56.10"
client_addr = "0.0.0.0"
ui_config {
  enabled = true
}
EOF

chown -R consul:consul /etc/consul.d /opt/consul

cat <<'EOF' >/etc/systemd/system/consul.service
[Unit]
Description=HashiCorp Consul
Documentation=https://www.consul.io/
After=network-online.target
Wants=network-online.target

[Service]
User=consul
Group=consul
ExecStart=/usr/bin/consul agent -config-dir=/etc/consul.d
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable consul
systemctl restart consul
