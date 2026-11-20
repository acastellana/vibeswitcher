#!/bin/bash
# scripts/nightly.sh [--update REF] [--out DIR]: the full suite, once, as a nightly job: `vs-heavy bash scripts/test.sh
# --retry-failed` in this checkout, its whole output kept in DIR (default <checkout>/.build/nightly) as <time>.log
# (the newest 14 kept), and a short report, DIR/last.md, that the supervisor reads: PASS or FAIL, when, the commit, how
# long, the tests that failed (with the file and line of their first issue), those that passed only on their retry
# (flaky), and what else the run said went wrong (a build error, the web tests, why nothing was retried). Exit 0 when the
# suite passed (flaky tests allowed, listed), 1 when it didn't or couldn't run, 2 for bad arguments.
#
# --update REF: first `git fetch` and check out REF detached (e.g. origin/v2), only in a clean checkout (any change, even
#   an untracked file, refuses it: a nightly never throws away someone's work). For a checkout kept for the nightly:
#     git worktree add --detach ~/projects/vibeswitcher-worktrees/nightly origin/v2
#     (cd ~/projects/vibeswitcher-worktrees/nightly && bash scripts/worktree-init.sh)
# --out DIR: where the logs and last.md go (e.g. the main checkout's .build/nightly, where the supervisor looks).
#
# One nightly at a time (a flock on DIR/lock): a second one exits 1 at once, saying so in last.md's place on stderr.
# Run by hand or by the systemd user timer beside this file (scripts/nightly/vibeswitcher-nightly.timer, NOT installed:
# its header says how). Full suites are heavy work: never during a merge's run by hand (vs-heavy queues it anyway).
#
# scripts/nightly.sh --report LOG STATUS STARTED ENDED COMMIT: only the report, from a run's LOG and its exit STATUS
#   (STARTED and ENDED: seconds since 1970), on stdout (NightlyScriptTests).
set -uo pipefail

# The report, from a test.sh --retry-failed log. Console lines as Swift Testing prints them: "✘ Test name() recorded an
# issue at File.swift:12:9: …", "✘ Test name() failed after …"; the retry's "flaky (passed on retry): Module.Suite/name()";
# web tests' "web tests: N of M passed; failed: …" and "WEB TEST FAILED: …"; the retry's "retry-failed: not retried: …"
# and "RETRY FAILED: …"; "LEFTOVER PROCESSES: …", "PREFERENCE FILES LEFT: …"; a build's "error: …".
# A time (seconds since 1970) in FORMAT: GNU date's -d, else BSD's -r (the Mac's).
when() { date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2"; }

report() {
    local log=$1 status=$2 started=$3 ended=$4 commit=$5
    local verdict=PASS minutes
    (( status == 0 )) || verdict=FAIL
    minutes=$(( (ended - started + 59) / 60 ))
    echo "# Nightly full suite: $verdict"
    echo
    echo "- when: $(when "$started" '%Y-%m-%d %H:%M') to $(when "$ended" '%H:%M') ($minutes min)"
    echo "- commit: $commit"
    echo "- exit: $status"
    echo "- log: $log"
    local flaky failed other
    flaky=$(grep -aoE 'flaky \(passed on retry\): .*' "$log" | sed 's/^flaky (passed on retry): //' | sort -u)
    # Each failed test once, with the file and line of its first issue when the console gave one.
    failed=$(grep -aE '✘ Test .* (recorded an issue at|failed after|failed with)' "$log" | awk '
        {
            line = $0
            sub(/.*✘ Test /, "", line)
            name = line; sub(/ (recorded an issue at|failed after|failed with).*/, "", name)
            where = ""
            if (line ~ / recorded an issue at /) { where = line; sub(/.* recorded an issue at /, "", where); sub(/: .*/, "", where) }
            if (!(name in seen)) { seen[name] = 1; order[++n] = name }
            if (where != "" && !(name in at)) at[name] = where
        }
        END { for (i = 1; i <= n; i++) print order[i] (order[i] in at ? " (" at[order[i]] ")" : "") }')
    if (( status == 0 )); then
        # A pass with failures in its log: each passed on its retry, listed as flaky above.
        failed=""
    fi
    other=$(grep -aE '^(web tests: [0-9]+ of [0-9]+ passed.*|WEB TEST FAILED: .*|retry-failed: not retried: .*|RETRY FAILED: .*|error: .*|.*: error: .*|LEFTOVER PROCESSES: .*|PREFERENCE FILES LEFT: .*)$' "$log" \
        | grep -avE '^web tests: ([0-9]+) of \1 passed$' | awk '!seen[$0]++' | head -20)
    echo
    echo "## Failed"
    echo
    if [[ -n $failed ]]; then sed 's/^/- /' <<<"$failed"; elif (( status == 0 )); then echo "none"; else echo "no test named: see Other and the log"; fi
    echo
    echo "## Flaky (passed on retry)"
    echo
    if [[ -n $flaky ]]; then sed 's/^/- /' <<<"$flaky"; else echo "none"; fi
    echo
    echo "## Other"
    echo
    if [[ -n $other ]]; then sed 's/^/- /' <<<"$other"; else echo "nothing"; fi
}

if [[ ${1:-} == --report ]]; then
    (( $# == 6 )) || { echo "usage: scripts/nightly.sh --report LOG STATUS STARTED ENDED COMMIT" >&2; exit 2; }
    report "$2" "$3" "$4" "$5" "$6"
    exit 0
fi

cd "$(dirname "$0")/.." || exit 1
checkout=$(pwd)
update="" out="$checkout/.build/nightly"
while (( $# )); do
    case $1 in
        --update) [[ -n ${2:-} ]] || { echo "scripts/nightly.sh: --update needs a REF" >&2; exit 2; }; update=$2; shift 2 ;;
        --out) [[ -n ${2:-} ]] || { echo "scripts/nightly.sh: --out needs a DIR" >&2; exit 2; }; out=$2; shift 2 ;;
        *) echo "usage: scripts/nightly.sh [--update REF] [--out DIR]" >&2; exit 2 ;;
    esac
done
mkdir -p "$out" || exit 1
exec 9>"$out/lock"
if ! flock -n 9; then
    echo "scripts/nightly.sh: another nightly holds $out/lock: nothing ran" >&2
    exit 1
fi

# The toolchain, for a run started by systemd with its bare environment.
[[ -f ~/.local/share/swiftly/env.sh ]] && source ~/.local/share/swiftly/env.sh

started=$(date +%s)
stamp=$(when "$started" %Y-%m-%dT%H%M)
log="$out/$stamp.log"
write_report() {
    local status=$1 commit
    commit="$(git -C "$checkout" rev-parse --short=12 HEAD 2>/dev/null || echo unknown) ($(git -C "$checkout" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'), $checkout)"
    report "$log" "$status" "$started" "$(date +%s)" "$commit" > "$out/last.md.new" && mv "$out/last.md.new" "$out/last.md"
}

(
    echo "nightly: $checkout at $(when "$started" '%Y-%m-%d %H:%M:%S')"
    if [[ -n $update ]]; then
        if [[ -n $(git status --porcelain) ]]; then
            echo "error: --update $update refused: the checkout has changes (git status shows them); nothing ran"
            exit 1
        fi
        git fetch --quiet && git checkout --quiet --detach "$update" || { echo "error: --update $update: git fetch or checkout failed; nothing ran"; exit 1; }
    fi
    echo "nightly: testing $(git rev-parse --short=12 HEAD) ($(git log -1 --format=%s | cut -c1-100))"
    Resources/bin/vs-heavy --as nightly bash scripts/test.sh --retry-failed
) > "$log" 2>&1
status=$?
write_report "$status"
# The newest 14 logs kept.
ls -1t "$out"/*.log 2>/dev/null | tail -n +15 | while read -r old; do rm -f -- "$old"; done
cat "$out/last.md"
(( status == 0 )) && exit 0 || exit 1
