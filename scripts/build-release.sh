#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
npm --prefix frontend ci
npm --prefix frontend test
npm --prefix frontend run build
mkdir -p release/frontend release/deploy
cp -R backend release/
cp -R frontend/dist release/frontend/
cp deploy/Dockerfile release/deploy/
cp scripts/deploy-test.sh release/deploy/
git rev-parse HEAD > release/REVISION
# Only these explicit paths enter the deployment artifact; no environment files or media.
tar -czf yearly-test.tgz -C release backend frontend deploy REVISION
