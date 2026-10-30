#!/bin/bash
# The one way to put load on this Mac for a test. With no command it runs the whole test suite 3 times at once beside
# a CPU burner (one busy loop per core), the way a Mac with several sessions building and testing is loaded, and checks
# that each run passes and leaves nothing behind. Run it when you add or change a host, timing or concurrency test: a
# wait that only holds on an idle Mac fails here, not on main. With `-- COMMAND` it runs COMMAND beside the
# busy loops instead (a `swift test --filter` reproducing a failure seen under load) and exits with its status.
#
# The Mac is shared with other sessions and the user. --load N is the load to reach, not loops to add: every few
# seconds it starts or stops busy loops so that its own make up what the others' load (the 1-minute load less its
# loops' share of it) leaves short of N, never more than N (at most 2 × ncpu), and says how many it ran on average.
# On a Mac already busy it adds little; on a calm one it still reaches N. On 2026-10-28 two runs of 24 loops each, two
# full suites and macOS's scans of the new test binaries took the load to 150 on 12 cores and froze the user's app for
# minutes, so: one load run burns at a time on this Mac (a flock on load-run.lock in vs-heavy's folder: a second run
# waits, saying whose it waits for), and each holds one of vs-heavy's Mac-wide slots for heavy work for the whole run
# (it runs itself under Resources/bin/vs-heavy, waiting in its line, its holder note naming the loops). Before it
# burns it waits while the 1-minute load is over --max-load, saying so; memory under the floor or a nearly full disk
# it refuses at once, saying what to wait for. --wait bounds the waits for the other load run and for the load.
# Each busy loop is its own watchdog: it stops when this script, its parent or the session's claude process is gone,
# or after --max-time, so a turn that ends without this shell ending leaves no load behind. The live busy loops' pids
# are kept in --pid-file and killed by pid on any exit, Ctrl-C too; never by name.
#
# Each run gets its own empty TMPDIR (tests put their scratch files under it, see `scratchRoot` in the tests'
# TestSupport.swift) and must leave it empty; what's left is named by prefix. Each run gets its own empty home too
# (HOME and CFFIXED_USER_HOME), so nothing a test writes under ~ (~/.vibeswitcher, ~/.claude) reaches yours. Run 1's is long (about 130 characters, as
# a Claude session's scratchpad is): the suite passes whatever TMPDIR is, sockets and names included. The runs start
# the test bundles the way `swift test` does (swiftpm-testing-helper), directly: three `swift test` would take turns on
# SwiftPM's lock on .build. The bundles are whatever the build produced: Swift Build's (the default since Swift 6.4) one
# per test target, run in turn, or the deprecated native build system's one for the package; a bundle missing, one not
# the package's, or a run in which no test ran (a filter matching nothing) fails the run rather than pass it.
# Logs: .build/test-under-load/run-N.log. Everything else (the TMPDIRs, the burner) is gone when it exits, Ctrl-C too.
# scripts/test-under-load-selfcheck.sh shows the cleanup and the refusals work.
#
# scripts/test-under-load.sh [--load N] [--memory-floor PCT] [--max-load L] [--max-time S] [--wait S]
#                            [--pid-file FILE] [--check-only] [-r RUNS] [-f FILTER] [-- COMMAND...]
#   --load N: the load to top up to (ncpu; at most 2 × ncpu), so at most N busy loops.  --memory-floor PCT: least free
#   memory to start (25 %); the runs are stopped if it falls under half of it.  --max-load L: the 1-minute load over
#   which it waits before burning (2 × ncpu; only lower).  --max-time S: everything stops after S seconds (1800; at
#   most 3600).  --wait S: how long it waits for the other load run and the load, together, before it gives up (3600;
#   at most 3600; 0: refuse at once).  --pid-file FILE: the live busy loops' pids (kept after it exits).
#   --check-only: the checks alone, refusing rather than waiting, nothing started and no slot taken.
#   -r RUNS: suites at once (3).  -f FILTER: only the tests matching FILTER (as `swift test --filter`), for a quick look.
# For its own tests only: TEST_UNDER_LOAD_FAKE_BURNER=1 makes each busy loop sleep instead of burn, and only then (or
# with --check-only) are the fake readings (TEST_UNDER_LOAD_FAKE_LOAD: a number, or a file holding one, read at each
# look) and TEST_UNDER_LOAD_TICK (seconds between looks, 5) taken.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
source scripts/lib/module-cache.sh
# Each run's home is the one given below; an exported VIBESWITCHER_HOME would come before it (`VibePaths.root`).
unset VIBESWITCHER_HOME

cores=$(sysctl -n hw.ncpu)
cap=$((2 * cores))
usage="usage: scripts/test-under-load.sh [--load N] [--memory-floor PCT] [--max-load L] [--max-time S] [--wait S]"
usage+=" [--pid-file FILE] [--check-only] [-r RUNS] [-f FILTER] [-- COMMAND...]"

arguments=("$@")
runs=3 filter="" load=$cores memory_floor=25 max_load=$cap max_time=1800 wait=3600 pid_file="" check_only=0 command=()
value() {
    [[ -n ${2-} ]] || { echo "$1 needs a value; $usage"; exit 64; }
}
while [[ $# -gt 0 ]]; do
    case $1 in
        --load) value "$@"; load=$2; shift 2 ;;
        --memory-floor) value "$@"; memory_floor=$2; shift 2 ;;
        --max-load) value "$@"; max_load=$2; shift 2 ;;
        --max-time) value "$@"; max_time=$2; shift 2 ;;
        --wait) value "$@"; wait=$2; shift 2 ;;
        --pid-file) value "$@"; pid_file=$2; shift 2 ;;
        --check-only) check_only=1; shift ;;
        -r) value "$@"; runs=$2; shift 2 ;;
        -f) value "$@"; filter=$2; shift 2 ;;
        --) shift; command=("$@"); break ;;
        -h | --help) echo "$usage"; exit 0 ;;
        *) echo "$1? $usage"; exit 64 ;;
    esac
done
for option in "load:$load" "memory-floor:$memory_floor" "max-time:$max_time" "wait:$wait" "r:$runs"; do
    [[ ${option#*:} =~ ^[0-9]+$ ]] || { echo "--${option%%:*} takes a whole number, not ${option#*:}"; exit 64; }
done
[[ $max_load =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "--max-load takes a number, not $max_load"; exit 64; }

# The fake readings below are for the checks' tests, and only with --check-only, which starts nothing, or with the
# fake burner, whose loops only sleep: they can make it refuse, never make it start load it shouldn't.
fake_burner=0
[[ ${TEST_UNDER_LOAD_FAKE_BURNER-} == 1 ]] && fake_burner=1
if [[ $check_only -eq 0 && $fake_burner -eq 0 ]]; then
    unset TEST_UNDER_LOAD_FAKE_LOAD TEST_UNDER_LOAD_FAKE_MEMORY TEST_UNDER_LOAD_FAKE_DISK_GB TEST_UNDER_LOAD_OWNER_NAME
    unset TEST_UNDER_LOAD_TICK
fi
tick=${TEST_UNDER_LOAD_TICK:-5}
[[ $tick =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v t="$tick" 'BEGIN { exit !(t > 0) }' || { echo "TEST_UNDER_LOAD_TICK takes seconds, not $tick"; exit 64; }

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
[[ $wait -le 3600 ]] || { echo "--wait $wait refused: at most 3600 s"; exit 1; }

# Run under vs-heavy (below), this script runs again as its command: `inner`, with the slot held.
inner=0
[[ -n ${TEST_UNDER_LOAD_INNER-} && -n ${VIBESWITCHER_TEST_LOCK-} ]] && inner=1
# Its own, not its runs': a harness a test starts takes the lock and a slot of its own.
starter=${TEST_UNDER_LOAD_INNER-} waited_until=${TEST_UNDER_LOAD_WAIT_UNTIL-} lock_note=${TEST_UNDER_LOAD_LOCK_NOTE-}
unset TEST_UNDER_LOAD_INNER TEST_UNDER_LOAD_WAIT_UNTIL TEST_UNDER_LOAD_LOCK_NOTE

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
# Under vs-heavy its parent is vs-heavy's supervisor; the owner is the one that started it, an ancestor still.
owners=("$PPID")
if [[ $inner -eq 1 ]]; then
    ancestor=$PPID
    while [[ $ancestor -gt 1 && $ancestor != "$starter" ]]; do
        ancestor=$(ps -o ppid= -p "$ancestor" 2>/dev/null | tr -d ' ')
        [[ -n $ancestor ]] || ancestor=0
    done
    if [[ $ancestor != "$starter" || $ancestor -le 1 ]]; then
        echo "not starting: the shell that started it (pid $starter) is gone, so nothing owns the load"
        exit 1
    fi
    owners=("$starter")
    # The load-run lock is vs-heavy's and its supervisor's to hold, so nothing this run starts keeps it; under a slot
    # held already (VIBESWITCHER_TEST_LOCK), vs-heavy ran this in its own process, and fd 8 is this one's alone to hold.
    [[ $PPID != "$starter" ]] && exec 8>&-
fi
if claude=$(claude_ancestor); then
    owners+=("$claude")
elif [[ -n ${CLAUDECODE-} ]]; then
    echo "not starting: this runs in a Claude Code session (CLAUDECODE is set) but no claude process is among its" \
        "parents, so the turn that ran it has no live owner and nothing would stop the load if it were left behind"
    exit 1
fi

# The 1-minute load: the fake's (a number, or the file holding one) in its tests.
one_minute() {
    local fake=${TEST_UNDER_LOAD_FAKE_LOAD-}
    if [[ $fake == /* ]]; then
        cat "$fake" 2>/dev/null || echo 0
    elif [[ -n $fake ]]; then
        echo "$fake"
    else
        sysctl -n vm.loadavg | awk '{ print $2 }'
    fi
}
over() { awk -v l="$1" -v m="$max_load" 'BEGIN { exit !(l > m) }'; }
# While it waits (for the other load run, for the load), it holds the load-run lock or a heavy slot: once an owner is
# gone (the turn ended without this shell ending), it stops waiting rather than hold them for nobody.
owned() {
    local pid
    for pid in "${owners[@]}"; do
        kill -0 "$pid" 2>/dev/null && continue
        echo "stopped waiting: its owner (pid $pid) is gone, so nothing would own the load; nothing was started"
        exit 1
    done
}
refuse_loaded() {
    echo "not starting: the Mac is already loaded, its 1-minute load is $1 (over $max_load, 2 × $cores cores)." \
        "Wait until the first of \`uptime\`'s load averages is under $max_load (the other sessions' builds and tests" \
        "finishing; it falls within a minute or two once they're done), then run this again."
    exit 1
}
# Until when it may wait, for the other load run and the load together (set once, before vs-heavy).
wait_until=${waited_until:-$(($(date +%s) + wait))}
[[ $inner -eq 1 ]] || wait_until=$(($(date +%s) + wait))

loadavg=$(one_minute)
if [[ $check_only -eq 1 || $wait -eq 0 ]]; then
    over "$loadavg" && refuse_loaded "$loadavg"
elif [[ $inner -eq 1 ]]; then
    said=0
    while over "$loadavg"; do
        owned
        [[ $(date +%s) -lt $wait_until ]] || refuse_loaded "$loadavg"
        if [[ $((SECONDS - said)) -ge 60 || $said -eq 0 ]]; then
            echo "waiting: the Mac's 1-minute load is $loadavg, over $max_load (2 × $cores cores); it burns once it's under" \
                "(for at most --wait $wait s from the start)"
            said=$SECONDS
            [[ $said -gt 0 ]] || said=1
        fi
        sleep "$tick"
        loadavg=$(one_minute)
    done
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

# One load run at a time on this Mac, each in a heavy-work slot: here the load-run lock (fd 8, waiting for the other
# run up to --wait), then this script again under vs-heavy, which waits in its line for a slot. The lock stays with
# vs-heavy and its supervisor (an exec keeps the fd) until the run is over, a kill -9 too.
if [[ $inner -eq 0 ]]; then
    lock_dir=${VIBESWITCHER_TEST_LOCK_DIR:-/private/tmp/vibeswitcher-$(id -u)}
    while [[ $lock_dir == */ && $lock_dir != / ]]; do lock_dir=${lock_dir%/}; done
    mkdir -p -m 700 "$lock_dir" || { echo "can't make $lock_dir for the load-run lock"; exit 1; }
    [[ -O $lock_dir && ! -L $lock_dir ]] || { echo "$lock_dir isn't a folder of yours: the load-run lock can't be kept there"; exit 1; }
    lock=$lock_dir/load-run.lock
    exec 8>> "$lock" || { echo "can't open $lock"; exit 1; }
    said=""
    until /usr/bin/perl -MFcntl=:flock -e 'open(my $fh, ">&=", 8) or exit 2; exit(flock($fh, LOCK_EX | LOCK_NB) ? 0 : 1)'; do
        holder=$(head -n 1 "$lock.holder" 2>/dev/null)
        # A note naming a process that has ended says nothing.
        [[ $holder =~ ^pid\ ([0-9]+), ]] && ! kill -0 "${BASH_REMATCH[1]}" 2>/dev/null && holder=""
        holder=${holder:-a run that did not say who it is}
        if [[ $holder != "$said" ]]; then
            echo "waiting for the other load run to end (one burns at a time on this Mac, $lock): $holder"
            said=$holder
        fi
        owned
        if [[ $(date +%s) -ge $wait_until ]]; then
            echo "not starting: another load run still burns after --wait $wait s ($holder); run this again once it's done"
            exit 1
        fi
        sleep 0.5
    done
    [[ -n $said ]] && echo "the other load run is over: this one goes on"
    where=$PWD
    [[ $where =~ ^(.*)/\.vibeswitcher/worktrees/([^/]+) ]] && where="$PWD (${BASH_REMATCH[1]##*/})"
    echo "pid $$, test-under-load in $where, since $(date +%H:%M:%S)" > "$lock.holder"
    what="test-under-load: up to $load busy loops (target load $load)"
    [[ ${#command[@]} -gt 0 ]] && what+=" beside ${command[*]}" || what+=" beside $runs suite runs${filter:+ of $filter}"
    TEST_UNDER_LOAD_INNER=$PPID TEST_UNDER_LOAD_WAIT_UNTIL=$wait_until TEST_UNDER_LOAD_LOCK_NOTE="pid $$, $lock.holder"
    export TEST_UNDER_LOAD_INNER TEST_UNDER_LOAD_WAIT_UNTIL TEST_UNDER_LOAD_LOCK_NOTE
    # The repository's own vs-heavy: its slots are the ones every vs-heavy and TestLock take. Its timeout is past
    # --max-time's and the waits', which end the run first.
    exec Resources/bin/vs-heavy --as "$(printf '%s' "$what" | cut -c 1-120)" --timeout "$((max_time + wait + 900))s" \
        /bin/bash "$PWD/scripts/test-under-load.sh" ${arguments[@]+"${arguments[@]}"}
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
    trap - INT TERM
    # /bin/bash 3.2 calls an empty array unbound.
    set +u
    [[ -n $watchdog ]] && kill "$watchdog" 2>/dev/null
    # No run starts another bundle while its processes are being listed and ended (`run_bundles`).
    [[ -n $scratch ]] && : > "$scratch/stopping"
    stop "${burners[@]}"
    stop "${tests[@]}"
    wait 2>/dev/null
    # Not from the terminal: rm would ask about each read-only file a test's git repository left.
    [[ -n $scratch ]] && rm -r "$scratch" < /dev/null
    # The load-run lock's note, while it's still this run's (the lock goes with vs-heavy, just after).
    if [[ -n $lock_note ]]; then
        local note=${lock_note#*, }
        [[ $(head -n 1 "$note" 2>/dev/null) == "${lock_note%%, *}, "* ]] && rm -f "$note"
    fi
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
# The build, and a COMMAND's swift test, leave SwiftPM's empty folders in TMPDIR: a scratch one, gone on exit.
scratch_tmpdir vs-loadtmp
# In a worktree the lead made, the build and a COMMAND's swift test take the SDK's modules from the worktrees' shared cache.
shared_module_cache
on_exit cleanup
trap stopped INT TERM

if [[ ${#command[@]} -eq 0 ]]; then
    # A test that writes to the user's temporary folder itself would escape the check below. The rule is
    # scripts/temporary-folder-lint.txt, which TemporaryFolderLintTests applies in the normal suite too.
    if ! bypass=$(scripts/temporary-folder-lint.sh); then
        echo "These tests use the system temporary folder; use scratchRoot (or a Scratch) instead, or allow them in" \
            "scripts/temporary-folder-lint.txt with a reason:"
        echo "$bypass"
        exit 1
    fi

    echo "building…"
    swift build --build-tests > /dev/null 2>&1 8>&- || { echo "the build failed: run swift build --build-tests"; exit 1; }
    bin=$(swift build --show-bin-path 2>/dev/null 8>&-)
    [[ -d $bin ]] || { echo "no build folder at ${bin:-?} (swift build --show-bin-path)"; exit 1; }
    helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
    [[ -x $helper ]] || { echo "no test runner at $helper"; exit 1; }
    # The test bundles the build produced, as `swift test` would run them: the deprecated native build system's one
    # <Package>PackageTests.xctest holding every test target, or Swift Build's (the default since Swift 6.4) one
    # <Target>.xctest per test target. Which is in $bin says which; the package's test targets (swift package describe)
    # say what must be there, and a bundle missing or unexpected stops the run rather than drop or add tests.
    command -v jq > /dev/null || { echo "no jq on PATH (macOS 15 and later have /usr/bin/jq): the package's test targets can't be read"; exit 1; }
    describe=$(swift package describe --type json 2>/dev/null 8>&-) || { echo "swift package describe failed: the test targets are unknown"; exit 1; }
    package=$(jq -r '.name' <<< "$describe")
    targets=$(jq -r '.targets[] | select(.type == "test") | .name' <<< "$describe" | sort)
    [[ -n $package && -n $targets ]] || { echo "swift package describe names no package or no test target; nothing to run"; exit 1; }
    bundles=()
    if [[ -d $bin/${package}PackageTests.xctest ]]; then
        bundles=("$bin/${package}PackageTests.xctest")
        layout="one bundle, ${package}PackageTests.xctest (the native build system)"
    else
        for target in $targets; do bundles+=("$bin/$target.xctest"); done
        layout="one bundle per test target ($(tr '\n' ' ' <<< "$targets" | sed 's/ $//'); Swift Build)"
    fi
    for bundle in "${bundles[@]}"; do
        executable=$bundle/Contents/MacOS/$(basename "$bundle" .xctest)
        made=$(ls -d "$bin"/*.xctest 2>/dev/null | tr '\n' ' ')
        [[ -x $executable ]] || { echo "no test bundle at $executable: the build made ${made:-none}"; exit 1; }
    done
    other=$(ls -d "$bin"/*.xctest 2>/dev/null | grep -vxF -f <(printf '%s\n' "${bundles[@]}"))
    [[ -z $other ]] || { echo "unexpected test bundles beside the package's in $bin: $(tr '\n' ' ' <<< "$other")"; echo "(the package's: $layout); remove them or run swift build --build-tests again"; exit 1; }
    echo "test bundles: $layout"
    # Where a bundle finds XCTest and Testing (its own folder's dylibs too), as `swift test` tells dyld.
    platform=$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)
    [[ -d $platform/Developer/Library/Frameworks ]] || { echo "no macOS platform at ${platform:-?} (xcrun --show-sdk-platform-path): XCTest.framework can't be found"; exit 1; }
    frameworks="$platform/Developer/Library/Frameworks:$platform/Developer/Library/PrivateFrameworks"
    libraries="$bin:$platform/Developer/usr/lib"
    failures="$bin/vibeswitcher-mcp"
    [[ -x $failures ]] || { echo "no $failures to name a failed run's tests with"; exit 1; }
    mkdir -p "$logs"
    rm -f "$logs"/run-*.log
fi

# Short: host tests put sockets under it, and a socket's path is limited to 104 bytes.
scratch=$(mktemp -d /tmp/vs-load.XXXXXX)
pid_file=${pid_file:-$scratch/load.pids}
: > "$pid_file"

# When this script ends without its trap (SIGKILL), nothing it started stays: the busy loops stop once its pid is gone,
# and this watchdog then stops them and the test runs (their pids in $pid_file and $scratch/pids) and removes the
# scratch folders. Meanwhile, every second: when an owner is gone or --max-time is up it stops this script (whose trap
# ends the rest); the lowest free disk goes in $scratch/disk-min (MB), and under $stop_mb it stops the load and the runs
# before the disk fills ($scratch/disk-low says so); free memory under half the floor does the same ($scratch/memory-low).
stop_mb=5120
memory_stop=$((memory_floor / 2))
(
    trap - INT TERM
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
    rm -r "$scratch" "$tool_scratch" < /dev/null 2>/dev/null
) &
watchdog=$!
# Out of the job table: bash would print its whole text once it's killed. Its end is waited for by pid (`stop`).
disown "$watchdog"

# A busy loop that checks, between rounds, that this script, the top-up and its owners are still there and its time
# isn't up. The fake burner's sleeps instead.
work='for ((i = 0; i < 200000; i++)); do :; done'
[[ $fake_burner -eq 1 ]] && work='sleep 0.1'
burn='end=$((SECONDS + $1)); shift
while [[ $SECONDS -lt $end ]]; do
    for pid in "$@"; do kill -0 "$pid" 2>/dev/null || exit 0; done
    '"$work"'
done'
# The top-up: every $tick seconds, as many busy loops as the others' load leaves short of --load. The others' load is
# the 1-minute load less its loops' share of it, which the kernel averages as it does the load (every 5 s, decaying
# over a minute), so the share is kept the same way; a loop started or stopped shows in the load only bit by bit, and
# without its share's lag the top-up would chase its own loops. The live loops' pids go in $pid_file (rewritten at each
# change), the loops summed over its looks in $scratch/loops ("SUM LOOKS"), each change said.
loops_file=$scratch/loops
(
    trap - INT TERM
    # Its own pid (/bin/bash 3.2 has no BASHPID): the parent of a shell it starts.
    me=$(exec /bin/sh -c 'echo $PPID') live=() share=0 sum=0 looks=0
    decay=$(awk -v t="$tick" 'BEGIN { printf "%.6f", exp(-t / 60) }')
    while kill -0 "$script" 2>/dev/null; do
        now=$(one_minute)
        want=$(awk -v n="$load" -v l="$now" -v s="$share" 'BEGIN { o = l - s; if (o < 0) o = 0; w = int(n - o + 0.5);
            if (w < 0) w = 0; if (w > n) w = n; print w }')
        before=${#live[@]}
        while [[ ${#live[@]} -lt $want ]]; do
            bash -c "$burn" burner "$max_time" "$script" "$me" "${owners[@]}" 8>&- &
            live+=($!)
        done
        while [[ ${#live[@]} -gt $want ]]; do
            last=${live[${#live[@]} - 1]}
            kill "$last" 2>/dev/null
            wait "$last" 2>/dev/null
            unset "live[${#live[@]}-1]"
        done
        if [[ ${#live[@]} -ne $before || $looks -eq 0 ]]; then
            printf '%s\n' ${live[@]+"${live[@]}"} > "$pid_file.new" && mv "$pid_file.new" "$pid_file"
            echo "busy loops: ${#live[@]} (1-minute load $now, target $load, on $cores cores)"
        fi
        sum=$((sum + ${#live[@]})) looks=$((looks + 1))
        echo "$sum $looks" > "$loops_file"
        share=$(awk -v s="$share" -v k="${#live[@]}" -v d="$decay" 'BEGIN { printf "%.4f", s * d + k * (1 - d) }')
        sleep "$tick"
    done
) &
burners+=($!)
disown "$!"
echo "topping the load up to $load on $cores cores (pids in $pid_file); load $(sysctl -n vm.loadavg)"
# Its first look before the runs start: the loops it starts then are running when they do.
for _ in $(seq 1 100); do [[ -s $loops_file ]] && break; sleep 0.1; done

# Run N's TMPDIR: run 1's long, the others' short.
tmpdir() {
    local dir="$scratch/$1"
    if [[ $1 -eq 1 ]]; then
        dir+="/long"
        while [[ ${#dir} -lt 130 ]]; do dir+="-tmpdir"; done
    fi
    echo "$dir"
}

# Run N's home (HOME and CFFIXED_USER_HOME): an empty folder of its own, gone with the scratch.
home() {
    echo "$scratch/home-$1"
}

started=$(date +%s)
failed=0
if [[ ${#command[@]} -gt 0 ]]; then
    # In the background so that a signal reaches the trap at once, not when the command is done.
    "${command[@]}" 8>&- &
    tests+=($!)
    echo $! >> "$scratch/pids"
    wait "${tests[0]}"
    failed=$?
    echo "${command[*]} exited $failed"
else
    # Run N: each test bundle in turn, the way `swift test` runs them, into the run's log ("=== Bundle" before each,
    # "=== Bundle exited S" after); its status is the first failing bundle's, and the bundles after it still run (their
    # tests are wanted too). Swift Testing exits 69 (EX_UNAVAILABLE) saying nothing when the filter matches none of a
    # bundle's tests: no test of that bundle's, not a failure (a run in which no bundle ran a test fails below). Once
    # the run is being stopped (cleanup's mark, the watchdog's disk-low or memory-low) no further bundle starts: one
    # started while `stop` lists the run's processes would outlive it.
    run_bundles() {
        local run=$1 status=0 bundle name executable args log=$logs/run-$1.log before code
        for bundle in "${bundles[@]}"; do
            [[ -e $scratch/stopping || -e $scratch/disk-low || -e $scratch/memory-low ]] && return 130
            name=$(basename "$bundle" .xctest)
            executable=$bundle/Contents/MacOS/$name
            args=(--test-bundle-path "$executable")
            [[ -n $filter ]] && args+=(--filter "$filter")
            echo "=== $name" >> "$log"
            before=$(wc -c < "$log")
            DYLD_FRAMEWORK_PATH=$frameworks DYLD_LIBRARY_PATH=$libraries \
                "$helper" "${args[@]}" "$executable" --testing-library swift-testing >> "$log" 2>&1
            code=$?
            if [[ $code -eq 69 && $(wc -c < "$log") -eq $before ]]; then
                echo "=== no test of $name matches" >> "$log"
                code=0
            fi
            echo "=== $name exited $code" >> "$log"
            [[ $status -eq 0 ]] && status=$code
        done
        return $status
    }
    for run in $(seq 1 "$runs"); do
        mkdir -p "$(tmpdir "$run")" "$(home "$run")"
        : > "$logs/run-$run.log"
        HOME="$(home "$run")" CFFIXED_USER_HOME="$(home "$run")" with_tmpdir "$(tmpdir "$run")/" run_bundles "$run" 8>&- &
        tests+=($!)
        echo $! >> "$scratch/pids"
    done

    counts=()
    for run in $(seq 1 "$runs"); do
        status=0
        wait "${tests[$((run - 1))]}" || status=$?
        # Each bundle's closing line ("✔ Test run with 12 tests in 3 suites passed after 3.1 seconds."; a test's own
        # output never starts with the mark); the run's tests are their sum, and a bundle none of whose tests matched
        # has no closing line.
        results=$(sed -E 's/\x1B\[[0-9;]*m//g' "$logs/run-$run.log" | grep -E "^[^ ]+ Test run with [0-9]+ tests? ")
        lines=$(grep -c . <<< "$results")
        unmatched=$(grep -c "^=== no test of .* matches$" "$logs/run-$run.log")
        count=$(grep -oE "Test run with [0-9]+" <<< "$results" | awk '{ s += $4 } END { print s + 0 }')
        counts+=("$count")
        if [[ ${#bundles[@]} -eq 1 ]]; then
            tail=$(tail -1 <<< "$results")
        else
            tail="$count tests over ${#bundles[@]} bundles"
        fi
        echo "run $run$([[ $run -eq 1 ]] && echo " (long TMPDIR)"): exit $status  ${tail:-(no result line)}  ($logs/run-$run.log)"
        if [[ $status -ne 0 ]]; then
            failed=1
            summary=$("$failures" --test-failures "$logs/run-$run.log")
            echo "${summary:-the run failed without naming a test; see the log}" | sed 's/^/    /'
        fi
        if [[ $((lines + unmatched)) -ne ${#bundles[@]} ]]; then
            failed=1
            echo "    $lines of ${#bundles[@]} bundles gave a result line$([[ $unmatched -gt 0 ]] && echo " ($unmatched matched no test)"): one crashed or was stopped; see the log"
        fi
        if [[ $count -eq 0 ]]; then
            failed=1
            echo "    no test ran${filter:+: nothing matches -f '$filter'} (a filter is a regular expression over Target.Suite/test, as swift test --filter's)"
        fi
        if [[ ${#bundles[@]} -gt 1 && ( $status -ne 0 || $((lines + unmatched)) -ne ${#bundles[@]} || $count -eq 0 ) ]]; then
            sed -E 's/\x1B\[[0-9;]*m//g' "$logs/run-$run.log" | grep -E "^=== |^[^ ]+ Test run with [0-9]+ tests? " | sed 's/^/    /'
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
# The load ends with the runs: no look of the top-up's comes after what follows.
stop "${burners[@]}"
burners=()
read -r sum looks < "$loops_file" 2>/dev/null
echo "busy loops: $(awk -v s="${sum:-0}" -v n="${looks:-0}" 'BEGIN { printf "%.1f", n ? s / n : 0 }') on average" \
    "(target load $load, over ${looks:-0} looks every $tick s)"
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
if [[ $failed -eq 0 && ${#command[@]} -eq 0 ]]; then
    echo "all $runs runs passed and left nothing behind ($(printf '%s\n' ${counts[@]+"${counts[@]}"} | sort -un | paste -sd, - | sed 's/,/, /g') tests each)"
fi
exit $failed
