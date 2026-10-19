#!/bin/bash
# Runs the whole test suite 3 times at once beside a CPU burner (one busy loop per core), the way a Mac with several
# sessions building and testing is loaded, and checks that each run passes and leaves nothing behind. Run it when you
# add or change a host, timing or concurrency test: a wait that only holds on an idle Mac fails here, not on
# project-lead.
#
# Each run gets its own empty TMPDIR (tests put their scratch files under it, see `scratchRoot` in the tests'
# TestSupport.swift) and must leave it empty; what's left is named by prefix. Run 1's is long (about 130 characters, as
# a Claude session's scratchpad is): the suite passes whatever TMPDIR is, sockets and names included. The runs start
# the test bundle the way `swift test` does (swiftpm-testing-helper), directly: three `swift test` would take turns on
# SwiftPM's lock on .build.
# Logs: .build/test-under-load/run-N.log. Everything else (the TMPDIRs, the burner) is gone when it exits, Ctrl-C too.
#
# scripts/test-under-load.sh [-r RUNS] [-f FILTER]
#   -r RUNS: suites at once (3).  -f FILTER: only the tests matching FILTER (as `swift test --filter`), for a quick look.
set -uo pipefail
cd "$(dirname "$0")/.."

runs=3 filter=""
while getopts "r:f:" option; do
    case $option in
        r) runs=$OPTARG ;; f) filter=$OPTARG ;;
        *) exit 64 ;;
    esac
done

# Not on a nearly full disk: a full one stops every session on this Mac, not just these runs.
floor_gb=15
free_gb=$(($(df -k . | awk 'NR == 2 { print $4 }') / 1024 / 1024))
if [[ $free_gb -lt $floor_gb ]]; then
    echo "only $free_gb GB free (under $floor_gb GB): not starting; free some space first"
    exit 1
fi

logs=.build/test-under-load
scratch="" burners=() tests=() watchdog=""
script=$$

# Every process started under `pid`, deepest first.
descendants() {
    local child
    for child in $(pgrep -P "$1"); do
        descendants "$child"
        echo "$child"
    done
}

# Ends test runs and everything they started, and waits until they're gone (killed outright after 10 s): a session
# host told to stop still writes its log, which would make its scratch folder again after the scratch is removed.
stop() {
    local pids=() pid alive
    for pid in "$@"; do pids+=($(descendants "$pid") "$pid"); done
    [[ ${#pids[@]} -eq 0 ]] && return
    kill "${pids[@]}" 2>/dev/null
    for _ in $(seq 1 100); do
        alive=0
        # A zombie (exited, not yet waited for) is gone.
        for pid in "${pids[@]}"; do [[ $(ps -o stat= -p "$pid" 2>/dev/null) == [^Z]* ]] && alive=1; done
        [[ $alive -eq 0 ]] && return
        sleep 0.1
    done
    kill -9 "${pids[@]}" 2>/dev/null
}

cleanup() {
    trap - EXIT INT TERM
    # /bin/bash 3.2 calls an empty array unbound.
    set +u
    [[ ${#burners[@]} -gt 0 ]] && kill "${burners[@]}" 2>/dev/null
    [[ -n $watchdog ]] && kill "$watchdog" 2>/dev/null
    stop "${tests[@]}"
    wait 2>/dev/null
    # Not from the terminal: rm would ask about each read-only file a test's git repository left.
    [[ -n $scratch ]] && rm -r "$scratch" < /dev/null
}
trap cleanup EXIT
trap 'echo; echo "stopped"; exit 130' INT TERM

# A test that writes to the user's temporary folder itself would escape the check below.
if bypass=$(grep -rnE "\.temporaryDirectory|NSTemporaryDirectory\(\) *\)?\.append" Tests --include='*.swift' | grep -v "/TestSupport.swift:"); then
    echo "These tests write to the user's temporary folder; use scratchRoot (or a Scratch) instead:"
    echo "$bypass"
    exit 1
fi

echo "building…"
swift build --build-tests > /dev/null 2>&1 || { echo "the build failed: run swift build --build-tests"; exit 1; }
bin=$(swift build --show-bin-path)
bundle="$bin/VibeSwitcherPackageTests.xctest/Contents/MacOS/VibeSwitcherPackageTests"
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
[[ -x $helper && -x $bundle ]] || { echo "no test runner at $helper, or no test bundle at $bundle"; exit 1; }
failures="$bin/vibeswitcher-mcp"

mkdir -p "$logs"
rm -f "$logs"/run-*.log
# Short: host tests put sockets under it, and a socket's path is limited to 104 bytes.
scratch=$(mktemp -d /tmp/vs-load.XXXXXX)

# When this script ends without its trap (SIGKILL), nothing it started stays: the burners stop once its pid is gone,
# and this watchdog then stops the test runs (their pids in $scratch/pids) and removes the scratch. Meanwhile it
# watches the disk every second: the lowest free space goes in $scratch/disk-min (MB), and under $stop_mb it stops
# the runs before the disk fills ($scratch/disk-low says so).
stop_mb=5120
(
    trap - EXIT INT TERM
    lowest=""
    while kill -0 "$script" 2>/dev/null; do
        free=$(($(df -k . | awk 'NR == 2 { print $4 }') / 1024))
        if [[ -z $lowest || $free -lt $lowest ]]; then lowest=$free; echo "$lowest" > "$scratch/disk-min"; fi
        if [[ $free -lt $stop_mb && ! -e $scratch/disk-low ]]; then
            echo "$free" > "$scratch/disk-low"
            stop $(cat "$scratch/pids" 2>/dev/null)
        fi
        sleep 1
    done
    stop $(cat "$scratch/pids" 2>/dev/null)
    rm -r "$scratch" < /dev/null 2>/dev/null
) &
watchdog=$!

cores=$(sysctl -n hw.ncpu)
for _ in $(seq 1 "$cores"); do
    bash -c 'while kill -0 "$1" 2>/dev/null; do for ((i = 0; i < 200000; i++)); do :; done; done' burner "$script" &
    burners+=($!)
done
echo "burning $cores cores; load $(sysctl -n vm.loadavg)"

# Run N's TMPDIR: run 1's long, the others' short.
tmpdir() {
    local dir="$scratch/$1"
    if [[ $1 -eq 1 ]]; then
        dir+="/long"
        while [[ ${#dir} -lt 130 ]]; do dir+="-tmpdir"; done
    fi
    echo "$dir"
}

started=$(date +%s)
for run in $(seq 1 "$runs"); do
    mkdir -p "$(tmpdir "$run")"
    args=(--test-bundle-path "$bundle")
    [[ -n $filter ]] && args+=(--filter "$filter")
    TMPDIR="$(tmpdir "$run")/" "$helper" "${args[@]}" "$bundle" --testing-library swift-testing > "$logs/run-$run.log" 2>&1 &
    tests+=($!)
    echo $! >> "$scratch/pids"
done

failed=0
for run in $(seq 1 "$runs"); do
    status=0
    wait "${tests[$((run - 1))]}" || status=$?
    tail=$(grep -E "Test run with" "$logs/run-$run.log" | tail -1 | sed -E 's/\x1B\[[0-9;]*m//g')
    echo "run $run$([[ $run -eq 1 ]] && echo " (long TMPDIR)"): exit $status  ${tail:-(no result line)}  ($logs/run-$run.log)"
    if [[ $status -ne 0 ]]; then
        failed=1
        summary=$("$failures" --test-failures "$logs/run-$run.log")
        echo "${summary:-the run failed without naming a test; see the log}" | sed 's/^/    /'
    fi
    # What the run left in its TMPDIR, by prefix (the name without its UUID or random tail).
    left=$(ls -A "$(tmpdir "$run")")
    if [[ -n $left ]]; then
        failed=1
        echo "    left in TMPDIR ($(wc -l <<< "$left" | tr -d ' ') entries), by prefix:"
        sed -E 's/[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}/*/; s/[-.][0-9A-Za-z]{6,8}(\.[a-z]+)?$/-*\1/' <<< "$left" \
            | sort | uniq -c | sort -rn | sed 's/^/    /'
    fi
done
tests=()
echo "took $(($(date +%s) - started)) s; load $(sysctl -n vm.loadavg); lowest free disk $(cat "$scratch/disk-min" 2>/dev/null) MB;" \
    "$(sysctl -n vm.swapusage | sed -E 's/  +/ /g')"
if [[ -e $scratch/disk-low ]]; then
    failed=1
    echo "STOPPED: the disk fell to $(cat "$scratch/disk-low") MB free (under $stop_mb MB); the runs were ended"
fi
[[ $failed -eq 0 ]] && echo "all $runs runs passed and left nothing behind"
exit $failed
