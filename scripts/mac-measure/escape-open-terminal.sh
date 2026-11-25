#!/bin/bash
# Measurement ESC-1: the escape `open -a Terminal x.command`, made the way a session's process would make it (from a
# process that double-forked and called setsid first). What the new window's shell looks like to the voice rule:
# its parent chain, terminal, coalition and responsible pid, beside this script's own (your Terminal's) facts.
#
# Run in Terminal:  bash scripts/mac-measure/escape-open-terminal.sh   (--dry-run: build and check only)
# Look for: a new Terminal window opens, runs for a moment and says [Process completed]; close it. Then compare the
# record's two blocks: if the escaped shell's coalition, terminal kind and chain look like yours, the escape is
# indistinguishable by process facts (what the design expects).
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
mm_build
{ echo "== this script's own facts (your Terminal)"; "$mm_bin/facts"; } > "$mm_out/mine.txt"
mm_write_command "$tool_scratch/escape.command" "$mm_out/escaped.txt"
mm_say ""
mm_say "What happens next: a detached process runs  open -a Terminal $tool_scratch/escape.command"
mm_say "A new Terminal window opens and runs it; close that window when it says the process completed."
mm_go "Ready?"
if [[ $mm_dry == 1 ]]; then mm_say "dry run done: nothing was opened"; exit 0; fi
"$mm_bin/detach" /usr/bin/open -a Terminal "$tool_scratch/escape.command" > /dev/null
mm_wait_for "$mm_out/escaped.txt" '^== its chain' 60
mm_record "$mm_out/mine.txt" "$mm_out/escaped.txt"
