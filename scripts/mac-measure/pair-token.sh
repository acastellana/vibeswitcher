#!/bin/bash
# K-M1 of the keeper's design (docs/superpowers/specs/2026-11-27-v2-mac-keeper-design.md, "Measurements owed"): what a
# received pair end's LOCAL_PEERTOKEN names in KP10's order, and Security's answer for it; the names of a pair's ends
# and a connection's; the token and poll(2) once the other end is closed or shut; a connection's token after a process
# holding a copy of the connecting socket writes last. What an agent may run, as taken-here.sh: every process read is
# one this script started (its children and theirs); nothing is shown on screen, nothing is loaded, no task port is
# taken (each process reads its own audit token), no port is bound (one Unix socket in the scratch folder), no sudo.
# The probe (probes/pair-token.c) is ad hoc signed with the Hardened Runtime; its makers exec facts-hardened, the
# measurements' hardened image (M6, M7).
#
#   bash scripts/mac-measure/pair-token.sh      prints the probe's lines, home, account name and scratch folder cut
source "$(dirname "$0")/lib.sh"
[[ $# == 0 ]] || mm_stop "no arguments"
mm_build > /dev/null
p=$mm_root/scripts/mac-measure/probes
b=$mm_bin
/usr/bin/clang -O1 -Wall -framework Security -framework CoreFoundation -o "$b/pair-token" "$p/pair-token.c" || mm_stop "pair-token didn't build"
/usr/bin/codesign -s - -o runtime -f "$b/pair-token" 2> /dev/null || mm_stop "codesign failed"
/bin/cp "$b/facts" "$b/facts-hardened"
/usr/bin/codesign -s - -o runtime -f "$b/facts-hardened" 2> /dev/null || mm_stop "codesign failed"
{
echo "## K-M1  $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion)), $(/usr/bin/csrutil status)"
/usr/bin/codesign -dv "$b/pair-token" 2>&1 | /usr/bin/grep -E '^CodeDirectory' | /usr/bin/sed 's/^/pair-token: /'
/usr/bin/codesign -dv "$b/facts-hardened" 2>&1 | /usr/bin/grep -E '^CodeDirectory' | /usr/bin/sed 's/^/PROGRAM (facts-hardened): /'
"$b/pair-token" "$tool_scratch/k.sock" "$b/facts-hardened"
} > "$mm_out/pair-token.txt" 2>&1
/usr/bin/sed -e "s#$mm_root#<clone>#g" -e "s#$tool_scratch#<scratch>#g" -e "s#$HOME#~#g" -e "s#$(/usr/bin/id -un)#<user>#g" "$mm_out/pair-token.txt"
