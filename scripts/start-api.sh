#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${APP_ENV:-test}"
if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
  profile=$1
  shift
fi
case "$profile" in test|production) ;; *) echo 'Usage: start-api.sh [test|production] [uvicorn options]' >&2; exit 2 ;; esac
if [ ! -f ".env.$profile" ]; then
  echo "Missing .env.$profile. Copy .env.$profile.example and configure MySQL first." >&2
  exit 1
fi
export APP_ENV="$profile"
export PYTHONPATH="$PWD/backend"
exec .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --no-access-log "$@"
