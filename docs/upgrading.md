# Upgrade Guide

This guide documents operational upgrade steps for breaking changes that require manual
intervention. The current required migration is MongoDB `4.2` → `6.0.7` for persisted data.

## Table of Contents

1. [When this guide applies](#when-this-guide-applies)
2. [Version-gated upgrade matrix](#version-gated-upgrade-matrix)
3. [MongoDB upgrade path for persisted 4.2 data](#mongodb-upgrade-path-for-persisted-42-data)
4. [Rollback and restore procedure](#rollback-and-restore-procedure)
5. [Fresh deployments](#fresh-deployments)

## When this guide applies

Use this guide if **all** of the following are true:

- your deployment has existing MongoDB data on a persistent volume (`mongodb_storage_type` is
  `host_volume` or `csi`)
- your currently running MongoDB major version is `4.2`
- you are upgrading to a pack configuration that sets `db_image = "mongo:6.0.7"` (or higher)

If you use `mongodb_storage_type = "ephemeral"` or are deploying a new empty environment, you do
not need the stepwise migration path.

## Version-gated upgrade matrix

| Current deployment state | Target deployment state | Manual migration required? | Why |
|---|---|---|---|
| Pack/job currently running with `db_image = "mongo:4.2"` and persisted MongoDB volume | Any release/config using `db_image = "mongo:6.0.7"` default | **Yes** | MongoDB does not support skipping major data-file upgrades (`4.2 → 6.0`) |
| Pack/job currently running with `db_image = "mongo:4.2"` and `mongodb_storage_type = "ephemeral"` | Any release/config using `db_image = "mongo:6.0.7"` default | No (data is disposable) | No persistent data to migrate |
| Fresh deployment (no existing MongoDB data volume) | `db_image = "mongo:6.0.7"` | No | New data files are created directly on 6.0.7 |

## MongoDB upgrade path for persisted 4.2 data

### 1) Take a backup before changing versions

If `backup_enabled = true`, force a backup run and wait for completion:

```bash
nomad job periodic force <job_name>-state-backup
nomad job status <job_name>-state-backup
```

If backup jobs are disabled, run a direct backup:

```bash
mongodump --uri="mongodb://openstudio-db.service.consul:27017" --gzip --archive=mongo-pre-upgrade.archive.gz
```

Keep this archive until the 6.0.7 upgrade is fully verified.

### 2) Upgrade one major version at a time

Do **not** jump directly from `4.2` to `6.0.7`. Use this exact sequence:

1. `4.2` → `4.4`
2. `4.4` → `5.0`
3. `5.0` → `6.0.7`

For each step, set `db_image` in your override file, then redeploy:

```hcl
# upgrade-override.hcl
db_image = "mongo:4.4"
```

```bash
nomad-pack run . --name <job_name> -var-file upgrade-override.hcl
```

Wait until MongoDB is healthy before moving to the next step:

```bash
nomad job status <job_name>-db
```

### 3) Verify version after each hop

Run a Mongo shell version check against the running MongoDB allocation:

```bash
nomad job allocs <job_name>-db
```

```bash
nomad alloc exec -task mongodb <db-allocation-id> mongo --eval 'db.version()'
```

If `mongo` shell is unavailable in the selected image, use:

```bash
nomad alloc exec -task mongodb <db-allocation-id> mongosh --eval 'db.version()'
```

Proceed to the next major version only after confirming the current target version is running.

## Rollback and restore procedure

If a migration step fails, restore from the most recent known-good backup using the pack's
parameterized restore job:

```bash
nomad job dispatch \
  -meta MONGO_BACKUP_FILE=mongo-<timestamp>.archive.gz \
  -meta REDIS_BACKUP_FILE=redis-<timestamp>.dump.tsv \
  <job_name>-state-restore
```

Then redeploy with the prior known-good `db_image` and re-verify database startup before retrying.

## Fresh deployments

Fresh installs can start directly on `db_image = "mongo:6.0.7"` with no migration sequence.
The major-version hop requirement applies only to existing persisted MongoDB data created on 4.2.
