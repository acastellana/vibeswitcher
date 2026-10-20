#!/bin/bash
# Opens conversations in `VibeSwitcher --chat-bench` the way the window does and checks that the chat settles:
# switching from conversation A to B, and B reopened and scrolled to the top, the middle and the bottom; at several
# pane widths; plain, LIVE (a working session's live line), STACK (in a stack) and WINDOW (the pane as the window
# has it); each N times, with the window's chat timer and a busy model. Once settled, each run pages back: Show
# earlier pressed PAGES times, each page left to settle (VIBESWITCHER_BENCH_EARLIER). A run fails when the content
# height still changes 3 s before its end or a page's, when the main thread gets stuck, or when a tick stalls over
# 0.25 s or the main thread works over 0.25 s on the CPU in one (over 4 × the first open's longest when the Mac's
# 1-minute load is over load_threshold: the bench prints the rule; see `ChatBench.StallRule`). A longest tick the main
# thread spent mostly waiting for a core (under half of it on the CPU) is the Mac's load, not a stall, as in
# ChatBenchTests: that run goes once more, and if that one is starved too it's recorded (status=starved) and passes;
# never when a tick worked over the limit on the CPU or no tick carried a CPU reading. Nothing touches the real
# ~/.vibeswitcher: the bench runs in a scratch home holding copies of the transcripts.
# A tick's wall time past its CPU time is the Mac's: top at 1728 on the fixture, page 2's longest tick was 0.05-0.22 s
# with at most 0.11 s of CPU at load 8-12 (2026-10-20, 24 runs), and 0.26-0.27 s with 0.15 s of CPU at load 14.5.
#
# scripts/chat-bench-settle.sh [-n RUNS] [-j JOBS] [-b BINARY] [-B REPO] [-q] [-e PAGES] [-W WORKFLOW] [-o OUTPUTS] [-w "700 900"] [-s "switch top"] [-v "plain LIVE"] A.jsonl B.jsonl
#   -B REPO: the WINDOW variant shows REPO/.vibeswitcher/board.json's team strip and open questions.
#   -q: only the window's once-a-second timer, not the busy model (VIBESWITCHER_BENCH_UPDATES).
#   -e PAGES: how many times Show earlier is pressed after settling (2; 0: not paging back).
#   -W WORKFLOW: the workflow.md whose load_threshold applies (the lead's: this checkout's .vibeswitcher/workflow.md, or
#   the one whose worktree this is; none: twice the cores).
#   -o OUTPUTS: where what the runs printed goes (.build/chat-bench-settle), replaced.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
# Each run's home is the one given below; an exported VIBESWITCHER_HOME would come before it (`VibePaths.root`).
unset VIBESWITCHER_HOME

runs=10 jobs=6 binary=.build/debug/VibeSwitcher board="" updates=1 earlier=2 workflow="" outputs=.build/chat-bench-settle
for candidate in .vibeswitcher/workflow.md ../../workflow.md; do
    [[ $candidate == ../* && $(basename "$(dirname "$PWD")") != worktrees ]] && continue
    [[ -f $candidate ]] && { workflow=$PWD/$candidate; break; }
done
widths="700 900 1200 1728" scenarios="switch top middle bottom" variants="plain LIVE STACK WINDOW"
while getopts "n:j:b:B:qe:W:o:w:s:v:" option; do
    case $option in
        n) runs=$OPTARG ;; j) jobs=$OPTARG ;; b) binary=$OPTARG ;; B) board=$OPTARG ;; q) updates=0 ;; e) earlier=$OPTARG ;; W) workflow=$OPTARG ;;
        o) outputs=$OPTARG ;;
        w) widths=$OPTARG ;; s) scenarios=$OPTARG ;; v) variants=$OPTARG ;;
        *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -eq 2 ]] || { echo "usage: $0 [options] A.jsonl B.jsonl" >&2; exit 64; }

# The scratch home goes when the bench ends (Ctrl-C too): copies of the transcripts filled the disk otherwise. What
# the runs printed stays in $outputs (replaced by the next run).
home=$(mktemp -d "${TMPDIR:-/tmp}/chat-bench-settle.XXXXXX")
on_exit 'rm -r "$home" < /dev/null'
trap 'exit 130' INT TERM
[[ -d $outputs ]] && rm -r "$outputs" < /dev/null
mkdir -p "$home/.claude/projects/bench" "$outputs/out"
cp -c "$1" "$home/.claude/projects/bench/a.jsonl" 2>/dev/null || cp "$1" "$home/.claude/projects/bench/a.jsonl"
cp -c "$2" "$home/.claude/projects/bench/b.jsonl" 2>/dev/null || cp "$2" "$home/.claude/projects/bench/b.jsonl"
a="$home/.claude/projects/bench/a.jsonl" b="$home/.claude/projects/bench/b.jsonl"

# Whether the run in $1 failed on a tick its main thread spent mostly waiting for a core, and on nothing else: not a tick
# it worked through over the limit on the CPU, which the longest, starved, mustn't hide, nor a run no tick of which
# carried a CPU reading.
starved() {
    local line wall cpu
    grep -qE "^FAIL: (a tick worked |no tick carried a CPU reading)" "$1" && return 1
    line=$(grep -oE "FAIL: a tick stalled [0-9.]+s \(.*, [0-9.]+s of it on the CPU\)" "$1" | tail -1)
    [[ -n $line ]] || return 1
    wall=$(sed -E 's/FAIL: a tick stalled ([0-9.]+)s.*/\1/' <<< "$line")
    cpu=$(sed -E 's/.*, ([0-9.]+)s of it on the CPU\)/\1/' <<< "$line")
    awk -v wall="$wall" -v cpu="$cpu" 'BEGIN { exit !(cpu < wall / 2) }'
}

one() {
    local scenario=$1 width=$2 variant=$3 run=$4
    local out="$outputs/out/$scenario-$width-$variant-$run.txt"
    local settings=(CFFIXED_USER_HOME="$home" VIBESWITCHER_BENCH_SECONDS=10 VIBESWITCHER_BENCH_SIZE="${width}x909"
                    VIBESWITCHER_BENCH_TICKS=1 VIBESWITCHER_BENCH_UPDATES=$updates VIBESWITCHER_BENCH_EARLIER="$earlier")
    [[ -n $workflow ]] && settings+=(VIBESWITCHER_BENCH_WORKFLOW="$workflow")
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
    if [[ $status -eq 4 ]] && starved "$out"; then
        mv "$out" "$out.starved"
        status=0
        env "${settings[@]}" "$binary" --chat-bench "$path" > "$out" 2>&1 || status=$?
        [[ $status -eq 4 ]] && starved "$out" && status=starved
    fi
    local verdict
    verdict=$(grep -E '^(settled|FAIL|HANG)' "$out" | tail -1)
    printf '%-7s %5s %-7s #%-2s status=%s %s\n' "$scenario" "$width" "$variant" "$run" "$status" "${verdict:-no verdict}"
}
export -f one starved
export home outputs a b binary board updates earlier workflow

for scenario in $scenarios; do for width in $widths; do for variant in $variants; do for run in $(seq 1 "$runs"); do
    echo "$scenario $width $variant $run"
done; done; done; done | xargs -P "$jobs" -L 1 bash -c 'one "$@"' _ | tee "$outputs/results.txt"

echo
echo "per case: passing runs, the content heights the runs settled at, and over the runs the longest tick and the most"
echo "CPU time the main thread spent in one (the first open's and each page's)"
# As the bench read it: workflow.md's load_threshold, or twice the cores when it has none.
echo "$(grep -ohE "load_threshold [0-9.]+ \([^)]*\)" "$outputs"/out/*.txt 2>/dev/null | sort | uniq -c | sort -rn | head -1 | sed -E 's/^ *[0-9]+ //')${workflow:+, workflow.md: $workflow}"
failed=0
for scenario in $scenarios; do for width in $widths; do for variant in $variants; do
    lines=$(grep -E "^$scenario +$width $variant " "$outputs/results.txt" || true)
    passed=$(grep -cE "status=(0 settled|starved)" <<< "$lines" || true)
    heights=$(grep -oE "settled.* height=[0-9]+" <<< "$lines" | grep -oE "[0-9]+$" | sort -u | tr '\n' ' ' || true)
    files=("$outputs/out/$scenario-$width-$variant-"*.txt)
    longest=$(grep -ohE "longest tick=[0-9.]+s" "${files[@]}" 2>/dev/null | grep -oE "[0-9.]+" | sort -n | tail -1) || true
    cpu=$(grep -ohE "most CPU in a tick [0-9.]+s|a tick worked [0-9.]+s" "${files[@]}" 2>/dev/null | grep -oE "[0-9.]+" | sort -n | tail -1) || true
    printf '%-7s %5s %-7s %2s/%s  %s longest tick %ss, most CPU %ss\n' "$scenario" "$width" "$variant" "$passed" "$runs" "$heights" \
        "${longest:--}" "${cpu:--}"
    [[ $passed -eq $runs ]] || failed=1
done; done; done
echo "outputs: $outputs/out"
exit $failed
