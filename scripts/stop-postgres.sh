#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -f "$PWD/data/postgres/PG_VERSION" ]; then
  echo "No local BeyondNet PostgreSQL cluster exists. Neon is unaffected."
  exit 0
fi
# Stops only the retired local cluster, never the configured Neon database.
PG_BIN="${BEYONDNET_PG_BIN:-}"
if [ -z "$PG_BIN" ]; then
 for p in /usr/local/opt/postgresql@18/bin /opt/homebrew/opt/postgresql@18/bin /usr/local/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@17/bin; do
  if [ -x "$p/pg_ctl" ]; then PG_BIN="$p"; break; fi
 done
fi
"$PG_BIN/pg_ctl" -D "$PWD/data/postgres" -m smart -t 15 stop
