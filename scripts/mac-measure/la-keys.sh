#!/bin/bash
# Measurement LA-7: whether a process of the user's can answer the dialog with synthetic keys (item 3: Accessibility
# driving the dialog). While a dialog from a LaunchAgent is open, a helper started from this Terminal posts ONE Escape
# key (never a password, never Return). If Terminal isn't trusted for Accessibility, macOS may ask whether to let it
# control the computer: DECLINE that (the measurement is what an untrusted process can do).
#
# Run in Terminal:  bash scripts/mac-measure/la-keys.sh         (--dry-run: build and check only)
# Look for: accessibility_trusted=…; whether the dialog closed by itself about 3 s after it appeared
# (outcome=declined("cancelled at the Mac") within ~4 s means synthetic keys reach it); if it stays, Cancel it yourself.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build la
/usr/bin/swiftc -O -o "$mm_bin/keys" "$mm_root/scripts/mac-measure/probes/keys.swift" > "$mm_out/keys-swiftc.log" 2>&1 \
    || { cat "$mm_out/keys-swiftc.log" >&2; mm_stop "keys didn't build"; }
"$mm_bin/keys" | tee "$mm_out/keys.txt"
mm_new_label la-keys
mm_write_plist "$mm_bin/la" ask "MEASURE-7 can a key answer this" 30
mm_say ""
mm_say "What happens next: a dialog appears; about 3 s later a helper posts Escape. Don't touch the dialog for 5 s."
mm_say "If it is still there after that, click Cancel. Decline any 'control this computer' request."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$mm_out/$mm_label.out" '^asking' 30
/bin/sleep 3
"$mm_bin/keys" escape | tee -a "$mm_out/keys.txt"
mm_wait_for "$mm_out/$mm_label.out" '^outcome=' 60
mm_record "$mm_out/keys.txt" "$mm_out/$mm_label.out" "$mm_out/$mm_label.err"
