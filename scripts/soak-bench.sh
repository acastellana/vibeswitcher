#!/bin/bash
# Runs `VibeSwitcher --ui-bench --soak MINUTES` in a fresh scratch home: two made-up leads and their workers on a private
# session host, a working day's traffic (session changes, hook events, board writes, growing transcripts, workers coming and going, the window
# switching chats) for MINUTES, printing the footprint each minute and what grew by kind of memory and by class (see
# UIBench.swift). Nothing touches the real ~/.vibeswitcher, the real host or real sessions. It exits 1 when the footprint
# (each minute's least) over the last 20 minutes strays more than 50 MB from its median (runs of 25 minutes or more).
#
# Unlike scripts/ui-bench.sh it runs on a loaded Mac: memory doesn't depend on the load (CPU figures aren't judged here).
#
# scripts/soak-bench.sh [-b BINARY] [-n NAME] MINUTES [--soak-workers N] [--soak-upserts PER_SECOND] [--soak-without LIST]
#   [--soak-leads L] [--soak-churn SECONDS] [--soak-replay TRANSCRIPT] [--soak-sidebar]
#   -b BINARY: the build (.build/debug/VibeSwitcher).  -n NAME: the log's name (soak): .build/soak/NAME.log
#   (SOAK_BENCH_LOGS: another folder).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
source scripts/lib/bench-defaults.sh
# The run's home is the one given below; an exported VIBESWITCHER_HOME would come before it (`VibePaths.root`).
unset VIBESWITCHER_HOME

binary=.build/debug/VibeSwitcher name=soak
while getopts "b:n:" option; do
    case $option in
        b) binary=$OPTARG ;;
        n) name=$OPTARG ;;
        *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
minutes=${1:-}
[[ $minutes =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "usage: scripts/soak-bench.sh [-b BINARY] [-n NAME] MINUTES [--soak-workers N] [--soak-upserts PER_SECOND]"; exit 64; }
shift
# It mustn't write the real ~/Library/Preferences/VibeSwitcher.plist (scripts/lib/bench-defaults.sh).
bench_defaults_in_scratch "$binary" || exit 1

logs=${SOAK_BENCH_LOGS:-.build/soak}
mkdir -p "$logs"
# Short: the host's socket lives under it, and socket paths are limited to 104 bytes.
home=$(mktemp -d "/tmp/vssoak.XXXXXX")
on_exit "rm -rf '$home' < /dev/null"
echo "== $name: $binary, $minutes minutes; scratch home: $home; load $(sysctl -n vm.loadavg | awk '{ print $2 }')"
status=0
CFFIXED_USER_HOME="$home" HOME="$home" "$binary" --ui-bench --soak "$minutes" "$@" 2>&1 | tee "$logs/$name.log" || status=${PIPESTATUS[0]}
echo "== $name: exit $status; log $logs/$name.log"
exit "$status"
