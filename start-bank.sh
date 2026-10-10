#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
export KARO_DATA_DIR="${KARO_DATA_DIR:-$PWD/data}"
export BEYONDNET_DB_CONFIG="${BEYONDNET_DB_CONFIG:-$PWD/data/postgres.properties}"
if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"${PORT:-8080}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo 'The bank port is already in use. Keep the existing bank, or stop it before restarting.' >&2; exit 1
fi
command -v java >/dev/null || { echo 'Install Java 21 or newer.' >&2; exit 1; }
. ./scripts/database-config.sh
if bank_database_is_local; then ./scripts/start-postgres.sh; fi
JAR=backend/target/bank-1.2.0.jar
if [ ! -f "$JAR" ] || [ "$(find backend/src backend/pom.xml -type f -newer "$JAR" -print -quit)" ]; then
  command -v mvn >/dev/null || { echo 'Install Maven 3.6.3 or newer.' >&2; exit 1; }
  mvn -q -f backend/pom.xml -DskipTests package
fi
# Import is atomic and runs once; back up the untouched legacy data before first cutover.
if [ -f data/bank.sqlite3 ] && [ ! -f data/postgres-migration-complete ]; then
  ./scripts/backup-bank.sh
  java -jar "$JAR" --migration-only
  touch data/postgres-migration-complete
fi
printf 'BeyondNet Java + PostgreSQL bank: http://localhost:%s\nKeep this window open. Ctrl+C stops the bank.\n' "${PORT:-8080}"
# Run an immutable copy so rebuilding/testing the project cannot replace an open JAR.
mkdir -p data/runtime
RUN_JAR="$PWD/data/runtime/bank-$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 4).jar"
cp "$JAR" "$RUN_JAR"
exec java -jar "$RUN_JAR" "$@"
