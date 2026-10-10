#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/database-config.sh
umask 077
BANK_DATA="${KARO_DATA_DIR:-$PWD/data}"
mkdir -p "$BANK_DATA/backups"
BANK_BACKUP="$BANK_DATA/backups/$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 3)"
mkdir "$BANK_BACKUP"
for file in bank-keys.json admin-token.txt public-url.txt; do
  if [ -f "$BANK_DATA/$file" ]; then cp "$BANK_DATA/$file" "$BANK_BACKUP/$file"; fi
done
if [ -f "${BEYONDNET_DB_CONFIG:-$PWD/data/postgres.properties}" ]; then
  cp "${BEYONDNET_DB_CONFIG:-$PWD/data/postgres.properties}" "$BANK_BACKUP/postgres.properties"
fi
if [ -f "$BANK_DATA/bank.sqlite3" ]; then
  sqlite3 "$BANK_DATA/bank.sqlite3" ".backup '$BANK_BACKUP/bank.sqlite3'"
fi
PG_DUMP="${BEYONDNET_PG_BIN:-/usr/local/opt/postgresql@18/bin}/pg_dump"
if [ ! -x "$PG_DUMP" ]; then PG_DUMP=/opt/homebrew/opt/postgresql@18/bin/pg_dump; fi
if [ ! -x "$PG_DUMP" ]; then PG_DUMP="$(command -v pg_dump)"; fi
BANK_URL="$(bank_config_value url BEYONDNET_DB_URL 'jdbc:postgresql://127.0.0.1:5433/beyondnet')"
if [[ ! "$BANK_URL" =~ ^jdbc:postgresql://([^/:?]+)(:([0-9]+))?/([^?]+)(\?.*)?$ ]]; then
  echo 'Backup requires a PostgreSQL JDBC host/database URL without inline credentials.' >&2; exit 1
fi
export PGHOST="${BASH_REMATCH[1]}" PGPORT="${BASH_REMATCH[3]:-5432}" PGDATABASE="${BASH_REMATCH[4]}"
export PGUSER="$(bank_config_value user BEYONDNET_DB_USER beyondnet)"
export PGPASSWORD="$(bank_config_value password BEYONDNET_DB_PASSWORD '')"
export PGCONNECT_TIMEOUT=20
if bank_database_is_local; then
  export PGSSLMODE=prefer
else
  # Remote backups verify both the server certificate and hostname using system roots.
  export PGSSLMODE=verify-full PGSSLROOTCERT=system
fi
"$PG_DUMP" --no-owner --no-acl -Fc -f "$BANK_BACKUP/bank.postgres.dump"
printf 'Private backup saved: %s\n' "$BANK_BACKUP"
