# Sourced by mm_chain (scripts/mac-measure/lib.sh) and by the .command files the escape measurements write
# (mm_write_command): prints the facts of PID ($2) and each ancestor up to launchd, with the probe in $1, then
# launchd's. Reads only.
mm_bin=$1
pid=$2
hops=0
while [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 && hops < 16 )); do
    printf -- '-- ancestor %d: ' "$hops"
    "$mm_bin/facts" --pid "$pid" VIBESWITCHER_SESSION
    parent=$("$mm_bin/facts" --pid "$pid" | /usr/bin/sed -n 's/^shortbsdinfo=read ppid=\([0-9]*\).*/\1/p')
    [[ -n $parent ]] || parent=$("$mm_bin/facts" --pid "$pid" | /usr/bin/sed -n 's/^kern_proc_pid=read ppid=\([0-9]*\).*/\1/p')
    pid=${parent:-0}
    hops=$((hops + 1))
done
printf -- '-- ancestor %d (launchd): ' "$hops"
"$mm_bin/facts" --pid 1
