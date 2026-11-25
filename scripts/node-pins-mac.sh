#!/bin/bash
# The Mac node's install, its one administrator step (docs/superpowers/specs/2026-11-19-v2-node-on-macos.md, "The
# anchor"): writes the node's record of its builds' cdhashes, a file only root can change, which the node's checks read
# (NodePins). It does one thing: write the record for the build it is given, with the rows of the record already there
# carried forward verbatim (never recomputed from the builds folder, which any process of yours can write), printing
# first exactly what it will write and where; then one `sudo`, whose script is text inside this one, not a file.
#
# scripts/node-pins-mac.sh [--dry-run] [--record PATH] [--fresh] --build COMMIT HOST SERVER CLI
#   --build COMMIT HOST SERVER CLI  the installed build: its commit (40 lowercase hex digits) and the cdhashes (40
#                                   lowercase hex digits each, this Mac's slice, as `codesign -d -a <arch> -v` prints
#                                   CDHash=) of its vibeswitcher-host, vibeswitcher-server and vibeswitcher. The install
#                                   (install-node-mac.sh) passes the values it read from the copies it signed and checked.
#   --record PATH                   where (default /Library/Application Support/VibeSwitcher/node-<uid>.pins, the node's;
#                                   another path is for a trial: the node reads only the default)
#   --fresh                         write only the given build, dropping the record that is there (when it can't be
#                                   carried: it isn't one this step wrote, or isn't root's alone)
#   --dry-run                       print what would be written and where, write nothing, ask for no password
#
# The record: `# …` once, `format 1`, `uid <uid>`, then `build <commit> host <cdhash> server <cdhash> cli <cdhash>` for
# the given build first and the carried ones after it, at most 16, no commit and no cdhash twice. A commit already in the
# record with other cdhashes is refused (a build's pins never change). As root, the step checks every folder from / down
# to the record's (each root's, writable by neither its group nor others, no link, no ACL), makes the last one when it
# is missing (root:wheel 0755), writes a temporary file in it, makes it root:wheel 0644 and renames it over the record.
#
# Exit codes: 0 written (or printed, --dry-run); 64 usage; 65 the record there can't be carried (see --fresh); 1 the
# write failed or was refused (sudo's password not given, a folder not root's alone).
#
# install-node-mac.sh checks this script against the commit's blob and runs it from memory (`bash -c`), as it does its
# libraries, so what sudo runs isn't a file a session could have edited. Nothing here reads PATH.
node_pins_main() {
    builtin unset -v BASH_ENV ENV CDPATH GLOBIGNORE
    IFS=$' \t\n'
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    set -u -o pipefail
    local name=node-pins-mac
    fail() { printf '%s: %s\n' "$name" "$2" >&2; exit "$1"; }

    local dry_run=0 fresh=0 record="" commit="" host="" server="" cli=""
    while (( $# )); do
        case $1 in
            --dry-run) dry_run=1; shift ;;
            --fresh) fresh=1; shift ;;
            --record) (( $# >= 2 )) && [[ -n $2 ]] || fail 64 "--record needs a path"; record=$2; shift 2 ;;
            --build)
                (( $# >= 5 )) || fail 64 "--build needs COMMIT HOST SERVER CLI"
                [[ -z $commit ]] || fail 64 "one --build only"
                commit=$2 host=$3 server=$4 cli=$5
                shift 5 ;;
            -h|--help) /usr/bin/sed -n '2,31p' "${BASH_SOURCE[0]:-/dev/null}" 2> /dev/null | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
            *) fail 64 "unknown argument $1 (usage: node-pins-mac.sh [--dry-run] [--record PATH] [--fresh] --build COMMIT HOST SERVER CLI)" ;;
        esac
    done
    [[ -n $commit ]] || fail 64 "usage: node-pins-mac.sh [--dry-run] [--record PATH] [--fresh] --build COMMIT HOST SERVER CLI"
    local hex='^[0-9a-f]{40}$' value
    for value in "$commit" "$host" "$server" "$cli"; do
        [[ $value =~ $hex ]] || fail 64 "$value isn't 40 lowercase hex digits"
    done
    [[ $(/usr/bin/uname -s) == Darwin ]] || fail 64 "this is the Mac's step: Linux keeps no such record"
    local uid
    uid=$(/usr/bin/id -u) || fail 1 "can't read your uid"
    [[ $uid =~ ^[0-9]+$ && $uid != 0 ]] || fail 64 "run it as yourself, not as root: it asks for the password itself"
    [[ -n $record ]] || record="/Library/Application Support/VibeSwitcher/node-$uid.pins"
    [[ $record == /* && $record != */ && $record != *//* && $record != */./* && $record != */../* && $record != *$'\n'* ]] \
        || fail 64 "--record must be an absolute path to a file, with no ., .. or empty part: $record"
    local folder=${record%/*}
    [[ -n $folder && $folder != / ]] || fail 64 "--record must be in a folder below /"

    # The rows already there, carried forward when the record is root's alone and one this step wrote.
    local carried=() line
    if (( ! fresh )) && [[ -e $record || -L $record ]]; then
        local walked="" part why=""
        local IFS=/
        set -f
        local parts=($record)
        set +f
        IFS=$' \t\n'
        for part in "" "${parts[@]:1}"; do
            walked=${walked%/}/$part
            [[ -n $part ]] || walked=/
            if [[ -L $walked ]]; then why="$walked is a symbolic link"; break; fi
            local facts
            facts=$(/usr/bin/stat -f '%u %Lp' -- "$walked") || { why="$walked can't be read"; break; }
            local owner=${facts% *} mode=${facts#* }
            if [[ $owner != 0 ]]; then why="$walked is owned by uid $owner, not root"; break; fi
            if (( 8#$mode & 8#022 )); then why="$walked is writable by its group or others (mode $mode)"; break; fi
            if [[ -n $(/bin/ls -lde -- "$walked" | /usr/bin/tail -n +2) ]]; then why="$walked carries an access control list"; break; fi
        done
        [[ -z $why ]] || fail 65 "the record there isn't root's alone ($why): pass --fresh to write only the given build"
        [[ -f $record ]] || fail 65 "$record isn't a regular file: pass --fresh to write only the given build"
        local seen_format=0 seen_uid=0
        while IFS= read -r line || [[ -n $line ]]; do
            case $line in
                '#'*) ;;
                'format 1') (( ! seen_format && ! seen_uid && ${#carried[@]} == 0 )) || fail 65 "the record there has its format line out of place: pass --fresh"; seen_format=1 ;;
                "uid $uid") (( seen_format && ! seen_uid )) || fail 65 "the record there has its uid line out of place: pass --fresh"; seen_uid=1 ;;
                *)
                    [[ $line =~ ^build\ [0-9a-f]{40}\ host\ [0-9a-f]{40}\ server\ [0-9a-f]{40}\ cli\ [0-9a-f]{40}$ ]] && (( seen_uid )) \
                        || fail 65 "the record there has a line this step doesn't write (${line:0:120}): pass --fresh"
                    carried+=("$line") ;;
            esac
        done < "$record"
        (( seen_uid )) || fail 65 "the record there names no uid $uid: pass --fresh"
    fi

    # The new record: the given build first, then the carried ones (another row for the same commit only if identical).
    local given="build $commit host $host server $server cli $cli"
    local rows=("$given") dropped=0
    for line in "${carried[@]+"${carried[@]}"}"; do
        if [[ $line == "build $commit "* ]]; then
            [[ $line == "$given" ]] || fail 65 "the record already pins $commit with other cdhashes (${line#build "$commit" }): a build's pins never change"
            continue
        fi
        if (( ${#rows[@]} >= 16 )); then dropped=$((dropped + 1)); continue; fi
        rows+=("$line")
    done
    local repeated
    repeated=$(printf '%s\n' "${rows[@]}" | /usr/bin/awk '{ print $4; print $6; print $8 }' | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/head -n 1)
    [[ -z $repeated ]] || fail 65 "the cdhash $repeated would be pinned twice"
    local content
    content="# VibeSwitcher node pins: written by the install's administrator step (scripts/node-pins-mac.sh); read by the node's checks
format 1
uid $uid
$(printf '%s\n' "${rows[@]}")
"

    printf '%s: will write %s (root:wheel 0644; its folder %s root:wheel 0755, every folder above it root'"'"'s alone):\n' "$name" "$record" "$folder"
    printf '%s' "$content" | /usr/bin/sed 's/^/    /'
    (( dropped == 0 )) || printf '%s: %s older build(s) dropped (16 at most): a rollback to one is refused until it is installed again\n' "$name" "$dropped"
    if (( dry_run )); then
        printf '%s: --dry-run: nothing written, no password asked\n' "$name"
        return 0
    fi

    # As root: the script is this text, the record's path and content its arguments.
    local as_root='
        set -u
        record=$1 content=$2
        folder=${record%/*}
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        refuse() { printf "node-pins-mac (as root): %s\n" "$1" >&2; exit 1; }
        root_alone() {
            [[ -L $1 ]] && refuse "$1 is a symbolic link"
            [[ -d $1 ]] || refuse "$1 is not a folder"
            facts=$(/usr/bin/stat -f "%u %Lp" -- "$1") || refuse "$1 can'"'"'t be read"
            owner=${facts%% *}
            mode=${facts##* }
            [[ $owner == 0 ]] || refuse "$1 is owned by uid $owner, not root"
            if (( 8#$mode & 8#022 )); then refuse "$1 is writable by its group or others (mode $mode)"; fi
            [[ -z $(/bin/ls -lde -- "$1" | /usr/bin/tail -n +2) ]] || refuse "$1 carries an access control list"
            return 0
        }
        walked=/
        root_alone /
        IFS=/
        set -f
        parts=($folder)
        set +f
        IFS=$'"'"' \t\n'"'"'
        for part in "${parts[@]:1}"; do
            walked=${walked%/}/$part
            if [[ $walked == "$folder" && ! -e $walked && ! -L $walked ]]; then
                /bin/mkdir -m 755 -- "$walked" && /usr/sbin/chown root:wheel -- "$walked" || refuse "can'"'"'t make $walked"
            fi
            root_alone "$walked"
        done
        [[ -d $record && ! -L $record ]] && refuse "$record is a folder"
        temporary=$(/usr/bin/mktemp "$folder/.node-pins.XXXXXX") || refuse "can'"'"'t make a temporary file in $folder"
        printf "%s" "$content" > "$temporary" \
            && /usr/sbin/chown root:wheel -- "$temporary" && /bin/chmod 0644 -- "$temporary" \
            && /bin/mv -f -h -- "$temporary" "$record" \
            || { /bin/rm -f -- "$temporary"; refuse "can'"'"'t write $record"; }
        printf "node-pins-mac: written %s\n" "$record"
    '
    printf '%s: asking for an administrator'"'"'s password (sudo) to write it\n' "$name"
    /usr/bin/sudo /bin/bash -c "$as_root" node-pins-root "$record" "$content" || fail 1 "the record wasn't written (above)"
    # What a reader sees afterwards.
    /bin/ls -lde -- "$folder" "$record"
}
node_pins_main "$@"
