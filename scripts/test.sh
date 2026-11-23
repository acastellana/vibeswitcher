#!/bin/bash
# `swift build && swift test "$@"` on a fresh scratch home, so nothing a test writes reaches your ~/.vibeswitcher,
# ~/.claude or login Keychain. HOME, CFFIXED_USER_HOME (what NSHomeDirectory() follows; HOME alone doesn't move it),
# VIBESWITCHER_HOME and TMPDIR all point into a folder this creates under /tmp and removes when it exits, Ctrl-C too
# (scripts/lib/scratch.sh). The run's umask is 022, and its test processes (swift's and node's) carry none of a team
# session's variables, whatever the caller's are (scripts/lib/test-environment.sh). In a worktree the lead made, both build against the worktrees' shared cache of the SDK's
# modules (scripts/lib/module-cache.sh); the main checkout and merge's own run build as ever.
# A plain `swift test` on your own home refuses to start (see `VibePaths.testRefusal`).
#
# Then no process of the run may be left: a scratch session host, its sessions' parsers (launcher-* --parse-session)
# or programs, a bench's app. Each has the run's scratch folder in its environment (HOME, TMPDIR) or its arguments,
# and nothing else on the Mac has. One still alive 10 s after the tests is ended (SIGTERM, then SIGKILL) and named,
# and the run fails. On 2026-10-20 hosts from a run a day before still ran, one of them a test's counter loop (8
# CPU-minutes so far): a host runs in a process group of its own and outlives a runner killed with its group.
#
# Nor may the run add a preference file under a test's name to the real ~/Library/Preferences, which cfprefsd writes
# whatever the scratch home says, or change VibeSwitcher.plist there, the unbundled build's own defaults
# (`check_preferences` below): the run fails, naming them. Only for a file this run made: that folder is every run's,
# and up to 3 suites run at once, so a file counts when a test process of this run opened a suite of that name (its
# ledger, Tests/VibeCoreTests/PreferenceLedger.swift). One that appeared or changed and isn't in it is named, and doesn't
# fail the run.
#
# swift build and swift test, --perf's too, run under vs-heavy (Resources/bin/vs-heavy, the Mac-wide lock for heavy
# work that every project's sessions have on PATH): while another run holds it (another worker's suite in any project,
# a build-app.sh, a merge's tests), this one waits, saying for whom. The web tests and the leftover check run after
# it's let go. Both build on the width vs-heavy gives the run (the cores free when it starts, at least the slot's share),
# `-j $VS_HEAVY_CORES` (scripts/lib/swift-jobs.sh).
#
# The phone's web tests run after swift test, in the same scratch home and TMPDIR: each Tests/Web/*.test.mjs with
# node, a failing one named, then one line saying how many passed; then the node's web client's, WebApp/tests/*.test.mjs. Without node on PATH the run stops before the
# build, naming it: PhoneWebTests (swift test) skips them without node, and Web/ changes had been checked only by hand.
#
# Inside Codex's sandbox (a Codex worker's commands: CODEX_SANDBOX is set) it runs the same, with no flag to give:
# SwiftPM's own sandbox is left out (`heavy_swift` passes --disable-sandbox: macOS refuses a sandbox inside Codex's), a
# new worktree's dependencies come from the main checkout's .build, there being no network to fetch them
# (`swiftpm_offline_dependencies`), and the leftover check lists processes through libproc where /bin/ps, setuid, can't
# start (scripts/lib/processes.sh).
#
# The default run is correctness only: its result doesn't depend on how busy the Mac is, so a merge's run doesn't fail
# because other sessions load it. The benches, tests judged by wall-clock time or memory (`perf_tests` below, each
# tagged `.perf` and skipped unless VIBESWITCHER_PERF=1), run alone in `--perf`: for a task about speed or memory, and
# before an install, on a calm Mac (over its load threshold a bench prints its numbers and doesn't judge them).
#
# scripts/test.sh [swift test options], e.g. scripts/test.sh --filter HomeIsolationTests
# scripts/test.sh --retry-failed [swift test options]: the default run, but when swift test fails on a few tests alone,
#   only those run once more in a fresh run, and pass the Swift tests when they pass, each named on a line of its own,
#   "flaky (passed on retry): Module.Suite/name()" (`swift_tests_retrying_failed`, below; TestScriptRetryTests).
#   For a merge's and an audit's full run, where one load-sensitive test failing would fail every merge.
# scripts/test.sh --perf [swift test options]: only the benches (no web tests), on a scratch home as above.
# scripts/test.sh --tsan [swift test options]: the Swift tests (no web tests) built with the thread sanitizer, in their
#   own build folder (.build/tsan, so the usual build stays), on a scratch home as above. Every process of the run, the
#   scratch hosts and servers the tests start too, writes each race it sees to $VS_TSAN_REPORTS (default .build/tsan-reports)
#   as tsan.<pid>; the run fails when there is one, naming each report's first frames (the nightly v2-tsan workflow).
# scripts/test.sh --width: only the width Swift Testing would get here (`slot_width`, below; TestScriptWidthTests).
# scripts/test.sh --leftovers MARK: only the check, for the processes whose environment or arguments hold MARK
#   (LeftoverCheckTests); exit 1 when it ended any.
# scripts/test.sh --web DIR: only the web tests, DIR/*.test.mjs (DIR from the repository's root, or absolute), on a
#   scratch home as above (TestScriptWebTests).
# scripts/test.sh --preferences DIR -- COMMAND…: only the preferences check, on DIR instead of the real
#   ~/Library/Preferences, around COMMAND (PreferencesCheckTests).
set -uo pipefail
cd "$(dirname "$0")/.."
# Whoever started this script (a merge's and an audit's run come from the lead's tool server, with its umask and
# environment): the umask from here on, and none of a team session's variables in what runs the tests, below
# (`clean_test_environment`: it says what they cost, and why this script and its vs-heavy keep the session's marker).
source scripts/lib/test-environment.sh
known_umask

# --retry-failed first, then the default run's swift test options: never with another mode (the benches judge time, the
# others run no Swift test).
retry_failed=""
if [[ ${1:-} == --retry-failed ]]; then
    shift
    case ${1:-} in
        --width | --leftovers | --web | --preferences | --perf | --retry-failed)
            echo "scripts/test.sh: --retry-failed is for the default run (swift test's options after it), not with $1. Nothing ran."
            exit 2
            ;;
    esac
    retry_failed=1
fi

# The live processes holding $1 in their environment or arguments, and every process under one of them (the programs a
# scratch host runs: ps shows the environment of the app's own binaries, not of Apple's /bin/sh), as "pid command".
# Never this script, a process it runs (the awk below, its subshells) or one it runs under (the shell that started it,
# whose command line may name the mark). ps carries nothing of this run: it starts with an empty environment. Inside
# Codex's sandbox, where /bin/ps can't start, the list comes from libproc instead (`processes`, scripts/lib/processes.sh):
# the processes of the sandbox, which are the ones this run started.
run_processes() {
    processes | awk -v self=$$ -v mark="$1" '
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
                command = line[p]; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +/, "", command); sub(/ [A-Z_][A-Z0-9_]*=.*/, "", command)
                print p " " substr(command, 1, 200)
            }
        }'
}

# Waits up to 10 s for the run's processes to end on their own (a parser follows its host within a moment), then ends
# the rest and names them. Returns 1 when any was left. Where no process can be listed at all (neither ps nor libproc
# answers), it says so in one line and passes: the check can't be made, which isn't the tests' failure.
end_leftovers() {
    local mark=$1 left pids
    if ! processes > /dev/null; then
        echo "leftover check: skipped, no process could be listed here (/bin/ps and libproc both refused)"
        return 0
    fi
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

# Each $1/*.test.mjs with node, its output as it goes, a failing one named; then one line: how many passed. Returns 1
# when any failed, or when there were none.
# $1: the folder; any further arguments: files in it not run here, each with its reason after a colon
# ("library-injection.test.mjs:why"), said as it is skipped.
run_web_tests() {
    local dir=$1 file passed=0 total=0 failed="" skip skipped
    shift
    for file in "$dir"/*.test.mjs; do
        [[ -f $file ]] || continue
        skipped=""
        for skip in "$@"; do
            [[ ${file##*/} == "${skip%%:*}" ]] && skipped=${skip#*:}
        done
        if [[ -n $skipped ]]; then
            echo "web test skipped: $file: $skipped"
            continue
        fi
        total=$((total + 1))
        # In a subshell: the variables go from node's environment, not from this script's.
        if (clean_test_environment; node "$file"); then
            passed=$((passed + 1))
        else
            echo "WEB TEST FAILED: $file (exit $?)"
            failed="$failed $file"
        fi
    done
    if (( total == 0 )); then
        echo "web tests: none in $dir (*.test.mjs)"
        return 1
    fi
    echo "web tests: $passed of $total passed${failed:+; failed:$failed}"
    [[ -z $failed ]]
}

# The benches, as `swift test --filter` patterns: the tests tagged `.perf` (Tag.perf in
# Tests/VibeSwitcherTests/TestSupport.swift and Tests/VibeCoreTests/PerfTag.swift), no more and no fewer (PerfRunTests checks).
perf_tests=(
    AppHealthTests/readingABigSampleCostsMillisecondsOfCPU
    ChatBenchTests/theChatSettlesWithoutAStall
    ChatBenchTests/aReopenSettlesAtTheFirstOpensHeight
    ChatBenchSettleScriptTests
    FootprintBenchTests/theWindowClosedIsUnder150MBAndChurnGrowsItAtMost10Percent
    PowerBenchTests/idleUnder1PercentAndLeadWorkUnder3
    BoardBenchTests/aBigBoardRefreshedBlocksTheMainThreadUnder50ms
    AccessibilityTreeBenchTests
    HostingViewDepthTests
    SandboxSoakBenchTests/theFootprintIsFlatOverFiveSimulatedHours
    FreezeCausesTests/aRowsSpokenLabelCostsAFractionOfTheFormatter
    ConfigSealPluginBenchTests/aRealSizedPluginCacheIsFingerprintedFast
    HookBoundsTests/aKeptLockIsGivenUpInTime
    HookBoundsTests/theBuiltHookLeavesInTime
    AppleScriptRunnerTests/aHungScriptEndsInTime
    ProcessTableTests/aSnapshotIsQuickOnABusyMac
    ChatMemoryTests
)

source scripts/lib/processes.sh

# Swift Testing's width, SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: at most a test a core at once (a caller's own
# width kept). Swift Testing gives no width of its own: it starts every test as a task on the cooperative pool, and only
# tests blocking a pool thread used to bound it, one a core. With their waits awaited (2026-11-05) a full run started
# hundreds at once, and their hosts and scripts took the Mac from load 18 to 193 in three minutes; 23 tests judged by
# time failed. Set before vs-heavy takes a slot. Its own default is marked (VIBESWITCHER_TEST_WIDTH_DEFAULT), so a slot's
# width replaces it where a caller's own width is only capped.
suite_width() {
    if [[ -z ${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-} ]]; then
        export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=$(cpu_count) VIBESWITCHER_TEST_WIDTH_DEFAULT=1
    fi
}
# Tests a core on a slot: VIBESWITCHER_TESTS_PER_CORE, a whole number from 1; 1 without one, a test a core. The tests
# mostly wait (on their git, scripts, hosts and sockets), each holding its place in the width while it does: on
# 2026-11-18 a full run's tests took 1009 s at a width of 4 with the test process at 1–35 % CPU, and 388–420 s at 2 a
# core (8). Not the default yet: at 2 a core, 3 of 10 full runs got a SIGPIPE from a write to a pipe or socket whose
# reader had gone (the run fails, naming it: `brokenPipesFailTheRun` in Tests/VibeCoreTests/TestSupport.swift), its
# writer not yet found; at 1, none in 4. Once it is, 2 is the default to give.
tests_per_core() {
    local per=${VIBESWITCHER_TESTS_PER_CORE:-1}
    [[ $per =~ ^[0-9]+$ ]] && (( 10#$per >= 1 )) || per=1
    echo $(( 10#$per ))
}
export -f tests_per_core
# Then, on the slot vs-heavy gives the run, its width, VS_HEAVY_CORES, times `tests_per_core` (a caller's narrower width
# kept), the build on VS_HEAVY_CORES itself (scripts/lib/swift-jobs.sh): a test a core of the whole Mac in each of 3 boosted slots ran up to 36 tests at
# once on 12 cores, and at 03:40–03:55 on 2026-11-08 an audit's full suite and other runs side by side took the load to
# 100–225 and froze the app about 40 times. The width is the cores free when the run starts (the load and the other
# slots held counted), at least the slot's share (Resources/bin/vs-heavy's `give_width`): capped at the share alone, a
# merge on a calm Mac took 15 min instead of 8 (2026-11-08 to 11-12). Without a VS_HEAVY_CORES (a whole number above 0), the
# width as it was. Exported, for the bash vs-heavy runs.
slot_width() {
    local width=${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-} cap
    if [[ ${VS_HEAVY_CORES:-} =~ ^[0-9]+$ ]] && (( 10#$VS_HEAVY_CORES >= 1 )); then
        cap=$(( 10#$VS_HEAVY_CORES * $(tests_per_core) ))
        [[ -z ${VIBESWITCHER_TEST_WIDTH_DEFAULT:-} && $width =~ ^[0-9]+$ ]] && (( 10#$width <= cap )) || width=$cap
    fi
    export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=$width
}
export -f slot_width

# Only the width swift test would get here, for the environment as given (no slot taken): TestScriptWidthTests.
if [[ ${1:-} == --width ]]; then
    suite_width
    slot_width
    echo "$SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"
    exit
fi

if [[ ${1:-} == --leftovers ]]; then
    end_leftovers "${2:?scripts/test.sh --leftovers MARK}"
    exit
fi
web_only=""
[[ ${1:-} == --web ]] && web_only=${2:?scripts/test.sh --web DIR}
preferences_only=""
if [[ ${1:-} == --preferences ]]; then
    preferences_only=${2:?scripts/test.sh --preferences DIR -- COMMAND}
    shift 2
    [[ ${1:-} == -- ]] && shift
fi
tsan=""
if [[ ${1:-} == --tsan ]]; then
    shift
    tsan=1
fi
perf=""
if [[ ${1:-} == --perf ]]; then
    shift
    perf=$(IFS='|'; echo "${perf_tests[*]}")
fi

if ! command -v node > /dev/null; then
    echo "scripts/test.sh: node isn't on PATH, and the phone's web tests (Tests/Web/*.test.mjs) run with it: install"
    echo "Node.js (e.g. brew install node) or put its folder on PATH. Nothing ran."
    exit 1
fi

source scripts/lib/scratch.sh
source scripts/lib/module-cache.sh
source scripts/lib/swift-jobs.sh

scratch_tmpdir vs-test
mkdir -p "$tool_scratch/home" || exit 1
# The folder's own name (vs-test.XXXXXX): processes may spell /tmp as /private/tmp.
mark=$(basename "$tool_scratch")
# Ctrl-C, or a build that fails: whatever the run started ends with it too (named, not judged).
on_exit 'end_leftovers "$mark" > /dev/null'
# The suites this run's test processes open, one name a line (`check_preferences`), in the folder only this run has.
export VIBESWITCHER_PREFERENCE_LEDGER=$tool_scratch/preference-suites
: > "$VIBESWITCHER_PREFERENCE_LEDGER"

# swift build, then swift test "$@", under one vs-heavy call: on the width it gives the run, VS_HEAVY_CORES
# (scripts/lib/swift-jobs.sh), and so are the tests (`slot_width` above). The bash it runs drops the team session's
# variables first; vs-heavy and its supervisor keep them.
swift_tests() {
    Resources/bin/vs-heavy --as scripts/test.sh bash -c 'clean_test_environment; slot_width; heavy_swift build || { : > "$VS_BUILD_FAILED_MARK"; exit 1; }; heavy_swift test "$@"' scripts/test.sh "$@"
}

# --tsan's: `swift_tests` with the thread sanitizer, built in .build/tsan (`heavy_swift` adds VS_SWIFT_EXTRA_OPTIONS to
# both the build and the tests; the default run's line above stays as PreferencesCheckTests and TestScriptWebTests read it).
swift_tests_sanitized() {
    VS_SWIFT_EXTRA_OPTIONS="--sanitize=thread --scratch-path .build/tsan" swift_tests "$@"
}

# --tsan's reports: none, 0; else each report's race and its first frames in the repository's code, and 1.
tsan_summary() {
    local reports=("$VS_TSAN_REPORTS"/tsan.*)
    if [[ ! -e ${reports[0]} ]]; then
        echo "thread sanitizer: no race reported"
        return 0
    fi
    echo "thread sanitizer: ${#reports[@]} report file(s) in $VS_TSAN_REPORTS:"
    for report in "${reports[@]}"; do
        echo "--- $(basename "$report") (the process of $(grep -m1 -oE 'pid=[0-9]+' "$report" || echo '?'))"
        grep -E '^WARNING: ThreadSanitizer|^SUMMARY: ThreadSanitizer|^  (Write|Read|Previous write|Previous read|Atomic)' "$report" | head -20
    done
    return 1
}

# The most failed tests --retry-failed retries: more is a broken change, not a flake.
retry_limit=10

# --retry-failed's run: `swift_tests "$@"`, and when it fails on at most `retry_limit` tests and nothing else, those
# tests alone once more, in a fresh run: a new swift test (--skip-build: the same build) in a new scratch home (HOME,
# CFFIXED_USER_HOME, VIBESWITCHER_HOME and TMPDIR in $tool_scratch/r, so the leftover check's mark covers it), on a
# vs-heavy slot of its own. Returns 0 when that run ran exactly them and each passed, each then named on a line,
# "flaky (passed on retry): Module.Suite/name()", printed only: today's engine reads flakes from a failed run alone, so
# its flake ledger and its "passed only on rerun" count never see them, and the lead copies them into the record; else 1,
# with both runs' failures, or a line saying why nothing was retried. On 2026-11-19 every full run on the node failed
# on one or two of several load-sensitive tests, each passing alone, and the merge's own rerun of the whole command
# then failed on another.
#
# Never a pass by accident: scripts/lib/retry-failed.mjs names the failed tests from Swift Testing's event stream (full
# IDs: the console prints "shared()" for every suite's shared()), and anything it can't vouch for fails the run as it
# would have without the option: swift test's exit not 1 (a signal, a stop, vs-heavy's time limit), a failed build, a
# run that never wrote its end (a crash or a kill) or left a test started and unended, an issue recorded outside a test
# function (a SIGPIPE, a disk read) or the console's count of issues differing from the stream's, a test process that
# SwiftPM says "exited with unexpected signal code" (signals 1, 3, 4, 6, 7, 8, 10, 11, 13 and 14, a fatalError's 4, even
# after the run's end), an XCTest failure, more than `retry_limit` tests, processes the run left behind.
# Not seen, a limit the lead accepted (2026-11-19): a test process ended by SIGKILL, SIGTERM or SIGINT, or exiting
# non-zero without a signal, only after every test has ended and been recorded, in a run that also has 1 to
# `retry_limit` failed tests that then pass alone, is retried into a pass. swift test 6.4.2 shows nothing of it: the
# same console, stderr, event stream (its end written) and exit 1 as those failures alone, -v too. The retry's
# filter is each ID matched literally and whole (`filter`), one argument (--filter=…); the caller's own --filter and
# --skip don't go to it (the failed tests passed them). The web, phone and security checks after it are never retried.
swift_tests_retrying_failed() {
    local first=$tool_scratch/first retry=$tool_scratch/r judge=scripts/lib/retry-failed.mjs
    local status again why pattern arg skip_next="" retry_args=()
    mkdir -p "$first" || return 1
    swift_tests "$@" --event-stream-output-path "$first/events.jsonl" --experimental-event-stream-version 0 2>&1 | tee "$first/console.log"
    status=${PIPESTATUS[0]}
    (( status == 0 )) && return 0
    if [[ -e $VS_BUILD_FAILED_MARK ]]; then
        echo "retry-failed: not retried: the build failed (above). The run fails as it would without --retry-failed."
        return "$status"
    fi
    if (( status != 1 )); then
        echo "retry-failed: not retried: swift test exited $status, not 1 as for failing tests (a signal, a stop, a time limit). The run fails as it would without --retry-failed."
        return "$status"
    fi
    if ! end_leftovers "$mark"; then
        echo "retry-failed: not retried: the run left processes behind (above). The run fails as it would without --retry-failed."
        return 1
    fi
    if ! why=$(node "$judge" first "$first/events.jsonl" "$first/console.log" "$retry_limit" "$first/failed" 2>&1); then
        echo "retry-failed: not retried: ${why:-its judge failed}. The run fails as it would without --retry-failed."
        return 1
    fi
    if ! pattern=$(node "$judge" filter "$first/failed" 2>&1); then
        echo "retry-failed: not retried: ${pattern:-no filter}. The run fails as it would without --retry-failed."
        return 1
    fi
    for arg in "$@"; do
        if [[ -n $skip_next ]]; then skip_next=""; continue; fi
        case $arg in
            --filter | --skip | --event-stream-output-path | --experimental-event-stream-version) skip_next=1 ;;
            --filter=* | --skip=* | --event-stream-output-path=* | --experimental-event-stream-version=* | --skip-build) ;;
            *) retry_args+=("$arg") ;;
        esac
    done
    echo "retry-failed: swift test failed on $(wc -l < "$first/failed" | tr -d ' ') tests and nothing else; running only them once more, in a fresh run (a new swift test, a new scratch home):"
    sed 's/^/  /' "$first/failed"
    mkdir -p "$retry/home" && mkdir -m 700 "$retry/tmp" || return 1
    (
        export HOME=$retry/home CFFIXED_USER_HOME=$retry/home VIBESWITCHER_HOME=$retry/home/.vibeswitcher
        with_tmpdir "$retry/tmp/" Resources/bin/vs-heavy --as scripts/test.sh bash -c 'clean_test_environment; slot_width; heavy_swift test --skip-build "$@"' scripts/test.sh \
            ${retry_args[@]+"${retry_args[@]}"} "--filter=$pattern" --event-stream-output-path "$retry/events.jsonl" --experimental-event-stream-version 0
    ) 2>&1 | tee "$retry/console.log"
    again=${PIPESTATUS[0]}
    if (( again == 0 )) && why=$(node "$judge" retry "$retry/events.jsonl" "$retry/console.log" "$first/failed" 2>&1); then
        node "$judge" flaky "$first/failed"
        echo "retry-failed: each test that failed passed on its retry: the Swift tests pass, those above listed as flaky."
        return 0
    fi
    (( again == 0 )) || why="swift test exited $again"
    echo "RETRY FAILED: the failed tests' retry didn't pass ($why). The first run's failures:"
    node "$judge" issues "$first/events.jsonl" "$first/failed"
    echo "The retry's:"
    node "$judge" issues "$retry/events.jsonl" "$first/failed"
    return 1
}

# The real user's preferences folder, before HOME moves: cfprefsd writes a named defaults suite
# (UserDefaults(suiteName: "x.y")) and an unbundled binary's own defaults (domain: the binary's file name) there,
# whatever HOME and CFFIXED_USER_HOME say, and removePersistentDomain leaves the file. Tests keep theirs in scratch
# (Scratch.defaults, a suite named by a path); on 2026-10-24 that folder held 8,012 dev.vibeswitcher.tests.<UUID>.plist
# and 11,000 more from tests, 18 VibeSwitcher-* from benches run on renamed binaries.
real_preferences=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2> /dev/null | awk '{print $2}')/Library/Preferences
# Linux (`on_linux`, scripts/lib/processes.sh) has no such folder and no cfprefsd: none, and `check_preferences` says so.
[[ -n $on_linux ]] && real_preferences=""
# The files there named the way tests and benches named theirs ("briefing-tests-<UUID>", "KeepAwakeTests-<UUID>",
# "dev.vibeswitcher.snapshots"), sorted. Another app's never match; the app's own (dev.vibeswitcher.VibeSwitcher) neither.
test_preferences() {
    ls "$real_preferences" 2> /dev/null \
        | grep -E '^(dev\.vibeswitcher\.(tests|snapshots)|VibeSwitcher-|[A-Za-z-]*([Tt]ests|snapshots)-[0-9A-Fa-f]{8}-)' | sort
}
# The unbundled build's own defaults there (.build/debug/VibeSwitcher's domain is its file name), as its sha, or "none".
# The benches wrote theirs there until 2026-10-25 (window frames, split views, chat font): they keep them in scratch now
# (BenchDefaults). The installed app's (dev.vibeswitcher.VibeSwitcher.plist) is never looked at.
build_defaults() {
    local file=$real_preferences/VibeSwitcher.plist
    if [[ -f $file ]]; then shasum "$file" | awk '{print $1}'; else echo none; fi
}
# Names the files this run added there (its test processes opened suites of those names: the ledger) and says when
# it changed VibeSwitcher.plist ($2: its build_defaults before; its domain in the ledger), and returns 1; nothing, 0.
# Files that appeared or changed and that it didn't open it names in a line and leaves as they are: not this run's. On
# 2026-11-09 that folder gained 264 files under test names, and an audit's run was failed twice for what a concurrent
# run had left there; VibeSwitcher.plist was rewritten at 18:16:56, inside a merge's run.
check_preferences() {
    local added own others status=0
    if [[ -z $real_preferences ]]; then
        echo "preferences check: skipped on Linux, which has no ~/Library/Preferences for a test to leave a file in"
        return 0
    fi
    added=$(comm -13 <(echo "$1") <(test_preferences))
    own=$(awk 'NR == FNR { opened[$0 ".plist"]; next } $0 in opened' "$VIBESWITCHER_PREFERENCE_LEDGER" <(echo "$added"))
    others=$(comm -23 <(echo "$added") <(echo "$own"))
    if [[ -n $own ]]; then
        echo "PREFERENCE FILES LEFT: the run added $(echo "$own" | wc -l | tr -d ' ') to $real_preferences, e.g.:"
        echo "$own" | head -5 | sed 's/^/  /'
        echo "  A test's UserDefaults go in scratch: Scratch.defaults (Tests/VibeSwitcherTests/TestSupport.swift)."
        status=1
    fi
    if [[ -n $others ]]; then
        echo "preference files that aren't this run's: $(echo "$others" | wc -l | tr -d ' ') appeared in $real_preferences that no process of this run opened, e.g.:"
        echo "$others" | head -5 | sed 's/^/  /'
    fi
    if [[ $(build_defaults) != "$2" ]]; then
        if grep -Fxq VibeSwitcher "$VIBESWITCHER_PREFERENCE_LEDGER"; then
            echo "PREFERENCES CHANGED: the run changed $real_preferences/VibeSwitcher.plist, the unbundled build's defaults:"
            echo "  something ran .build/debug/VibeSwitcher on its real domain. A bench's go in scratch: BenchDefaults"
            echo "  (Sources/VibeSwitcher/BenchDefaults.swift), a sandbox's in its state folder."
            status=1
        else
            echo "preference file that isn't this run's: $real_preferences/VibeSwitcher.plist changed, and no process of this run opened its domain"
        fi
    fi
    return $status
}

if [[ -n $preferences_only ]]; then
    real_preferences=$preferences_only
    preferences_before=$(test_preferences)
    defaults_before=$(build_defaults)
    "$@"
    check_preferences "$preferences_before" "$defaults_before"
    exit
fi

# In a branch run's box, SwiftPM keeps the cache the box gave the caller's HOME (scripts/lib/swift-jobs.sh): exported
# (only there) for the bash vs-heavy runs, the retry's too, whose heavy_swift keeps it from SwiftPM and the tests.
swiftpm_run_cache
[[ -n ${swiftpm_cache:-} ]] && export swiftpm_cache
export HOME=$tool_scratch/home CFFIXED_USER_HOME=$tool_scratch/home VIBESWITCHER_HOME=$tool_scratch/home/.vibeswitcher
# The suites run in UTC, as on CI: a time a test checks (the wire vectors' usage resets) reads the same everywhere.
export TZ=UTC
# Only --perf runs the benches, whatever the caller's environment holds.
unset VIBESWITCHER_PERF
if [[ -n $web_only ]]; then
    run_web_tests "$web_only"
    status=$?
else
    if [[ -n $tsan ]]; then
        export VS_TSAN_REPORTS=${VS_TSAN_REPORTS:-$PWD/.build/tsan-reports}
        rm -rf "$VS_TSAN_REPORTS" && mkdir -p "$VS_TSAN_REPORTS" || exit 1
        # Each process, the scratch hosts and servers too, writes its own file; a race doesn't end it.
        export TSAN_OPTIONS="log_path=$VS_TSAN_REPORTS/tsan halt_on_error=0 second_deadlock_stack=1 ${TSAN_OPTIONS:-}"
        echo "thread sanitizer run: built in .build/tsan; reports in $VS_TSAN_REPORTS"
    fi
    if [[ -n $perf ]]; then
        echo "perf run: the benches alone; the Mac's 1-minute load is $(load_one_minute) on $(cpu_count) cores"
        export VIBESWITCHER_PERF=1
        set -- --filter "$perf" "$@"
    fi
    # Both runs too: exports the swift function that adds it, for the bash under vs-heavy.
    shared_module_cache
    # Inside Codex's sandbox, a new worktree's dependencies come from the main checkout (no network there).
    swiftpm_offline_dependencies
    # The default run and --perf alike, under the one lock call. The repository's own vs-heavy, not the installed app's:
    # the one these tests check.
    preferences_before=$(test_preferences)
    defaults_before=$(build_defaults)
    # A failed build leaves a mark, so what needs its products is skipped rather than failed (or run on an older build).
    export VS_BUILD_FAILED_MARK=$tool_scratch/build-failed
    # A test a core, then at most the run's width (`suite_width`, `slot_width` above).
    suite_width
    # Both on the width vs-heavy gives the run, VS_HEAVY_CORES (scripts/lib/swift-jobs.sh), and so are the tests.
    if [[ -n $retry_failed ]]; then
        swift_tests_retrying_failed "$@"
    elif [[ -n $tsan ]]; then
        swift_tests_sanitized "$@"
    else
        swift_tests "$@"
    fi
    status=$?
    export -n swiftpm_cache 2> /dev/null
    check_preferences "$preferences_before" "$defaults_before" || status=1
    [[ -z $tsan ]] || tsan_summary || status=1
    # Even when the build or a test failed: they don't need the build, and their result is worth having. Not in --perf
    # or --tsan.
    if [[ -z $perf && -z $tsan ]]; then
        run_web_tests Tests/Web || status=1
        # The node's web client (WebApp/: its store, its socket feed against the wire's vectors, its no-markup lint).
        run_web_tests WebApp/tests || status=1
        # These use a private host, synthetic data and ad-hoc signed copies: no user sessions or Keychain.
        if [[ -e $VS_BUILD_FAILED_MARK ]]; then
            echo "security socket/signing tests: skipped, the build failed (above): they need its vibeswitcher-host"
        elif [[ -n ${CODEX_SANDBOX:-} ]]; then
            # Their scratch host listens on a Unix socket, which Codex's sandbox refuses (network off): the probe
            # times out, and every Codex worker's run would fail on it. The merge's and an audit's runs have them.
            echo "security socket/signing tests: skipped inside Codex's sandbox, which refuses their scratch host's socket"
        elif [[ -x .build/debug/vibeswitcher-host ]]; then
            # library-injection tests the Mac's Hardened Runtime (codesign, DYLD_INSERT_LIBRARIES): on Linux the
            # unit's UnsetEnvironment= and the static build hold that line for the host's start instead.
            run_web_tests Tests/SecurityAudit \
                ${on_linux:+"library-injection.test.mjs:the Mac's Hardened Runtime and code signing; Linux has neither"} \
                || status=1
        else
            echo "security socket/signing tests: no built host at .build/debug/vibeswitcher-host"
            status=1
        fi
    fi
fi
end_leftovers "$mark" || status=1
exit $status
