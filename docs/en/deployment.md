# Deploy with an existing MySQL and Nginx installation

[简体中文](../deployment.md) | **English** · [Home](../../README.en.md)

## Environment selection

Local testing uses `.env.test`, `yearly_test`, and a dedicated test database account. Start it with `scripts/start-local.sh`. Production uses `.env.production`, `yearly`, and a separate production account. Both environments use MySQL; the interface and health endpoint identify the active environment. The following steps target production. Skip initial database/schema creation if it has already been completed.

## 1. Runtime dependencies

Use Linux, Python 3.12, Node.js 22.12+, MySQL 5.7.8+, and Nginx. JSON columns require at least MySQL 5.7.8; use the latest available 5.7 patch release. Docker and additional MySQL / Nginx containers are not required. Keep the database clock in UTC; local capture times are stored separately as DATETIME values.

Place the repository at `/opt/yearly` and create a `yearly` system user. The Nginx user must be able to read `frontend/dist`. Set `.env.production` permissions to 600 and its owner to `yearly`. Application code and the virtual environment can be read-only at runtime. The API does not store media locally, but the video preview worker needs enough temporary space for an original and its compressed copy; it removes temporary files after processing.

```bash
cd /opt/yearly
python3.12 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
cp .env.production.example .env.production
chmod 600 .env.production
# Generate SESSION_SECRET with secrets.token_urlsafe(48), save it in .env.production,
# and keep the configuration private.
```

Production requires `APP_ENV=production` and `COOKIE_SECURE=true`. Set `ALLOWED_ORIGIN` to the exact HTTPS origin of the site, without a trailing `/`. Local testing uses `APP_ENV=test` and a separate `.env.test` with Secure cookies disabled. The application validates these requirements on production startup. URL-encode special characters in database passwords. Never commit `.env.production` to version control.

## 2. Create application databases in MySQL

A database administrator should run this only during initial setup. Skip it for an initialized deployment. Generate the two passwords independently.

```sql
CREATE DATABASE yearly CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE yearly_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'yearly_app'@'%' IDENTIFIED BY 'REPLACE_WITH_RANDOM_PRODUCTION_PASSWORD' REQUIRE SSL;
CREATE USER 'yearly_test_app'@'%' IDENTIFIED BY 'REPLACE_WITH_RANDOM_TEST_PASSWORD' REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES
  ON `yearly`.* TO 'yearly_app'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES
  ON `yearly\_test`.* TO 'yearly_test_app'@'%';
```

These example accounts allow remote connections from a development machine and require TLS. Each account is restricted to its own database; the underscore is escaped in the grant. Set the corresponding account and trusted CA path in `DATABASE_URL`. If the source address is fixed, restrict the account Host accordingly. The grants include CREATE / ALTER / INDEX / DROP / REFERENCES for schema migrations.

```bash
export APP_ENV=production
export PYTHONPATH="$PWD/backend"
# Reads the production database account from .env.production
.venv/bin/alembic -c backend/alembic.ini upgrade head
.venv/bin/python -m app.cli create-admin your-admin-name
```

Alternatively, import `deploy/schema-mysql57.sql` manually and then run `alembic -c backend/alembic.ini stamp 0006`. Choose one initialization method. For an existing database, run `./scripts/manage.sh production migrate` to upgrade to `0006` before starting the new backend. Tables use InnoDB / utf8mb4, BIGINT IDs, DATETIME(3) timestamps, DECIMAL coordinates, and JSON metadata. The models do not rely on MySQL 8-only SQL.

## 3. Configure private OSS

Follow [storage and metadata](storage-and-metadata.md) to create or choose a private bucket and configure the region required for V4 signing, CORS, RAM permissions, and an HTTPS domain. Use a dedicated RAM user's credentials in production, never the main account's access keys. Store them only in the server's `.env.production`.

## 4. Build the frontend

```bash
cd frontend
npm ci
npm test
npm run build
cd ..
```

The frontend uses same-origin `/api`. It does not need database passwords or permanent OSS keys. For updates, build in a temporary release directory and switch releases atomically so users do not receive an incomplete `dist` directory.

## 5. Start systemd services

```bash
sudo cp deploy/yearly.service deploy/yearly-previews.service /etc/systemd/system/
sudo cp deploy/yearly-cleanup.service deploy/yearly-cleanup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now yearly.service yearly-previews.service yearly-cleanup.timer
sudo systemctl status yearly.service
```

The default single API worker avoids keeping duplicate Python processes in memory on small servers. Blocking SDK and SQL calls run in FastAPI's synchronous route thread pool. Task state and login limits persist in MySQL, so restarts preserve previously issued tasks. Adjust the worker count after measuring CPU and memory usage.

The service listens only on `127.0.0.1`. `--forwarded-allow-ips=127.0.0.1` trusts proxy headers only from local Nginx. Do not expose port 8000 directly to the internet.

Enable `yearly-previews.service` as well, or new videos will remain in the “preview preparing” state. Every 15 seconds it discovers completed new and historical uploads, transcodes them sequentially, and reuses copies by SHA-256. `imageio-ffmpeg` supplies a standalone FFmpeg executable. If no wheel is available for the platform, install system FFmpeg and set `IMAGEIO_FFMPEG_EXE=/absolute/path/ffmpeg`. It must support libx264, AAC, zscale, and tonemap. Transcoding uses two encoding threads; check temporary disk space and CPU quotas before deployment.

```bash
# Process historical videos once instead of running a persistent worker.
# Run only one generator per database.
./scripts/manage.sh production generate-previews
# Stop the persistent worker before retrying failed tasks.
sudo systemctl stop yearly-previews.service
./scripts/manage.sh production generate-previews --retry-failed
sudo systemctl start yearly-previews.service
journalctl -u yearly-previews.service
```

## 6. Configure Nginx

Merge `deploy/nginx.conf` into the existing Nginx `http {}` context. Replace the site domain, certificates, static root, and OSS / custom domains in the CSP. `log_format` and `limit_req_zone` belong at the `http` level, not inside a `server` block.

```bash
sudo nginx -t
sudo systemctl reload nginx
curl --fail https://yearly.example.com/api/health
```

Issue and renew certificates using your existing ACME workflow. Enable HTTPS before opening access to family accounts. The CSP permits hash-wasm WebAssembly and Element Plus inline styles, but not third-party analytics scripts. Multipart PUT requests go directly to OSS; Nginx's 2 MiB request limit applies only to metadata API requests.

## 7. Release acceptance checks

1. Log in and confirm the cookie has HttpOnly, Secure, and SameSite=Strict attributes.
2. Create two children with different birthdays and upload a shared photo. In the network panel, PUT requests should target OSS; the API should not receive file binaries.
3. Check counts in each child's timeline and the combined timeline. Download the original and compare its SHA-256.
4. Interrupt a large multipart video upload. After refreshing, reselect the same original to resume; uploaded parts should be skipped.
5. Check local HEIC / MOV compatibility, paired Live Photo files, GPS, and capture times using originals from real devices.
6. Perform a restore drill using the backup guide.

## Operations

- Use `journalctl -u yearly.service` for service logs without access parameters. SQL parameters are hidden, OSS SDK logging is set to WARNING, and error responses do not expose raw signed URLs from the SDK.
- `yearly-cleanup.timer` cleans expired authorizations, incomplete multipart uploads, and authentication records daily. Original objects are retained. Configure OSS lifecycle cleanup for incomplete multipart uploads, but do not set originals to expire automatically.
- Run backups and restores in a maintenance window. Stop writes before taking a complete snapshot. Exports contain family information: use directory permissions 700 and file permissions 600, and keep encrypted off-site copies.
- Changing `SESSION_SECRET` invalidates all sessions. Changing a password invalidates all sessions for that account.
- Before the first real deployment, run `scripts/test.sh` against the separate test environment and verify Nginx / MySQL / OSS settings for your installation. Local development verification is not proof of a production release.
