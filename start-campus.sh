#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${CAMPUS_DB_URL:?Set the dedicated campus PostgreSQL JDBC URL}"
: "${CAMPUS_DB_USER:?Set the dedicated campus database user}"
: "${CAMPUS_DB_PASSWORD?Set the campus database password}"
: "${CAMPUS_KEYS_DIR:?Set the directory containing the provisioned publisher key}"
if [ ! -f "$CAMPUS_KEYS_DIR/publisher.pk8" ] || [ ! -f "$CAMPUS_KEYS_DIR/publisher.der" ]; then
  echo 'Provision or restore the campus publisher key before starting. See docs/campus/SETUP.md.' >&2
  exit 1
fi
mvn -q -DskipTests package
exec java -jar campus-backend/target/campus-backend-0.1.0.jar "$@"
