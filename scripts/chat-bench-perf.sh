#!/bin/bash
# What opening and reading a conversation costs, build against build: the default `VibeSwitcher --chat-bench` (15 s,
# resizing and scrolling like a reader) on each transcript, plain, LIVE and STACK, the builds interleaved and each run
# waiting for the machine's 1-minute load to drop under a limit. Prints per transcript and build the first tick's
# stall (opening), the worst stall after it, the largest RSS and the CPU used, as medians and maxima over the runs.
# Nothing touches the real ~/.vibeswitcher: the bench runs in a scratch home holding copies of the transcripts.
#
# scripts/chat-bench-perf.sh [-n RUNS] [-l LOAD] [-v "plain LIVE STACK"] NAME=BINARY... -- T.jsonl...
#   e.g. scripts/chat-bench-perf.sh base=/tmp/base/.build/debug/VibeSwitcher head=.build/debug/VibeSwitcher -- t1.jsonl t2.jsonl
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
source scripts/lib/bench-defaults.sh
# Each run's home is the one given below; an exported VIBESWITCHER_HOME would come before it (`VibePaths.root`).
unset VIBESWITCHER_HOME

runs=3 limit=12 variants="plain LIVE STACK"
while getopts "n:l:v:" option; do
    case $option in
        n) runs=$OPTARG ;; l) limit=$OPTARG ;; v) variants=$OPTARG ;;
        *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
builds=()
while [[ $# -gt 0 && $1 != -- ]]; do builds+=("$1"); shift; done
[[ $# -gt 1 && ${#builds[@]} -gt 0 ]] || { echo "usage: $0 [options] NAME=BINARY... -- T.jsonl..." >&2; exit 64; }
shift
# None may write the real ~/Library/Preferences/VibeSwitcher.plist (scripts/lib/bench-defaults.sh).
for build in "${builds[@]}"; do bench_defaults_in_scratch "${build#*=}" || exit 1; done

# The scratch home goes when the bench ends (Ctrl-C too): copies of the transcripts filled the disk otherwise. What
# the runs printed stays in .build/chat-bench-perf (replaced by the next run).
home=$(mktemp -d "${TMPDIR:-/tmp}/chat-bench-perf.XXXXXX")
on_exit 'rm -r "$home" < /dev/null'
trap 'exit 130' INT TERM
outputs=.build/chat-bench-perf
[[ -d $outputs ]] && rm -r "$outputs" < /dev/null
mkdir -p "$home/.claude/projects/bench" "$outputs/out"
transcripts=()
for path in "$@"; do
    name=$(basename "$path" .jsonl)
    cp -c "$path" "$home/.claude/projects/bench/$name.jsonl" 2>/dev/null || cp "$path" "$home/.claude/projects/bench/$name.jsonl"
    transcripts+=("$name")
done

for run in $(seq 1 "$runs"); do for t in "${transcripts[@]}"; do for variant in $variants; do for build in "${builds[@]}"; do
    while load=$(sysctl -n vm.loadavg | awk '{print $2}'); ! awk "BEGIN { exit !($load < $limit) }"; do sleep 5; done
    out="$outputs/out/${build%%=*}~$t~$variant~$run"
    settings=(CFFIXED_USER_HOME="$home")
    [[ $variant != plain ]] && settings+=("VIBESWITCHER_BENCH_$variant=1")
    /usr/bin/time -l env "${settings[@]}" "${build#*=}" --chat-bench "$home/.claude/projects/bench/$t.jsonl" > "$out.txt" 2> "$out.time" || true
    echo "load=$load" > "$out.load"
done; done; done; done

python3 - "$outputs/out" <<'EOF'
import collections, glob, os, re, statistics, sys
rows = collections.defaultdict(list)
for path in glob.glob(sys.argv[1] + "/*.txt"):
    build, t, variant, run = os.path.basename(path)[:-4].split("~")
    text = open(path).read()
    stalls = [float(x) for x in re.findall(r"worst stall=([\d.]+)s", text)]
    cpu = re.findall(r"cpu=([\d.]+)s", text)
    rss = re.search(r"(\d+)\s+maximum resident set size", open(path[:-4] + ".time").read())
    if len(stalls) < 2 or not cpu or not rss:
        print(f"no result: {path}")
        continue
    rows[(t, build)].append((stalls[0], max(stalls[1:]), int(rss.group(1)) / 1048576, float(cpu[-1])))
print("| transcript | build | runs | first tick stall (med / max) | worst stall after it | max RSS | CPU 15 s |")
print("|---|---|---|---|---|---|---|")
for (t, build), r in sorted(rows.items()):
    col = lambda i, f: f"{f % statistics.median(x[i] for x in r)} / {f % max(x[i] for x in r)}"
    print(f"| {t} | {build} | {len(r)} | {col(0, '%.2f')} s | {col(1, '%.2f')} s | {col(2, '%.0f')} MB | {col(3, '%.1f')} s |")
EOF
echo "outputs: $outputs/out"
