#!/bin/bash
# Measurement LA-7: whether a process of the user's can answer the dialog with synthetic keys (item 3: Accessibility
# driving the dialog). While a dialog from a LaunchAgent is open, a helper started from this Terminal posts ONE Escape
# key (never a password, never Return). If Terminal isn't trusted for Accessibility, macOS may ask whether to let it
# control the computer: DECLINE that (the measurement is what an untrusted process can do).
#
# Run in Terminal:  bash scripts/mac-measure/la-keys.sh         (--dry-run: build and check only)
# The Escape is posted only while the frontmost app is the system's authentication dialog (its bundle id one of
# DIALOGS below); otherwise nothing is posted and the record names what was in front (rerun with that id added if it
# is the dialog). Look for: accessibility_trusted=…; "keys: posted Escape at=T" followed by outcome=declined(…) with
# its at= within a second or two of T, while you touched nothing, means synthetic keys reach the dialog; a dialog
# that stays until you Cancel it means they don't.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build la
# The processes that draw LocalAuthentication's dialog (macOS 26-27): only while one of these is in front is a key posted.
DIALOGS=(com.apple.coreautha com.apple.LocalAuthentication.UIAgent com.apple.LocalAuthenticationRemoteService com.apple.SecurityAgent)
/usr/bin/swiftc -O -o "$mm_bin/keys" "$mm_root/scripts/mac-measure/probes/keys.swift" > "$mm_out/keys-swiftc.log" 2>&1 \
    || { cat "$mm_out/keys-swiftc.log" >&2; mm_stop "keys didn't build"; }
if [[ $mm_dry == 1 ]]; then mm_say "(dry run: would run  keys  to print whether Terminal is trusted for Accessibility)"; else "$mm_bin/keys" | tee "$mm_out/keys.txt"; fi
mm_new_label la-keys
mm_write_plist "$mm_bin/la" ask "MEASURE-7 can a key answer this" 30
mm_say ""
mm_say "What happens next: a dialog appears; about 3 s later a helper posts one Escape, only if the dialog is in front."
mm_say "Don't touch anything for 10 s. If the dialog is still there after that, click Cancel. Decline any 'control this computer' request."
mm_go "Ready?"
mm_bootstrap_and_start
mm_wait_for "$mm_out/$mm_label.out" '^asking' 30
/bin/sleep 3
"$mm_bin/keys" escape "${DIALOGS[@]}" | tee -a "$mm_out/keys.txt" || true
mm_wait_for "$mm_out/$mm_label.out" '^outcome=' 60
mm_seen="did the dialog close by itself a few seconds after it appeared, or did you Cancel it? Any 'control this computer' request (its words)?"
mm_record "$mm_out/keys.txt" "$mm_out/$mm_label.out" "$mm_out/$mm_label.err"
