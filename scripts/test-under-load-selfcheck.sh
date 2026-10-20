#!/bin/bash
# Checks that scripts/test-under-load.sh leaves no load behind: its busy loops (2, for a few seconds) are gone after a
# failing command, after Ctrl-C, after its owner dies and after it's killed outright; that it refuses more than
# 2 × ncpu, an already loaded Mac, low memory and a session with no live owner; and that a run's home is its own. Like
# the harness, it won't start on a loaded Mac: run it again once `uptime` is under 2 × ncpu.
#
# scripts/test-under-load-selfcheck.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

harness=scripts/test-under-load.sh
cores=$(sysctl -n hw.ncpu)
work=$(mktemp -d /tmp/vs-load-check.XXXXXX)
started=()
cleanup() {
    # Whatever a failed check left: the harnesses it started and the busy loops they recorded, by pid.
    set +u
    kill -9 "${started[@]}" $(cat "$work"/*.pids 2>/dev/null) 2>/dev/null
    rm -r "$work"
}
on_exit cleanup
# Ctrl-C reaches the whole process group, as from a terminal: each harness gets its own (job control).
set -m

failures=0
check() {
    if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi
}

# True once none of the pids in FILE is running, within S seconds (a zombie is gone).
gone_within() {
    local file=$1 seconds=$2 pid alive
    [[ -s $file ]] || return 1
    for _ in $(seq 1 $((seconds * 10))); do
        alive=0
        for pid in $(cat "$file"); do [[ $(ps -o stat= -p "$pid" 2>/dev/null) == [^Z]* ]] && alive=1; done
        [[ $alive -eq 0 ]] && return 0
        sleep 0.1
    done
    return 1
}

# Waits until the harness has recorded its busy loops in FILE (the load started), up to 10 s.
loaded() {
    for _ in $(seq 1 100); do
        [[ -e $1 && $(wc -l < "$1") -ge 2 ]] && return 0
        sleep 0.1
    done
    return 1
}

if ! $harness --load 2 --check-only > "$work/ready.out"; then
    cat "$work/ready.out"
    echo "not checking now: the harness wouldn't start (above); nothing was started"
    exit 1
fi

# Refusals: none starts anything.
out=$($harness --load $((2 * cores + 1)) --pid-file "$work/cap.pids" -- true); status=$?
check "--load over 2 × ncpu is refused" "[[ $status -ne 0 && \$out == *'at most $((2 * cores))'* && ! -e $work/cap.pids ]]"
out=$(TEST_UNDER_LOAD_FAKE_LOAD=$((2 * cores + 1)) $harness --check-only); status=$?
check "a loaded Mac is refused, saying what to wait for" "[[ $status -ne 0 && \$out == *'already loaded'*'Wait until'* ]]"
out=$($harness --memory-floor 100 --check-only); status=$?
check "memory under the floor is refused" "[[ $status -ne 0 && \$out == *'memory_pressure'* ]]"
out=$(CLAUDECODE=1 TEST_UNDER_LOAD_OWNER_NAME=no-such-process $harness --check-only); status=$?
check "a session with no live claude is refused" "[[ $status -ne 0 && \$out == *'no live owner'* ]]"
# A fake load of 0 would pass --max-load 0.01; the real one (never 0 on a running Mac) doesn't.
out=$(TEST_UNDER_LOAD_FAKE_LOAD=0 $harness --max-load 0.01 --pid-file "$work/fake.pids" -- true); status=$?
check "fake readings are ignored when it would start load" "[[ $status -ne 0 && \$out == *'already loaded'* && ! -e $work/fake.pids ]]"

# A failing command: its status comes back and the busy loops are gone.
$harness --load 2 --pid-file "$work/fail.pids" -- bash -c 'sleep 1; exit 3' > "$work/fail.out" 2>&1
status=$?
check "a failing command's status comes back (3)" "[[ $status -eq 3 ]]"
check "the busy loops are gone after a failing command" "gone_within $work/fail.pids 2"

# Ctrl-C (SIGINT to the harness's process group).
$harness --load 2 --pid-file "$work/int.pids" -- sleep 30 > "$work/int.out" 2>&1 &
harness_pid=$!
started+=($harness_pid)
if loaded "$work/int.pids"; then
    kill -INT -- -"$harness_pid"
    wait "$harness_pid"
    status=$?
    check "Ctrl-C stops the harness (130)" "[[ $status -eq 130 ]]"
    check "the busy loops are gone after Ctrl-C" "gone_within $work/int.pids 2"
else
    check "the harness started its load for Ctrl-C" false
    cat "$work/int.out"
fi

# Its owner dies (a turn ending without its shell): the harness and its busy loops stop by themselves.
bash -c "$harness --load 2 --pid-file $work/owner.pids -- sleep 30 > $work/owner.out 2>&1 & echo \$! > $work/owner.harness; wait" &
owner=$!
started+=($owner)
if loaded "$work/owner.pids"; then
    started+=($(cat "$work/owner.harness"))
    kill -9 "$owner"
    wait "$owner" 2>/dev/null
    echo "$(cat "$work/owner.harness")" > "$work/owner-harness.pids"
    check "the harness stops when its owner is gone" "gone_within $work/owner-harness.pids 5"
    check "the busy loops are gone when the owner is" "gone_within $work/owner.pids 5"
else
    check "the harness started its load under an owner" false
    cat "$work/owner.out"
fi

# Killed outright (SIGKILL, no trap): the busy loops and the command stop anyway.
$harness --load 2 --pid-file "$work/kill.pids" -- bash -c "echo \$\$ > $work/command.pids; exec sleep 30" > "$work/kill.out" 2>&1 &
harness_pid=$!
started+=($harness_pid)
if loaded "$work/kill.pids"; then
    sleep 0.5
    kill -9 "$harness_pid"
    wait "$harness_pid" 2>/dev/null
    check "the busy loops are gone after SIGKILL" "gone_within $work/kill.pids 5"
    check "the command is gone after SIGKILL" "gone_within $work/command.pids 5"
else
    check "the harness started its load for SIGKILL" false
    cat "$work/kill.out"
fi

# A run's home is its own (HOME and CFFIXED_USER_HOME under the harness's scratch), never yours: one test's run says
# where it found itself (LoadHarnessTests.aRunsHomeIsTheOneItsEnvironmentNames).
TEST_UNDER_LOAD_HOME_REPORT="$work/home.txt" $harness --load 2 -r 1 -f aRunsHomeIsTheOneItsEnvironmentNames > "$work/home.out" 2>&1
status=$?
report=$(cat "$work/home.txt" 2>/dev/null)
check "a run's HOME and CFFIXED_USER_HOME are its own, under the harness's scratch" \
    "[[ $status -eq 0 && \$report =~ ^home=(/private)?/tmp/vs-load\.[^/]+/home-1\ HOME=(/private)?/tmp/vs-load\.[^/]+/home-1\ CFFIXED_USER_HOME=(/private)?/tmp/vs-load\.[^/]+/home-1$ ]]"
[[ $status -eq 0 ]] || cat "$work/home.out"

if [[ $failures -eq 0 ]]; then echo "all checks passed"; else echo "$failures checks failed"; fi
exit $((failures > 0))
