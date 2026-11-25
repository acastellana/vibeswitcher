#!/bin/bash
# Measurement ANC-1: a chain from the user's own Terminal read whole (item 11): each ancestor of this script's shell,
# up to launchd, as the voice rule reads it: PROC_PIDTBSDINFO (refused for root's `login`), the short record and
# sysctl's fallback, the environment, the code's status word. Reads only; nothing on screen.
#
# Run in Terminal:  bash scripts/mac-measure/ancestry-terminal.sh   (--dry-run: build, and read the chain of a detached
# probe of its own, launchd its only ancestor: never the caller's ancestors)
# Look for: every ancestor gives shortbsdinfo=read or kern_proc_pid=read; `login` (root) with bsdinfo=refused.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build
if [[ $mm_dry == 1 ]]; then
    probe=$("$mm_bin/detach" "$mm_bin/facts" --sleep 30)
    mm_chain "$probe" > "$mm_out/chain.txt"
    /bin/kill "$probe"
    cat "$mm_out/chain.txt"
    mm_say "dry run done: the chain of a detached probe of its own ($(/usr/bin/grep -c '^-- ancestor' "$mm_out/chain.txt") links)"
    exit 0
fi
mm_chain $$ > "$mm_out/chain.txt"
mm_record "$mm_out/chain.txt"
