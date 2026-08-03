# Swift / Object-Storage Artifact Backend

## Overview

By default, OpenStudio Server stores analysis artifacts (result files, OSW outputs, reports) on a shared filesystem — typically NFS or a Docker named volume — that all web and worker allocations mount at `nfs_volume_mount_path`.

This pack supports an **opt-in object-storage mode** that injects OpenStack Swift credentials and the `ARTIFACT_STORAGE_BACKEND=swift` env var into web and worker tasks. When the application detects this env var it routes artifact I/O through the Swift API instead of the local filesystem.

### When to use Swift vs NFS

| Scenario | Recommended backend |
|---|---|
| Single-node dev / CI | NFS (default) — simpler, no object-storage dependency |
| Multi-node cluster, artifacts must survive task rescheduling | Swift / object storage |
| Very large result files (> 1 GB) | Swift — avoids NFS saturation |
| Air-gapped / on-prem OpenStack | Swift |
| AWS / GCP / Azure | S3/GCS/Azure Blob (via S3-compatible middleware) |

> **Application requirement:** The OpenStudio Server application must be built with support for `ARTIFACT_STORAGE_BACKEND=swift`. This pack only injects env vars — it does not modify the application binary.

---

## Required OpenStack Swift Setup

Before enabling this feature, provision the following in your OpenStack project:

### 1. Create the container

```bash
openstack container create openstudio-artifacts
```

### 2. Set container ACLs

Grant read/write access to the service account:

```bash
# Allow the service user to read and write objects
openstack object store account set \
  --property "X-Account-Access-Control" \
  '{"admin": ["<service-user-id>"]}'
```

Or via Swift CLI:

```bash
swift post openstudio-artifacts \
  --read-acl "<project-id>:<service-user-id>" \
  --write-acl "<project-id>:<service-user-id>"
```

### 3. Verify connectivity

```bash
export OS_AUTH_URL=https://keystone.example.com:5000/v3
export OS_USERNAME=openstudio-service
export OS_PASSWORD=<password>
export OS_TENANT_NAME=openstudio-project
export OS_REGION_NAME=RegionOne

swift list
swift stat openstudio-artifacts
```

---

## Variable Configuration Reference

| Variable | Default | Description |
|---|---|---|
| `swift_artifact_storage_enabled` | `false` | Master switch. Set to `true` to enable Swift mode. |
| `swift_auth_url` | `""` | Keystone endpoint (OS_AUTH_URL). E.g. `https://keystone.example.com:5000/v3` |
| `swift_username` | `""` | OpenStack username (OS_USERNAME) |
| `swift_password` | `""` | OpenStack password (OS_PASSWORD). Use Vault in production. |
| `swift_tenant_name` | `""` | Project/tenant name (OS_TENANT_NAME) |
| `swift_container` | `"openstudio-artifacts"` | Swift container name (SWIFT_CONTAINER) |
| `swift_region` | `""` | Region name (OS_REGION_NAME). Leave empty for default. |
| `swift_auth_version` | `"3"` | Keystone API version (`"2"` or `"3"`) |

### Example var-file snippet

```hcl
swift_artifact_storage_enabled = true
swift_auth_url                 = "https://keystone.example.com:5000/v3"
swift_username                 = "openstudio-service"
swift_password                 = "changeme"   # use vault_integration_enabled instead
swift_tenant_name              = "openstudio"
swift_container                = "openstudio-artifacts"
swift_region                   = "RegionOne"
swift_auth_version             = "3"
```

### Production: use Vault to inject the password

Set `vault_integration_enabled = true` and store `OS_PASSWORD` in the Vault KV path configured by `vault_kv_app_path`. Leave `swift_password = ""` so the plaintext variable is never rendered into the job spec.

---

## Migration: NFS → Swift

Follow these steps to migrate a running stack from NFS to Swift artifact storage.

### Step 1 — Provision the Swift container

See [Required OpenStack Swift Setup](#required-openstack-swift-setup) above.

### Step 2 — Copy existing artifacts to Swift (optional)

If you need to preserve historical artifacts for retrieval:

```bash
# On the NFS host
cd /mnt/openstudio/server/assets/analyses
for dir in */; do
  swift upload openstudio-artifacts "$dir"
done
```

### Step 3 — Drain workers

```bash
nomad job stop <job_name>-worker
```

Wait for all running analyses to complete (check `<job_name>-worker` job status).

### Step 4 — Update variables and redeploy

```hcl
# Add to your var-file
swift_artifact_storage_enabled = true
swift_auth_url                 = "https://keystone.example.com:5000/v3"
# ... remaining Swift vars
```

```bash
nomad-pack run --name <job_name> -var-file <your-var-file>.hcl .
```

### Step 5 — Validate

1. Submit a small test analysis through the web UI.
2. Confirm the result file appears in the Swift container:
   ```bash
   swift list openstudio-artifacts
   ```
3. Download and verify a result file:
   ```bash
   swift download openstudio-artifacts <analysis-id>/result.zip
   ```

### Step 6 — Decommission NFS (optional)

Once validated, you may disable the NFS volume:

```hcl
nfs_shared_volume_enabled = false
```

---

## Rollback Procedure

To revert to NFS mode:

1. Set `swift_artifact_storage_enabled = false` (or remove the variable) in your var-file.
2. Ensure `nfs_shared_volume_enabled = true` and the NFS volume is mounted.
3. Redeploy:
   ```bash
   nomad-pack run --name <job_name> -var-file <your-var-file>.hcl .
   ```
4. Artifacts written during Swift mode will not be accessible via NFS unless manually copied back:
   ```bash
   swift download --all openstudio-artifacts -D /mnt/openstudio/server/assets/analyses/
   ```

---

## Compatibility Note

This feature requires **OpenStudio Server ≥ 3.x** with Swift support compiled in. Older application images that do not recognise `ARTIFACT_STORAGE_BACKEND=swift` will silently fall back to local filesystem writes. Verify your image version supports this env var before enabling.

Refer to [docs/compatibility.md](compatibility.md) for the pack ↔ application version matrix.
