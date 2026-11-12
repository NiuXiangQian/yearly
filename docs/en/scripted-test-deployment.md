# Scripted test deployment

[简体中文](../scripted-test-deployment.md) | **English** · [Home](../../README.en.md)

Build the frontend locally, upload a release archive, and run the API and video preview worker in separate Docker containers on an existing Linux server. Reuse Nginx, MySQL, and private OSS. This flow reads only the server's test configuration; the database name must end in `_test`.

## Prepare the server once

Install Docker, Nginx, Bash, Python 3, and curl, then prepare:

- `/opt/yearly-test/config/.env.test`, based on `.env.test.example`, with `APP_ENV=test`, the test database account, and OSS settings. For an HTTP test site, use `COOKIE_SECURE=false` and `ALLOWED_ORIGIN=http://yearly.example.com`.
- `/opt/yearly-test/config/mysql-ca.pem`, the trusted MySQL CA. Set `ssl_ca=/app/certs/mysql-ca.pem` in `DATABASE_URL`; a database on the same server can use `127.0.0.1`.
- The test environment file must be owned by UID/GID `10001:10001` with mode `600`; use mode `700` for its parent directory. Configuration files are mounted read-only and are excluded from images and release archives.
- The default Python image is `python:3.12-slim-bookworm`. To use an image mirror, write the full reference, preferably with a digest, to `/opt/yearly-test/config/python-image`.

Replace `YEARLY_HOST` and `YEARLY_OSS_ORIGINS` in `deploy/nginx-test.conf` with the test hostname and HTTPS OSS origins. Include this file inside the existing Nginx `http {}` block, validate with `nginx -t`, and reload. The API listens only on `127.0.0.1:18080`; Nginx serves the frontend.

## Build and deploy

The local machine needs Node.js 22.12+, Git, and SSH. Commit the source you intend to deploy so it matches the recorded revision, then run:

```bash
./scripts/deploy-remote-test.sh your-user@your-server 22
```

This installs dependencies, runs all frontend tests, type-checks, builds, and packages explicit backend/frontend/deployment paths. Environment files, credentials, photos, and local artifacts are excluded. SSH uses an existing key or an interactive password, never a password stored in the deployment script.

For separate steps:

```bash
./scripts/build-release.sh
scp yearly-test.tgz your-user@your-server:/opt/yearly-test/incoming/
# After extracting into a new /opt/yearly-test/releases/<release> directory:
bash /opt/yearly-test/releases/<release>/deploy/deploy-test.sh
```

The server script builds the Python image, stops only `yearly-test-api` and `yearly-test-previews`, migrates the test database, starts the API, waits for its database health check, starts the worker, and switches the static `current` symlink. Containers have restart policies and memory, CPU, and log limits. Test service downtime is expected during deployment. Migration or health failures return a nonzero exit status; inspect container logs before proceeding.

```bash
curl --fail http://yearly.example.com/api/health
docker ps --filter name=yearly-test
docker logs --tail 50 yearly-test-api
docker logs --tail 50 yearly-test-previews
```

Health must report `environment: test`. Sign in with an existing test account. For an empty database, follow the deployment guide and run `python -m app.cli create-admin` interactively inside a configured container. Run cleanup with `docker exec yearly-test-api python -m app.cli cleanup`, scheduling it as needed.

## Share the test database with local development

Only one video preview worker may use the same database. Once the server owns previews, start local development with:

```bash
YEARLY_LOCAL_PREVIEWS=false ./scripts/start-local.sh
```

The local API and frontend still run; the server generates video previews.
