#!/bin/bash
# Measurement LA-2: the same dialog from a LaunchAgent, declined: Cancel must read as declined (nothing approved), and
# the dialog's own timeout (60 s) must end it as declined if left alone (the CLI waits 120 s for a state change).
#
# Run in Terminal:  bash scripts/mac-measure/la-cancel.sh       (--dry-run: build and check only)
# Look for: outcome=declined("cancelled at the Mac") after Cancel. Then it asks once more: leave that one alone for
# 60 s and look for outcome=declined("not answered within 60 s").
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build la
mm_new_label la-cancel
mm_write_plist "$mm_bin/la" ask "MEASURE-2 answer card 1234 with no" 60
mm_say ""
mm_say "What happens next: a job $mm_label asks LocalAuthentication twice, one after the other."
mm_say "First dialog: click Cancel. Second dialog: touch nothing for 60 seconds; it should go away by itself."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$mm_out/$mm_label.out" '^outcome=' 90
mm_say "First ask ended. Now the second: leave it alone."
/bin/launchctl kickstart "gui/$mm_uid/$mm_label" || mm_stop "kickstart failed"
mm_wait_for "$mm_out/$mm_label.out" '^outcome=' 100 2
mm_seen="did Cancel close the first dialog, and did the second go away by itself (after about 60 s)?"
mm_record "$mm_out/$mm_label.out" "$mm_out/$mm_label.err"
