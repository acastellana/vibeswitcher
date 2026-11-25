#!/bin/bash
# Measurement ESC-2: the escape `osascript -e 'tell application "Terminal" to do script …'`, from a detached process.
# macOS may ask whether to let the caller control Terminal (Automation): answer as you would for an unknown request
# (Don't Allow is fine: then the record says the escape needed consent, which is a measurement too).
#
# Run in Terminal:  bash scripts/mac-measure/escape-osascript.sh   (--dry-run: build and check only)
# Look for: whether any consent dialog appeared and whom it named; a new Terminal window running the facts (close it);
# the record's escaped block against yours.
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build
{ echo "== this script's own facts (your Terminal)"; "$mm_bin/facts"; } > "$mm_out/mine.txt"
mm_write_command "$tool_scratch/escape.command" "$mm_out/escaped.txt"
mm_say ""
mm_say "What happens next: a detached process runs  osascript -e 'tell application \"Terminal\" to do script \"$tool_scratch/escape.command\"'"
mm_say "If a consent dialog appears, note its words. Close the new window when it finishes."
mm_go "Ready?"
if [[ $mm_dry == 1 ]]; then mm_say "dry run done: nothing was run"; exit 0; fi
"$mm_bin/detach" /usr/bin/osascript -e "tell application \"Terminal\" to do script \"$tool_scratch/escape.command; exit\"" > /dev/null
mm_wait_soft "$mm_out/escaped.txt" '^== its chain' 90 \
    || echo "== nothing ran within 90 s: the escape was refused or needed a consent that wasn't given" > "$mm_out/escaped.txt"
mm_record "$mm_out/mine.txt" "$mm_out/escaped.txt"
