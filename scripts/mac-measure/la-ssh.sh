#!/bin/bash
# Measurement LA-5: LocalAuthentication asked from an ssh login (the design expects .notInteractive, read as
# unavailable: no dialog, no approval). Needs Remote Login on (System Settings › General › Sharing; it is off on this
# Mac as of 2026-11-25: turning it on is your call, and you can turn it off after).
#
# Run from an ssh login to this Mac (ssh localhost from Terminal works):  bash scripts/mac-measure/la-ssh.sh
# (--dry-run: build and check only, anywhere)
# Look for: `la can` over ssh; then the ask's outcome, and whether any dialog appeared on the Mac's own screen.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
if [[ $mm_dry == 0 && -z ${SSH_CONNECTION:-} ]]; then mm_stop "SSH_CONNECTION isn't set: run this from an ssh login"; fi
mm_build la
mm_say "launchctl managername here: $(/bin/launchctl managername 2>&1)" | tee "$mm_out/ssh.txt"
"$mm_bin/la" can | tee -a "$mm_out/ssh.txt"
mm_say ""
mm_say "Next: this process asks once, directly (the server would be a LaunchAgent; this is what an ssh login itself gets)."
mm_say "If a dialog appears on the Mac's screen, Cancel it and note that it appeared."
mm_go "Ready?"
if [[ $mm_dry == 1 ]]; then mm_say "dry run done: nothing was asked"; exit 0; fi
MEASURE_ASK=yes "$mm_bin/la" ask "MEASURE-5 approve over ssh" 30 2>&1 | tee -a "$mm_out/ssh.txt"
mm_record "$mm_out/ssh.txt"
