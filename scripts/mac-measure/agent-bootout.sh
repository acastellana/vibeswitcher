#!/bin/bash
# Measurement AG-1: the node's LaunchAgent shape, short of the node (the design's step 5; NodeAgent's "Needs a real
# Mac"): `launchctl print`'s real lines (`pid = `, `program = ` one tab in, as NodeAgent.printed parses them), and what
# `launchctl bootout` ends: the job's process, a child in its process group, a child that called setsid. Throwaway
# label; what survives the bootout is ended by this script (its own processes, by pid).
#
# Run in Terminal:  bash scripts/mac-measure/agent-bootout.sh      (--dry-run: build and check only)
# Look for: nothing on screen. The record: the parsed pid and program, and which of the three outlived the bootout.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build
mm_new_label agent-bootout
f=$mm_bin/facts d=$mm_bin/detach o=$mm_out
mm_write_plist /bin/sh -c "'$d' '$f' --sleep 600 > '$o/setsid.pid'; '$f' --sleep 600 & echo \$! > '$o/group.pid'; echo \$\$ > '$o/main.pid'; exec '$f' --sleep 600"
mm_say ""
mm_say "What happens next: job $mm_label starts three sleeping probes, is printed, then booted out; nothing on screen."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$o/main.pid" '^[0-9]+$' 30
mm_wait_for "$o/setsid.pid" '^[0-9]+$' 30
{
    echo "== launchctl print, the job's own lines"
    /bin/launchctl print "gui/$mm_uid/$mm_label" | /usr/bin/grep -E '^	(pid|program|state|path|type|domain) = '
    echo "== parsed as NodeAgent.printed does (one tab in, no deeper)"
    /bin/launchctl print "gui/$mm_uid/$mm_label" | /usr/bin/awk -F' = ' '/^\t[^\t]/ { k=$1; sub(/^\t/, "", k); if (k == "pid" || k == "program") print k "=" $2 }'
    for name in main group setsid; do printf '%s pid %s: ' "$name" "$(cat "$o/$name.pid")"; "$f" --pid "$(cat "$o/$name.pid")" | /usr/bin/grep -E '^coalition'; done
} > "$o/print.txt"
mm_bootout
mm_ended() { ! /bin/kill -0 "$(cat "$o/main.pid")" 2> /dev/null; }
for _ in $(seq 1 20); do mm_ended && break; /bin/sleep 0.25; done
{
    echo "== after bootout (once the job's own process ended, or 5 s)"
    for name in main group setsid; do
        p=$(cat "$o/$name.pid")
        if /bin/kill -0 "$p" 2> /dev/null; then echo "$name ($p): still running"; /bin/kill "$p"; else echo "$name ($p): ended"; fi
    done
} > "$o/after.txt"
mm_record "$o/print.txt" "$o/after.txt"
