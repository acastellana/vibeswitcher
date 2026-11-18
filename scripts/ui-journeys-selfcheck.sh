#!/bin/bash
# Checks that scripts/ui-journeys.sh never reads "unchanged" without having compared a shot: run from a `git archive`
# copy of this commit under TMPDIR (where the sandbox spells its shot paths /tmp/…, not the runner's /private/tmp/…, so
# no shot reaches current/), the smoke journey must fail and name its missing shots; a journey with no shot lines must
# fail too. Needs a built VibeSwitcher (vibeswitcher-host beside it): the sandbox runs it, off screen, fake sessions only.
#
# scripts/ui-journeys-selfcheck.sh --binary PATH
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

[[ ${1:-} == --binary && -x ${2:-} ]] || { echo "scripts/ui-journeys-selfcheck.sh --binary PATH (a built VibeSwitcher)"; exit 64; }
binary=$2
scratch_tmpdir vs-ui-journeys-check
copy=$TMPDIR/copy
mkdir -p "$copy"
git archive HEAD | tar -x -C "$copy"

failures=0
# check NAME EXPECTED-STATUS PATTERN JOURNEY: runs the copy's runner on JOURNEY; its exit status must be EXPECTED-STATUS
# ("nonzero" for any failure) and its output must match PATTERN (grep -E).
check() {
    local name=$1 expected=$2 pattern=$3 journey=$4 output status=0
    output=$(bash "$copy/scripts/ui-journeys.sh" --binary "$binary" run "$journey" 2>&1) || status=$?
    if [[ $expected == nonzero ]] && ((status == 0)) || [[ $expected != nonzero && $status != "$expected" ]]; then
        echo "FAIL $name: exit $status, expected $expected"; echo "$output" | sed 's/^/    /'; failures=$((failures + 1)); return
    fi
    if ! grep -qE -- "$pattern" <<<"$output"; then
        echo "FAIL $name: no line matching $pattern"; echo "$output" | sed 's/^/    /'; failures=$((failures + 1)); return
    fi
    if grep -qE -- "^$journey: unchanged" <<<"$output"; then
        echo "FAIL $name: says unchanged"; echo "$output" | sed 's/^/    /'; failures=$((failures + 1)); return
    fi
    echo "ok   $name"
}

check "a copy outside the repo: the shots it names are missing" nonzero 'chat-main-light\.png.*chat-main-dark\.png|chat-main-dark\.png.*chat-main-light\.png' smoke

printf 'desc No shots at all.\nchat\n' >"$copy/scripts/ui-journeys/no-shots.journey"
check "a journey with no shot lines" nonzero 'no shots' no-shots

((failures == 0)) && echo "ui-journeys selfcheck: all passed" || echo "ui-journeys selfcheck: $failures failed"
((failures == 0))
