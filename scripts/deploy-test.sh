#!/usr/bin/env bash
set -euo pipefail
base=/opt/yearly-test
release=$(cd "$(dirname "$0")/.." && pwd)
revision=$(cat "$release/REVISION")
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid release revision' >&2; exit 1; }
test -f "$base/config/.env.test"
test -f "$base/config/mysql-ca.pem"
python_image=python:3.12-slim-bookworm
if [ -f "$base/config/python-image" ]; then
  python_image=$(cat "$base/config/python-image")
fi
image="yearly-test:$revision"
docker build --network host --build-arg "PYTHON_IMAGE=$python_image" -t "$image" -f "$release/deploy/Dockerfile" "$release"
common=(--network host --read-only --cap-drop ALL --security-opt no-new-privileges
  --log-opt max-size=10m --log-opt max-file=3
  -e APP_ENV=test
  --mount "type=bind,source=$base/config/.env.test,target=/app/.env.test,readonly"
  --mount "type=bind,source=$base/config/mysql-ca.pem,target=/app/certs/mysql-ca.pem,readonly")
mkdir -p "$base/tmp/api" "$base/tmp/previews"
chown 10001:10001 "$base/tmp/api" "$base/tmp/previews"
# Stop only yearly-test containers before updating its test schema.
for name in yearly-test-previews yearly-test-api; do
  if docker container inspect "$name" >/dev/null 2>&1; then docker stop "$name"; fi
done
docker run --rm "${common[@]}" "$image" alembic -c backend/alembic.ini upgrade head
for name in yearly-test-previews yearly-test-api; do
  if docker container inspect "$name" >/dev/null 2>&1; then docker rm "$name"; fi
done
docker run -d --name yearly-test-api --restart unless-stopped \
  "${common[@]}" --memory 384m --memory-swap 768m --cpus 0.5 \
  --mount "type=bind,source=$base/tmp/api,target=/tmp" "$image"
healthy=false
for attempt in {1..30}; do
  if curl --fail --silent http://127.0.0.1:18080/api/health > "$base/health.json"; then
    healthy=true
    break
  fi
  sleep 2
done
if [ "$healthy" != true ]; then
  echo 'yearly-test API health check failed; inspect docker logs yearly-test-api' >&2
  exit 1
fi
docker run -d --name yearly-test-previews --restart unless-stopped \
  "${common[@]}" --memory 512m --memory-swap 1g --cpus 1 \
  --mount "type=bind,source=$base/tmp/previews,target=/tmp" \
  "$image" python -m app.cli generate-previews --watch
ln -sfn "$release" "$base/current.next"
mv -Tf "$base/current.next" "$base/current"
printf 'Deployed yearly-test %s\n' "$revision"
cat "$base/health.json"
