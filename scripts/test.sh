#!/bin/bash
# `swift build && swift test "$@"` on a fresh scratch home, so nothing a test writes reaches your ~/.vibeswitcher,
# ~/.claude or login Keychain. HOME, CFFIXED_USER_HOME (what NSHomeDirectory() follows; HOME alone doesn't move it),
# VIBESWITCHER_HOME and TMPDIR all point into a folder this creates under /tmp and removes when it exits, Ctrl-C too
# (scripts/lib/scratch.sh). In a worktree the lead made, both build against the worktrees' shared cache of the SDK's
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
# (`check_preferences` below): the run fails, naming them.
#
# swift build and swift test, --perf's too, run under vs-heavy (Resources/bin/vs-heavy, the Mac-wide lock for heavy
# work that every project's sessions have on PATH): while another run holds it (another worker's suite in any project,
# a build-app.sh, a merge's tests), this one waits, saying for whom. The web tests and the leftover check run after
# it's let go. Both build on the slot's share of the cores, `-j $VS_HEAVY_CORES` (scripts/lib/swift-jobs.sh).
#
# The phone's web tests run after swift test, in the same scratch home and TMPDIR: each Tests/Web/*.test.mjs with
# node, a failing one named, then one line saying how many passed. Without node on PATH the run stops before the
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
# scripts/test.sh --perf [swift test options]: only the benches (no web tests), on a scratch home as above.
# scripts/test.sh --width: only the width Swift Testing would get here (`slot_width`, below; TestScriptWidthTests).
# scripts/test.sh --leftovers MARK: only the check, for the processes whose environment or arguments hold MARK
#   (LeftoverCheckTests); exit 1 when it ended any.
# scripts/test.sh --web DIR: only the web tests, DIR/*.test.mjs (DIR from the repository's root, or absolute), on a
#   scratch home as above (TestScriptWebTests).
# scripts/test.sh --preferences DIR -- COMMAND…: only the preferences check, on DIR instead of the real
#   ~/Library/Preferences, around COMMAND (PreferencesCheckTests).
set -uo pipefail
cd "$(dirname "$0")/.."

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
run_web_tests() {
    local dir=$1 file passed=0 total=0 failed=""
    for file in "$dir"/*.test.mjs; do
        [[ -f $file ]] || continue
        total=$((total + 1))
        if node "$file"; then
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
)

source scripts/lib/processes.sh

# Swift Testing's width, SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: at most a test a core at once (a caller's own
# width kept). Swift Testing gives no width of its own: it starts every test as a task on the cooperative pool, and only
# tests blocking a pool thread used to bound it, one a core. With their waits awaited (2026-11-05) a full run started
# hundreds at once, and their hosts and scripts took the Mac from load 18 to 193 in three minutes; 23 tests judged by
# time failed. Set before vs-heavy takes a slot.
suite_width() {
    export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-$(cpu_count)}
}
# Then, on the slot vs-heavy gives the run, at most its share of the cores, VS_HEAVY_CORES (a caller's narrower width
# kept), as the build is (scripts/lib/swift-jobs.sh): a test a core of the whole Mac in each of 3 boosted slots ran up
# to 36 tests at once on 12 cores, and at 03:40–03:55 on 2026-11-08 an audit's full suite and other runs side by side
# took the load to 100–225 and froze the app about 40 times. Without a VS_HEAVY_CORES (a whole number above 0), the
# width as it was. Exported, for the bash vs-heavy runs.
slot_width() {
    local width=${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-}
    if [[ ${VS_HEAVY_CORES:-} =~ ^[0-9]+$ ]] && (( 10#$VS_HEAVY_CORES >= 1 )); then
        [[ $width =~ ^[0-9]+$ ]] && (( 10#$width <= 10#$VS_HEAVY_CORES )) || width=$(( 10#$VS_HEAVY_CORES ))
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

# The real user's preferences folder, before HOME moves: cfprefsd writes a named defaults suite
# (UserDefaults(suiteName: "x.y")) and an unbundled binary's own defaults (domain: the binary's file name) there,
# whatever HOME and CFFIXED_USER_HOME say, and removePersistentDomain leaves the file. Tests keep theirs in scratch
# (Scratch.defaults, a suite named by a path); on 2026-10-24 that folder held 8,012 dev.vibeswitcher.tests.<UUID>.plist
# and 11,000 more from tests, 18 VibeSwitcher-* from benches run on renamed binaries.
real_preferences=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2> /dev/null | awk '{print $2}')/Library/Preferences
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
# Names what the run added there (left as they are: they may be another run's), and says when VibeSwitcher.plist
# changed ($2: its build_defaults before), and returns 1; nothing, 0.
check_preferences() {
    local added status=0
    added=$(comm -13 <(echo "$1") <(test_preferences))
    if [[ -n $added ]]; then
        echo "PREFERENCE FILES LEFT: the run added $(echo "$added" | wc -l | tr -d ' ') to $real_preferences, e.g.:"
        echo "$added" | head -5 | sed 's/^/  /'
        echo "  A test's UserDefaults go in scratch: Scratch.defaults (Tests/VibeSwitcherTests/TestSupport.swift)."
        status=1
    fi
    if [[ $(build_defaults) != "$2" ]]; then
        echo "PREFERENCES CHANGED: the run changed $real_preferences/VibeSwitcher.plist, the unbundled build's defaults:"
        echo "  something ran .build/debug/VibeSwitcher on its real domain. A bench's go in scratch: BenchDefaults"
        echo "  (Sources/VibeSwitcher/BenchDefaults.swift), a sandbox's in its state folder."
        status=1
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

export HOME=$tool_scratch/home CFFIXED_USER_HOME=$tool_scratch/home VIBESWITCHER_HOME=$tool_scratch/home/.vibeswitcher
# Only --perf runs the benches, whatever the caller's environment holds.
unset VIBESWITCHER_PERF
if [[ -n $web_only ]]; then
    run_web_tests "$web_only"
    status=$?
else
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
    # A test a core, then at most the slot's share (`suite_width`, `slot_width` above).
    suite_width
    # Both on the slot's share of the cores, VS_HEAVY_CORES (scripts/lib/swift-jobs.sh), and so are the tests.
    Resources/bin/vs-heavy --as scripts/test.sh bash -c 'slot_width; heavy_swift build || { : > "$VS_BUILD_FAILED_MARK"; exit 1; }; heavy_swift test "$@"' scripts/test.sh "$@"
    status=$?
    check_preferences "$preferences_before" "$defaults_before" || status=1
    # Even when the build or a test failed: they don't need the build, and their result is worth having. Not in --perf.
    if [[ -z $perf ]]; then
        run_web_tests Tests/Web || status=1
        # These use a private host, synthetic data and ad-hoc signed copies: no user sessions or Keychain.
        if [[ -e $VS_BUILD_FAILED_MARK ]]; then
            echo "security socket/signing tests: skipped, the build failed (above): they need its vibeswitcher-host"
        elif [[ -n ${CODEX_SANDBOX:-} ]]; then
            # Their scratch host listens on a Unix socket, which Codex's sandbox refuses (network off): the probe
            # times out, and every Codex worker's run would fail on it. The merge's and an audit's runs have them.
            echo "security socket/signing tests: skipped inside Codex's sandbox, which refuses their scratch host's socket"
        elif [[ -x .build/debug/vibeswitcher-host ]]; then
            run_web_tests Tests/SecurityAudit || status=1
        else
            echo "security socket/signing tests: no built host at .build/debug/vibeswitcher-host"
            status=1
        fi
    fi
fi
end_leftovers "$mark" || status=1
exit $status
