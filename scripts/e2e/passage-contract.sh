#!/bin/bash
# Does the installed Passage command line still match what VibeSwitcher assumes? VibeSwitcher runs `passage` only for
# wallet requests (Sources/VibeCore/PassageLink.swift, PassageCommand.swift; docs/protocol/wallet-request.md), and the
# contract is copied by hand there and into scripts/e2e/loop-passage, the stand-in the wallet e2e run uses. This
# compares both with the real binary's own `help` and `version`, and says exactly what drifted. Run on demand (never
# part of scripts/test.sh): Passage is a separate project that changes on its own.
#
# scripts/e2e/passage-contract.sh [--passage PATH] [--stand-in PATH] [--apps DIR:DIR…]
#   --passage PATH   the Passage to check, read as Settings › Wallet reads a path (PassageCommand.forPath): an app
#                    bundle (….app) runs its Contents/MacOS/Passage with `cli`; a file named `passage` runs as is; any
#                    other file runs with `cli` when it is, or links to, a binary inside an app bundle, else as is.
#                    Without it, found as PassageCommand.resolve finds it with an empty setting: the first executable
#                    `passage` on the PATH, else the first app bundle of --apps whose binary is executable.
#   --stand-in PATH  the stand-in whose help is compared (scripts/e2e/loop-passage).
#   --apps DIR:DIR…  the app bundles looked in after the PATH (/Applications/Passage.app:~/Applications/Passage.app);
#                    the test gives scratch ones.
#
# What it checks, one line each (`ok` or `DRIFT`):
#   - the version (`passage version` prints `passage <version>`; the version itself is shown, never judged)
#   - the commands and flags VibeSwitcher calls: send <peer> <file> --name N; inbox [peer] --json; listen;
#     peers --no-discovery --json; and that `send`, `inbox`, `listen` and `peers` take no other required argument
#   - the exit codes PassageLink reads: 0 ok, 1 failure, 2 usage, 3 not paired, 4 not reachable, 5 refused; a code
#     help lists beyond these is drift too (PassageLink would call it unexpected)
#   - the stand-in: each command its help lists takes the same arguments and options, in the same order, as the real
#     one (but `[--yes]`, which the stand-in refuses and neither app passes), and each exit code it lists means the same
# Help text it can't read (no usage line, no command lines, no exit-code sentence, an item that isn't `<code>
# <meaning>`) is drift, never a pass.
#
# What it can't check: help and version don't show the `sent<TAB><peer ID><TAB><name><TAB><bytes>` line of a send, the
# JSON shapes of `inbox --json`, `peers --json` and `listen`, or how any command behaves. Those are still compared by
# hand (Passage's README, "Command line").
#
# It runs the real binary with `help` and `version` only (`ask`, below): both are read-only and need no Keychain. It
# never sends, listens, lists peers or the inbox, or unpairs; it never touches Passage's pairings, Keychain items or
# inbox, and never uses the network.
#
# Exit: 0 everything matches; 1 drift (each difference on a DRIFT line); 3 no Passage found; 64 usage.
set -uo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/scripts/lib/scratch.sh"

passage_path=""
stand_in=$repo/scripts/e2e/loop-passage
apps="/Applications/Passage.app:$HOME/Applications/Passage.app"
while [[ $# -gt 0 ]]; do
    case $1 in
        --passage|--stand-in|--apps)
            [[ $# -ge 2 ]] || { echo "$1 needs a value (--help)"; exit 64; }
            case $1 in
                --passage) passage_path=$2 ;;
                --stand-in) stand_in=$2 ;;
                --apps) apps=$2 ;;
            esac
            shift 2 ;;
        -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        *) echo "unknown option $1 (--help)"; exit 64 ;;
    esac
done

# A regular file (a link followed) that can run: PassageCommand.isExecutableFile.
runnable() { [[ -f $1 && -x $1 ]]; }

# Where a link ends up, as far as it can be followed (the path itself when it's no link).
real_path() {
    local path=$1 target hops=0
    while [[ -L $path && $hops -lt 40 ]]; do
        target=$(readlink "$path") || break
        [[ $target == /* ]] && path=$target || path=$(dirname "$path")/$target
        hops=$((hops + 1))
    done
    printf '%s' "$path"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Sets $exe and $leading for a path, as PassageCommand.forPath does.
for_path() {
    local path=$1
    while [[ ${#path} -gt 1 && $path == */ ]]; do path=${path%/}; done
    exe=$path; leading=""
    if [[ $(lower "$path") == *.app ]]; then exe=$path/Contents/MacOS/Passage; leading=cli; return; fi
    [[ $(basename "$path") == passage ]] && return
    case "$(lower "$path") $(lower "$(real_path "$path")")" in
        *.app/contents/macos/*) leading=cli ;;
    esac
}

exe=""; leading=""; found_as=""
if [[ -n $passage_path ]]; then
    [[ $passage_path == /* ]] || { echo "--passage needs an absolute path"; exit 64; }
    for_path "$passage_path"
    found_as="--passage"
    runnable "$exe" || { echo "passage-contract: no Passage found: $exe isn't a file that can run"; exit 3; }
else
    # The first executable `passage` in the PATH's absolute folders (WalletAsk.WalletManager.onPath).
    IFS=: read -r -a folders <<<"${PATH:-}"
    for folder in ${folders[@]+"${folders[@]}"}; do
        [[ $folder == /* ]] || continue
        if runnable "$folder/passage"; then for_path "$folder/passage"; found_as="on the PATH"; break; fi
    done
    if [[ -z $found_as ]]; then
        IFS=: read -r -a bundles <<<"$apps"
        for bundle in ${bundles[@]+"${bundles[@]}"}; do
            if runnable "$bundle/Contents/MacOS/Passage"; then
                exe=$bundle/Contents/MacOS/Passage; leading=cli; found_as="the app, run with cli"; break
            fi
        done
    fi
    if [[ -z $found_as ]]; then
        echo "passage-contract: no Passage found: no passage on the PATH, and no ${apps//:/ or }. Give one with --passage PATH."
        exit 3
    fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/passage-contract.XXXXXX") || { echo "can't make a scratch folder"; exit 1; }
on_exit 'rm -rf "$work" </dev/null'

# The one place the real binary is run: `help` or `version`, nothing else, with no stdin and at most 20 s (perl's
# alarm stays set across exec, and ends a binary that opened a window in place of answering). Output in $work/$1.
ask() {
    case $1 in help|version) ;; *) echo "passage-contract: refusing to run passage $1"; exit 1 ;; esac
    # shellcheck disable=SC2086
    perl -e 'alarm 20; exec @ARGV or exit 127' "$exe" $leading "$1" </dev/null >"$work/$1" 2>"$work/$1.err"
}

drifts=0
checked=0
ok() { checked=$((checked + 1)); printf 'ok     %s\n' "$*"; }
drift() { checked=$((checked + 1)); drifts=$((drifts + 1)); printf 'DRIFT  %s\n' "$*"; }

# Reads a help text into lines of fields split by tabs:
#   usage                     the `usage: passage <command>` line is there
#   cmd <name> <synopsis>     a command line: two spaces, the name, its arguments, then (after two or more spaces, or on
#                             the next line) what it does
#   exit <code> <meaning>     an item of the `Exit codes:` sentence, anything in parentheses dropped
#   bad <text>                an item of that sentence that isn't `<code> <meaning>`
parse_help() {
    awk '
        /^usage: passage <command>/ { print "usage" }
        /^  [a-z]/ {
            line = substr($0, 3)
            cut = match(line, /   *|\t/)
            if (cut) line = substr(line, 1, cut - 1)
            sub(/ +$/, "", line)
            name = line
            sub(/ .*/, "", name)
            print "cmd\t" name "\t" line
        }
        { text = text " " $0 }
        END {
            at = index(text, "Exit codes:")
            if (!at) exit
            rest = substr(text, at + length("Exit codes:"))
            while (match(rest, /\([^)]*\)/)) rest = substr(rest, 1, RSTART - 1) substr(rest, RSTART + RLENGTH)
            stop = index(rest, ".")
            if (stop) rest = substr(rest, 1, stop - 1)
            count = split(rest, items, ",")
            for (i = 1; i <= count; i++) {
                item = items[i]
                gsub(/^[ \t]+|[ \t]+$/, "", item)
                gsub(/[ \t]+/, " ", item)
                if (item ~ /^[0-9]+ [^ ].*$/) {
                    code = item; sub(/ .*/, "", code)
                    meaning = item; sub(/^[0-9]+ /, "", meaning)
                    print "exit\t" code "\t" meaning
                } else print "bad\t" item
            }
        }
    ' "$1"
}

# The synopsis of command $2 in parsed help $1; several lines when help lists it more than once.
synopsis() { awk -F '\t' -v name="$2" '$1 == "cmd" && $2 == name { print $3 }' "$1"; }
# What exit code $2 means in parsed help $1; several lines when it's listed more than once.
meaning() { awk -F '\t' -v code="$2" '$1 == "exit" && $2 == code { print $3 }' "$1"; }

# A synopsis's arguments, one per line, the command's name left out: `[--name N]` is one.
tokens() {
    printf '%s\n' "$1" | awk '{
        token = ""
        for (i = 2; i <= NF; i++) {
            token = token == "" ? $i : token " " $i
            if (token ~ /^\[/ && token !~ /\]$/) continue
            print token
            token = ""
        }
        if (token != "") print token
    }'
}
# The arguments of a synopsis that aren't in brackets, on one line.
required() { tokens "$1" | grep -v '^\[' | tr '\n' ' ' | sed 's/ $//'; }
# Whether synopsis $1 has the argument $2, exactly.
has() { tokens "$1" | grep -qxF -- "$2"; }
# Whether synopsis $1 has an option $2 that takes a value: `[--name N]`.
has_valued() { tokens "$1" | grep -qE -- "^\[$2 [^] ]+\]$"; }

# Checks command $2 of parsed help $1 as VibeSwitcher calls it ($3, for the line): its required arguments are $4
# (alternatives split by `|` in $5 when given), and it has each of the remaining arguments; `--name=` means an option
# with a value.
check_command() {
    local parsed=$1 name=$2 call=$3 needs=$4 line wants problems="" got
    shift 4
    line=$(synopsis "$parsed" "$name")
    if [[ -z $line ]]; then drift "$call: help lists no \`$name\` command"; return; fi
    if [[ $line == *$'\n'* ]]; then drift "$call: help lists \`$name\` more than once"; return; fi
    got=$(required "$line")
    case "|$needs|" in
        *"|$got|"*) ;;
        *) problems="it requires \"$got\" where VibeSwitcher passes \"${needs%%|*}\"" ;;
    esac
    for wants in "$@"; do
        if [[ $wants == *= ]]; then
            has_valued "$line" "${wants%=}" || problems="${problems:+$problems; }no [${wants%=} <value>] option"
        else
            has "$line" "$wants" || problems="${problems:+$problems; }no $wants"
        fi
    done
    if [[ -n $problems ]]; then drift "$call: $problems in \`$line\`"; else ok "$call: \`$line\`"; fi
}

printf 'passage  %s%s (%s)\n' "$exe" "${leading:+ $leading}" "$found_as"

# The version.
ask version
status=$?
version_line=$(cat "$work/version")
if [[ $status -ne 0 ]]; then
    drift "version: \`passage version\` exited $status: $(head -1 "$work/version.err")"
elif [[ $version_line =~ ^passage\ ([0-9][0-9A-Za-z.+-]*)$ ]]; then
    ok "version: passage ${BASH_REMATCH[1]}"
else
    drift "version: \`passage version\` printed \"$(head -1 "$work/version")\", not \`passage <version>\`"
fi

# The real help.
ask help
status=$?
parse_help "$work/help" >"$work/real"
real_readable=""
if [[ $status -ne 0 ]]; then
    drift "help: \`passage help\` exited $status: $(head -1 "$work/help.err")"
elif ! grep -qx usage "$work/real"; then
    drift "help: no \`usage: passage <command>\` line: this help can't be read"
elif ! grep -q '^cmd' "$work/real"; then
    drift "help: no command lines under the usage line: this help can't be read"
else
    real_readable=1
    ok "help: $(grep -c '^cmd' "$work/real" | tr -d ' ') commands listed"
fi

if [[ -n $real_readable ]]; then
    # The commands and flags VibeSwitcher calls (PassageLink.send, .inbox, PassageListener; Settings › Wallet's peers).
    check_command "$work/real" send "send <peer> <file> --name N" "<peer> <file>|-|<peer> <file>" "<peer>" --name=
    check_command "$work/real" inbox "inbox [peer] --json" "" "[peer]" "[--json]"
    check_command "$work/real" listen "listen" ""
    check_command "$work/real" peers "peers --no-discovery --json" "" "[--no-discovery]" "[--json]"

    # The exit codes PassageLink.SendOutcome reads.
    if ! grep -q '^exit' "$work/real"; then
        drift "exit codes: no \`Exit codes:\` sentence: this help can't be read"
    else
        while IFS=$'\t' read -r _ item; do
            drift "exit codes: \"$item\" isn't \`<code> <meaning>\`: this help can't be read"
        done < <(grep '^bad' "$work/real")
        for expected in "0 ok" "1 failure" "2 usage" "3 not paired" "4 not reachable" "5 refused"; do
            code=${expected%% *}
            means=$(meaning "$work/real" "$code")
            if [[ -z $means ]]; then drift "exit $code: help doesn't list it (VibeSwitcher reads it as \"${expected#* }\")"
            elif [[ $means != "${expected#* }" ]]; then drift "exit $code: help says \"${means//$'\n'/\" and \"}\", VibeSwitcher reads it as \"${expected#* }\""
            else ok "exit $expected"; fi
        done
        while IFS=$'\t' read -r _ code means; do
            [[ $code =~ ^[0-5]$ ]] || drift "exit $code: help lists \"$means\", a code VibeSwitcher doesn't know"
        done < <(grep '^exit' "$work/real")
    fi
fi

# The stand-in's help (it wants a root and a side, and logs its call there: a scratch one).
mkdir "$work/loop"
LOOP_PASSAGE_ROOT=$work/loop LOOP_PASSAGE_SIDE=dev "$stand_in" help </dev/null >"$work/stand-in" 2>"$work/stand-in.err"
status=$?
parse_help "$work/stand-in" >"$work/loop-parsed"
shown=${stand_in#"$repo"/}
if [[ $status -ne 0 ]]; then
    drift "stand-in: \`$shown help\` exited $status: $(head -1 "$work/stand-in.err")"
elif ! grep -qx usage "$work/loop-parsed" || ! grep -q '^cmd' "$work/loop-parsed" || ! grep -q '^exit' "$work/loop-parsed" || grep -q '^bad' "$work/loop-parsed"; then
    drift "stand-in: $shown's help can't be read (its usage line, command lines or exit-code sentence)"
elif [[ -n $real_readable ]]; then
    for name in send inbox listen peers; do
        [[ -n $(synopsis "$work/loop-parsed" "$name") ]] || drift "stand-in $name: $shown's help lists no \`$name\` command"
    done
    while IFS=$'\t' read -r _ name line; do
        real_line=$(synopsis "$work/real" "$name")
        if [[ -z $real_line ]]; then drift "stand-in $name: $shown has it, passage's help doesn't"; continue; fi
        if [[ "$(tokens "$line")" == "$(tokens "$real_line" | grep -vxF -- '[--yes]')" ]]; then
            ok "stand-in $name: \`$line\`, as passage's"
        else
            drift "stand-in $name: $shown says \`$line\`, passage says \`${real_line//$'\n'/\` and \`}\`"
        fi
    done < <(grep '^cmd' "$work/loop-parsed")
    for code in 0 1 2 3 4; do
        [[ -n $(meaning "$work/loop-parsed" "$code") ]] || drift "stand-in exit $code: $shown's help doesn't list it"
    done
    while IFS=$'\t' read -r _ code means; do
        real_means=$(meaning "$work/real" "$code")
        if [[ $means == "$real_means" ]]; then ok "stand-in exit $code $means, as passage's"
        else drift "stand-in exit $code: $shown says \"$means\", passage says \"${real_means//$'\n'/\" and \"}\""; fi
    done < <(grep '^exit' "$work/loop-parsed")
else
    drift "stand-in: not compared: passage's help can't be read"
fi

if ((drifts > 0)); then
    echo "passage-contract: $drifts of $checked checks drifted (the DRIFT lines above)"
    exit 1
fi
echo "passage-contract: all $checked checks match"
