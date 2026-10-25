#!/bin/bash
# The worktree's VibeSwitcher, sandboxed: built from this worktree and run as a copy with nothing of yours in reach, to
# drive and photograph (see Sources/VibeSwitcher/Sandbox.swift). Its state is a folder of its own (a short one in
# TMPDIR, else /tmp: the host's socket is in it, and a socket's path is limited to 104 bytes): its home, VibeSwitcher
# folder, defaults, its own session host on its own lock and socket, and a throwaway app key (no Keychain item is read).
# Its sessions are fake: the tests' FakeClaude (Tests/VibeSwitcherTests/FakeClaude.swift) on scratch ptys, never a
# real agent or a real session. It never shows a window or takes focus (off screen, never active), has no menu bar
# icon, hot key, Phone Access or login item, and quits by itself after 10 minutes (--minutes) or on `quit`.
#
# scripts/sandbox-app.sh [options] run          builds (swift build, under vs-heavy) and starts it; one per worktree
# scripts/sandbox-app.sh [options] shot NAME    draws its windows, light and dark: .build/sandbox-shots/NAME-*.png
# scripts/sandbox-app.sh [options] quit         quits it and removes its state folder (the shots stay)
# scripts/sandbox-app.sh [options] COMMAND…     any other command of the sandbox's: status, chat, type TEXT, send,
#                                               tell JSON, new, select TEXT, home, settings [TAB], sheet NAME,
#                                               close settings|sheet (help lists them)
# e.g. run; chat; type "hello"; shot chat; settings agents; shot settings; sheet new-project; shot new-project; quit
#
# Options: --minutes N (run: how long it lives, 10), --binary PATH (run: this build of VibeSwitcher, with
# vibeswitcher-host beside it, instead of building), --shots DIR (run: where shots go, .build/sandbox-shots),
# --dir DIR (where the sandbox's pid, state pointer and app.log are kept, .build/sandbox), --wait S (how long a
# command's reply is waited for, 120).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh

repo=$(pwd -P)
dir=$repo/.build/sandbox
shots=$repo/.build/sandbox-shots
binary=""
minutes=10
wait_for=120
# TMPDIR as given: scratch_tmpdir (the build's) replaces it and removes its own when this script exits.
given_tmpdir=${TMPDIR:-}

while [[ $# -gt 0 ]]; do
    case $1 in
        --minutes) minutes=$2; shift 2 ;;
        --binary) binary=$2; shift 2 ;;
        --shots) shots=$2; shift 2 ;;
        --dir) dir=$2; shift 2 ;;
        --wait) wait_for=$2; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*) echo "unknown option $1 (--help)"; exit 64 ;;
        *) break ;;
    esac
done
[[ $# -gt 0 ]] || { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }
[[ $minutes =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "--minutes $minutes: a number of minutes"; exit 64; }
mkdir -p "$dir"
dir=$(cd "$dir" && pwd -P)
mkdir -p "$shots"
shots=$(cd "$shots" && pwd -P)

# The running sandbox's state folder and pid, when it's running (the pid's command names that folder).
running_state() {
    local state pid
    state=$(cat "$dir/state" 2>/dev/null) || return 1
    pid=$(cat "$dir/pid" 2>/dev/null) || return 1
    [[ -n $state && -n $pid ]] && kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o command= | grep -qF -- "--sandbox $state" || return 1
    echo "$state $pid"
}

# Whether $1 is a state folder this script made (so `quit` may remove it).
is_state_folder() {
    [[ $(basename "$1") == vss.* && -d $1/control && -d $1/home ]]
}

# ask WORD…: hands the running sandbox a command and prints its reply; exits 1 when it says error.
ask() {
    local found state pid id reply deadline
    found=$(running_state) || { echo "no sandbox is running here: scripts/sandbox-app.sh run"; return 1; }
    read -r state pid <<<"$found"
    id="$$-$RANDOM$RANDOM"
    printf '%s\0' "$@" >"$state/control/.req-$id"
    mv "$state/control/.req-$id" "$state/control/req-$id"
    reply=$state/control/rep-$id
    deadline=$((SECONDS + wait_for))
    until [[ -f $reply ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then echo "the sandbox quit before it answered (see $dir/app.log)"; return 1; fi
        if ((SECONDS > deadline)); then echo "no answer in ${wait_for}s to: $*"; return 1; fi
        sleep 0.1
    done
    tail -n +2 "$reply"
    local first
    first=$(head -1 "$reply")
    rm -f "$reply"
    [[ $first == ok ]]
}

quit_sandbox() {
    local found state pid
    if found=$(running_state); then
        read -r state pid <<<"$found"
        ask quit >/dev/null || true
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        echo "quit the sandbox (pid $pid)"
    fi
    state=$(cat "$dir/state" 2>/dev/null) || state=""
    if [[ -n $state ]] && is_state_folder "$state"; then rm -rf "$state" </dev/null; fi
    rm -f "$dir/state" "$dir/pid"
}

# The tests' FakeClaude, from the Swift file that holds it (a raw string, so its text is the script's as it is).
extract_fake_claude() {
    awk '/static let script = #"""$/ { inside = 1; next } /^"""#$/ { inside = 0 } inside' \
        Tests/VibeSwitcherTests/FakeClaude.swift >"$1"
    grep -q 'TRANSCRIPT, CONTROL, STATE = sys.argv' "$1" || { echo "couldn't read FakeClaude from Tests/VibeSwitcherTests/FakeClaude.swift"; return 1; }
}

run_sandbox() {
    quit_sandbox >/dev/null
    if [[ -z $binary ]]; then
        scratch_tmpdir vs-sandbox
        Resources/bin/vs-heavy --as scripts/sandbox-app.sh swift build --product vibeswitcher-host
        Resources/bin/vs-heavy --as scripts/sandbox-app.sh swift build --product VibeSwitcher
        binary=$(swift build --show-bin-path)/VibeSwitcher
    fi
    [[ -x $binary && -x $(dirname "$binary")/vibeswitcher-host ]] || { echo "no VibeSwitcher with vibeswitcher-host beside it at $binary"; exit 1; }
    local base=${given_tmpdir%/}
    [[ -n $base && ${#base} -le 50 && -d $base ]] || base=/tmp
    local state
    state=$(mktemp -d "$base/vss.XXXXXX")
    state=$(cd "$state" && pwd -P)
    # Spelled as Foundation spells it (/tmp, not /private/tmp), so the app shows its home as ~.
    [[ $state == /private/tmp/* ]] && state=${state#/private}
    mkdir -m 700 "$state/home" "$state/tmp" "$state/control"
    extract_fake_claude "$state/fake_claude.py"
    echo "$state" >"$dir/state"
    : >"$dir/app.log"
    with_tmpdir "$state/tmp/" env HOME="$state/home" CFFIXED_USER_HOME="$state/home" VIBESWITCHER_HOME="$state/home/.vibeswitcher" \
        nohup "$binary" --sandbox "$state" --shots "$shots" --minutes "$minutes" --fake-claude "$state/fake_claude.py" \
        >>"$dir/app.log" 2>&1 </dev/null &
    local launched=$! deadline=$((SECONDS + wait_for))
    disown 2>/dev/null || true
    until [[ -s $state/control/started ]]; do
        if ! kill -0 "$launched" 2>/dev/null && [[ ! -s $state/control/started ]]; then
            echo "the sandbox didn't start:"; tail -20 "$dir/app.log"; rm -rf "$state" </dev/null; rm -f "$dir/state"; exit 1
        fi
        if ((SECONDS > deadline)); then echo "the sandbox didn't say it was ready in ${wait_for}s (see $dir/app.log)"; exit 1; fi
        sleep 0.1
    done
    tr -d '\n' <"$state/control/started" >"$dir/pid"
    echo "sandbox running: pid $(cat "$dir/pid"), state $state, quits by itself in $minutes min"
    echo "shots go to $shots; drive it with: scripts/sandbox-app.sh chat | type TEXT | send | settings [TAB] | sheet NAME | shot NAME | quit"
}

command=$1
shift
case $command in
    run) run_sandbox ;;
    quit) quit_sandbox ;;
    shot) [[ $# -gt 0 ]] || { echo "shot NAME"; exit 64; }; ask shot "$@" ;;
    *) ask "$command" "$@" ;;
esac
