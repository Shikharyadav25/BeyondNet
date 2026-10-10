#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. ./scripts/database-config.sh
if bank_database_is_local; then ./scripts/start-postgres.sh; fi
export BEYONDNET_DB_CONFIG="${BEYONDNET_DB_CONFIG:-$PWD/data/postgres.properties}"
mvn -q -f backend/pom.xml package
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1; then
  if [ -x "$HOME/.local/share/beyondnet-flutter/bin/flutter" ]; then FLUTTER_BIN="$HOME/.local/share/beyondnet-flutter/bin/flutter";
  else echo 'Set FLUTTER_BIN to your Flutter executable.' >&2; exit 1; fi
fi
(cd mobile && "$FLUTTER_BIN" analyze && "$FLUTTER_BIN" test)
if [ ! -x .venv/bin/python ]; then echo 'For independent compatibility tests, create .venv and install requirements-test.txt.' >&2; exit 1; fi
.venv/bin/python -m pytest -q tests/test_java_bank.py tests/test_dart_interop.py
