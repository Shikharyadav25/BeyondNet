#!/bin/zsh
set -e
cd "${0:A:h}"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
if ! command -v ngrok >/dev/null 2>&1; then
  print 'Install ngrok and sign into its free plan first. See docs/NGROK.md.'
  exit 1
fi
print 'Keep the bank running on port 8080. Keep this window open during testing.'
exec ngrok http http://127.0.0.1:8080 --inspect=false
