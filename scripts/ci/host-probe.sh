#!/bin/bash
# scripts/ci/host-probe.sh [ROUNDS]: the host-probe nightly (.github/workflows/v2-host-probe.yml). A build (clean on a
# fresh runner), then
# `config held` of the home folder on a fresh scratch node ROUNDS times (default 300; HostProbeTests): half as it is,
# half under load (two busy loops a core). A host that dies fails the run: each dead round's wait status, stderr and
# log are printed, and its trace's addresses symbolized with llvm-symbolizer from the image base the scratch host logs
# (HostHardening.imageBaseLine). Twice on 2026-11-22 the request killed the host right after a worktree switched trees,
# never since (docs/process/v2-flaky-tests.md); this looks for it on a clean machine. Not a gate.
set -uo pipefail
cd "$(dirname "$0")/../.."

rounds=${1:-300}
half=$(( (rounds + 1) / 2 ))
out="$PWD/.build/host-probe"
rm -rf "$out"
mkdir -p "$out"
export VIBESWITCHER_HOST_PROBE_OUT="$out" VIBESWITCHER_ACCEPTANCE=0

status=0
echo "host probe: $half rounds, as it is"
VIBESWITCHER_HOST_PROBE_ROUNDS=$half bash scripts/test.sh --filter 'HostProbeTests' || status=1

cores=$(getconf _NPROCESSORS_ONLN)
loops=()
for (( i = 0; i < 2 * cores; i++ )); do
    ( while :; do :; done ) &
    loops+=($!)
done
echo "host probe: $half rounds, under load ($(( 2 * cores )) busy loops)"
VIBESWITCHER_HOST_PROBE_ROUNDS=$half bash scripts/test.sh --filter 'HostProbeTests' || status=1
kill "${loops[@]}" 2>/dev/null
wait "${loops[@]}" 2>/dev/null

shopt -s nullglob
for log in "$out"/round-*.log; do
    echo "=== $log"
    cat "$log"
    line=$(grep -m1 -o 'image base 0x[0-9a-f]* of [^ ]*' "$log")
    base=$(awk '{ print $3 }' <<< "$line")
    # The scratch node's link is gone with it: the built program it named.
    program=$(ls .build/*-linux-gnu/debug/vibeswitcher-host 2>/dev/null | head -n 1)
    if [[ -n $base && -e $program ]] && command -v llvm-symbolizer > /dev/null; then
        echo "--- symbolized against $program at $base"
        grep -oE '\[ra\] 0x[0-9a-f]+|^ *[0-9]+ +0x[0-9a-f]+' "$log" | grep -oE '0x[0-9a-f]+' \
            | xargs -r llvm-symbolizer --obj="$program" --adjust-vma="$base" --demangle
    fi
done
exit $status
