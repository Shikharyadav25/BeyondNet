#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/local/bin:$HOME/.nvm/versions/node/v22.23.1/bin:$PATH"
NGROK_BIN="$HOME/.local/share/beyondnet-ngrok/ngrok"
[ -x "$NGROK_BIN" ] || NGROK_BIN="ngrok"
if ! lsof -nP -iTCP:8079 -sTCP:LISTEN >/dev/null 2>&1; then
  mkdir -p data
  nohup node scripts/shared-ngrok-proxy.mjs > data/shared-ngrok-proxy.log 2>&1 < /dev/null &
fi
if curl -fsS http://127.0.0.1:4040/api/tunnels 2>/dev/null | /usr/bin/grep -q '127.0.0.1:8079'; then
  echo 'Shared bank and campus ngrok tunnel is already running.'
  exit 0
fi
exec "$NGROK_BIN" http http://127.0.0.1:8079 --inspect=false "$@"
