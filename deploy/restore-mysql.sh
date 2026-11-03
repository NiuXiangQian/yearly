#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo 'Usage: restore-mysql.sh /secure/mysql-client.cnf empty_database /secure/backup.sql.gz' >&2
  exit 2
fi
client_config=$1
database_name=$2
backup_file=$3
[[ "$database_name" =~ ^[A-Za-z0-9_]+$ ]] || { echo 'Invalid database name' >&2; exit 2; }
# Restore only into a separately prepared empty database.
table_count=$(mysql --defaults-extra-file="$client_config" --batch --skip-column-names -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$database_name'")
[ "$table_count" = 0 ] || { echo 'Target database must be empty' >&2; exit 1; }
gzip -dc "$backup_file" | mysql --defaults-extra-file="$client_config" --default-character-set=utf8mb4 "$database_name"
echo 'Database restore complete'
