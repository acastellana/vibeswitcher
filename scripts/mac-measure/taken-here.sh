#!/bin/bash
# The measurements of docs/process/v2-mac-measurements.md that need no one at the Mac (M2 to M8, M10), again: what an
# agent may run. Every process read is one this script started (its children, double-forked ones) or launchd's pid 1;
# nothing is shown on screen, nothing is loaded, no task port is taken, no port is bound. M10 writes a few entries
# into the unified log under a throwaway subsystem (dev.vibeswitcher.measure.<random>) and one with `logger`.
#
#   bash scripts/mac-measure/taken-here.sh      prints each measurement's lines, home and account name cut
source "$(dirname "$0")/lib.sh"
[[ $# == 0 ]] || mm_stop "no arguments"
mm_build > /dev/null
p=$mm_root/scripts/mac-measure/probes
b=$mm_bin
/usr/bin/clang -O1 -Wall -dynamiclib -o "$b/inject.dylib" "$p/inject.c" || mm_stop "inject didn't build"
/usr/bin/clang -O1 -Wall -o "$b/oslog" "$p/oslog.c" || mm_stop "oslog didn't build"
/usr/bin/clang -O1 -Wall -framework Security -framework CoreFoundation -o "$b/token-exec" "$p/token-exec.c" || mm_stop "token-exec didn't build"
/bin/cp "$b/facts" "$b/facts-hardened"
/usr/bin/codesign -s - -o runtime -f "$b/facts-hardened" 2> /dev/null || mm_stop "codesign failed"
reads='^(procargs|cs_status|responsible|bsdinfo=|coalition)'
{
echo "## M1  $(/usr/bin/csrutil status)"
echo "## M2-M5  environment, detach, coalition, responsible pid: target x relation, read by a sibling (plain) and by the hardened copy"
for target in "/bin/sleep 30" "$b/facts --sleep 30" "$b/facts-hardened --sleep 30"; do
    MEASURE_MARK=1 $target & pid=$!
    echo "== child: $target"; "$b/facts" --pid $pid | /usr/bin/grep -E "$reads"
    echo "   read by the hardened copy:"; "$b/facts-hardened" --pid $pid | /usr/bin/grep -E '^(procargs|coalition)'
    kill $pid; wait $pid 2> /dev/null || true
    pid=$(MEASURE_MARK=1 "$b/detach" $target)
    echo "== detached (double fork + setsid): $target"; "$b/facts" --pid "$pid" | /usr/bin/grep -E "$reads"
    kill "$pid"
done
echo "== this script's reader itself"; "$b/facts" | /usr/bin/grep -E '^(self|dev_tty|coalition|responsible)'
echo "## M6  DYLD_INSERT_LIBRARIES into the plain and the hardened copy"
for t in facts facts-hardened; do
    MEASURE_INJECTED=$mm_out/injected-$t DYLD_INSERT_LIBRARIES=$b/inject.dylib "$b/$t" --sleep 0
    echo "$t: marker=$([[ -f $mm_out/injected-$t ]] && echo injected || echo absent)"
done
/usr/bin/codesign -dv "$b/facts-hardened" 2>&1 | /usr/bin/grep -E '^CodeDirectory'
echo "## M7  the connect-write-exec race"
"$b/token-exec" "$tool_scratch/te.sock" "$b/facts-hardened"
echo "## M8  root's records (pid 1), a zombie"
"$b/facts" --pid 1 | /usr/bin/grep -E '^(bsdinfo|shortbsdinfo|kern_proc|procargs|coalition)'
"$b/facts" --zombie | /usr/bin/grep -E '^(zombie|bsdinfo|shortbsdinfo|kern_proc|procargs|coalition|cs_status)'
echo "## M10  the unified log: a copy, a link, exec -a, logger, and another program carrying oslog's UUID"
sub=dev.vibeswitcher.measure.$RANDOM$RANDOM
/bin/mkdir -p "$b/fakebin"
/bin/ln -s "$b/oslog" "$b/fakebin/vibeswitcher"
/bin/cp "$b/oslog" "$b/fakebin/vibeswitcher-copy"
/usr/bin/clang -O1 -DFORGER -o "$b/fakebin/forger" "$p/oslog.c" || mm_stop "the forger didn't build"
/usr/bin/python3 -I "$p/patch-uuid.py" "$b/oslog" "$b/fakebin/forger"
/usr/bin/codesign -s - -f "$b/fakebin/forger" 2> /dev/null
/usr/bin/cmp -s "$b/oslog" "$b/fakebin/forger" && mm_stop "the forger is oslog's bytes" || echo "forger: other bytes than oslog, same UUID: $(/usr/bin/dwarfdump --uuid "$b/fakebin/forger" | /usr/bin/awk '{print $2}')"
"$b/oslog" "$sub" plain
"$b/fakebin/vibeswitcher" "$sub" symlink
"$b/fakebin/vibeswitcher-copy" "$sub" copy
/bin/bash -c "exec -a /usr/local/bin/vibeswitcher '$b/oslog' $sub exec-a"
"$b/fakebin/forger" "$sub" forged 2> /dev/null
/usr/bin/logger -t vibeswitcher "logger-$sub"
/usr/bin/log show --last 2m --style ndjson --predicate "subsystem == \"$sub\" OR eventMessage CONTAINS \"logger-$sub\"" \
    | /usr/bin/python3 -I -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if line.startswith("{") and "eventMessage" in line:
        e = json.loads(line)
        print("message=%r processImagePath=%s senderImagePath=%s" % (e.get("eventMessage"), e.get("processImagePath"), e.get("senderImagePath")))
'
} > "$mm_out/taken.txt" 2>&1
/usr/bin/sed -e "s#$mm_root#<clone>#g" -e "s#$tool_scratch#<scratch>#g" -e "s#$HOME#~#g" -e "s#$(/usr/bin/id -un)#<user>#g" "$mm_out/taken.txt"
