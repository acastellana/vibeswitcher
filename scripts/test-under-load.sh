#!/bin/bash
# The one way to put load on this Mac for a test. With no command it runs the whole test suite 3 times at once beside
# a CPU burner (one busy loop per core), the way a Mac with several sessions building and testing is loaded, and checks
# that each run passes and leaves nothing behind. Run it when you add or change a host, timing or concurrency test: a
# wait that only holds on an idle Mac fails here, not on project-lead. With `-- COMMAND` it runs COMMAND beside the
# busy loops instead (a `swift test --filter` reproducing a failure seen under load) and exits with its status.
#
# The Mac is shared with other sessions and the user, so it starts at most 2 × ncpu busy loops, and not at all while
# the 1-minute load (`uptime`) is already over 2 × ncpu, memory is under the floor or the disk is nearly full: it says
# what to wait for instead. Each busy loop is its own watchdog: it stops when this script, its parent or the session's
# claude process is gone, or after --max-time, so a turn that ends without this shell ending leaves no load behind.
# The busy loops' pids are recorded (--pid-file) and killed by pid on any exit, Ctrl-C too; never by name.
#
# Each run gets its own empty TMPDIR (tests put their scratch files under it, see `scratchRoot` in the tests'
# TestSupport.swift) and must leave it empty; what's left is named by prefix. Run 1's is long (about 130 characters, as
# a Claude session's scratchpad is): the suite passes whatever TMPDIR is, sockets and names included. The runs start
# the test bundle the way `swift test` does (swiftpm-testing-helper), directly: three `swift test` would take turns on
# SwiftPM's lock on .build.
# Logs: .build/test-under-load/run-N.log. Everything else (the TMPDIRs, the burner) is gone when it exits, Ctrl-C too.
# scripts/test-under-load-selfcheck.sh shows the cleanup and the refusals work.
#
# scripts/test-under-load.sh [--load N] [--memory-floor PCT] [--max-load L] [--max-time S] [--pid-file FILE]
#                            [--check-only] [-r RUNS] [-f FILTER] [-- COMMAND...]
#   --load N: busy loops (ncpu; at most 2 × ncpu).  --memory-floor PCT: least free memory to start (25 %); the runs are
#   stopped if it falls under half of it.  --max-load L: the 1-minute load over which it won't start (2 × ncpu; only
#   lower).  --max-time S: everything stops after S seconds (1800; at most 3600).  --pid-file FILE: where the busy
#   loops' pids go (kept after it exits).  --check-only: the checks alone, nothing started.
#   -r RUNS: suites at once (3).  -f FILTER: only the tests matching FILTER (as `swift test --filter`), for a quick look.
set -uo pipefail
cd "$(dirname "$0")/.."

cores=$(sysctl -n hw.ncpu)
cap=$((2 * cores))
usage="usage: scripts/test-under-load.sh [--load N] [--memory-floor PCT] [--max-load L] [--max-time S] [--pid-file FILE]"
usage+=" [--check-only] [-r RUNS] [-f FILTER] [-- COMMAND...]"

runs=3 filter="" load=$cores memory_floor=25 max_load=$cap max_time=1800 pid_file="" check_only=0 command=()
value() {
    [[ -n ${2-} ]] || { echo "$1 needs a value; $usage"; exit 64; }
}
while [[ $# -gt 0 ]]; do
    case $1 in
        --load) value "$@"; load=$2; shift 2 ;;
        --memory-floor) value "$@"; memory_floor=$2; shift 2 ;;
        --max-load) value "$@"; max_load=$2; shift 2 ;;
        --max-time) value "$@"; max_time=$2; shift 2 ;;
        --pid-file) value "$@"; pid_file=$2; shift 2 ;;
        --check-only) check_only=1; shift ;;
        -r) value "$@"; runs=$2; shift 2 ;;
        -f) value "$@"; filter=$2; shift 2 ;;
        --) shift; command=("$@"); break ;;
        -h | --help) echo "$usage"; exit 0 ;;
        *) echo "$1? $usage"; exit 64 ;;
    esac
done
for option in "load:$load" "memory-floor:$memory_floor" "max-time:$max_time" "r:$runs"; do
    [[ ${option#*:} =~ ^[0-9]+$ ]] || { echo "--${option%%:*} takes a whole number, not ${option#*:}"; exit 64; }
done
[[ $max_load =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "--max-load takes a number, not $max_load"; exit 64; }

# The fake readings below are for the checks' tests, and only with --check-only, which starts nothing: they can make
# it refuse, never make it start load it shouldn't.
if [[ $check_only -eq 0 ]]; then
    unset TEST_UNDER_LOAD_FAKE_LOAD TEST_UNDER_LOAD_FAKE_MEMORY TEST_UNDER_LOAD_FAKE_DISK_GB TEST_UNDER_LOAD_OWNER_NAME
fi

# More load than this is no longer "a loaded Mac", it's one nobody else can use.
if [[ $load -gt $cap ]]; then
    echo "--load $load refused: at most $cap load processes (2 × $cores cores). Reproduce at the contract's load," \
        "not more: other sessions and the user are working on this Mac."
    exit 1
fi
if awk -v l="$max_load" -v c="$cap" 'BEGIN { exit !(l > c) }'; then
    echo "--max-load $max_load refused: it can only lower the threshold (at most $cap, 2 × $cores cores)"
    exit 1
fi
[[ $memory_floor -le 100 ]] || { echo "--memory-floor is a percentage (0–100), not $memory_floor"; exit 64; }
[[ $max_time -le 3600 ]] || { echo "--max-time $max_time refused: at most 3600 s"; exit 1; }

# Who this run belongs to: its parent, and the session's claude process when it runs in one. The load stops when
# either is gone, so a session whose turn has no live owner can't start any.
claude_ancestor() {
    local pid=$PPID comm
    while [[ $pid -gt 1 ]]; do
        comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
        [[ ${comm##*/} == "${TEST_UNDER_LOAD_OWNER_NAME:-claude}" ]] && { echo "$pid"; return 0; }
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [[ -n $pid ]] || return 1
    done
    return 1
}
if [[ $PPID -le 1 ]]; then
    echo "not starting: this script's parent is gone (the shell that started it has ended), so nothing owns the load"
    exit 1
fi
owners=("$PPID")
if claude=$(claude_ancestor); then
    owners+=("$claude")
elif [[ -n ${CLAUDECODE-} ]]; then
    echo "not starting: this runs in a Claude Code session (CLAUDECODE is set) but no claude process is among its" \
        "parents, so the turn that ran it has no live owner and nothing would stop the load if it were left behind"
    exit 1
fi

loadavg=${TEST_UNDER_LOAD_FAKE_LOAD:-$(uptime | sed -E 's/.*load averages?: *([0-9.]+).*/\1/')}
if awk -v l="$loadavg" -v m="$max_load" 'BEGIN { exit !(l > m) }'; then
    echo "not starting: the Mac is already loaded, its 1-minute load is $loadavg (over $max_load, 2 × $cores cores)." \
        "Wait until the first of \`uptime\`'s load averages is under $max_load (the other sessions' builds and tests" \
        "finishing; it falls within a minute or two once they're done), then run this again."
    exit 1
fi

free_memory() {
    echo "${TEST_UNDER_LOAD_FAKE_MEMORY:-$(memory_pressure -Q | sed -nE 's/.*free percentage: *([0-9]+)%.*/\1/p')}"
}
memory=$(free_memory)
if [[ -z $memory || $memory -lt $memory_floor ]]; then
    echo "not starting: only ${memory:-?} % of memory is free (under the floor of $memory_floor %). Wait until" \
        "\`memory_pressure -Q\` shows at least $memory_floor % free (another session's build or test run finishing)."
    exit 1
fi

# Not on a nearly full disk: a full one stops every session on this Mac, not just these runs.
floor_gb=15
free_gb=${TEST_UNDER_LOAD_FAKE_DISK_GB:-$(($(df -k . | awk 'NR == 2 { print $4 }') / 1024 / 1024))}
if [[ $free_gb -lt $floor_gb ]]; then
    echo "only $free_gb GB free (under $floor_gb GB): not starting; free some space first"
    exit 1
fi

if [[ $check_only -eq 1 ]]; then
    echo "ok to start: load $loadavg (under $max_load), $memory % of memory free (floor $memory_floor %)," \
        "$free_gb GB of disk free; up to $load load processes, owned by ${owners[*]}"
    exit 0
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
    [[ -n $watchdog ]] && kill "$watchdog" 2>/dev/null
    stop "${burners[@]}"
    stop "${tests[@]}"
    wait 2>/dev/null
    # Not from the terminal: rm would ask about each read-only file a test's git repository left.
    [[ -n $scratch ]] && rm -r "$scratch" < /dev/null
}
# Why the watchdog stopped this script, if it did.
stopped() {
    echo
    if [[ -e $scratch/owner-gone ]]; then
        echo "stopped: its owner (pid $(cat "$scratch/owner-gone")) is gone, so the load and the runs were ended"
    elif [[ -e $scratch/timed-out ]]; then
        echo "stopped: it ran over --max-time ($max_time s), so the load and the runs were ended"
    else
        echo "stopped"
    fi
    exit 130
}
trap cleanup EXIT
trap stopped INT TERM

if [[ ${#command[@]} -eq 0 ]]; then
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
fi

# Short: host tests put sockets under it, and a socket's path is limited to 104 bytes.
scratch=$(mktemp -d /tmp/vs-load.XXXXXX)
pid_file=${pid_file:-$scratch/load.pids}
: > "$pid_file"

# When this script ends without its trap (SIGKILL), nothing it started stays: the busy loops stop once its pid is gone,
# and this watchdog then stops them and the test runs (their pids in $pid_file and $scratch/pids) and removes the
# scratch. Meanwhile, every second: when an owner is gone or --max-time is up it stops this script (whose trap ends the
# rest); the lowest free disk goes in $scratch/disk-min (MB), and under $stop_mb it stops the load and the runs before
# the disk fills ($scratch/disk-low says so); free memory under half the floor does the same ($scratch/memory-low).
stop_mb=5120
memory_stop=$((memory_floor / 2))
(
    trap - EXIT INT TERM
    lowest="" deadline=$((SECONDS + max_time))
    while kill -0 "$script" 2>/dev/null; do
        for pid in "${owners[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                echo "$pid" > "$scratch/owner-gone"
                kill -TERM "$script"
                break 2
            fi
        done
        if [[ $SECONDS -ge $deadline ]]; then
            touch "$scratch/timed-out"
            kill -TERM "$script"
            break
        fi
        free=$(($(df -k . | awk 'NR == 2 { print $4 }') / 1024))
        if [[ -z $lowest || $free -lt $lowest ]]; then lowest=$free; echo "$lowest" > "$scratch/disk-min"; fi
        if [[ $free -lt $stop_mb && ! -e $scratch/disk-low ]]; then
            echo "$free" > "$scratch/disk-low"
            stop $(cat "$pid_file" "$scratch/pids" 2>/dev/null)
        fi
        memory=$(free_memory)
        if [[ -n $memory && $memory -lt $memory_stop && ! -e $scratch/memory-low ]]; then
            echo "$memory" > "$scratch/memory-low"
            stop $(cat "$pid_file" "$scratch/pids" 2>/dev/null)
        fi
        sleep 1
    done
    # Stopped by this script's trap, which ends the rest; or the script is gone, so end it here.
    while kill -0 "$script" 2>/dev/null; do sleep 0.2; done
    stop $(cat "$pid_file" "$scratch/pids" 2>/dev/null)
    rm -r "$scratch" < /dev/null 2>/dev/null
) &
watchdog=$!

# A busy loop that checks, between rounds, that this script and its owners are still there and its time isn't up.
burn='end=$((SECONDS + $1)); shift
while [[ $SECONDS -lt $end ]]; do
    for pid in "$@"; do kill -0 "$pid" 2>/dev/null || exit 0; done
    for ((i = 0; i < 200000; i++)); do :; done
done'
for ((n = 0; n < load; n++)); do
    bash -c "$burn" burner "$max_time" "$script" "${owners[@]}" &
    burners+=($!)
    echo $! >> "$pid_file"
done
echo "burning $load of $cores cores (pids in $pid_file); load $(sysctl -n vm.loadavg)"

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
failed=0
if [[ ${#command[@]} -gt 0 ]]; then
    # In the background so that a signal reaches the trap at once, not when the command is done.
    "${command[@]}" &
    tests+=($!)
    echo $! >> "$scratch/pids"
    wait "${tests[0]}"
    failed=$?
    echo "${command[*]} exited $failed"
else
    for run in $(seq 1 "$runs"); do
        mkdir -p "$(tmpdir "$run")"
        args=(--test-bundle-path "$bundle")
        [[ -n $filter ]] && args+=(--filter "$filter")
        TMPDIR="$(tmpdir "$run")/" "$helper" "${args[@]}" "$bundle" --testing-library swift-testing > "$logs/run-$run.log" 2>&1 &
        tests+=($!)
        echo $! >> "$scratch/pids"
    done

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
fi
tests=()
echo "took $(($(date +%s) - started)) s; load $(sysctl -n vm.loadavg); lowest free disk $(cat "$scratch/disk-min" 2>/dev/null) MB;" \
    "$(sysctl -n vm.swapusage | sed -E 's/  +/ /g')"
if [[ -e $scratch/disk-low ]]; then
    failed=1
    echo "STOPPED: the disk fell to $(cat "$scratch/disk-low") MB free (under $stop_mb MB); the load and the runs were ended"
fi
if [[ -e $scratch/memory-low ]]; then
    failed=1
    echo "STOPPED: free memory fell to $(cat "$scratch/memory-low") % (under $memory_stop %); the load and the runs were ended"
fi
[[ $failed -eq 0 && ${#command[@]} -eq 0 ]] && echo "all $runs runs passed and left nothing behind"
exit $failed
