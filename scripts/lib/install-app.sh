#!/bin/bash
# The --install step of scripts/build-app.sh: quits the running app, replaces the installed bundle with the built one,
# launches it, and checks the app running afterwards is the one just installed. Fails closed: when the app won't quit,
# nothing is replaced and the exit status is 1; when no new process is up after the launch, it says so and exits 1.
# "Installed and launched" is printed only over a process that started after the copy.
#
# 2026-10-30: three --install runs printed "Installed and launched" while the app process stayed the one started at
# 13:08. The app ignores SIGTERM at the signal level and routes it to a normal quit on its main queue (AppDelegate), so
# `pkill` is dropped whenever that queue is busy; the 10 s wait gave up silently, the bundle was replaced under the
# running process, and `open` only activated it. A quit Apple Event (what ⌘Q and osascript send) got it to quit at
# once. So: ask with the Apple Event first, SIGTERM only as a fallback, and never carry on over a process still up.
#
# Its parts are injectable so a test can drive it against a scratch stand-in instead of the user's app:
#
# scripts/lib/install-app.sh SOURCE_APP DEST_APP
#   VS_INSTALL_PROCESS  the app's process name, as pgrep -x sees it (VibeSwitcher)
#   VS_INSTALL_QUIT     the command that asks it to quit, run as `bash -c "$VS_INSTALL_QUIT" quit PID…` (osascript's
#                       quit Apple Event to the app by name)
#   VS_INSTALL_LAUNCH   the command that launches DEST_APP, run as `bash -c "$VS_INSTALL_LAUNCH" launch DEST_APP` (open)
#   VS_INSTALL_WAIT     seconds to wait for each quit attempt, and for the new process after the launch (10)
set -euo pipefail
source_app=$1
dest=$2
name=${VS_INSTALL_PROCESS:-VibeSwitcher}
quit=${VS_INSTALL_QUIT:-osascript -e "quit app \"$name\""}
launch=${VS_INSTALL_LAUNCH:-open "\$1"}
wait_s=${VS_INSTALL_WAIT:-10}
export LC_ALL=C

# The pids of the app's processes, space separated ("" when none).
running() { pgrep -x "$name" 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true; }
# "pid N, started <lstart>" for each pid in $*.
describe() {
    local pid out="" started
    for pid in $*; do
        started=$(ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^ *//; s/ *$//') || started=""
        out+="${out:+; }pid $pid, started ${started:-at an unknown time}"
    done
    echo "$out"
}
# The epoch seconds a pid started at (ps's lstart, to the second), or nothing when it can't be read.
started_at() {
    local lstart
    lstart=$(ps -p "$1" -o lstart= 2>/dev/null | tr -s ' ' | sed 's/^ *//; s/ *$//') || return 0
    [[ -n $lstart ]] && date -j -f '%a %b %d %T %Y' "$lstart" +%s 2>/dev/null || true
}
# Waits up to $wait_s seconds for every pid in $* to be gone; 1 when one is still up.
wait_gone() {
    local pid up
    for _ in $(seq 1 $((wait_s * 5))); do
        up=0
        for pid in $*; do kill -0 "$pid" 2>/dev/null && up=1; done
        (( up )) || return 0
        sleep 0.2
    done
    return 1
}
# $1 is one of the pids in $2.
among() { local p; for p in $2; do [[ $p == "$1" ]] && return 0; done; return 1; }

old=$(running)
old_desc=$(describe $old)
if [[ -z $old ]]; then
    echo "$name isn't running."
else
    echo "Asking $name ($old_desc) to quit."
    # In the background: a quit sent to an app whose main thread is stuck doesn't return until its event times out.
    bash -c "$quit" quit $old & quit_pid=$!
    if wait_gone $old; then
        echo "$name quit."
    else
        kill "$quit_pid" 2>/dev/null || true
        echo "$name didn't quit within ${wait_s}s of being asked; sending SIGTERM."
        kill -TERM $old 2>/dev/null || true
        if wait_gone $old; then
            echo "$name quit on SIGTERM."
        else
            echo "$name is still running ($old_desc) ${wait_s}s after a quit request and ${wait_s}s after SIGTERM." >&2
            echo "Nothing was installed: $dest is the one that was there. Quit it yourself (its menu, or Force Quit)," >&2
            echo "then run this again." >&2
            exit 1
        fi
    fi
    wait "$quit_pid" 2>/dev/null || true
fi

copied_at=$(date +%s)
rm -rf "$dest"
cp -R "$source_app" "$dest"
if ! bash -c "$launch" launch "$dest"; then
    echo "Installed $dest, but launching it failed (see above): open it yourself." >&2
    exit 1
fi
# A new process of the app: one that wasn't running before (the old pids are all gone, so any pid is new, unless a
# process of the name that wasn't the app's survived: then it isn't the one just launched).
new=""
for _ in $(seq 1 $((wait_s * 5))); do
    for pid in $(running); do among "$pid" "$old" || new="$new $pid"; done
    [[ -z $new ]] || break
    sleep 0.2
done
if [[ -z $new ]]; then
    echo "Installed $dest, but no new $name process is up ${wait_s}s after the launch (running: $(describe $(running)))." >&2
    echo "Open it yourself: open $dest" >&2
    exit 1
fi
new=${new# }
started=$(started_at "${new%% *}")
if [[ -z $started ]]; then
    echo "Installed $dest and a new $name process is up ($(describe $new)), but its start time couldn't be read, so this" >&2
    echo "can't tell it's the one just installed. Quit and open it yourself: open $dest" >&2
    exit 1
fi
if (( started < copied_at )); then
    echo "Installed $dest, but the $name running ($(describe $new)) started before the copy ($(date -r "$copied_at" '+%a %b %d %T %Y')):" >&2
    echo "it isn't the one just installed. Quit it yourself, then: open $dest" >&2
    exit 1
fi
echo "Installed and launched $dest: running as $(describe $new), after the copy at $(date -r "$copied_at" +%T)${old:+ (before: $old_desc)}."
