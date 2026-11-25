#!/bin/bash
# Measurement LA-4: the dialog with the lid closed (clamshell: an external display and keyboard on, the MacBook's lid
# shut), where the built-in Touch ID sensor can't be reached. Without an external display a closed lid sleeps the Mac:
# then don't run this; the record says "not measured".
#
# Run in Terminal on the external display:  bash scripts/mac-measure/la-lid-closed.sh   (--dry-run: build and check only)
# Look for: what `la can` says with the lid closed (biometry available or not), then which route the dialog offers
# (password, an Apple Watch, or none), and the outcome.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build la
mm_new_label la-lid
mm_write_plist "$mm_bin/la" ask "MEASURE-4 approve with the lid closed" 60
mm_say ""
mm_say "First: close the lid now (external display and keyboard on), then press Return here."
mm_go "Lid closed?"
mm_say "What LocalAuthentication says with the lid closed (shows nothing):"
"$mm_bin/la" can | tee "$mm_out/can.txt"
mm_say "Next: a job $mm_label asks once. Approve with whatever the dialog offers (the password into the system dialog only)."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$mm_out/$mm_label.out" '^outcome=' 90
mm_record "$mm_out/can.txt" "$mm_out/$mm_label.out" "$mm_out/$mm_label.err"
