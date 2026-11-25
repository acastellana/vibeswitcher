#!/bin/bash
# Measurement ESC-3: the escape by launchd itself: a session's process bootstraps a job of its own into gui/<uid>
# (`launchctl bootstrap`, which needs no consent). What the job's process looks like: its parent (launchd), terminal
# (none), coalition (a new one?) and responsible pid. Throwaway label, booted out at the end.
#
# Run in Terminal:  bash scripts/mac-measure/escape-launchctl.sh   (--dry-run: build and check only)
# Look for: nothing on screen. The record's job block: ppid=1, tty none, its coalition against yours.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build
{ echo "== this script's own facts (run from: $(mm_where))"; "$mm_bin/facts"; } > "$mm_out/mine.txt"
mm_new_label escape-launchctl
mm_write_plist "$mm_bin/facts"
mm_say ""
mm_say "What happens next: job $mm_label is loaded into gui/$mm_uid, runs the facts probe once, and is booted out."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$mm_out/$mm_label.out" '^responsible=' 30
mm_record "$mm_out/mine.txt" "$mm_out/$mm_label.out" "$mm_out/$mm_label.err"
