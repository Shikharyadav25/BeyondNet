#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if command -v flutter >/dev/null 2>&1; then
  (cd mobile && flutter pub get && flutter analyze && flutter test)
else
  echo 'Flutter is not on PATH. Bank tests will run; mobile verification requires Flutter.'
fi
.venv/bin/python -m pytest -q
