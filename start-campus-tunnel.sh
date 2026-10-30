#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec ./Start-Ngrok.command "$@"
