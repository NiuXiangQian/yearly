#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -lt 2 ]; then
  echo 'Usage: manage.sh test|production migrate|create-admin|cleanup|verify-oss|backup|restore [arguments]' >&2
  exit 2
fi
export APP_ENV=$1
shift
case "$APP_ENV" in test|production) ;; *) echo 'APP_ENV must be test or production' >&2; exit 2 ;; esac
if [ ! -f ".env.$APP_ENV" ]; then
  echo "Missing .env.$APP_ENV" >&2
  exit 1
fi
export PYTHONPATH="$PWD/backend"
command_name=$1
shift
if [ "$command_name" = migrate ]; then
  exec .venv/bin/alembic -c backend/alembic.ini upgrade head "$@"
fi
exec .venv/bin/python -m app.cli "$command_name" "$@"
