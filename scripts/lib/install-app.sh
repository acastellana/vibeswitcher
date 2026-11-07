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
# 2026-10-31: run from a sandboxed shell (`! scripts/build-app.sh --install` in a Claude Code session), `pgrep -x` saw no
# process at all while ps listed the app, so the script said "VibeSwitcher isn't running", removed and replaced the
# bundle under the live app, and `open` only brought the old process forward. So the app is found with ps (setuid, it
# reads the process list where pgrep can't), by its executable inside DEST_APP rather than by name, and a process list
# that can't be read stops the install before anything is copied.
#
# 2026-11-03: the quit Apple Event had never been sent. Every --install printed `0:4: execution error: «script» doesn't
# understand the "quit" message. (-1708)` and fell back to SIGTERM 10 s later. The default was written
# ${VS_INSTALL_QUIT:-osascript -e "quit app \"$name\""}, and quote removal inside ${…:-…} strips the inner quotes, so
# the command run was `osascript -e quit app "VibeSwitcher"`: a script of just `quit` (to the script itself, hence
# «script» at 0:4), with "app" and the name as its arguments. Not a sandbox or TCC refusal. The default is now built
# outside the expansion and tells the app at DEST_APP, by its path (the copy running from there, not another of the
# same name or bundle id, which is how the app is found below too), to quit.
#
# Its parts are injectable so a test can drive it against a scratch stand-in instead of the user's app:
#
# scripts/lib/install-app.sh SOURCE_APP DEST_APP
#   VS_INSTALL_PROCESS  the app's executable name, DEST_APP/Contents/MacOS/<name> (VibeSwitcher)
#   VS_INSTALL_QUIT     the command that asks it to quit, run as `bash -c "$VS_INSTALL_QUIT" quit PID…` (osascript's
#                       quit Apple Event to the app at DEST_APP, by its path)
#   VS_INSTALL_LAUNCH   the command that launches DEST_APP, run as `bash -c "$VS_INSTALL_LAUNCH" launch DEST_APP` (open)
#   VS_INSTALL_WAIT     seconds to wait for each quit attempt, and for the new process after the launch (10)
#   VS_INSTALL_VERIFY   the command that checks the copied bundle's signature, run as
#                       `bash -c "$VS_INSTALL_VERIFY" verify APP` (codesign -v)
#
# 2026-11-07: the copy into /Applications failed partway (`cp: …/VibeSwitcher_VibeHostTests.bundle/…: fcopyfile failed:
# Input/output error`) after the old bundle had been removed and the app quit, which left an installed app that failed
# `codesign -v` ("a sealed resource is missing or invalid") and nothing running. So the new bundle is copied next to
# DEST_APP (DEST_APP.installing, same volume, not an .app), its signature checked, and only then swapped in by two
# renames; a copy or check that fails removes the partial copy, leaves DEST_APP as it was, relaunches it when it was
# running, and exits 1 saying what failed.
set -euo pipefail
source_app=$1
dest=$2
name=${VS_INSTALL_PROCESS:-VibeSwitcher}
# Built here, not inside ${VS_INSTALL_QUIT:-…}, whose quote removal took the script apart (2026-11-03, above). The path
# goes in as the script's argument, so no quote or backslash in it can change the script.
default_quit=$(printf 'osascript -e %q -e %q -e %q %q' 'on run argv' 'tell application (item 1 of argv) to quit' 'end run' "$dest")
quit=${VS_INSTALL_QUIT:-$default_quit}
# The same quote removal made this `open $1`, split at any space in DEST_APP.
default_launch='open "$1"'
launch=${VS_INSTALL_LAUNCH:-$default_launch}
wait_s=${VS_INSTALL_WAIT:-10}
default_verify='codesign -v "$1"'
verify=${VS_INSTALL_VERIFY:-$default_verify}
staged="$dest.installing"
aside="$dest.replaced"
export LC_ALL=C

# The app's executable, as ps shows it (the path it was started by, with any // squeezed), and its path with the
# symlinks above DEST_APP resolved: either is the app.
exe="$dest/Contents/MacOS/$name"
exe_real=$( (cd "$(dirname "$dest")" 2>/dev/null && pwd -P) || true)
exe_real=${exe_real:+$exe_real/$(basename "$dest")/Contents/MacOS/$name}
# The pids of the app's processes, space separated ("" when none): those whose executable is $exe, and those ps shows
# by the bare name (it couldn't read their path, so they may be the app). 1 when the process list can't be read: then
# nothing can say the app isn't running.
running() {
    local list
    list=$(ps -Ao pid=,comm= 2>/dev/null) && [[ -n $list ]] || return 1
    awk -v exe="$exe" -v real="$exe_real" -v name="$name" '
        function squeeze(p) { while (index(p, "//")) sub("//", "/", p); return p }
        { pid = $1; comm = $0; sub(/^ *[0-9]+ +/, "", comm); comm = squeeze(comm)
          if (comm == squeeze(exe) || (real != "" && comm == squeeze(real)) || comm == name) printf "%s%s", (n++ ? " " : ""), pid }
    ' <<<"$list"
}
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
# Waits up to $wait_s seconds for every pid in $* to be gone from the app's processes; 1 when one is still up. Read from
# ps, as running() is, not from `kill -0`: a sandbox that refuses signals to the app makes kill -0 fail on a live pid,
# which would read as gone. A process list that can't be read counts as still up.
wait_gone() {
    local pid up now
    for _ in $(seq 1 $((wait_s * 5))); do
        up=0
        if now=$(running); then
            for pid in $*; do among "$pid" "$now" && up=1; done
        else
            up=1
        fi
        (( up )) || return 0
        sleep 0.2
    done
    return 1
}
# $1 is one of the pids in $2.
among() { local p; for p in $2; do [[ $p == "$1" ]] && return 0; done; return 1; }

if ! old=$(running); then
    echo "Couldn't read the process list (ps -Ao pid=,comm= failed), so this can't tell whether $name is running." >&2
    echo "Nothing was installed: $dest is the one that was there. Quit $name yourself, then run this again." >&2
    exit 1
fi
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

# The install failed before DEST_APP was touched: removes the partial copy, relaunches the old app if it was running,
# and exits 1. $1: what failed.
keep_old() {
    rm -rf "$staged" 2>/dev/null || true
    echo "$1" >&2
    echo "Nothing was installed: $dest is the one that was there." >&2
    if [[ -n $old ]]; then
        if bash -c "$launch" launch "$dest"; then
            echo "Relaunched the old $dest." >&2
        else
            echo "Relaunching the old $dest failed too (see above): open it yourself." >&2
        fi
    fi
    exit 1
}

copied_at=$(date +%s)
rm -rf "$staged" "$aside" || keep_old "Couldn't remove what an earlier install left at $staged or $aside."
cp -R "$source_app" "$staged" || keep_old "Copying $source_app to $staged failed (see above)."
bash -c "$verify" verify "$staged" || keep_old "The copy at $staged doesn't pass its signature check (see above)."
# Two renames on one volume: DEST_APP is the old bundle, then (after an instant with none) the new one, never partial.
if [[ -e $dest ]]; then
    mv "$dest" "$aside" || keep_old "Couldn't move the old $dest aside to $aside."
fi
if ! mv "$staged" "$dest"; then
    if [[ -e $aside ]] && ! mv "$aside" "$dest"; then
        echo "Couldn't move the new copy $staged to $dest, nor the old bundle back from $aside: move it back yourself" >&2
        echo "(mv $(printf %q "$aside") $(printf %q "$dest")), then open it." >&2
        exit 1
    fi
    keep_old "Couldn't move the new copy $staged to $dest."
fi
rm -rf "$aside" || echo "Installed $dest, but couldn't remove the old bundle at $aside: remove it yourself." >&2
if ! bash -c "$launch" launch "$dest"; then
    echo "Installed $dest, but launching it failed (see above): open it yourself." >&2
    exit 1
fi
# A new process of the app: one that wasn't running before (the old pids are all gone, so any pid is new, unless a
# process of the name that wasn't the app's survived: then it isn't the one just launched).
new=""
for _ in $(seq 1 $((wait_s * 5))); do
    for pid in $(running || true); do among "$pid" "$old" || new="$new $pid"; done
    [[ -z $new ]] || break
    sleep 0.2
done
if [[ -z $new ]]; then
    echo "Installed $dest, but no new $name process is up ${wait_s}s after the launch (running: $(describe $(running || true)))." >&2
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
