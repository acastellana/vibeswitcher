#!/bin/bash
# Runs `VibeSwitcher --ui-bench` in a fresh scratch home: the window on two made-up leads with day-sized boards, a
# private session host and its own sessions. Nothing touches the real ~/.vibeswitcher, the real host or real sessions.
# Checks SwiftUI's faults on clicks and a host restart, what a switch between the leads costs, and idle CPU, work and
# memory (see UIBench.swift); exits 1 when one fails.
#
# Idle work (instructions/s) rises with the Mac's load, so it's judged against a base build run in the same invocation
# (-B), never against a fixed number: base and branch run alternately, ROUNDS times each, and the branch's median may be
# at most PCT % over the base's. The 50 M line on an idle Mac is shown, not checked. On a Mac whose 1-minute load is
# over scripts/test-under-load.sh's threshold (2 × ncpu) it doesn't judge: at the start it runs nothing, and a load
# over it during the runs leaves instructions/s unjudged; it says so and exits 0 for that. Without -B instructions/s
# is shown only. See docs/eval/runtime-data/idle-bench.md.
#
# scripts/ui-bench.sh [-b BINARY] [-B BASE] [-r ROUNDS] [-t PCT] [MINUTES] [--onscreen] [--ticking] [--transcript PATH]
#   -b BINARY: the build judged (.build/debug/VibeSwitcher).  -B BASE: the base: a VibeSwitcher binary, or a git ref
#   (main) exported and built in this run's scratch folder under /tmp, outside the worktree, and removed on exit
#   (Ctrl-C too). Not under .build/: the export holds the ref's AGENTS.md and CLAUDE.md, and the lead's audit counts
#   instructions files a worktree holds uncommitted (its verifier then starts with project settings off).
#   -r ROUNDS: runs of each with -B (2).  -t PCT: how far over the base's instructions/s the branch may be (20).
#   MINUTES: the idle phase (default 5). --onscreen: the window shows (without taking focus) instead of off screen.
#   Logs: .build/ui-bench/{base,branch}-N.log, and the base's build-base.log (UI_BENCH_LOGS: another folder).
set -euo pipefail
[[ ${1-} == -h || ${1-} == --help ]] && { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
source scripts/lib/bench-defaults.sh
# Each run's home is the one given below; an exported VIBESWITCHER_HOME would come before it (`VibePaths.root`).
unset VIBESWITCHER_HOME

binary=.build/debug/VibeSwitcher base="" rounds=2 tolerance=20
while getopts "b:B:r:t:" option; do
    case $option in
        b) binary=$OPTARG ;;
        B) base=$OPTARG ;;
        r) rounds=$OPTARG ;;
        t) tolerance=$OPTARG ;;
        *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
[[ $rounds =~ ^[1-9][0-9]*$ ]] || { echo "-r $rounds: a number of runs, at least 1"; exit 64; }
[[ $tolerance =~ ^[0-9]+$ ]] || { echo "-t $tolerance: a percentage"; exit 64; }

cores=$(sysctl -n hw.ncpu)
max_load=$((2 * cores))
# The 1-minute load. In the tests UI_BENCH_FAKE_LOAD stands in for it: a number, or a file holding one.
load() {
    local fake=${UI_BENCH_FAKE_LOAD-}
    if [[ -f $fake ]]; then cat "$fake"; elif [[ -n $fake ]]; then echo "$fake"; else sysctl -n vm.loadavg | awk '{ print $2 }'; fi
}
over() { awk -v l="$1" -v m="$max_load" 'BEGIN { exit !(l > m) }'; }

started_load=$(load)
if over "$started_load"; then
    echo "not judging: the Mac's 1-minute load is $started_load, over $max_load (2 × $cores cores, as scripts/test-under-load.sh)."
    echo "At that load a build's numbers say how busy the Mac is, not what the build changed. Nothing was run;"
    echo "run it again when the first of \`uptime\`'s load averages is under $max_load."
    exit 0
fi

logs=${UI_BENCH_LOGS:-.build/ui-bench}
mkdir -p "$logs"
rm -f "$logs"/*.log
if [[ -n $base && ! ( -f $base && -x $base ) ]]; then
    commit=$(git rev-parse --verify --quiet "$base^{commit}") || { echo "-B $base: neither a binary nor a git ref"; exit 64; }
    # Where it was built before 2026-10-28 (about 1 GB, the ref's AGENTS.md and CLAUDE.md in it).
    rm -rf .build/ui-bench-base
    scratch_tmpdir vs-uibench
    folder=$tool_scratch/base
    mkdir "$folder"
    echo "building the base, $base ($commit), in $folder"
    git archive "$commit" | tar -x -C "$folder"
    # In the tests UI_BENCH_SWIFT stands in for swift.
    [[ -z ${UI_BENCH_SWIFT:-} ]] || swift() { "$UI_BENCH_SWIFT" "$@"; }
    swift build --package-path "$folder" > "$logs/build-base.log" 2>&1 || { echo "the base didn't build: $logs/build-base.log"; exit 1; }
    base=$folder/.build/debug/VibeSwitcher
fi
# Neither may write the real ~/Library/Preferences/VibeSwitcher.plist (scripts/lib/bench-defaults.sh).
bench_defaults_in_scratch "$binary" || exit 1
[[ -z $base ]] || bench_defaults_in_scratch "$base" || exit 1

loaded=""   # set when the load went over the threshold during a run
# run NAME BINARY ARGS…: one bench in a scratch home of its own; its log is $logs/NAME.log, its exit status in $status.
run() {
    local name=$1 binary=$2 home
    shift 2
    # Short: the host's socket lives under it, and socket paths are limited to 104 bytes.
    home=$(mktemp -d "${TMPDIR:-/tmp}/vsui.XXXXXX")
    echo "== $name: $binary; scratch home: $home; load $(load)"
    status=0
    CFFIXED_USER_HOME="$home" HOME="$home" "$binary" --ui-bench "$@" 2>&1 | tee "$logs/$name.log" || status=${PIPESTATUS[0]}
    rm -rf "$home"
    local now
    now=$(load)
    echo "== $name: exit $status; load $now"
    if over "$now"; then loaded="$loaded $now"; fi
}
# The idle instructions/s each run printed, one a line.
rates() { cat "$@" 2>/dev/null | awk '$1 == "RESULT" && $2 == "idle-instructions-per-second" { print $3 }'; }
median() { sort -n | awk '{ v[NR] = $1 } END { if (NR == 0) exit 1; print (NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2) }'; }

failed=0
if [[ -z $base ]]; then
    run branch-1 "$binary" "$@"
    failed=$status
    echo "instructions/s not judged: give -B main (or a base binary) to judge it against the base in the same run."
else
    base_failed=0
    for round in $(seq 1 "$rounds"); do
        run "base-$round" "$base" "$@"
        [[ $status == 0 ]] || base_failed=$((base_failed + 1))
        run "branch-$round" "$binary" "$@"
        [[ $status == 0 ]] || failed=$status
    done
    echo "== verdict (base $base, branch $binary, $rounds run(s) each)"
    [[ $base_failed == 0 ]] || echo "note: $base_failed of the base's runs failed a check or crashed too (see $logs/base-*.log)"
    base_median=$(rates "$logs"/base-*.log | median) || base_median=""
    branch_median=$(rates "$logs"/branch-*.log | median) || branch_median=""
    if [[ -n $loaded ]]; then
        echo "not judging instructions/s: the 1-minute load went over $max_load (2 × $cores cores) during the runs (${loaded# })."
    elif [[ -z $branch_median ]]; then
        echo "FAIL  idle: no instructions/s from the branch's runs (see $logs/branch-*.log)"
        [[ $failed != 0 ]] || failed=1
    elif [[ -z $base_median ]]; then
        echo "not judging instructions/s: no base run got that far (see $logs/base-*.log)"
    else
        if awk -v b="$branch_median" -v a="$base_median" -v t="$tolerance" 'BEGIN { exit !(b <= a * (1 + t / 100)) }'; then
            verdict=PASS
        else
            verdict=FAIL
            [[ $failed != 0 ]] || failed=1
        fi
        awk -v b="$branch_median" -v a="$base_median" -v t="$tolerance" -v v="$verdict" 'BEGIN {
            printf "%s  idle: %.1f M instructions/s, the base %.1f M (%+.0f %%; at most +%d %%; medians)\n", v, b / 1e6, a / 1e6,
                (b - a) / a * 100, t }'
    fi
fi
exit "$failed"
