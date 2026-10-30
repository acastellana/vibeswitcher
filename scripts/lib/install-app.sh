#!/bin/bash
# The --install step of scripts/build-app.sh: quits the running app, replaces the installed bundle with the built one
# and launches it. Its parts are injectable so a test can drive it against a scratch stand-in instead of the user's app:
#
# scripts/lib/install-app.sh SOURCE_APP DEST_APP
#   VS_INSTALL_PROCESS  the app's process name, as pgrep -x sees it (VibeSwitcher)
#   VS_INSTALL_LAUNCH   the command that launches DEST_APP, run as `bash -c "$VS_INSTALL_LAUNCH" launch DEST_APP` (open)
#   VS_INSTALL_WAIT     seconds to wait for the app to quit (10)
set -euo pipefail
source_app=$1
dest=$2
name=${VS_INSTALL_PROCESS:-VibeSwitcher}
launch=${VS_INSTALL_LAUNCH:-open "\$1"}
wait_s=${VS_INSTALL_WAIT:-10}

pids=$(pgrep -x "$name" || true)
[[ -z $pids ]] || kill -TERM $pids 2>/dev/null || true
# Wait for it to finish quitting: `open` on an app that's still quitting is silently dropped.
for _ in $(seq 1 $((wait_s * 5))); do pgrep -x "$name" >/dev/null || break; sleep 0.2; done
rm -rf "$dest"
cp -R "$source_app" "$dest"
bash -c "$launch" launch "$dest"
echo "Installed and launched $dest"
