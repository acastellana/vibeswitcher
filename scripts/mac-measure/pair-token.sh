#!/bin/bash
# K-M1 of the keeper's design (docs/superpowers/specs/2026-11-27-v2-mac-keeper-design.md, "Measurements owed"): what a
# received pair end's LOCAL_PEERTOKEN names in KP10's order, and Security's answer for it; the names of a pair's ends
# and a connection's; the token and poll(2) once the other end is closed or shut; a connection's token after a process
# holding a copy of the connecting socket writes last. What an agent may run, as taken-here.sh: every process read is
# one this script started (its children and theirs); nothing is shown on screen, nothing is loaded, no task port is
# taken (each process reads its own audit token), no port is bound (one Unix socket in the scratch folder), no sudo.
# The probe (probes/pair-token.c) is ad hoc signed with the Hardened Runtime; its makers exec facts-hardened, the
# measurements' hardened image (M6, M7), and, for the second part ((g) to (o), the proof's redesign), pair-image
# (probes/pair-image.c), a hardened image that acts on its descriptors, signed under its own identifier so its cdhash is
# neither's. Neither is the node's host: a copy of the host started bare could touch the account's ~/.vibeswitcher.
# The third part (K-M16's here part and D1, 2026-11-27) adds PLAIN (pair-image as linked, not hardened), BIG
# (pair-image with a 256 MiB section of random bytes, hardened) and WINDOW (probes/window-image.swift, hardened): the
# probe names exception ports for its own children with a port it never receives on, each child reports what it finds
# on itself, and nothing is raised, received or answered.
#
#   bash scripts/mac-measure/pair-token.sh               every part; prints the probe's lines, home, account name and
#                                                        scratch folder cut
#   bash scripts/mac-measure/pair-token.sh --a-routes    the third part alone
source "$(dirname "$0")/lib.sh"
only_a=0
case "${1:-}" in
    "") ;;
    --a-routes) only_a=1 ;;
    *) mm_stop "the only argument is --a-routes" ;;
esac
[[ $# -le 1 ]] || mm_stop "one argument at most"
mm_build > /dev/null
p=$mm_root/scripts/mac-measure/probes
b=$mm_bin
/usr/bin/clang -O1 -Wall -framework Security -framework CoreFoundation -o "$b/pair-token" "$p/pair-token.c" || mm_stop "pair-token didn't build"
/usr/bin/codesign -s - -o runtime -f "$b/pair-token" 2> /dev/null || mm_stop "codesign failed"
/usr/bin/clang -O1 -Wall -o "$b/pair-image" "$p/pair-image.c" || mm_stop "pair-image didn't build"
/usr/bin/codesign -s - -o runtime -i dev.vibeswitcher.measure.pair-image -f "$b/pair-image" 2> /dev/null || mm_stop "codesign failed"
/bin/cp "$b/facts" "$b/facts-hardened"
/usr/bin/codesign -s - -o runtime -f "$b/facts-hardened" 2> /dev/null || mm_stop "codesign failed"
/usr/bin/clang -O1 -Wall -o "$b/pair-image-plain" "$p/pair-image.c" || mm_stop "pair-image-plain didn't build"
/bin/dd if=/dev/urandom of="$b/big.bin" bs=1048576 count=256 2> /dev/null || mm_stop "dd failed"
/usr/bin/clang -O1 -Wall -Wl,-sectcreate,__BIG,__big,"$b/big.bin" -o "$b/pair-image-big" "$p/pair-image.c" || mm_stop "pair-image-big didn't build"
/usr/bin/codesign -s - -o runtime -i dev.vibeswitcher.measure.pair-image-big -f "$b/pair-image-big" 2> /dev/null || mm_stop "codesign failed"
/usr/bin/swiftc -O -module-cache-path "$tool_scratch/swift-cache" -o "$b/window-image" "$p/window-image.swift" 2> /dev/null || mm_stop "window-image didn't build"
/usr/bin/codesign -s - -o runtime -i dev.vibeswitcher.measure.window-image -f "$b/window-image" 2> /dev/null || mm_stop "codesign failed"
third=("$b/pair-image" "$b/pair-image-plain" "$b/pair-image-big" "$b/window-image")
{
if [[ $only_a == 1 ]]; then what="K-M16, here (pair-token.sh --a-routes)"; else what="K-M1 and K-M16, here"; fi
echo "## $what  $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion)), $(/usr/bin/csrutil status)"
/usr/bin/codesign -dv "$b/pair-token" 2>&1 | /usr/bin/grep -E '^CodeDirectory' | /usr/bin/sed 's/^/pair-token: /'
/usr/bin/codesign -dv "$b/facts-hardened" 2>&1 | /usr/bin/grep -E '^CodeDirectory' | /usr/bin/sed 's/^/PROGRAM (facts-hardened): /'
/usr/bin/codesign -dv "$b/pair-image" 2>&1 | /usr/bin/grep -E '^CodeDirectory' | /usr/bin/sed 's/^/IMAGE (pair-image): /'
/usr/bin/codesign -dv "$b/pair-image-plain" 2>&1 | /usr/bin/grep -E '^CodeDirectory' | /usr/bin/sed 's/^/PLAIN (pair-image, as linked): /'
/usr/bin/codesign -dv "$b/pair-image-big" 2>&1 | /usr/bin/grep -E '^CodeDirectory' | /usr/bin/sed 's/^/BIG (pair-image with 256 MiB): /'
/usr/bin/codesign -dv "$b/window-image" 2>&1 | /usr/bin/grep -E '^CodeDirectory' | /usr/bin/sed 's/^/WINDOW (window-image.swift): /'
if [[ $only_a == 1 ]]; then
    "$b/pair-token" --a-routes "${third[@]}"
else
    "$b/pair-token" "$tool_scratch/k.sock" "$b/facts-hardened" "${third[@]}"
fi
} > "$mm_out/pair-token.txt" 2>&1
/usr/bin/sed -e "s#$mm_root#<clone>#g" -e "s#$tool_scratch#<scratch>#g" -e "s#$HOME#~#g" -e "s#$(/usr/bin/id -un)#<user>#g" "$mm_out/pair-token.txt"
