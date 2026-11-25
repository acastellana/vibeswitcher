#!/bin/bash -p
# The Mac node's install, its one administrator step (docs/superpowers/specs/2026-11-19-v2-node-on-macos.md, "The
# anchor"): writes the node's record of its builds' cdhashes, a file only root can change, which the node's checks read
# (NodePins). It does one thing: write the record, printing first exactly what it will write and where; then one `sudo`,
# whose script is text inside this one, not a file, and which checks again, as root, the path and every line it writes.
#
# scripts/node-pins-mac.sh [--dry-run] [--record PATH] [--fresh] --build COMMIT HOST SERVER CLI
#   The install's form (install-node-mac.sh runs it from the commit's checked blob, under env -i): the installed build's
#   commit and the cdhashes (40 lowercase hex digits each, this Mac's slice) of its vibeswitcher-host,
#   vibeswitcher-server and vibeswitcher, as the install read them from the copies it signed and checked. The record's
#   rows already there are carried after it, verbatim (never recomputed from the builds folder, which any process of
#   yours can write); --fresh drops them. Never type these values by hand: read from the builds folder they are a
#   session's to choose. A record that is missing or names no running build is mended by installing a newer commit.
# scripts/node-pins-mac.sh [--dry-run] [--record PATH] --keep N
#   Takes no values: rewrites the record there, root's alone (checked again as root), keeping its first N rows (1 to
#   16; the installed build is the first). After a security update, --keep 1 leaves no older build a rollback (or a
#   session's re-bootstrap) can run.
#   --record PATH  the node's /Library/Application Support/VibeSwitcher/node-<uid>.pins (the default), or for a trial
#                  only /Library/Application Support/VibeSwitcher-trial/node-<uid>.pins; nothing else, dry or not
#   --dry-run      print what would be written and where, write nothing, ask for no password
#
# The record: `# …` once, `format 1`, `uid <uid>`, then `build <commit> host <cdhash> server <cdhash> cli <cdhash>`, at
# most 16, no commit and no cdhash twice. A commit already in the record with other cdhashes is refused (a build's pins
# never change). As root, the step checks every folder from / down to the record's (each root's, writable by neither
# its group nor others, no link, no ACL), makes the last one when it is missing (root:wheel 0755), writes a temporary
# file in it, makes it root:wheel 0644 and renames it over the record.
#
# Run it as `/usr/bin/env -i /bin/bash -p <its absolute path> …`: bash's privileged mode imports no function from the
# environment (an exported `builtin` would defeat the drop below, then an exported `printf` would print one record and
# hand sudo another), and env -i passes no variable at all.
#
# Exit codes: 0 written (or printed, --dry-run); 64 usage; 65 the record there can't be carried or kept (see --fresh);
# 1 the write failed or was refused (sudo's password not given, a folder not root's alone).
node_pins_main() {
    # As the install does: no function this shell imported (an exported `printf` would print one record and hand sudo
    # another), no startup variables, a fixed locale and PATH.
    local name
    for name in $(builtin compgen -A function); do
        [[ $name == node_pins_main ]] || builtin unset -f -- "$name"
    done
    builtin unset -v BASH_ENV ENV CDPATH GLOBIGNORE
    IFS=$' \t\n'
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    LC_ALL=C
    export PATH LC_ALL
    set -u -o pipefail
    name=node-pins-mac
    fail() { printf '%s: %s\n' "$name" "$2" >&2; exit "$1"; }
    local usage="usage: node-pins-mac.sh [--dry-run] [--record PATH] [--fresh] --build COMMIT HOST SERVER CLI | [--dry-run] [--record PATH] --keep N"

    local dry_run=0 fresh=0 record="" commit="" host="" server="" cli="" keep=""
    while (( $# )); do
        case $1 in
            --dry-run) dry_run=1; shift ;;
            --fresh) fresh=1; shift ;;
            --record) (( $# >= 2 )) && [[ -n $2 ]] || fail 64 "--record needs a path"; record=$2; shift 2 ;;
            --keep) (( $# >= 2 )) || fail 64 "--keep needs a count"; keep=$2; shift 2 ;;
            --build)
                (( $# >= 5 )) || fail 64 "--build needs COMMIT HOST SERVER CLI"
                [[ -z $commit ]] || fail 64 "one --build only"
                commit=$2 host=$3 server=$4 cli=$5
                shift 5 ;;
            *) fail 64 "unknown argument $1 ($usage)" ;;
        esac
    done
    [[ -n $commit || -n $keep ]] || fail 64 "$usage"
    [[ -z $commit || -z $keep ]] || fail 64 "--build or --keep, not both"
    [[ -z $keep ]] || (( ! fresh )) || fail 64 "--fresh goes with --build"
    [[ -z $keep || $keep =~ ^([1-9]|1[0-6])$ ]] || fail 64 "--keep takes 1 to 16"
    local hex='^[0-9a-f]{40}$' value
    if [[ -n $commit ]]; then
        for value in "$commit" "$host" "$server" "$cli"; do
            [[ $value =~ $hex ]] || fail 64 "$value isn't 40 lowercase hex digits"
        done
    fi
    [[ $(/usr/bin/uname -s) == Darwin ]] || fail 64 "this is the Mac's step: Linux keeps no such record"
    local uid
    uid=$(/usr/bin/id -u) || fail 1 "can't read your uid"
    [[ $uid =~ ^[0-9]+$ && $uid != 0 ]] || fail 64 "run it as yourself, not as root: it asks for the password itself"
    local node_record="/Library/Application Support/VibeSwitcher/node-$uid.pins"
    local trial_record="/Library/Application Support/VibeSwitcher-trial/node-$uid.pins"
    [[ -n $record ]] || record=$node_record
    [[ $record == "$node_record" || $record == "$trial_record" ]] \
        || fail 64 "--record names the node's record ($node_record) or a trial's ($trial_record), nothing else"
    local folder=${record%/*}

    # The rows there: read only from a record root's alone, every folder above it too.
    local there=() line
    if [[ -e $record || -L $record ]] && { (( ! fresh )) || [[ -n $keep ]]; }; then
        local walked="" part why="" facts owner mode
        local parts=()
        IFS=/ read -r -a parts <<< "$record"
        for part in "" "${parts[@]:1}"; do
            if [[ -z $part ]]; then walked=/; else walked=${walked%/}/$part; fi
            if [[ -L $walked ]]; then why="$walked is a symbolic link"; break; fi
            facts=$(/usr/bin/stat -f '%u %Lp' -- "$walked") || { why="$walked can't be read"; break; }
            owner=${facts%% *} mode=${facts##* }
            if [[ $owner != 0 ]]; then why="$walked is owned by uid $owner, not root"; break; fi
            if (( 8#$mode & 8#022 )); then why="$walked is writable by its group or others (mode $mode)"; break; fi
            if [[ -n $(/bin/ls -lde -- "$walked" | /usr/bin/tail -n +2) ]]; then why="$walked carries an access control list"; break; fi
        done
        [[ -z $why ]] || fail 65 "the record there isn't root's alone ($why)${commit:+: pass --fresh to write only the given build}"
        [[ -f $record ]] || fail 65 "$record isn't a regular file${commit:+: pass --fresh to write only the given build}"
        local seen_format=0 seen_uid=0
        while IFS= read -r line || [[ -n $line ]]; do
            case $line in
                '#'*) ;;
                'format 1') (( ! seen_format && ! seen_uid && ${#there[@]} == 0 )) || fail 65 "the record there has its format line out of place"; seen_format=1 ;;
                "uid $uid") (( seen_format && ! seen_uid )) || fail 65 "the record there has its uid line out of place"; seen_uid=1 ;;
                *)
                    [[ $line =~ ^build\ [0-9a-f]{40}\ host\ [0-9a-f]{40}\ server\ [0-9a-f]{40}\ cli\ [0-9a-f]{40}$ ]] && (( seen_uid )) \
                        || fail 65 "the record there has a line this step doesn't write (${line:0:120})"
                    there+=("$line") ;;
            esac
        done < "$record"
        (( seen_uid )) || fail 65 "the record there names no uid $uid"
    fi

    local rows=() dropped=0
    if [[ -n $keep ]]; then
        (( ${#there[@]} > 0 )) || fail 65 "there is no record at $record to keep rows of: install a newer commit (install-node-mac.sh writes it)"
        rows=("${there[@]:0:keep}")
        dropped=$(( ${#there[@]} - ${#rows[@]} ))
    else
        # The given build first, then the carried ones (another row for the same commit only if identical).
        local given="build $commit host $host server $server cli $cli"
        rows=("$given")
        for line in "${there[@]+"${there[@]}"}"; do
            if [[ $line == "build $commit "* ]]; then
                [[ $line == "$given" ]] || fail 65 "the record already pins $commit with other cdhashes (${line#build "$commit" }): a build's pins never change"
                continue
            fi
            if (( ${#rows[@]} >= 16 )); then dropped=$((dropped + 1)); continue; fi
            rows+=("$line")
        done
    fi
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
    (( dropped == 0 )) || printf '%s: %s older build(s) dropped: a rollback to one is refused until it is installed again\n' "$name" "$dropped"
    if (( dry_run )); then
        printf '%s: --dry-run: nothing written, no password asked\n' "$name"
        return 0
    fi

    # As root: this text is the script; the uid, the record's path, the mode and the content are its arguments, and each
    # is checked again here. With --keep the content must be the record there, root's alone, cut to its first N rows.
    local as_root='
        set -u
        export LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin
        uid=$1 record=$2 keep=$3 content=$4
        refuse() { printf "node-pins-mac (as root): %s\n" "$1" >&2; exit 1; }
        [[ $uid =~ ^[0-9]+$ && $uid != 0 && $uid == "${SUDO_UID:-}" ]] || refuse "the uid $uid isn'"'"'t the one sudo was asked by"
        [[ $record == "/Library/Application Support/VibeSwitcher/node-$uid.pins" || $record == "/Library/Application Support/VibeSwitcher-trial/node-$uid.pins" ]] \
            || refuse "$record is neither the node'"'"'s record nor a trial'"'"'s"
        [[ $keep =~ ^([0-9]|1[0-6])$ ]] || refuse "--keep $keep"
        # Every line by the record'"'"'s pattern: the comment, the format, this uid, then 1 to 16 builds, no commit twice.
        header="# VibeSwitcher node pins: written by the install'"'"'s administrator step (scripts/node-pins-mac.sh); read by the node'"'"'s checks"
        newline=$'"'"'\n'"'"'
        [[ $content == *"$newline" ]] || refuse "the content doesn'"'"'t end with a line'"'"'s end"
        lines=()
        while IFS= read -r line; do lines+=("$line"); done <<< "${content%"$newline"}"
        (( ${#lines[@]} >= 4 && ${#lines[@]} <= 19 )) || refuse "the content holds ${#lines[@]} lines"
        [[ ${lines[0]} == "$header" && ${lines[1]} == "format 1" && ${lines[2]} == "uid $uid" ]] || refuse "the content'"'"'s first lines aren'"'"'t the record'"'"'s"
        commits=" "
        for line in "${lines[@]:3}"; do
            [[ $line =~ ^build\ [0-9a-f]{40}\ host\ [0-9a-f]{40}\ server\ [0-9a-f]{40}\ cli\ [0-9a-f]{40}$ ]] || refuse "the content holds a line that isn'"'"'t a build'"'"'s"
            c=${line:6:40}
            [[ $commits != *" $c "* ]] || refuse "the content names $c twice"
            commits="$commits$c "
        done
        folder=${record%/*}
        root_alone() {
            [[ -L $1 ]] && refuse "$1 is a symbolic link"
            [[ -e $1 ]] || refuse "$1 is missing"
            facts=$(/usr/bin/stat -f "%u %Lp" -- "$1") || refuse "$1 can'"'"'t be read"
            owner=${facts%% *}
            mode=${facts##* }
            [[ $owner == 0 ]] || refuse "$1 is owned by uid $owner, not root"
            if (( 8#$mode & 8#022 )); then refuse "$1 is writable by its group or others (mode $mode)"; fi
            [[ -z $(/bin/ls -lde -- "$1" | /usr/bin/tail -n +2) ]] || refuse "$1 carries an access control list"
            return 0
        }
        root_alone /
        walked=
        IFS=/ read -r -a parts <<< "$folder"
        for part in "${parts[@]:1}"; do
            walked=$walked/$part
            if [[ $walked == "$folder" && ! -e $walked && ! -L $walked ]]; then
                /bin/mkdir -m 755 -- "$walked" && /usr/sbin/chown root:wheel -- "$walked" || refuse "can'"'"'t make $walked"
            fi
            root_alone "$walked"
            [[ -d $walked ]] || refuse "$walked is not a folder"
        done
        [[ -d $record && ! -L $record ]] && refuse "$record is a folder"
        if [[ $keep != 0 ]]; then
            [[ -f $record && ! -L $record ]] || refuse "there is no record at $record to keep rows of"
            root_alone "$record"
            kept=()
            while IFS= read -r line; do
                case $line in "build "*) kept+=("$line") ;; esac
            done < "$record"
            want=$keep
            (( want <= ${#kept[@]} )) || want=${#kept[@]}
            (( want >= 1 && ${#lines[@]} == 3 + want )) || refuse "the content isn'"'"'t the record there cut to $keep rows"
            i=0
            for line in "${lines[@]:3}"; do
                [[ $line == "${kept[i]}" ]] || refuse "the content isn'"'"'t the record there cut to $keep rows"
                i=$((i + 1))
            done
        fi
        temporary=$(/usr/bin/mktemp "$folder/.node-pins.XXXXXX") || refuse "can'"'"'t make a temporary file in $folder"
        printf "%s" "$content" > "$temporary" \
            && /usr/sbin/chown root:wheel -- "$temporary" && /bin/chmod 0644 -- "$temporary" \
            && /bin/mv -f -h -- "$temporary" "$record" \
            || { /bin/rm -f -- "$temporary"; refuse "can'"'"'t write $record"; }
        printf "node-pins-mac: written %s\n" "$record"
    '
    printf '%s: asking for an administrator'"'"'s password (sudo) to write it\n' "$name"
    /usr/bin/sudo /bin/bash -c "$as_root" node-pins-root "$uid" "$record" "${keep:-0}" "$content" || fail 1 "the record wasn't written (above)"
    # What a reader sees afterwards.
    /bin/ls -lde -- "$folder" "$record"
}
node_pins_main "$@"
