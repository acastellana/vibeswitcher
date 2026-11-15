#!/bin/bash
# scripts/ci/watchdog.sh PID AFTER: beside a CI test run (PID: the process running it), so that a run stopped by its
# timeout still names what hung. On the Mac, swift test holds back every test line until it exits, and vs-heavy's stop
# throws them away (v2 macos, 2026-11-14 and 15: 22 and 27 minutes of nothing, then the stop).
#
# Every WATCHDOG_TICK seconds (5) it looks at PID's process tree and says, timestamped, when one of its phases starts
# and ends (swift-build, swift-test, swiftpm-testing-helper, xctest, node), so the log shows where the time went. Once
# AFTER seconds have passed with PID still there, it says what is still running in the tree (ps) and the descriptors
# each holds but its mapped files (lsof: a pipe's write end held where nothing should hold it is a read that never
# ends), then sends SIGABRT to each swiftpm-testing-helper in it (WATCHDOG_STOP: other names, space-separated) and to
# nothing else: swift test sees its child end and prints the lines it held (the tests that started and never
# finished), and macOS's crash reporter writes every thread's backtrace to ~/Library/Logs/DiagnosticReports, which
# this prints (with python3, when there is one) and copies to WATCHDOG_REPORTS when that's set. It ends when PID does
# (after its report, when it is giving one), and never stops PID itself.
#
# AFTER: seconds, or "35m", "2h". Bash 3.2 (the Mac's /bin/bash): no associative arrays.
set -uo pipefail

root=${1:-} after=${2:-}
usage="usage: scripts/ci/watchdog.sh PID AFTER (seconds, or 35m, 2h)"
[[ $root =~ ^[0-9]+$ ]] || { echo "$usage" >&2; exit 2; }
if [[ $after =~ ^([0-9]+)([smh]?)$ ]]; then
    case ${BASH_REMATCH[2]} in
        m) after=$(( 10#${BASH_REMATCH[1]} * 60 )) ;;
        h) after=$(( 10#${BASH_REMATCH[1]} * 3600 )) ;;
        *) after=$(( 10#${BASH_REMATCH[1]} )) ;;
    esac
else
    echo "$usage" >&2
    exit 2
fi
tick=${WATCHDOG_TICK:-5}
stop_names=${WATCHDOG_STOP:-swiftpm-testing-helper}
phases="swift-build swift-test swiftpm-testing-helper xctest node"

say() { echo "watchdog $(date -u +%H:%M:%SZ): $*"; }

# PID's tree, PID first: "pid name" a line, the name without its folder.
tree() {
    ps -A -o pid= -o ppid= -o comm= 2>/dev/null | awk -v root="$root" '
        {
            pid = $1; parent = $2
            $1 = ""; $2 = ""; sub(/^ +/, ""); sub(/.*\//, "")
            name[pid] = $0; children[parent] = children[parent] " " pid
        }
        END {
            queue[1] = root; n = 1
            for (i = 1; i <= n; i++) {
                if (queue[i] in name) print queue[i], name[queue[i]]
                count = split(children[queue[i]], kids, " ")
                for (k = 1; k <= count; k++) queue[++n] = kids[k]
            }
        }'
}

cd "$(dirname "$0")/../.."
source scripts/lib/scratch.sh
scratch_tmpdir vs-watchdog
# What a crash report must be newer than.
touch "$tool_scratch/start"
started=$(date +%s)
known=""  # the phases running: "pid name since" a line
fired=""
say "watching pid $root; says what still runs there after $after s"
while kill -0 "$root" 2>/dev/null; do
    now=$(date +%s)
    current=$(tree)
    while read -r pid name; do
        [[ -n $pid && " $phases " == *" $name "* ]] || continue
        grep -q "^$pid " <<< "$known" && continue
        known+="$pid $name $now"$'\n'
        say "$name started (pid $pid): $(ps -o args= -p "$pid" 2>/dev/null | cut -c1-200)"
    done <<< "$current"
    still=""
    while read -r pid name since; do
        [[ -n $pid ]] || continue
        if grep -q "^$pid $name\$" <<< "$current"; then
            still+="$pid $name $since"$'\n'
        else
            say "$name ended (pid $pid) after $(( now - since )) s"
        fi
    done <<< "$known"
    known=$still

    if [[ -z $fired ]] && (( now - started >= after )); then
        fired=1
        pids=$(cut -d' ' -f1 <<< "$current" | paste -sd, -)
        say "still running after $(( now - started )) s, the tree of pid $root:"
        ps -o pid,ppid,pgid,stat,etime,time,args -p "$pids" 2>/dev/null | cut -c1-300
        if command -v lsof > /dev/null; then
            while read -r pid name; do
                say "descriptors of pid $pid ($name), mapped files left out:"
                lsof -nP -p "$pid" 2>/dev/null | awk 'NR == 1 || ($4 != "txt" && $4 != "mem")' | head -n 200
            done <<< "$current"
        else
            say "no lsof here: descriptors not listed"
        fi
        stopped=""
        while read -r pid name; do
            [[ " $stop_names " == *" $name "* ]] || continue
            say "SIGABRT to $name (pid $pid): a backtrace from the crash reporter, and swift test prints what it held"
            kill -ABRT "$pid" 2>/dev/null && stopped+=" $name"
        done <<< "$current"
        reports=$HOME/Library/Logs/DiagnosticReports
        if [[ -n $stopped && -d $reports ]]; then
            # The crash reporter takes some seconds to write it.
            for _ in $(seq 1 30); do
                found=""
                for name in $stopped; do
                    found+=$(find "$reports" -maxdepth 1 -name "$name*.ips" -newer "$tool_scratch/start" 2>/dev/null)$'\n'
                done
                (( $(grep -c . <<< "$found") >= $(wc -w <<< "$stopped") )) && break
                sleep 2
            done
            grep -q . <<< "$found" || say "no crash report in $reports"
            while IFS= read -r file; do
                [[ -n $file ]] || continue
                say "crash report $file:"
                if [[ -n ${WATCHDOG_REPORTS:-} ]]; then mkdir -p "$WATCHDOG_REPORTS" && cp "$file" "$WATCHDOG_REPORTS/"; fi
                command -v python3 > /dev/null || continue
                python3 -I - "$file" <<'EOF' || say "couldn't read it"
import json, sys
# An .ips: a line of JSON (its header), then the report, one JSON document.
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
report = json.loads(text.partition("\n")[2])
images = report.get("usedImages", [])
for index, thread in enumerate(report.get("threads", [])):
    label = thread.get("name") or thread.get("queue") or ""
    print(f"thread {index}{' (triggered)' if thread.get('triggered') else ''} {label}".rstrip())
    for frame in thread.get("frames", [])[:40]:
        at = frame.get("imageIndex", -1)
        image = images[at].get("name", "?") if 0 <= at < len(images) else "?"
        print(f"  {image}  {frame.get('symbol', hex(frame.get('imageOffset', 0)))}")
EOF
            done <<< "$found"
        fi
    fi
    sleep "$tick"
done
say "pid $root ended"
