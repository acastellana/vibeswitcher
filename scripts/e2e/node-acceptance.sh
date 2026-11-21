#!/bin/bash
# The acceptance run (docs/process/v2-acceptance.md), automated: NodeAcceptanceTests, one case per row, each on a scratch
# node of its own (ScratchNode: a scratch session host, the server built from this worktree, its own root and home)
# with FakeClaude for every agent, driven through the built command line on a pty with the typed codes. It never
# touches ~/.vibeswitcher, ~/.claude, the user's node or a real agent. The suite runs in the Linux CI's core job and the
# full suite too (VibeNodeTests); this runs it alone, under vs-heavy, on a scratch home (scripts/test.sh).
#
# scripts/e2e/node-acceptance.sh            every row
# scripts/e2e/node-acceptance.sh A14 A15    those rows only (a case is named after its row: a14…, a15…)
set -euo pipefail
cd "$(dirname "$0")/../.."

filter=NodeAcceptanceTests
if (($#)); then
    rows=()
    for row in "$@"; do
        [[ $row =~ ^[Aa][0-9]{1,2}$ ]] || { echo "node-acceptance.sh: $row isn't a row (A1 … A37)" >&2; exit 64; }
        rows+=("a${row:1}[A-Z]")
    done
    filter="NodeAcceptanceTests/($(IFS='|'; echo "${rows[*]}"))"
fi
export VIBESWITCHER_ACCEPTANCE=1
exec Resources/bin/vs-heavy bash scripts/test.sh --filter "$filter"
