#!/bin/bash
# Runs `VibeSwitcher --ui-bench` in a fresh scratch home: the window on two made-up leads with day-sized boards, a
# private session host and its own sessions. Nothing touches the real ~/.vibeswitcher, the real host or real sessions.
# Checks SwiftUI's faults on clicks and a host restart, what a switch between the leads costs, and idle CPU, work and
# memory (see UIBench.swift); exits 1 when one fails.
#
# scripts/ui-bench.sh [-b BINARY] [MINUTES] [--onscreen] [--ticking] [--transcript PATH]
#   MINUTES: the idle phase (default 5). --onscreen: the window shows (without taking focus) instead of off screen.
set -euo pipefail
cd "$(dirname "$0")/.."

binary=.build/debug/VibeSwitcher
while getopts "b:" option; do
    case $option in
        b) binary=$OPTARG ;;
        *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))

# Short: the host's socket lives under it, and socket paths are limited to 104 bytes.
home=$(mktemp -d "${TMPDIR:-/tmp}/vsui.XXXXXX")
echo "scratch home: $home; $(uptime | sed 's/.*load/load/')"
status=0
CFFIXED_USER_HOME="$home" HOME="$home" "$binary" --ui-bench "$@" || status=$?
echo "$(uptime | sed 's/.*load/load/')"
exit $status
