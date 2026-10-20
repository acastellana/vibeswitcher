#!/bin/bash
# `swift build && swift test "$@"` on a fresh scratch home, so nothing a test writes reaches your ~/.vibeswitcher,
# ~/.claude or login Keychain. HOME, CFFIXED_USER_HOME (what NSHomeDirectory() follows; HOME alone doesn't move it),
# VIBESWITCHER_HOME and TMPDIR all point into a folder this creates under /tmp and removes when it exits, Ctrl-C too
# (scripts/lib/scratch.sh).
# A plain `swift test` on your own home refuses to start (see `VibePaths.testRefusal`).
#
# Then no process of the run may be left: a scratch session host, its sessions' parsers (launcher-* --parse-session)
# or programs, a bench's app. Each has the run's scratch folder in its environment (HOME, TMPDIR) or its arguments,
# and nothing else on the Mac has. One still alive 10 s after the tests is ended (SIGTERM, then SIGKILL) and named,
# and the run fails. On 2026-10-20 hosts from a run a day before still ran, one of them a test's counter loop (8
# CPU-minutes so far): a host runs in a process group of its own and outlives a runner killed with its group.
#
# scripts/test.sh [swift test options], e.g. scripts/test.sh --filter HomeIsolationTests
# scripts/test.sh --leftovers MARK: only the check, for the processes whose environment or arguments hold MARK
#   (LeftoverCheckTests); exit 1 when it ended any.
set -uo pipefail
cd "$(dirname "$0")/.."

# The live processes holding $1 in their environment or arguments, and every process under one of them (the programs a
# scratch host runs: ps shows the environment of the app's own binaries, not of Apple's /bin/sh), as "pid command".
# Never this script, a process it runs (the awk below, its subshells) or one it runs under (the shell that started it,
# whose command line may name the mark). ps carries nothing of this run: it starts with an empty environment.
run_processes() {
    env -i PATH=/usr/bin:/bin /bin/ps -axwwE -o pid=,ppid=,command= | awk -v self=$$ -v mark="$1" '
        { pid[NR] = $1; parent[$1] = $2; line[$1] = $0 }
        END {
            for (up = self; up > 1; up = parent[up]) kin[up] = 1
            for (i = 1; i <= NR; i++) { p = pid[i]; if (!(p in kin) && index(line[p], mark)) found[p] = 1 }
            for (i = 1; i <= NR; i++) {
                p = pid[i]; ofRun = 0
                if (p in kin) continue
                for (up = p; up > 1 && up != self; up = parent[up]) if (up in found) ofRun = 1
                if (up == self || !ofRun) continue
                # The command, without the environment ps appends.
                command = line[p]; sub(/^ *[0-9]+ +[0-9]+ +/, "", command); sub(/ [A-Z_][A-Z0-9_]*=.*/, "", command)
                print p " " substr(command, 1, 200)
            }
        }'
}

# Waits up to 10 s for the run's processes to end on their own (a parser follows its host within a moment), then ends
# the rest and names them. Returns 1 when any was left.
end_leftovers() {
    local mark=$1 left pids
    for _ in $(seq 1 20); do
        left=$(run_processes "$mark")
        [[ -z $left ]] && return 0
        sleep 0.5
    done
    pids=$(echo "$left" | awk '{print $1}')
    echo "LEFTOVER PROCESSES: the run left these running (ending them now):"
    echo "$left" | sed 's/^/  /'
    kill -TERM $pids 2> /dev/null
    for _ in $(seq 1 10); do
        [[ -z $(run_processes "$mark") ]] && break
        sleep 0.5
    done
    pids=$(run_processes "$mark" | awk '{print $1}')
    [[ -n $pids ]] && kill -KILL $pids 2> /dev/null
    return 1
}

if [[ ${1:-} == --leftovers ]]; then
    end_leftovers "${2:?scripts/test.sh --leftovers MARK}"
    exit
fi

source scripts/lib/scratch.sh

scratch_tmpdir vs-test
mkdir -p "$tool_scratch/home" || exit 1
# The folder's own name (vs-test.XXXXXX): processes may spell /tmp as /private/tmp.
mark=$(basename "$tool_scratch")
# Ctrl-C, or a build that fails: whatever the run started ends with it too (named, not judged).
on_exit 'end_leftovers "$mark" > /dev/null'

export HOME=$tool_scratch/home CFFIXED_USER_HOME=$tool_scratch/home VIBESWITCHER_HOME=$tool_scratch/home/.vibeswitcher
swift build && swift test "$@"
status=$?
end_leftovers "$mark" || status=1
exit $status
