#!/bin/bash
# Measurement LA-6: what a second LocalAuthentication dialog does while one is open (two processes of the same job ask
# 3 s apart). The server allows one at a time itself (`Requests.approvalJudgment`); this is the system's own behaviour.
#
# Run in Terminal:  bash scripts/mac-measure/la-second.sh       (--dry-run: build and check only)
# Look for: whether the second dialog queues behind the first, replaces it, or fails at once; Cancel both.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build la
mm_new_label la-second
la=$mm_bin/la
mm_write_plist /bin/sh -c "'$la' ask 'MEASURE-6 FIRST dialog' 60 & /bin/sleep 3; '$la' ask 'MEASURE-6 SECOND dialog' 60; wait"
mm_say ""
mm_say "What happens next: two dialogs are asked 3 s apart ('MEASURE-6 FIRST', then 'MEASURE-6 SECOND')."
mm_say "Note what you see when the second comes, then Cancel each one."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$mm_out/$mm_label.out" '^outcome=' 150 2
mm_seen="when the second dialog came: did it wait behind the first, replace it, or appear beside it?"
mm_record "$mm_out/$mm_label.out" "$mm_out/$mm_label.err"
