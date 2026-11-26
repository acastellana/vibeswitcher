#!/bin/bash
# Measurement LA-3: the login-password route of the same dialog (what a Mac with no Touch ID enrolled, or Touch ID not
# reachable, gets): from a LaunchAgent, the user chooses the password instead of the finger.
#
# Run in Terminal:  bash scripts/mac-measure/la-password.sh     (--dry-run: build and check only)
# Look for: the dialog offers "Use Password…" (or asks for it after a failed touch); typing the login password into
# the SYSTEM dialog gives outcome=approved. Type it only into the system's dialog, never into Terminal or anywhere else.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build la
mm_new_label la-password
mm_write_plist "$mm_bin/la" ask "MEASURE-3 approve setting x to y with the password" 60
mm_say ""
mm_say "What happens next: a job $mm_label asks once. In the system dialog choose the password route"
mm_say "(\"Use Password…\", or rest a finger that isn't enrolled until it offers it), and type your login password there."
mm_say "Never type the password in this Terminal."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$mm_out/$mm_label.out" '^outcome=' 90
mm_seen="how you reached the password (the button's words), and whether the dialog took it"
mm_record "$mm_out/$mm_label.out" "$mm_out/$mm_label.err"
