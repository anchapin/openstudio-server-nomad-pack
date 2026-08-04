# Traefik on Jump Host

Traefik v2.11.2 runs as a systemd service on the jump host (`10.60.126.125`) to provide external HTTP access to the OpenStudio Server web UI.

## Access URLs

- **OpenStudio Server**: http://10.60.126.125/
- **Traefik Dashboard**: http://10.60.126.125:8080/dashboard/

## Files on Jump Host

- `/usr/local/bin/traefik` — Traefik v2.11.2 binary (linux/amd64)
- `/etc/traefik/traefik.yml` — static configuration
- `/etc/systemd/system/traefik.service` — systemd unit

## Config: `/etc/traefik/traefik.yml`

```yaml
entryPoints:
  web:
    address: ':80'
  websecure:
    address: ':443'

api:
  dashboard: true
  insecure: true

ping: {}

log:
  level: INFO

providers:
  consulCatalog:
    endpoint:
      # Consul Catalog endpoint must be host:port (no URL scheme).
      address: '127.0.0.1:8500'
    exposedByDefault: false
    defaultRule: 'PathPrefix(`/`)'
```

## Config: `/etc/systemd/system/traefik.service`

```ini
[Unit]
Description=Traefik reverse proxy
After=network.target consul.service

[Service]
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## How It Works

- Traefik uses the Consul Catalog provider to auto-discover services
- Only services tagged with `traefik.enable=true` are exposed (`exposedByDefault: false`)
- The `openstudio-web` Consul service has the tag set via the Nomad job
- Traffic to port 80 is forwarded to `192.168.100.173:80` (web Nomad alloc)

## Installing the Binary

The jump host has no internet access. Copy the binary from a machine that does:

```bash
# On local machine:
curl -sL -o /tmp/traefik.tar.gz \
  https://github.com/traefik/traefik/releases/download/v2.11.2/traefik_v2.11.2_linux_amd64.tar.gz
tar -xzf /tmp/traefik.tar.gz -C /tmp traefik
scp /tmp/traefik ubuntu@10.60.126.125:/tmp/traefik
ssh ubuntu@10.60.126.125 "sudo mv /tmp/traefik /usr/local/bin/traefik && sudo chmod +x /usr/local/bin/traefik"
```

## Service Management

```bash
sudo systemctl status traefik
sudo systemctl restart traefik
sudo journalctl -u traefik -f
```

## Ingress Smoke Check (recommended after every Traefik restart)

Run from the pack repo root:

```bash
./scripts/check-openstack-ingress.sh
```

Or through the OpenStack helper wrapper:

```bash
make os-ingress-check
```
