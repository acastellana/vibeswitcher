#!/bin/bash
# The sandbox's soak as a bench: a sandboxed copy of the app (scripts/sandbox-app.sh: its own home, defaults and session
# host, fake sessions only, never the user's app or sessions) runs `soak` for HOURS simulated hours of a working day,
# CYCLES cycles each (a cycle every 3 s: a fake Claude started and its chat shown, a reply streamed, a dictation, the
# lead's Team tab and board checkpoints, an accessibility walk, a wallet request filed and sent or discarded, the
# wallet desk's clock and refreshes moved the cycle's share of the hour, the oldest fake ended). It prints the soak's
# log: each simulated hour's least footprint, malloc in use and the debug counters, a census of what grew, and
# `RESULT soak-simulated-hour-growth-mb` (a line through each simulated hour's least footprint after the first).
#
# scripts/sandbox-soak-bench.sh [--binary PATH] [--dir DIR] [--without LIST] [--max-minutes M] [--bound] HOURS [CYCLES]
#   --binary: the build (default: scripts/sandbox-app.sh builds this checkout's).  --dir: the sandbox's folder
#   (default .build/sandbox-soak).  --max-minutes: real minutes at most (default 15): the soak stops then with the
#   simulated hours done so far.  CYCLES: cycles in a simulated hour (default 20).  --bound: prints the seconds a run
#   with these options takes at most, its build aside (the soak's minutes and each of its waits run out), and runs
#   nothing: SandboxSoakBenchTests guards the run past it. The soak takes about all its minutes (5 simulated hours of 20
#   cycles: ~14.3 of 15 on 2026-11-19, ~7 cycles a minute), so a guard under the soak's own minutes ends a healthy run
#   ("the soak bench hung", the app's first daily run).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

binary=() dir=.build/sandbox-soak without="" max_minutes=15 bound=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --binary) binary=(--binary "$2"); shift 2 ;;
        --dir) dir=$2; shift 2 ;;
        --without) without=$2; shift 2 ;;
        --max-minutes) max_minutes=$2; shift 2 ;;
        --bound) bound=1; shift ;;
        --*) echo "unknown option $1"; exit 64 ;;
        *) break ;;
    esac
done
hours=${1:-}
cycles=${2:-20}
[[ $hours =~ ^[0-9]+$ && $hours -ge 2 && $cycles =~ ^[0-9]+$ && $cycles -ge 1 ]] ||
    { echo "usage: scripts/sandbox-soak-bench.sh [--binary PATH] [--dir DIR] [--without LIST] [--max-minutes M] [--bound] HOURS(2 or more) [CYCLES]"; exit 64; }

# Room for slow cycles on a loaded Mac: 15 s a cycle at most, and the soak's own minutes as an upper bound.
minutes=$(( (hours * cycles * 15 + 59) / 60 + 1 ))
[[ $max_minutes =~ ^[0-9]+$ && $max_minutes -ge 1 ]] || { echo "--max-minutes $max_minutes: a whole number of minutes"; exit 64; }
((minutes > max_minutes)) && minutes=$max_minutes
# Each wait below, at most: the sandbox's start and each command's answer (sandbox-app.sh's --wait), the soak's minutes
# and 2 more, the soak's end after `soak stop`, and the sandbox's quit (its answer, then 15 s to end).
wait_for=120 slack=120 done_wait=60
if [[ -n $bound ]]; then
    echo $(( wait_for + wait_for + minutes * 60 + slack + 2 + wait_for + done_wait + wait_for + 15 ))
    exit 0
fi
sandbox=(bash scripts/sandbox-app.sh --dir "$dir" --wait "$wait_for")
on_exit "${sandbox[*]} quit >/dev/null 2>&1 < /dev/null"
"${sandbox[@]}" ${binary[@]+"${binary[@]}"} --minutes $((minutes + 5)) run >/dev/null
"${sandbox[@]}" soak "$minutes" every 3 hour "$cycles" ${without:+without "$without"} >/dev/null
state=$(cat "$dir/state")
log=$state/soak.log
# Done after HOURS simulated hours (its last census taken), or when the soak's minutes ran out.
deadline=$((SECONDS + minutes * 60 + slack))
until grep -q "simulated hour *$hours " "$log" 2>/dev/null && [[ $(grep -c "grew since" "$log") -ge $((hours - 1)) ]]; do
    if grep -q "soak: done" "$log" 2>/dev/null || ((SECONDS > deadline)); then break; fi
    sleep 2
done
"${sandbox[@]}" soak stop >/dev/null || true
for _ in $(seq 1 "$done_wait"); do grep -q "soak: done" "$log" && break; sleep 1; done
cat "$log"
grep -q "^.*RESULT soak-simulated-hour-growth-mb" "$log"
