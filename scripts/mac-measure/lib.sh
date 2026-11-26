# Sourced by each scripts/mac-measure/*.sh: the design's step 4 measurements that need the user at the Mac
# (docs/process/v2-mac-measurements.md says what each is for). Each script does one thing, says what will appear on
# screen before it happens, and fails closed: an unexpected state stops it, saying what it found.
#
# What these never do: load or touch dev.vibeswitcher.node, write ~/Library/LaunchAgents, ~/.vibeswitcher or the
# Keychain, start the user's node, or bind a port. A job they load has a label of their own
# (dev.vibeswitcher.measure.<what>.<pid>), a property list in their scratch folder, and is booted out when the script
# ends, Ctrl-C too. A job that asks LocalAuthentication is never booted out while its ask is open: the script waits for
# the dialog to end (Cancel, or its own 60 s limit) and leaves the job loaded, naming the bootout line, if it doesn't
# (nothing kills a process inside an authentication call).
#
# Each real run saves its record in .build/mac-measure-records/<script>.txt of this checkout (git-ignored; the scratch
# folder is removed at the end), with a line of what the person saw, asked at the end; a run that stopped saves what it
# had as <script>.stopped.txt.
#
# --dry-run (every script takes it): builds the probes, writes and checks the property list, prints what the real run
# would do, and stops before anything appears on screen or is loaded. It is what an agent may run; the real run refuses
# an agent's session and wants a terminal.

set -euo pipefail

mm_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../lib/scratch.sh
source "$mm_root/scripts/lib/scratch.sh"
scratch_tmpdir mac-measure
mm_bin=$tool_scratch/bin
mm_out=$tool_scratch/out
mkdir -m 700 "$mm_bin" "$mm_out"
mm_dry=0
mm_label=""
mm_plist=""
mm_loaded=0
mm_asks=0
mm_saved=0
mm_seen=""
mm_uid=$(/usr/bin/id -u)
mm_name=$(/usr/bin/basename "$0" .sh)
mm_records=$mm_root/.build/mac-measure-records

mm_say() { printf '%s\n' "$*"; }
mm_stop() { printf 'STOPPED: %s\n' "$*" >&2; exit 1; }

# The arguments every script takes: --dry-run, nothing else.
mm_arguments() {
    case "${1:-}" in
        "") ;;
        --dry-run) mm_dry=1 ;;
        *) mm_stop "unknown argument ${1}: the only one is --dry-run" ;;
    esac
}

# The real run is the user's: at a terminal (Terminal.app, or a shell card the app's host started, whose shell carries
# VIBESWITCHER_SESSION and a pty), never from an agent's own process (Claude Code's or Codex's commands: CLAUDECODE,
# CODEX_SANDBOX), which could otherwise put a dialog on the user's screen without them knowing why. The Return prompt
# (mm_go) is the person's.
mm_users_terminal() {
    [[ $mm_dry == 1 ]] && return 0
    [[ -n ${CLAUDECODE:-} || -n ${CODEX_SANDBOX:-} ]] \
        && mm_stop "this runs from an agent's process (CLAUDECODE or CODEX_SANDBOX is set): run it yourself in Terminal or a shell card, or use --dry-run"
    [[ -t 0 && -t 1 ]] || mm_stop "no terminal on stdin and stdout: run it in Terminal or a shell card (or --dry-run)"
    [[ $(/usr/bin/uname -s) == Darwin ]] || mm_stop "not a Mac"
    on_exit mm_finish
}

# On every real run's exit (a stop and Ctrl-C too): the job booted out (once no ask is open), and what the run had
# saved as <script>.stopped.txt when it ended before its record.
mm_finish() {
    trap '' INT
    mm_bootout
    if [[ $mm_saved == 1 ]]; then return 0; fi
    local had=() file
    for file in "$mm_out"/*; do
        if [[ -f $file ]]; then had+=("$file"); fi
    done
    if (( ${#had[@]} == 0 )); then return 0; fi
    /bin/mkdir -p "$mm_records"
    { echo "== $mm_name: STOPPED before its record; what it had"; mm_scrub "${had[@]}"; } > "$mm_records/$mm_name.stopped.txt"
    printf 'what this run had is saved in %s\n' "${mm_records#"$mm_root"/}/$mm_name.stopped.txt" >&2
}

# The files' lines with the account's name and home taken out.
mm_scrub() {
    /usr/bin/sed -e "s#$HOME#~#g" -e "s#$(/usr/bin/id -un)#<user>#g" "$@"
}

# For a measurement of Terminal.app itself (its chain through login): refuses anywhere else, a shell card included.
mm_terminal_app() {
    [[ $mm_dry == 1 ]] && return 0
    [[ ${TERM_PROGRAM:-} == Apple_Terminal && -z ${VIBESWITCHER_SESSION:-} ]] \
        || mm_stop "this measures Terminal.app's own chain: run it in a Terminal.app window (TERM_PROGRAM is '${TERM_PROGRAM:-}'; a shell card of the app's isn't Terminal.app)"
}

# Where "your own facts" were read: Terminal.app, a shell card of the app's, or another terminal.
mm_where() {
    if [[ -n ${VIBESWITCHER_SESSION:-} ]]; then echo "a shell session of the app's host (a shell card)"
    else echo "${TERM_PROGRAM:-an unknown terminal}"; fi
}

# Return goes on; anything else (or end of input) stops, nothing done. Dry runs don't ask.
mm_go() {
    [[ $mm_dry == 1 ]] && { mm_say "(dry run: would ask \"$*\" and wait for Return)"; return 0; }
    local answer
    printf '%s [Return goes on, anything else stops] ' "$*"
    IFS= read -r answer || mm_stop "no answer"
    [[ -z $answer ]] || mm_stop "stopped at your word"
}

# The probes, built from this checkout into the scratch folder: facts, detach (C), la (the node's own
# Sources/VibePlatform/Approval*.swift, unchanged). Ad hoc signed by the linker; nothing is installed.
mm_build() {
    local probes=$mm_root/scripts/mac-measure/probes
    for tool in /usr/bin/clang /usr/bin/swiftc /usr/bin/plutil /bin/launchctl /usr/bin/codesign; do
        [[ -x $tool ]] || mm_stop "$tool is missing"
    done
    /usr/bin/clang -O1 -Wall -o "$mm_bin/facts" "$probes/facts.c" || mm_stop "facts didn't build"
    /usr/bin/clang -O1 -Wall -o "$mm_bin/detach" "$probes/detach.c" || mm_stop "detach didn't build"
    if [[ ${1:-} == la ]]; then
        mm_asks=1
        /usr/bin/swiftc -O -parse-as-library -o "$mm_bin/la" "$probes/platform-stub.swift" \
            "$mm_root/Sources/VibePlatform/Approval.swift" "$mm_root/Sources/VibePlatform/Approval+Darwin.swift" \
            "$probes/la-main.swift" > "$mm_out/swiftc.log" 2>&1 || { cat "$mm_out/swiftc.log" >&2; mm_stop "la didn't build"; }
    fi
    mm_say "probes built in $mm_bin"
}

# A throwaway label for this run's job: never the node's, and not loaded already.
mm_new_label() {
    mm_label="dev.vibeswitcher.measure.$1.$$"
    [[ $mm_label == dev.vibeswitcher.node* ]] && mm_stop "refusing the node's label"
    if /bin/launchctl print "gui/$mm_uid/$mm_label" > /dev/null 2>&1; then
        mm_stop "gui/$mm_uid/$mm_label is loaded already: nothing done"
    fi
    return 0
}

# A LaunchAgent property list in the scratch folder (never ~/Library/LaunchAgents) for mm_label: the node's own shape
# (NodeAgent: ProcessType Interactive, LimitLoadToSessionType Aqua, KeepAlive false, RunAtLoad false), its program
# and arguments the given ones, stdout and stderr to the scratch folder, MEASURE_ASK=yes in its environment (a job
# inherits nothing from this shell, and `la ask` refuses without it). Checked with plutil.
mm_write_plist() {
    [[ -n $mm_label ]] || mm_stop "no label"
    mm_plist=$tool_scratch/$mm_label.plist
    local args="" arg
    for arg in "$@"; do args+="<string>$(printf '%s' "$arg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>"; done
    cat > "$mm_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$mm_label</string>
    <key>ProgramArguments</key><array>$args</array>
    <key>RunAtLoad</key><false/>
    <key>KeepAlive</key><false/>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>EnvironmentVariables</key><dict><key>MEASURE_ASK</key><string>yes</string></dict>
    <key>StandardOutPath</key><string>$mm_out/$mm_label.out</string>
    <key>StandardErrorPath</key><string>$mm_out/$mm_label.err</string>
</dict>
</plist>
PLIST
    /usr/bin/plutil -lint "$mm_plist" > /dev/null || mm_stop "the property list doesn't parse: $mm_plist"
    case $mm_plist in "$HOME/Library/LaunchAgents/"*) mm_stop "the property list landed in ~/Library/LaunchAgents" ;; esac
    mm_say "property list: $mm_plist (plutil: OK)"
}

# Whether the job has a running process (`pid = ` one tab in, as AG-1 reads launchctl print).
mm_job_running() {
    /bin/launchctl print "gui/$mm_uid/$mm_label" 2> /dev/null | /usr/bin/grep -qE '^	pid = [0-9]+'
}

mm_bootout() {
    [[ $mm_loaded == 1 ]] || return 0
    # A job that asks LocalAuthentication is booted out only once its process has ended: never while a dialog is open
    # (bootout would kill it inside the authentication call). The ask ends by itself within its limit (60 s at most,
    # then 5 s to take the dialog down); 80 s is past every script's. If it hasn't ended, the job is left loaded.
    if [[ $mm_asks == 1 ]] && mm_job_running; then
        mm_say "A dialog may still be open: Cancel it (or leave it: it ends by itself within 60 s). Waiting for it to end before the job is booted out."
        local waited=0
        while mm_job_running && (( waited < 160 )); do
            /bin/sleep 0.5
            waited=$((waited + 1))
        done
        if mm_job_running; then
            printf 'WARNING: gui/%s/%s still runs its ask after 80 s: left loaded, not killed. Once no dialog is on screen, run  launchctl bootout gui/%s/%s\n' "$mm_uid" "$mm_label" "$mm_uid" "$mm_label" >&2
            mm_loaded=0
            return 0
        fi
    fi
    /bin/launchctl bootout "gui/$mm_uid/$mm_label" > /dev/null 2>&1 || true
    if /bin/launchctl print "gui/$mm_uid/$mm_label" > /dev/null 2>&1; then
        printf 'WARNING: gui/%s/%s is still loaded: run  launchctl bootout gui/%s/%s\n' "$mm_uid" "$mm_label" "$mm_uid" "$mm_label" >&2
    else
        mm_say "booted out gui/$mm_uid/$mm_label"
    fi
    mm_loaded=0
}

# Loads the job into the login session (gui/<uid>) and starts it once. Dry runs stop here.
mm_bootstrap_and_start() {
    if [[ $mm_dry == 1 ]]; then
        mm_say "(dry run: would run  launchctl bootstrap gui/$mm_uid $mm_plist  then  launchctl kickstart gui/$mm_uid/$mm_label)"
        mm_say "dry run done: nothing was loaded or shown"
        exit 0
    fi
    # mm_finish (on exit, from mm_users_terminal) boots it out.
    /bin/launchctl bootstrap "gui/$mm_uid" "$mm_plist" || mm_stop "launchctl bootstrap refused the job"
    mm_loaded=1
    /bin/launchctl kickstart "gui/$mm_uid/$mm_label" || mm_stop "launchctl kickstart failed"
}

# Waits until FILE holds COUNT lines matching PATTERN (default 1), at most SECONDS (launchd appends a job's output, so a
# second start's lines follow the first's). Fails closed on the time, printing what the file holds.
mm_wait_for() {
    local file=$1 pattern=$2 seconds=$3 count=${4:-1} waited=0 seen
    while :; do
        seen=$(/usr/bin/grep -cE "$pattern" "$file" 2> /dev/null || true)
        (( ${seen:-0} >= count )) && break
        if (( waited >= seconds * 2 )); then
            [[ -f $file ]] && cat "$file"
            mm_stop "$count line(s) matching '$pattern' not in $file after ${seconds}s"
        fi
        /bin/sleep 0.5
        waited=$((waited + 1))
    done
    return 0
}

# mm_wait_for's form that returns 1 on the time instead of stopping (a measurement whose "nothing came" is a result).
mm_wait_soft() {
    local file=$1 pattern=$2 seconds=$3 waited=0
    until /usr/bin/grep -qE "$pattern" "$file" 2> /dev/null; do
        (( waited >= seconds * 2 )) && return 1
        /bin/sleep 0.5
        waited=$((waited + 1))
    done
    return 0
}

# The record: the script's results, with the account's name and home taken out, then (when the script set mm_seen, its
# question) one line of what the person saw, typed here. Saved as .build/mac-measure-records/<script>.txt of this
# checkout (a run again replaces it) and printed.
mm_record() {
    local file=$mm_out/record.txt seen=""
    { echo "== $mm_name ($(/bin/date '+%Y-%m-%d %H:%M'), run from: $(mm_where))"; mm_scrub "$@"; } > "$file"
    if [[ -n $mm_seen ]]; then
        mm_say ""
        mm_say "One line for the record (never a password): $mm_seen"
        printf '> '
        IFS= read -r seen || seen=""
        printf 'seen: %s\n' "${seen:-(nothing typed)}" >> "$file"
    fi
    /bin/mkdir -p "$mm_records"
    /bin/cp "$file" "$mm_records/$mm_name.txt"
    /bin/rm -f "$mm_records/$mm_name.stopped.txt"
    mm_saved=1
    mm_say ""
    mm_say "---- the record (account name and home taken out) ----"
    cat "$file"
    mm_say "---- end of the record: saved in ${mm_records#"$mm_root"/}/$mm_name.txt ----"
}

# The facts of PID and of each of its ancestors up to launchd, as the voice rule would read them (Darwin ancestry:
# items 7 and 11). Reads only: proc_pidinfo, sysctl, csops.
mm_chain() {
    source "$mm_root/scripts/mac-measure/lib-chain.sh" "$mm_bin" "$1"
}

# A .command file that, run by Terminal, writes its own facts and its chain to OUT, then exits.
mm_write_command() {
    local file=$1 out=$2
    cat > "$file" <<COMMAND
#!/bin/bash
{ echo "== the escaped shell's own facts"; "$mm_bin/facts"; echo "== its chain"; } > "$out.tmp"
source "$mm_root/scripts/mac-measure/lib-chain.sh" "$mm_bin" \$\$ >> "$out.tmp" 2>&1
/bin/mv "$out.tmp" "$out"
exit 0
COMMAND
    /bin/chmod 700 "$file"
}
