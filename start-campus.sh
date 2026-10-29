#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# Campus uses its own process, schema, keys and queue; the bank can stay on 8080.
export KARO_DATA_DIR="${CAMPUS_DATA_DIR:-$PWD/data/campus-psit}"
export BEYONDNET_DB_CONFIG="${CAMPUS_DB_CONFIG:-$PWD/data/postgres.properties}"
export BEYONDNET_DB_SCHEMA="${CAMPUS_DB_SCHEMA:-campus_psit}"
export CAMPUS_PORT="${CAMPUS_PORT:-8090}"
. ./scripts/database-config.sh
if bank_database_is_local; then ./scripts/start-postgres.sh; fi
JAR=backend/target/bank-1.3.3.jar
if [ ! -f "$JAR" ] || [ "$(find backend/src backend/pom.xml -type f -newer "$JAR" -print -quit)" ]; then
  mvn -q -f backend/pom.xml -DskipTests package
fi
umask 077
mkdir -p "$KARO_DATA_DIR/runtime"
RUN_JAR="$KARO_DATA_DIR/runtime/campus-$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 4).jar"
cp "$JAR" "$RUN_JAR"
cleanup() { rm -f -- "$RUN_JAR"; }
trap cleanup EXIT
java -jar "$RUN_JAR" --spring.profiles.active=campus "$@" &
CAMPUS_PID=$!
stop_campus() { kill "$CAMPUS_PID" 2>/dev/null || true; wait "$CAMPUS_PID" 2>/dev/null || true; }
trap stop_campus INT TERM
printf 'PSIT campus on localhost:%s. Operator key: %s/admin-token.txt\n' "$CAMPUS_PORT" "$KARO_DATA_DIR"
wait "$CAMPUS_PID"
