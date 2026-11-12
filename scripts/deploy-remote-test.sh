#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -lt 1 ]; then
  echo 'Usage: deploy-remote-test.sh user@host [ssh-port]' >&2
  exit 2
fi
target=$1
port=${2:-22}
./scripts/build-release.sh
ssh -p "$port" "$target" 'mkdir -p /opt/yearly-test/incoming'
scp -P "$port" yearly-test.tgz "$target:/opt/yearly-test/incoming/yearly-test.tgz"
ssh -p "$port" "$target" 'bash -s' <<'REMOTE'
set -euo pipefail
release=/opt/yearly-test/releases/$(date -u +%Y%m%d%H%M%S)
mkdir -p "$release"
tar -xzf /opt/yearly-test/incoming/yearly-test.tgz -C "$release"
bash "$release/deploy/deploy-test.sh"
REMOTE
