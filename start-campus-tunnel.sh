#!/usr/bin/env bash
set -euo pipefail
command -v ngrok >/dev/null || { echo 'Install ngrok and configure your own account token using ngrok config add-authtoken.' >&2; exit 1; }
exec ngrok http "http://127.0.0.1:${CAMPUS_PORT:-8090}" --inspect=false "$@"
