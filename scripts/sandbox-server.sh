#!/bin/bash
# A scratch node with its web page on, to look at in a browser (the live plan's G1): a scratch session host and the
# server built from this worktree, the server's web listener on 127.0.0.1 (a port the kernel picks, never the user's
# 47830), two fake sessions, a scratch shell (its terminal open to the page: --test-web-terminal) and a fake lead with
# a question open and a made-up board (the Projects tab, its Board link). It is the tests' own node (ScratchNode, FakeClaude), run by
# Tests/VibeNodeTests/SandboxServerDriver.swift, which runs only when this script names its folder. Its state is a short
# folder of its own under /tmp (the host's socket is in it): its home, root, tmp and control files. It never touches
# your ~/.vibeswitcher, ~/.claude, node or browser, and quits by itself after 24 h.
#
# scripts/sandbox-server.sh [options] run    builds (under vs-heavy) and starts it; one per worktree
# scripts/sandbox-server.sh [options] url    prints the page's address with a fresh pairing code (works once, 120 s)
# scripts/sandbox-server.sh [options] shell  prints the shell session's id: its Terminal pane is at the page's #/s/<id>
#                                            (a scratch shell, the one session a page types into)
# scripts/sandbox-server.sh [options] flip   the first session's turn ends, or starts again: watch the page change
# scripts/sandbox-server.sh [options] chat   the first session's agent takes a step: watch its chat grow
# scripts/sandbox-server.sh [options] answer runs `vibeswitcher answer CARD` on the lead's open card, its code typed:
#                                            what the page drafted is sent, and the card closes on the page
# scripts/sandbox-server.sh [options] quit   quits it and removes its state folder
# e.g. run; url (open the address in a browser); flip; pick an answer on the card, answer; quit
#
# Options: --dir DIR (where its pid, state pointer and log are kept, .build/sandbox-server), --port N (run: the web's
# port; by default a free one picked at the start and kept, so the page reconnects across a server restart), --web-root (run: serve WebApp/ from the worktree, read at each request, instead of
# the files embedded in the server: a change shows at the next reload), --still (run: no status changes by
# themselves; by default the second session's changes every 20 s and the first one's agent takes a step every 8 s), --wait S (how long a reply is waited for, 600 for
# run, 60 otherwise).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/scratch.sh
source scripts/lib/module-cache.sh
source scripts/lib/swift-jobs.sh

repo=$(pwd -P)
dir=$repo/.build/sandbox-server
port=0
web_root=""
still=""
wait_for=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dir) dir=$2; shift 2 ;;
        --port) port=$2; shift 2 ;;
        --web-root) web_root=$repo/WebApp; shift ;;
        --still) still=1; shift ;;
        --wait) wait_for=$2; shift 2 ;;
        -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        --*) echo "unknown option $1 (--help)"; exit 64 ;;
        *) break ;;
    esac
done
[[ $# -gt 0 ]] || { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 64; }
[[ $port =~ ^[0-9]+$ ]] && ((port != 47830 && port < 65536)) || { echo "--port $port: a port's number, not the node's own 47830"; exit 64; }
mkdir -p "$dir"
dir=$(cd "$dir" && pwd -P)

# The running sandbox's state folder and pid, when it's running (the pid's environment names that folder).
running_state() {
    local state pid
    state=$(cat "$dir/state" 2>/dev/null) || return 1
    pid=$(head -1 "$state/control/started" 2>/dev/null) || return 1
    [[ -n $state && -n $pid ]] && kill -0 "$pid" 2>/dev/null || return 1
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF "VIBESWITCHER_SANDBOX_SERVER=$state" || return 1
    echo "$state $pid"
}

# Whether $1 is a state folder this script made (so `quit` may remove it).
is_state_folder() {
    [[ $(basename "$1") == vsss.* && -d $1/control && -d $1/home ]]
}

# ask WORD: hands the running sandbox a command and prints its reply; exits 1 when it says error.
ask() {
    local found state pid id reply deadline first
    found=$(running_state) || { echo "no sandbox node is running here: scripts/sandbox-server.sh run"; return 1; }
    read -r state pid <<<"$found"
    id="$$-$RANDOM$RANDOM"
    printf '%s' "$1" >"$state/control/.req-$id"
    mv "$state/control/.req-$id" "$state/control/req-$id"
    reply=$state/control/rep-$id
    deadline=$((SECONDS + ${wait_for:-60}))
    until [[ -f $reply ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then echo "the sandbox node quit before it answered (see $dir/node.log)"; return 1; fi
        if ((SECONDS > deadline)); then echo "no answer in ${wait_for:-60}s to: $1"; return 1; fi
        sleep 0.1
    done
    tail -n +2 "$reply"
    echo
    first=$(head -1 "$reply")
    rm -f "$reply"
    [[ $first == ok ]]
}

quit_sandbox() {
    local found state pid
    if found=$(running_state); then
        read -r state pid <<<"$found"
        ask quit >/dev/null || true
        for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        echo "quit the sandbox node (pid $pid)"
    fi
    state=$(cat "$dir/state" 2>/dev/null) || state=""
    if [[ -n $state ]] && is_state_folder "$state"; then rm -rf "$state" </dev/null; fi
    rm -f "$dir/state"
}

run_sandbox() {
    quit_sandbox >/dev/null
    scratch_tmpdir vs-sandbox-server
    shared_module_cache
    # The products and the test bundle the driver is in, as scripts/test.sh builds them.
    Resources/bin/vs-heavy --as scripts/sandbox-server.sh bash -c 'heavy_swift build --build-tests' || { echo "the build failed"; exit 1; }
    local bundle
    bundle=$(swift build $(swiftpm_options) --show-bin-path | tail -n 1)/VibeSwitcherPackageTests.xctest
    [[ -x $bundle ]] || { echo "no test bundle at $bundle"; exit 1; }
    # One port for the node's life: a server restarted by its host binds the same one, and the page comes back.
    if ((port == 0)); then
        port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
    fi
    local state
    state=$(mktemp -d /tmp/vsss.XXXXXX)
    mkdir -m 700 "$state/home" "$state/tmp" "$state/control" "$state/xdg"
    echo "$state" >"$dir/state"
    : >"$dir/node.log"
    with_tmpdir "$state/tmp/" env -u DBUS_SESSION_BUS_ADDRESS -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u VIBESWITCHER_SESSION \
        HOME="$state/home" CFFIXED_USER_HOME="$state/home" VIBESWITCHER_HOME="$state/home/.vibeswitcher" XDG_RUNTIME_DIR="$state/xdg" \
        VIBESWITCHER_SANDBOX_SERVER="$state" VIBESWITCHER_SANDBOX_PORT="$port" \
        ${web_root:+VIBESWITCHER_SANDBOX_WEB_ROOT="$web_root"} ${still:+VIBESWITCHER_SANDBOX_STILL=1} \
        nohup "$bundle" --testing-library swift-testing --filter 'SandboxServerDriver' >>"$dir/node.log" 2>&1 </dev/null &
    local launched=$! deadline=$((SECONDS + ${wait_for:-600}))
    disown 2>/dev/null || true
    until [[ -s $state/control/started ]]; do
        if ! kill -0 "$launched" 2>/dev/null; then
            echo "the sandbox node didn't start:"; tail -30 "$dir/node.log"; rm -rf "$state" </dev/null; rm -f "$dir/state"; exit 1
        fi
        if ((SECONDS > deadline)); then echo "the sandbox node didn't say it was ready in ${wait_for:-600}s (see $dir/node.log)"; exit 1; fi
        sleep 0.2
    done
    echo "sandbox node running: pid $launched, state $state, its page on 127.0.0.1:$port${web_root:+, serving $web_root}"
    echo "its page: scripts/sandbox-server.sh url (open the address it prints); then flip, and quit"
}

command=$1
shift
case $command in
    run) run_sandbox ;;
    quit) quit_sandbox ;;
    url | shell | flip | chat | answer) ask "$command" ;;
    *) echo "unknown command $command: run, url, shell, flip, chat, answer, quit (--help)"; exit 64 ;;
esac
