#!/usr/bin/env bash
set -euo pipefail
umask 077
if [ "$#" -ne 3 ]; then
  echo 'Usage: backup-mysql.sh /secure/mysql-client.cnf database /secure/backup.sql.gz' >&2
  exit 2
fi
client_config=$1
database_name=$2
output_file=$3
[[ "$database_name" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid database name' >&2; exit 2; }
mysqldump --defaults-extra-file="$client_config" --single-transaction --quick --hex-blob \
  --set-gtid-purged=OFF --default-character-set=utf8mb4 "$database_name" | gzip > "$output_file.partial"
mv "$output_file.partial" "$output_file"
echo 'Database backup complete'
