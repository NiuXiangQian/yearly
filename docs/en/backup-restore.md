# Recoverable backups and long-term migration

[简体中文](../backup-restore.md) | **English** · [Home](../../README.en.md)

## What a backup contains

A complete backup includes a full MySQL dump, a portable `manifest.json`, individual copies of original OSS objects, and SHA-256 / CRC64 records. JSON / CSV downloads are manifests only; use the CLI to back up original files. A full MySQL dump contains account password hashes and sessions. The portable manifest intentionally excludes `sys_user`, `user_session`, `captcha`, `login_guard`, and `upload_task`.

The yearly manifest preserves stable IDs for children, media, physical files, metadata, `media_child`, events, ordered `event_media`, and `event_child`. Changing a nickname or avatar does not change these relationships.

## Create a backup

Use `mysqldump` / `mysql` clients compatible with MySQL 5.7. Start a maintenance window, pause content creation and changes, and wait for uploads to finish. You can temporarily restrict Nginx access to a maintenance administrator. Do not modify the database or perform physical OSS maintenance while creating the snapshot and downloading originals.

Use directory permissions 700 for backup storage and permissions 600 for the following MySQL client configuration. Fill in the actual backup account locally. Do not put passwords in command-line arguments or commit them to Git.

```ini
[client]
host=127.0.0.1
user=yearly_backup
password=REPLACE_WITH_BACKUP_PASSWORD
```

```bash
cd /opt/yearly
umask 077
mkdir -p /secure-backups/yearly-20261103
./deploy/backup-mysql.sh /secure/mysql-client.cnf yearly \
  /secure-backups/yearly-20261103/mysql.sql.gz
export APP_ENV=production
export PYTHONPATH="$PWD/backend"
.venv/bin/python -m app.cli backup /secure-backups/yearly-20261103
```

The CLI writes `manifest.json` and `objects/<media_file.id>`. It checks each object with HEAD, downloads the original, and calculates SHA-256 in 4 MiB chunks. Downloads use temporary `.partial` files and are renamed atomically after validation. Repeated runs skip correctly backed-up originals. All complete files are included, including originals of soft-deleted media. Original filenames stay in the manifest; local copies use IDs to avoid collisions and path injection.

Mark a backup complete only after the command exits successfully. An interrupted backup must not be your only recovery source. Copy the entire directory to encrypted off-site storage, retain multiple versions, and periodically check SHA-256 values.

`verify-oss` compares object size, CRC64, and declared SHA-256 metadata. `backup` verifies SHA-256 from all file bytes. The former is faster; the latter generates OSS download traffic.

## Option 1: Restore the full MySQL dump

Prepare a separate empty database and the original bucket or its complete restored copy. Do not import over a database that already contains content.

```bash
./deploy/restore-mysql.sh /secure/mysql-client.cnf yearly_restored \
  /secure-backups/yearly-20261103/mysql.sql.gz
```

Point `.env.production` to the restored database. The dump preserves the Alembic revision, so do not repeat initial schema creation. Delete restored `user_session` records or rotate `SESSION_SECRET` to invalidate old sessions. OSS bucket names and keys must match the database. To move to a different bucket, use the portable restore workflow to rebuild keys and integrity relationships together.

## Option 2: Restore the portable JSON and originals

1. Run Alembic migrations on a new database.
2. Use `create-admin` to create the target administrator and record the user ID, usually 1 in a new empty database.
3. Configure the target private bucket and domain in `.env.production`.
4. Restore from the offline copy.

```bash
export APP_ENV=production
export PYTHONPATH="$PWD/backend"
.venv/bin/python -m app.cli restore /secure-backups/yearly-20261103/manifest.json \
  --owner-id 1 --objects /secure-backups/yearly-20261103/objects
.venv/bin/python -m app.cli verify-oss
```

The restore command streams JSON to limit memory use, prechecks object sizes and SHA-256, and restores large files using single-threaded OSS `resumable_upload`. Uploads forbid overwrites; existing objects must pass validation. After all objects are verified, tables are restored in dependency order within one database transaction. Child avatar foreign keys are filled in last. The target content database must be empty. Interrupted uploads can be rerun; database failures can be investigated and retried without overwriting originals.

Omit `--objects` only when restoring the manifest while keeping the same original bucket. Preserve the original bucket and keys, then immediately run `verify-oss`. If the target bucket differs, include `--objects`; otherwise database references and actual storage may not match.

The owner / `created_by` of completed files is mapped to the specified administrator. Stable media, child, file, and journal IDs remain unchanged. Portable manifests do not restore passwords, sessions, or upload authorizations; recreate family accounts.

## Restore acceptance checks

- Compare counts of children, media, events, and physical files against the portable manifest.
- Confirm a shared photo appears under both children and only once in the combined timeline.
- Verify shared journal child associations, explicit media order, and covers.
- Change a test child's birthday, verify ages recalculate from capture dates, then restore the birthday.
- Download HEIC / MOV originals and recompute SHA-256; sample photo EXIF and video duration.
- Reopen normal family access only after originals pass verification. Perform an independent restore drill at least quarterly.

The recycle bin restores logical media and journals. Deleting a child normally removes associations; historical backups retain earlier relationships. The application has no physical permanent-delete entry point. Any physical cleanup must be a separate administrator maintenance operation after verifying backups.

New exports use `yearly` as the manifest format. Imports also accept the historical format from before the project rename, preserving the same stable-ID and relationship restoration rules.
