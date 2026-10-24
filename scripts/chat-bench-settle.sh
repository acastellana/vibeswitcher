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
# The runs start staggered: one at a time, STAGGER seconds after the last one started and half that after it opened
# its conversation (its "clock …: opening" line; at most 10 s), so the jobs don't open or page back in the same instant.
# Started together, a whole -j 6 batch reached page 2 at once and starved six at a time (2026-10-20: 37 of 768 runs,
# docs/eval/chat-bench-settle-2026-10-20.md). Each starved attempt is recorded in OUTPUTS/starved.txt with why the
# main thread was off the CPU: its tick's wall and CPU time, the 1-minute load and the threads runnable at the tick's
# end (sampled every second into OUTPUTS/load.txt), and what the other runs were doing then; a run that failed on a
# stalled tick is recorded there too, the same way.
#
# scripts/chat-bench-settle.sh [-n RUNS] [-j JOBS] [-S STAGGER] [-b BINARY] [-B REPO] [-q] [-e PAGES] [-W WORKFLOW] [-o OUTPUTS] [-w "700 900"] [-s "switch top"] [-v "plain LIVE"] A.jsonl B.jsonl
#   -S STAGGER: the seconds between two runs' starts (2; 0: started as the jobs free up, not waiting for an opening).
#   -B REPO: the WINDOW variant shows REPO/.vibeswitcher/board.json's team strip and open questions.
#   -q: only the window's once-a-second timer, not the busy model (VIBESWITCHER_BENCH_UPDATES).
#   -e PAGES: how many times Show earlier is pressed after settling (2; 0: not paging back).
#   -L LIMITS: the Mac-wide limits whose load_threshold applies (Settings › Project lead's: ~/.vibeswitcher/mac-limits.json;
#   none: twice the cores).
#   -o OUTPUTS: where what the runs printed goes (.build/chat-bench-settle), replaced.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
# Each run's home is the one given below; an exported VIBESWITCHER_HOME would come before it (`VibePaths.root`).
unset VIBESWITCHER_HOME

runs=10 jobs=6 stagger=2 binary=.build/debug/VibeSwitcher board="" updates=1 earlier=2 limits="" outputs=.build/chat-bench-settle
[[ -f $HOME/.vibeswitcher/mac-limits.json ]] && limits=$HOME/.vibeswitcher/mac-limits.json
widths="700 900 1200 1728" scenarios="switch top middle bottom" variants="plain LIVE STACK WINDOW"
while getopts "n:j:S:b:B:qe:L:o:w:s:v:" option; do
    case $option in
        n) runs=$OPTARG ;; j) jobs=$OPTARG ;; S) stagger=$OPTARG ;; b) binary=$OPTARG ;; B) board=$OPTARG ;; q) updates=0 ;; e) earlier=$OPTARG ;; L) limits=$OPTARG ;;
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

# Every second until the script ends: the wall clock, the 1-minute load and the threads runnable (running or waiting
# for a core: the run queue with what's on the cores; ps's own one not counted).
/usr/bin/perl -MTime::HiRes=time,sleep -e '$| = 1; while (1) {
    my $load = (split " ", `sysctl -n vm.loadavg`)[1];
    my @threads = `ps -A -M -o state=`;
    my $runnable = grep { (split)[-1] =~ /^R/ } @threads[1 .. $#threads];
    printf "%.2f %s %d\n", time, $load, $runnable > 0 ? $runnable - 1 : 0;
    sleep 1 - (time - int time) }' > "$outputs/load.txt" &
sampler=$!
on_exit 'kill "$sampler" 2> /dev/null'

clock() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }

# Waits for this run's turn to start (see the top): $stagger seconds after the last start, and half that after that run
# opened or ended (at most 10 s after its start), so a slow launch doesn't put two openings together. Then it's the last
# start, and prints its clock (the run's launching). One run at a time holds $outputs/gate.lock.
gate() {
    local out=$1 last previous started
    [[ $stagger == 0 ]] && { clock; return; }
    until mkdir "$outputs/gate.lock" 2> /dev/null; do sleep 0.05; done
    if read -r last previous 2> /dev/null < "$outputs/gate"; then
        /usr/bin/perl -MTime::HiRes=time,sleep -e '
            my ($last, $previous, $stagger) = @ARGV;
            # When the previous run opened (or ended, not opening), undef until then.
            sub opened {
                open(my $file, "<", $previous) or open($file, "<", "$previous.starved") or return undef;
                for (<$file>) { return $1 if /^  clock ([0-9.]+): (opening|done|exited)$/ }
                undef
            }
            my $opened;
            sleep 0.05 until time >= $last + $stagger && (defined($opened //= opened()) && time >= $opened + $stagger / 2 || time >= $last + 10)' \
            "$last" "$previous" "$stagger"
    fi
    started=$(clock)
    echo "$started $out" > "$outputs/gate"
    rmdir "$outputs/gate.lock"
    echo "$started"
}

# The record of the attempt in $1 (scenario/width/variant #run, and which attempt in $2) that $3 (starved, or stalled:
# failed) on its longest tick: the tick, the load and the threads runnable at its end, and the other runs' phases then
# (launching, opening, page N: busy; settled or done: not).
why() {
    local out=$1 attempt=$2 verb=$3 line wall place cpu end
    line=$(grep -oE "FAIL: a tick stalled [0-9.]+s \(.*, [0-9.]+s of it on the CPU\)" "$out" | tail -1)
    wall=$(sed -E 's/FAIL: a tick stalled ([0-9.]+)s.*/\1/' <<< "$line")
    place=$(sed -E 's/FAIL: a tick stalled [0-9.]+s \((t=[0-9]+s, [^,]+),.*/\1/' <<< "$line")
    cpu=$(sed -E 's/.*, ([0-9.]+)s of it on the CPU\)/\1/' <<< "$line")
    end=$(grep -oE "^  clock [0-9.]+: the longest tick's end" "$out" | grep -oE "[0-9]+\.[0-9]+" | tail -1)
    /usr/bin/perl -MPOSIX=strftime -e '
        my ($label, $verb, $out, $wall, $place, $cpu, $end, $loads, @others) = @ARGV;
        my ($t, $phase) = $place =~ /^t=(\d+)s, (.+)$/;
        my $text = "$label $verb on " . ($phase eq "opening" ? "the opening" : $phase) . " at t=$t s";
        unless (length $end) { print "$text: $wall s with $cpu s CPU, the tick'"'"'s clock unknown\n"; exit }
        $text .= sprintf " (%s.%02d)", strftime("%H:%M:%S", localtime $end), ($end - int $end) * 100;
        my ($load, $runnable, $near);
        open(my $samples, "<", $loads);
        while (<$samples>) {
            my ($at, $l, $r) = split;
            ($near, $load, $runnable) = (abs($at - $end), $l, $r) if !defined $near || abs($at - $end) < $near;
        }
        my (%busy, $idle);
        for my $other (@others) {
            next if $other eq $out;
            open(my $file, "<", $other) or next;
            # Its latest phase begun by then (the longest tick end is printed late, with an earlier clock).
            my ($now, $since);
            for (<$file>) {
                next unless /^  clock ([0-9.]+): (.+)$/ && $1 <= $end && $2 !~ /longest tick/;
                ($since, $now) = ($1, $2) if !defined $since || $1 >= $since;
            }
            next unless defined $now;
            if ($now =~ /^(launching|opening|page \d+)$/) { $busy{$now}++ } elsif ($now !~ /^(done|exited)$/) { $idle++ }
        }
        my $count = 0; $count += $_ for values %busy;
        my $phases = join ", ", map { "$_ ×$busy{$_}" } sort { $busy{$b} <=> $busy{$a} || $a cmp $b } keys %busy;
        printf "%s: %s s with %s s CPU, at load %s, %s threads runnable; %d other run%s opening or paging%s, %d settled\n",
            $text, $wall, $cpu, $load // "unknown", $runnable // "unknown", $count, $count == 1 ? "" : "s",
            $phases ? " ($phases)" : "", $idle // 0' "$attempt" "$verb" "$out" "$wall" "$place" "$cpu" "$end" "$outputs/load.txt" \
        "$outputs"/out/*.txt "$outputs"/out/*.starved
}

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
    [[ -n $limits ]] && settings+=(VIBESWITCHER_BENCH_LIMITS="$limits")
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
    local status=0 label="$scenario/$width/$variant #$run"
    echo "  clock $(gate "$out"): launching" > "$out"
    env "${settings[@]}" "$binary" --chat-bench "$path" >> "$out" 2>&1 || status=$?
    echo "  clock $(clock): exited" >> "$out"
    if [[ $status -eq 4 ]] && starved "$out"; then
        mv "$out" "$out.starved"
        why "$out.starved" "$label, first attempt," starved >> "$outputs/starved.txt"
        status=0
        echo "  clock $(gate "$out"): launching" > "$out"
        env "${settings[@]}" "$binary" --chat-bench "$path" >> "$out" 2>&1 || status=$?
        echo "  clock $(clock): exited" >> "$out"
        [[ $status -eq 4 ]] && starved "$out" && status=starved && why "$out" "$label, second attempt too (recorded)," starved >> "$outputs/starved.txt"
    fi
    # A stall that failed the run, beside the starved ones and told apart by the same fields.
    [[ $status == 4 ]] && grep -q "^FAIL: a tick stalled " "$out" && why "$out" "$label, failed," stalled >> "$outputs/starved.txt"
    local verdict opened
    verdict=$(grep -E '^(settled|FAIL|HANG)' "$out" | tail -1)
    # When it opened its conversation (the bench's first beat), to the hundredth of a second.
    opened=$(grep -oE "^  clock [0-9.]+: opening$" "$out" | grep -oE "[0-9]+\.[0-9]+" | head -1 \
        | /usr/bin/perl -MPOSIX=strftime -ne 'chomp; printf "%s.%02d", strftime("%H:%M:%S", localtime $_), ($_ - int $_) * 100' || true)
    printf '%-7s %5s %-7s #%-2s open at %-11s status=%s %s\n' "$scenario" "$width" "$variant" "$run" "${opened:--}" "$status" "${verdict:-no verdict}"
}
export -f one starved gate why clock
export home outputs a b binary board updates earlier limits stagger

for scenario in $scenarios; do for width in $widths; do for variant in $variants; do for run in $(seq 1 "$runs"); do
    echo "$scenario $width $variant $run"
done; done; done; done | xargs -P "$jobs" -L 1 bash -c 'one "$@"' _ | tee "$outputs/results.txt"

echo
echo "per case: passing runs, the content heights the runs settled at, and over the runs the longest tick and the most"
echo "CPU time the main thread spent in one (the first open's and each page's)"
# As the bench read it: the Mac-wide load_threshold, or twice the cores when none is set.
echo "$(grep -ohE "load_threshold [0-9.]+ \([^)]*\)" "$outputs"/out/*.txt 2>/dev/null | sort | uniq -c | sort -rn | head -1 | sed -E 's/^ *[0-9]+ //')${limits:+, limits: $limits}"
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
# How close the runs' openings came, every attempt's: the stagger's doing.
grep -ohE "^  clock [0-9.]+: opening$" "$outputs"/out/* 2> /dev/null | sed -E 's/^  clock ([0-9.]+).*/\1/' | sort -n \
    | awk 'NR > 1 && (gap == "" || $1 - last < gap) { gap = $1 - last } { last = $1 } END {
        if (NR > 1) printf "openings: %d, the closest two %.2f s apart (stagger %s s)\n", NR, gap, stagger }' stagger="$stagger" || true
starved_runs=$(grep -c "first attempt," "$outputs/starved.txt" 2> /dev/null || true)
recorded=$(grep -c "second attempt too" "$outputs/starved.txt" 2> /dev/null || true)
failures=$(grep -c ", failed," "$outputs/starved.txt" 2> /dev/null || true)
echo "starved: ${starved_runs:-0} first attempts run again, ${recorded:-0} recorded starved (status=starved); ${failures:-0} failed on a stalled tick"
[[ -s $outputs/starved.txt ]] && sort "$outputs/starved.txt" | sed 's/^/  /'
echo "outputs: $outputs/out"
exit $failed
