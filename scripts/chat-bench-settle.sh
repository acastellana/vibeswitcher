#!/bin/bash
# Opens conversations in `VibeSwitcher --chat-bench` the way the window does and checks that the chat settles:
# switching from conversation A to B, and B reopened and scrolled to the top, the middle and the bottom; at several
# pane widths; plain, LIVE (a working session's live line), STACK (in a stack) and WINDOW (the pane as the window
# has it); each N times, with the window's chat timer and a busy model. A run fails when the content height still
# changes 3 s before its end, or the main thread gets stuck. Nothing touches the real ~/.vibeswitcher: the bench
# runs in a scratch home holding copies of the transcripts.
#
# scripts/chat-bench-settle.sh [-n RUNS] [-j JOBS] [-b BINARY] [-B REPO] [-q] [-w "700 900"] [-s "switch top"] [-v "plain LIVE"] A.jsonl B.jsonl
#   -B REPO: the WINDOW variant shows REPO/.vibeswitcher/board.json's team strip and open questions.
#   -q: only the window's once-a-second timer, not the busy model (VIBESWITCHER_BENCH_UPDATES).
set -euo pipefail
cd "$(dirname "$0")/.."

runs=10 jobs=6 binary=.build/debug/VibeSwitcher board="" updates=1
widths="700 900 1200 1728" scenarios="switch top middle bottom" variants="plain LIVE STACK WINDOW"
while getopts "n:j:b:B:qw:s:v:" option; do
    case $option in
        n) runs=$OPTARG ;; j) jobs=$OPTARG ;; b) binary=$OPTARG ;; B) board=$OPTARG ;; q) updates=0 ;;
        w) widths=$OPTARG ;; s) scenarios=$OPTARG ;; v) variants=$OPTARG ;;
        *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -eq 2 ]] || { echo "usage: $0 [options] A.jsonl B.jsonl" >&2; exit 64; }

# The scratch home goes when the bench ends (Ctrl-C too): copies of the transcripts filled the disk otherwise. What
# the runs printed stays in .build/chat-bench-settle (replaced by the next run).
home=$(mktemp -d "${TMPDIR:-/tmp}/chat-bench-settle.XXXXXX")
trap 'rm -r "$home" < /dev/null' EXIT
trap 'exit 130' INT TERM
outputs=.build/chat-bench-settle
[[ -d $outputs ]] && rm -r "$outputs" < /dev/null
mkdir -p "$home/.claude/projects/bench" "$outputs/out"
cp -c "$1" "$home/.claude/projects/bench/a.jsonl" 2>/dev/null || cp "$1" "$home/.claude/projects/bench/a.jsonl"
cp -c "$2" "$home/.claude/projects/bench/b.jsonl" 2>/dev/null || cp "$2" "$home/.claude/projects/bench/b.jsonl"
a="$home/.claude/projects/bench/a.jsonl" b="$home/.claude/projects/bench/b.jsonl"

one() {
    local scenario=$1 width=$2 variant=$3 run=$4
    local out="$outputs/out/$scenario-$width-$variant-$run.txt"
    local settings=(CFFIXED_USER_HOME="$home" VIBESWITCHER_BENCH_SECONDS=10 VIBESWITCHER_BENCH_SIZE="${width}x909"
                    VIBESWITCHER_BENCH_TICKS=1 VIBESWITCHER_BENCH_UPDATES=$updates)
    [[ -n ${VIBESWITCHER_BENCH_FONT:-} ]] && settings+=(VIBESWITCHER_BENCH_FONT="$VIBESWITCHER_BENCH_FONT")
    [[ $variant != plain ]] && settings+=("VIBESWITCHER_BENCH_$variant=1")
    [[ $variant == WINDOW && -n $board ]] && settings+=(VIBESWITCHER_BENCH_BOARD="$board")
    local path=$b
    if [[ $scenario == switch ]]; then
        settings+=(VIBESWITCHER_BENCH_SWITCH="$b")
        path=$a
    else
        settings+=(VIBESWITCHER_BENCH_OPEN="$scenario" VIBESWITCHER_BENCH_AT="$scenario")
    fi
    local status=0
    env "${settings[@]}" "$binary" --chat-bench "$path" > "$out" 2>&1 || status=$?
    local verdict
    verdict=$(grep -E '^(settled|FAIL|HANG)' "$out" | tail -1)
    printf '%-7s %5s %-7s #%-2s status=%s %s\n' "$scenario" "$width" "$variant" "$run" "$status" "${verdict:-no verdict}"
}
export -f one
export home outputs a b binary board updates

for scenario in $scenarios; do for width in $widths; do for variant in $variants; do for run in $(seq 1 "$runs"); do
    echo "$scenario $width $variant $run"
done; done; done; done | xargs -P "$jobs" -L 1 bash -c 'one "$@"' _ | tee "$outputs/results.txt"

echo
echo "per case: passing runs, and the content heights the runs settled at"
failed=0
for scenario in $scenarios; do for width in $widths; do for variant in $variants; do
    lines=$(grep -E "^$scenario +$width $variant " "$outputs/results.txt" || true)
    passed=$(grep -c "status=0 settled" <<< "$lines" || true)
    heights=$(grep -oE "settled.* height=[0-9]+" <<< "$lines" | grep -oE "[0-9]+$" | sort -u | tr '\n' ' ' || true)
    printf '%-7s %5s %-7s %2s/%s  %s\n' "$scenario" "$width" "$variant" "$passed" "$runs" "$heights"
    [[ $passed -eq $runs ]] || failed=1
done; done; done
echo "outputs: $outputs/out"
exit $failed
