# Sourced by the scripts that look at processes (test.sh's leftover check, test-under-load.sh's owners and stop):
# what they asked /bin/ps, pgrep and sysctl, with a way that still works inside Codex's sandbox.
#
# Codex runs a Codex worker's commands under its seatbelt (CODEX_SANDBOX=seatbelt), and there:
# - /bin/ps can't start: it's setuid root, and macOS starts no setuid program in a sandbox, whatever the profile allows
#   (`sandbox-exec -p '(version 1)(allow default)' /bin/ps` fails too). Codex's launch settings can't let it through.
# - pgrep can't list ("sysmon request failed … Cannot get process list"), and the sysctl command fails on every name
#   ("sysctl fmt -1 1024 1: Operation not permitted": it asks for each name's format first), though the profile
#   allows reading hw.ncpu and vm.loadavg themselves.
# - libproc (proc_listallpids, proc_pidinfo, proc_pidpath) and KERN_PROCARGS2 answer, for the processes in the same
#   sandbox: every process a command there starts, the run's own. That's what the fallback below reads, with
#   /usr/bin/python3 (the Command Line Tools', which swift needs too).
# On 2026-11-02 a Codex worker's scripts/test.sh printed "env: /bin/ps: Operation not permitted" twice, and its
# leftover check found nothing whatever was left.

# Set on Linux (uname -s), where a script asks some of this in other words; empty on the Mac, where nothing changes.
on_linux=""
[[ $(uname -s) == Linux ]] && on_linux=1

# The python that reads libproc: one line a process, "pid ppid stat command", the command as ps -wwE gives it (its
# arguments, then its environment). stat is ps's first letter: Z for a zombie, else R, S, T or I. Only the processes it
# may read (in a sandbox, its own sandbox's); a zombie, whose arguments are gone, shows its name.
processes_python='
import ctypes, struct, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
count = libc.proc_listallpids(None, 0)
pids = (ctypes.c_int * (count + 64))()
count = libc.proc_listallpids(pids, ctypes.sizeof(pids))
if count <= 0:
    sys.exit(1)
info = ctypes.create_string_buffer(136)
args = ctypes.create_string_buffer(1 << 20)
out = []
for pid in pids[:count]:
    if pid <= 0 or libc.proc_pidinfo(pid, 3, 0, info, 136) != 136:
        continue
    status, ppid = struct.unpack_from("<I", info.raw, 4)[0], struct.unpack_from("<I", info.raw, 16)[0]
    name = info.raw[48:64].split(b"\0")[0]
    stat = {1: "I", 2: "R", 3: "S", 4: "T", 5: "Z"}.get(status, "S")
    command = name
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(len(args))
    if stat != "Z" and libc.sysctl(mib, 3, args, ctypes.byref(size), None, 0) == 0 and size.value > 4:
        raw = args.raw[:size.value]
        rest = raw[4:].split(b"\0", 1)[1].lstrip(b"\0") if b"\0" in raw[4:] else b""
        words = [word for word in rest.split(b"\0") if word]
        if words:
            command = b" ".join(words)
    out.append(b"%d %d %s %s" % (pid, ppid, stat.encode(), command.replace(b"\n", b" ")))
sys.stdout.buffer.write(b"\n".join(out) + b"\n")
'

# Every process this may read, "pid ppid stat command" (the command with its environment, as `ps -wwE`), from /bin/ps
# with an empty environment, so it carries nothing of the caller's; where ps can't start (Codex's sandbox), from libproc
# above, with an empty environment too. Fails when neither answers.
processes() {
    local out status
    # Linux: procps' ps, whose `e` prints the environment after the command as the Mac's -E does. No libproc there.
    if [[ -n $on_linux ]]; then
        out=$(env -i PATH=/usr/bin:/bin ps axwwe -o pid=,ppid=,stat=,command= 2> /dev/null) && [[ -n $out ]] && printf '%s\n' "$out"
        return
    fi
    out=$(env -i PATH=/usr/bin:/bin /bin/ps -axwwE -o pid=,ppid=,stat=,command= 2> /dev/null)
    status=$?
    if (( status == 0 )) && [[ -n $out ]]; then
        printf '%s\n' "$out"
        return 0
    fi
    # In braces: bash's own word on a python killed by the sandbox ("Trace/BPT trap") goes to /dev/null too.
    { env -i PATH=/usr/bin:/bin /usr/bin/python3 -I -c "$processes_python"; } 2> /dev/null
}

# `ps -o FIELD= -p PID` for FIELD ppid, stat or comm (the executable's path, as ps gives it); fails when PID is gone.
# Where ps can't start, from `processes` (comm: its command's first word).
process_field() {
    local field=$1 pid=$2 out status
    out=$(/bin/ps -o "$field=" -p "$pid" 2> /dev/null)
    status=$?
    if ! ps_denied "$status"; then
        [[ -n $out ]] || return 1
        printf '%s\n' "$out" | sed 's/^ *//'
        return 0
    fi
    processes | awk -v pid="$pid" -v field="$field" '
        $1 == pid { found = 1; if (field == "ppid") print $2; else if (field == "stat") print $3; else print $4 }
        END { exit !found }'
}

# The pids whose parent is PID, one a line (`pgrep -P PID`); where pgrep can't list, from `processes`.
process_children() {
    local out status
    out=$(pgrep -P "$1" 2> /dev/null)
    status=$?
    if (( status <= 1 )); then
        [[ -n $out ]] && printf '%s\n' "$out"
        return 0
    fi
    processes | awk -v pid="$1" '$2 == pid { print $1 }'
}

# Whether ps's exit status $1 says it couldn't start (bash's 126 when exec is refused) rather than found no process.
ps_denied() { (( $1 == 126 || $1 == 127 )); }

# Whether PID is still there (kill -0). Inside Codex's sandbox a signal reaches only the sandbox's own processes: kill -0
# to another (the codex process a command's shell exec'd from, a run's owner) fails with "Operation not permitted",
# though it lives. Only "No such process" is gone.
process_alive() {
    local err
    # Linux: a zombie (ended, not yet waited for) is gone. kill -0 still reaches one, and an owner killed outright stays
    # one while its parent doesn't wait: Foundation there waits for a child only once every process it started has
    # closed the socket it inherited (the Mac's waits at once). Its state follows the name's last ")" in /proc.
    if [[ -n $on_linux ]]; then
        local stat
        stat=$(cat "/proc/$1/stat" 2> /dev/null) && [[ ${stat##*) } == Z* ]] && return 1
    fi
    err=$(kill -0 "$1" 2>&1) && return 0
    [[ $err != *"No such process"* ]]
}

# The Mac's cores (sysctl -n hw.ncpu); where the sysctl command fails, getconf's count.
cpu_count() {
    local n
    n=$(sysctl -n hw.ncpu 2> /dev/null)
    [[ $n =~ ^[0-9]+$ ]] || n=$(getconf _NPROCESSORS_ONLN 2> /dev/null)
    [[ $n =~ ^[0-9]+$ ]] && echo "$n"
}

# The 1-minute load average (sysctl -n vm.loadavg's first); where the sysctl command fails, uptime's.
load_one_minute() {
    local load
    load=$(sysctl -n vm.loadavg 2> /dev/null | awk '{ print $2 }')
    [[ -n $load ]] || load=$(uptime | sed -E 's/.*load averages?: *//' | tr ',' ' ' | awk '{ print $1 }')
    echo "$load"
}
