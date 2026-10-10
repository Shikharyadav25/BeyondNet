#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/database-config.sh
if ! bank_database_is_local; then
  echo "Managed PostgreSQL configured; local database will not be started or initialized."
  exit 0
fi
# A dedicated cluster avoids touching any other database installed on this laptop.
PG_BIN="${BEYONDNET_PG_BIN:-}"
if [ -z "$PG_BIN" ]; then
  for candidate in /opt/homebrew/opt/postgresql@18/bin /usr/local/opt/postgresql@18/bin /opt/homebrew/opt/postgresql@17/bin /usr/local/opt/postgresql@17/bin; do
    if [ -x "$candidate/pg_ctl" ]; then PG_BIN="$candidate"; break; fi
  done
fi
if [ -z "$PG_BIN" ]; then echo 'Install PostgreSQL 17+ (Mac: brew install postgresql@18), or set BEYONDNET_PG_BIN to its bin directory.' >&2; exit 1; fi
umask 077
mkdir -p data/postgres-run
PG_ROOT="$PWD/data/postgres"
PG_SOCKET="$PWD/data/postgres-run"
if [ ! -f "$PG_ROOT/PG_VERSION" ]; then
  "$PG_BIN/initdb" -D "$PG_ROOT" -U beyondnet_admin --auth-local=trust --auth-host=scram-sha-256 > data/postgres-init.log
  cat >> "$PG_ROOT/postgresql.conf" <<EOF
listen_addresses = '127.0.0.1'
port = 5433
unix_socket_directories = '$PG_SOCKET'
EOF
fi
if ! "$PG_BIN/pg_ctl" -D "$PG_ROOT" status >/dev/null 2>&1; then
  "$PG_BIN/pg_ctl" -D "$PG_ROOT" -l "$PWD/data/postgres-server.log" -w start
fi
if [ ! -f data/postgres.properties ]; then
  if [ "$("$PG_BIN/psql" -h "$PG_SOCKET" -p 5433 -U beyondnet_admin -d postgres -Atc "SELECT count(*) FROM pg_roles WHERE rolname='beyondnet'")" != 0 ]; then
    echo 'The database role exists but its credential file is missing. Restore data/postgres.properties from backup; refusing to rotate the password.' >&2; exit 1
  fi
  BANK_DB_PASSWORD="$(openssl rand -hex 32)"
  "$PG_BIN/psql" -h "$PG_SOCKET" -p 5433 -U beyondnet_admin -d postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE ROLE beyondnet LOGIN PASSWORD '$BANK_DB_PASSWORD' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE beyondnet OWNER beyondnet;
SQL
  cat > data/postgres.properties <<EOF
url=jdbc:postgresql://127.0.0.1:5433/beyondnet
user=beyondnet
password=$BANK_DB_PASSWORD
schema=public
EOF
  chmod 600 data/postgres.properties
fi
printf 'BeyondNet PostgreSQL is ready on localhost:5433.\n'
