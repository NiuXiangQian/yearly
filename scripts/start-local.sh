#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/manage.sh test migrate
api_pid=''
frontend_pid=''
cleanup() {
  trap - EXIT INT TERM
  [ -z "$api_pid" ] || kill "$api_pid" 2>/dev/null || true
  [ -z "$frontend_pid" ] || kill "$frontend_pid" 2>/dev/null || true
  wait || true
}
trap cleanup EXIT INT TERM
./scripts/start-api.sh test --reload --reload-dir backend/app &
api_pid=$!
(cd frontend && exec node_modules/.bin/vite --host 127.0.0.1 --port 5173 --strictPort) &
frontend_pid=$!
echo 'Test environment uses MySQL. Open http://127.0.0.1:5173/'
while kill -0 "$api_pid" 2>/dev/null && kill -0 "$frontend_pid" 2>/dev/null; do
  sleep 1
done
exit 1
