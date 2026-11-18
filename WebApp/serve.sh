#!/bin/bash
# Serves the web client's files on this machine only, for its mock: http://127.0.0.1:8765/?mock (Ctrl-C stops it).
# There is no node behind it: without ?mock the page says it isn't paired. The page is plain files, but its scripts
# are modules, which a browser won't load from file://. The live page comes from a node (scripts/sandbox-server.sh).
#
# WebApp/serve.sh [PORT]
set -euo pipefail
cd "$(dirname "$0")"
port=${1:-8765}
echo "VibeSwitcher web client (mock data): http://127.0.0.1:$port/?mock"
exec python3 -m http.server "$port" --bind 127.0.0.1
