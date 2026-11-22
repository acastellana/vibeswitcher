#!/bin/bash
# The page rows of the acceptance run (docs/process/v2-acceptance.md: A3, A10, A19, A23, and the views added since:
# Brief me, dev servers, the shell request card, the Team tab, statistics, health, between leads) on the real node, in
# one step once the user has paired: `vibeswitcher web` prints a pairing URL (behind the user's typed code), and this
# takes it. Headless Chrome (scripts/e2e/real-page.cjs over the DevTools protocol, Node's own WebSocket) pairs with it,
# looks at each view, screenshots it into .build/real-page/, and prints a pass/fail/skip table (exit 1 on any fail).
#
# Read-only: it changes nothing on the node. It moves between the page's routes and view tabs, presses Brief me (a read,
# which may ask the summaries' model), types into nothing (A10 checks the terminal is watch-only by the page's state),
# and A23's refused `answer` and `send` name a card and a session that don't exist. The pairing code is spent by this
# page, so the user's own browser needs its own `vibeswitcher web`. A Chrome profile of its own, removed after.
#
# scripts/e2e/real-page-check.sh 'http://127.0.0.1:47830/#pair=CODE' [OUT]
set -euo pipefail
cd "$(dirname "$0")/../.."

url=${1:-}
[[ $url =~ ^http://[0-9a-zA-Z.:-]+/#pair=[A-Za-z0-9_-]+$ ]] || {
    echo "usage: scripts/e2e/real-page-check.sh 'http://127.0.0.1:47830/#pair=CODE' [OUT]   (the URL vibeswitcher web printed)" >&2
    exit 64
}
out=${2:-.build/real-page}
chrome=${REAL_PAGE_CHROME:-/opt/google/chrome/chrome}
[[ -x $chrome ]] || { echo "real-page-check.sh: no Chrome at $chrome (REAL_PAGE_CHROME names another)" >&2; exit 69; }
command -v node >/dev/null || { echo "real-page-check.sh: node isn't on PATH" >&2; exit 69; }
mkdir -p "$out"
exec node scripts/e2e/real-page.cjs "$url" "$out" "$chrome"
