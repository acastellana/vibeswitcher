#!/bin/bash
# Serves the web client's mock on this machine only: http://127.0.0.1:8765/ (Ctrl-C stops it). The page is plain
# files, but its scripts are modules, which a browser won't load from file://.
#
# WebApp/serve.sh [PORT]
set -euo pipefail
cd "$(dirname "$0")"
port=${1:-8765}
echo "VibeSwitcher web client (mock data): http://127.0.0.1:$port/"
exec python3 -m http.server "$port" --bind 127.0.0.1
