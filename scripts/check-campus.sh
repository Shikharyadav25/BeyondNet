#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CAMPUS_TEST_DB_URL:?Set CAMPUS_TEST_DB_URL to a disposable PostgreSQL JDBC URL}"
: "${CAMPUS_TEST_DB_USER:?Set CAMPUS_TEST_DB_USER to its test-only role}"
mvn verify
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [ -x "$HOME/.local/share/beyondnet-flutter/bin/flutter" ]; then
  FLUTTER_BIN="$HOME/.local/share/beyondnet-flutter/bin/flutter"
fi
(cd mobile && "$FLUTTER_BIN" analyze && "$FLUTTER_BIN" test test/campus_protocol_test.dart test/campus_client_test.dart)
