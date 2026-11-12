#!/bin/bash
# scripts/ci/macos-tests.sh: the suite on GitHub's hosted Mac, through scripts/test.sh, without the tests a hosted
# runner can't run. Those are listed in scripts/ci/macos-runner-skips.txt, one a line: the test as `Suite` or
# `Suite/test`, two spaces, the reason. A line with no reason is refused, and so is one naming a test that is no
# longer under Tests/ (a merge from main renamed or removed it): exit 2 either way, so a skip never outlives its test
# or hides without saying why. Prints how many are skipped before it runs.
#
# scripts/ci/macos-tests.sh --check-list: only checks the list (it runs anywhere, Linux too).
# SKIPS=FILE: another list, for this script's own checks.
set -uo pipefail
cd "$(dirname "$0")/../.."

list=${SKIPS:-scripts/ci/macos-runner-skips.txt}
[[ -f $list ]] || { echo "no skip list at $list"; exit 2; }

skips=()
while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    if [[ ! $line =~ ^([A-Za-z0-9_]+)(/([A-Za-z0-9_]+))?\ \ [^\ ].*$ ]]; then
        echo "bad skip (wanted: Suite or Suite/test, two spaces, the reason): $line"
        exit 2
    fi
    suite=${BASH_REMATCH[1]} test=${BASH_REMATCH[3]}
    files=$(grep -rlw --include='*.swift' -- "$suite" Tests) || { echo "stale skip: $suite"; exit 2; }
    if [[ -n $test ]]; then
        # The test's name, in a file that names its suite.
        echo "$files" | xargs grep -qw -- "$test" || { echo "stale skip: $suite/$test"; exit 2; }
    fi
    skips+=("$suite${test:+/$test}")
done < "$list"

echo "runner skips: ${#skips[@]}"
for skip in ${skips[@]+"${skips[@]}"}; do echo "  $skip"; done
[[ ${1:-} == --check-list ]] && exit 0

arguments=()
for skip in ${skips[@]+"${skips[@]}"}; do arguments+=(--skip "$skip"); done
bash scripts/test.sh ${arguments[@]+"${arguments[@]}"}
