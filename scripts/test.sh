#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_ENV=test PYTHONPATH=backend .venv/bin/pytest -c backend/pytest.ini -q --tb=short
(cd frontend && npm test && npm run build)
