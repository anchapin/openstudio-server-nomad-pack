# Quickstart: Run Your First Batch Simulation

This guide gets OpenStudio Server running on a single Nomad node in about
10 minutes. No Vault, no Consul Connect, no autoscaling — just simulations.

## Prerequisites

- A running Nomad cluster (≥ 1.5) with Consul (≥ 1.15)
- [`nomad-pack`](https://developer.hashicorp.com/nomad/tutorials/nomad-pack/nomad-pack-intro) installed
- Docker available on at least one Nomad client node

For a full local dev environment on macOS or Linux, see the cluster setup
guide in [`docs/infrastructure/`](../infrastructure/).

---

## Step 1 — Choose Your OpenStudio Server Version

Check available versions at:
- <https://hub.docker.com/r/nrel/openstudio-server/tags>
- <https://hub.docker.com/r/nrel/openstudio-rserve/tags>

---

## Step 2 — Create Your Overrides File

Copy the template from the repository root:

```bash
cp user-overrides.hcl my-deployment.hcl
```

Open `my-deployment.hcl` and uncomment the four image lines, setting your
chosen version tag:

```hcl
web_image            = "nrel/openstudio-server:3.8.0"
web_background_image = "nrel/openstudio-server:3.8.0"
worker_image         = "nrel/openstudio-server:3.8.0"
rserve_image         = "nrel/openstudio-rserve:3.8.0"
```

Optionally set the number of parallel simulation workers:

```hcl
worker_count = 4
```

---

## Step 3 — Deploy

```bash
nomad-pack run -var-file my-deployment.hcl .
```

Nomad will start the following jobs:
- `openstudio-server-web` — the web UI and API
- `openstudio-server-worker` — simulation worker(s)
- `openstudio-server-db` — MongoDB
- `openstudio-server-redis` — Redis queue
- `openstudio-server-rserve` — R analysis server

---

## Step 4 — Verify

Wait 60–90 seconds for all services to become healthy, then open:

```
http://<your-nomad-client-ip>:80
```

You should see the OpenStudio Server web interface.

To check job status from the command line:

```bash
nomad job status openstudio-server-web
nomad job status openstudio-server-worker
```

---

## Step 5 — Submit a Simulation

See [Submitting OSW Jobs](submitting-osw-jobs.md) for how to submit
an OpenStudio Workflow (OSW) file or a Parametric Analysis Tool (PAT)
project to the server.

---

## Stopping the Server

```bash
nomad-pack destroy --name openstudio-server .
```

---

## Need More Help?

- [Submitting OSW Jobs](submitting-osw-jobs.md)
- [Infrastructure & Admin Docs](../infrastructure/)
- [Variable Reference](../variables.md)
