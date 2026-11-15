#!/bin/bash
# scripts/ci/macos-tests.sh [TARGETS]: the suite on GitHub's hosted Mac, through scripts/test.sh, without what a hosted
# runner can't run. With TARGETS (a test target, or several as 'A|B') only those targets' tests: the whole suite takes
# over an hour on the runner's cores, so the workflow runs a job for each of three groups.
#
# What isn't run is listed in scripts/ci/macos-runner-skips.txt, one a line, then two spaces, then the reason:
#   Suite or Suite/test       a Swift test, passed to swift test as --skip
#   Tests/…/name.test.mjs     a node test scripts/test.sh runs after the Swift ones; it still runs, and its failure
#                             alone doesn't fail this script
# A line with no reason is refused, and so is one naming a test or file that is no longer there (a merge from main
# renamed or removed it): exit 2 either way, so a skip never outlives its test or hides without saying why.
#
# scripts/test.sh has one exit status for everything it runs. When it fails, this passes only if its output shows that
# nothing but a listed node test failed: Swift Testing's own "Test run … passed" line, no failed test or suite, no
# build error, no timeout, nothing left running, no preference file left, and no node test failed but listed ones.
#
# Beside scripts/test.sh runs scripts/ci/watchdog.sh: timestamped lines as each swift phase starts and ends, and,
# WATCHDOG_MARGIN seconds (300) before vs-heavy's timeout, what still runs, its open descriptors, and a SIGABRT to the
# testing helper alone, so a hung run names its test (swift test holds back its lines until it exits, and vs-heavy's
# stop loses them) and leaves a backtrace in .build/crash-reports.
#
# scripts/ci/macos-tests.sh --check-list: only checks the list (it runs anywhere, Linux too).
# SKIPS=FILE: another list, for this script's own checks. JUDGE=FILE: only judges FILE as scripts/test.sh's output.
set -uo pipefail
cd "$(dirname "$0")/../.."

list=${SKIPS:-scripts/ci/macos-runner-skips.txt}
[[ -f $list ]] || { echo "no skip list at $list"; exit 2; }

skips=()
files=()
while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    if [[ $line =~ ^(Tests/[A-Za-z0-9_/.-]+\.test\.mjs)\ \ [^\ ].*$ ]]; then
        [[ -f ${BASH_REMATCH[1]} ]] || { echo "stale skip: ${BASH_REMATCH[1]}"; exit 2; }
        files+=("${BASH_REMATCH[1]}")
        continue
    fi
    if [[ ! $line =~ ^([A-Za-z0-9_]+)(/([A-Za-z0-9_]+))?\ \ [^\ ].*$ ]]; then
        echo "bad skip (wanted: Suite, Suite/test or Tests/….test.mjs, two spaces, the reason): $line"
        exit 2
    fi
    suite=${BASH_REMATCH[1]} test=${BASH_REMATCH[3]}
    found=$(grep -rlw --include='*.swift' -- "$suite" Tests) || { echo "stale skip: $suite"; exit 2; }
    if [[ -n $test ]]; then
        # The test's name, in a file that names its suite.
        echo "$found" | xargs grep -qw -- "$test" || { echo "stale skip: $suite/$test"; exit 2; }
    fi
    skips+=("$suite${test:+/$test}")
done < "$list"

echo "runner skips: $(( ${#skips[@]} + ${#files[@]} ))"
for skip in ${skips[@]+"${skips[@]}"} ${files[@]+"${files[@]}"}; do echo "  $skip"; done
[[ ${1:-} == --check-list ]] && exit 0

# Whether scripts/test.sh's output ($1) shows that only listed node tests failed.
only_listed_failed() {
    local log=$1 failed file listed known
    # "✔ Test run with 224 tests in 54 suites passed after …"; the mark differs when the run had known issues.
    grep -qE '^[^ ]+ Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$log" || { echo "judge: no passing Swift test run in the output"; return 1; }
    if grep -qE '^(✘ |error: |vs-heavy: .*stopping it|LEFTOVER PROCESSES|PREFERENCE FILES LEFT|PREFERENCES CHANGED|WEB TEST FAILED: Tests/Web/)' "$log"; then
        echo "judge: a failure that isn't a listed node test:"
        grep -E '^(✘ |error: |vs-heavy: .*stopping it|LEFTOVER PROCESSES|PREFERENCE FILES LEFT|PREFERENCES CHANGED|WEB TEST FAILED: Tests/Web/)' "$log" | head -20
        return 1
    fi
    failed=$(grep -E '^WEB TEST FAILED: ' "$log" | sed -E 's/^WEB TEST FAILED: ([^ ]+).*/\1/' | sort -u)
    [[ -n $failed ]] || { echo "judge: scripts/test.sh failed and its output doesn't say what did"; return 1; }
    for file in $failed; do
        known=""
        for listed in ${files[@]+"${files[@]}"}; do [[ $file == "$listed" ]] && known=1; done
        [[ -n $known ]] || { echo "judge: $file failed and isn't listed"; return 1; }
    done
    echo "judge: only listed node tests failed: $(echo $failed)"
}

if [[ -n ${JUDGE:-} ]]; then
    only_listed_failed "$JUDGE"
    exit
fi

arguments=()
[[ -n ${1:-} ]] && arguments+=(--filter "^($1)\\.")
for skip in ${skips[@]+"${skips[@]}"}; do arguments+=(--skip "$skip"); done
# GitHub's own temporary folder on the runner; the build folder (git-ignored) anywhere else.
log=${RUNNER_TEMP:-.build}/macos-tests.log
mkdir -p "$(dirname "$log")"
# The runner is slower than the Mac vs-heavy's hour was chosen on.
export VIBESWITCHER_HEAVY_TIMEOUT=${VIBESWITCHER_HEAVY_TIMEOUT:-80m}
# The watchdog's report comes this long before vs-heavy's stop, as vs-heavy reads its TIME: minutes unless it says.
if [[ $VIBESWITCHER_HEAVY_TIMEOUT =~ ^([0-9]+)([smh]?)$ ]]; then
    case ${BASH_REMATCH[2]} in
        s) timeout=$(( 10#${BASH_REMATCH[1]} )) ;;
        h) timeout=$(( 10#${BASH_REMATCH[1]} * 3600 )) ;;
        *) timeout=$(( 10#${BASH_REMATCH[1]} * 60 )) ;;
    esac
else
    echo "VIBESWITCHER_HEAVY_TIMEOUT=$VIBESWITCHER_HEAVY_TIMEOUT: give minutes (90, 90m), seconds (30s) or hours (2h)"
    exit 2
fi
margin=${WATCHDOG_MARGIN:-300}
(( timeout > 2 * margin )) && after=$(( timeout - margin )) || after=$(( timeout / 2 ))
# Where the workflow keeps them from.
export WATCHDOG_REPORTS=$PWD/.build/crash-reports
echo "macos-tests $(date -u +%H:%M:%SZ): scripts/test.sh starts (vs-heavy stops it after $timeout s)"
( bash scripts/test.sh ${arguments[@]+"${arguments[@]}"} 2>&1 | tee "$log"; exit "${PIPESTATUS[0]}" ) &
run=$!
bash scripts/ci/watchdog.sh "$run" "$after" &
watchdog=$!
wait "$run"
status=$?
echo "macos-tests $(date -u +%H:%M:%SZ): scripts/test.sh ended, exit $status"
# It ends with the run, after its report when it is giving one.
wait "$watchdog"
(( status == 0 )) && exit 0
only_listed_failed "$log"
