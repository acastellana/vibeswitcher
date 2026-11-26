#!/bin/bash
# Measurement ANC-2: the same chain from an ssh login (item 11: through root's sshd-session). Needs Remote Login on
# (off on this Mac as of 2026-11-25: your call).
#
# Run from an ssh login:  bash scripts/mac-measure/ancestry-ssh.sh   (--dry-run: build only)
# Look for: every ancestor read by shortbsdinfo or kern_proc_pid; sshd-session (root) with bsdinfo=refused; and
# launchctl managername (Background, not Aqua: the LaunchAgent's LimitLoadToSessionType Aqua keeps the node out).
source "$(dirname "$0")/lib.sh"
mm_arguments "$@"
mm_users_terminal
if [[ $mm_dry == 0 && -z ${SSH_CONNECTION:-} ]]; then mm_stop "SSH_CONNECTION isn't set: run this from an ssh login"; fi
mm_build
if [[ $mm_dry == 1 ]]; then mm_say "dry run done: nothing read"; exit 0; fi
{ echo "managername=$(/bin/launchctl managername 2>&1)"; mm_chain $$; } > "$mm_out/chain.txt"
mm_record "$mm_out/chain.txt"
