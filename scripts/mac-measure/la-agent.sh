#!/bin/bash
# Measurement LA-1: LocalAuthentication's dialog asked by a LaunchAgent in gui/<uid>, as the node's server would ask it
# (the design's step 4; item 2 of "Before approvalMeasured flips": what the dialog shows first). Touch ID, then Cancel.
#
# Run in Terminal:  bash scripts/mac-measure/la-agent.sh        (--dry-run: build and check only, nothing shown)
# Look for: a system dialog appears; note its title line (the program's name, "la"), whether the reason
# "MEASURE-1 approve setting x to y" reads first or after the system's words, and whether Touch ID is offered.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build la
mm_new_label la-agent
mm_write_plist "$mm_bin/la" ask "MEASURE-1 approve setting x to y" 60
mm_say ""
mm_say "What happens next: a job $mm_label is loaded into your login session and asks LocalAuthentication once."
mm_say "A system dialog appears (Touch ID, or your login password) saying 'la is trying to MEASURE-1 approve setting x to y'."
mm_say "Do this: note the dialog's exact words (a screenshot helps), then touch Touch ID to approve."
mm_say "The job is booted out when this ends. Nothing else is changed."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$mm_out/$mm_label.out" '^outcome=' 90
mm_record "$mm_out/$mm_label.out" "$mm_out/$mm_label.err"
