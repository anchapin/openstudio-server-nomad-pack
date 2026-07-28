#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get install -y nomad

install -o nomad -g nomad -m 0750 -d /opt/nomad
install -o nomad -g nomad -m 0750 -d /etc/nomad.d

cat <<'EOF' >/etc/nomad.d/nomad.hcl
datacenter = "dc1"
data_dir = "/opt/nomad"
bind_addr = "0.0.0.0"

advertise {
  http = "192.168.56.11:4646"
  rpc  = "192.168.56.11:4647"
  serf = "192.168.56.11:4648"
}

server {
  enabled          = true
  bootstrap_expect = 1
}

consul {
  address = "192.168.56.10:8500"
}

vault {
  enabled = true
  address = "http://192.168.56.13:8200"
}
EOF

chown -R nomad:nomad /etc/nomad.d /opt/nomad

cat <<'EOF' >/etc/systemd/system/nomad.service
[Unit]
Description=HashiCorp Nomad
Documentation=https://www.nomadproject.io/docs
After=network-online.target consul.service
Wants=network-online.target

[Service]
User=nomad
Group=nomad
ExecStart=/usr/bin/nomad agent -config=/etc/nomad.d
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nomad
systemctl restart nomad
