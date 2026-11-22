#!/bin/bash
# Installs the node's next build: COMMIT, fetched by its hash from GitHub into a fresh repository, built with the
# root-owned toolchain and laid out under the builds folder, with its record. The node runs it after `vs switch COMMIT`
# (or the first `vs start`, which starts `current`). The start plan's ST-D8 to ST-D14; the security document's S9.
#
# scripts/install-node.sh COMMIT [--prefix DIR] [--repo DIR] [--toolchain DIR]
#   COMMIT           40 lowercase hex digits: a commit on v2 that both CI runners (`v2 linux`, `v2 macos`) passed
#   --prefix DIR     the builds folder (default: <your home from getent passwd>/.vibeswitcher/v2/builds)
#   --repo DIR       your checkout, only for the courtesy check that it is clean (default: the current folder's)
#   --toolchain DIR  the root-owned Swift toolchain (default /opt/swift-6.4.2), always checked
# Test-only, each refused unless --prefix names a scratch folder (not the default one, by its realpath or its device
# and inode, and not inside <home>/.vibeswitcher):
#   --gh PATH            a stand-in for /usr/bin/gh
#   --test-origin URL    fetch from URL (file:// allowed) instead of GitHub
#   --test-products DIR  copy DIR's built products instead of building (no toolchain, no build); DIR/swift-version
#                        stands for `swift --version`'s output
#   --test-hold DIR      once the products are checked, where a FIFO DIR/checked.go is there: write DIR/checked.at
#                        (src=, partial=, bin=: the checkout, the staging folder, the products' folder) and wait for a
#                        line on the FIFO (120 s at most), so a test can change what a worker could change there
#
# Exit codes: 0 installed; 64 usage; 65 your checkout isn't clean; 66 provenance (this script, or a library beside it,
# isn't the expected commit's); 67 COMMIT isn't on v2 or CI didn't pass it; 68 the toolchain; 69 the linked-library
# check; 1 anything else (another install running on the prefix, COMMIT installed already, a failed fetch, a failed
# build, install-record's refusal). Each refusal is one line on stderr naming what failed. Every local refusal comes
# before any network call, and every refusal that doesn't need the built products before the build; the link check
# and the re-checks of the copies, the checkout and the record come after it, before anything is laid out. One install
# runs at a time on a prefix (a lock on it). A folder for COMMIT already there is refused: installed when installs
# records it and current is there; otherwise (an install that stopped after its rename, or a folder anyone else put
# there) "remove it, then install". Nothing in such a folder is trusted, its build-info included: the rerun fetches,
# checks and builds again.
#
# What it trusts (ST-D9): nothing in --repo, and nothing in your git and gh configuration: every git and gh runs under
# `env -i`, gh with a configuration folder no process of yours can make, and the courtesy check's git with a git folder
# of the script's own, never --repo's configuration; COMMIT and v2 are fetched from the constant
# repository below, never from your `origin`. Before it sources anything, it checks its own bytes and those of
# lib/scratch.sh and lib/swift-jobs.sh beside it against the expected commit's blobs, and it sources the blob, never the
# file: COMMIT on the first install; once <prefix>/current exists, the commit current/build-info names, and it then runs
# only as <prefix>/current/Resources/install-node.sh. So a change to this script takes effect one install later: the
# install after the one that installed it.
# It does trust the environment it is started with: bash runs what that environment tells it to (exported functions,
# SHELLOPTS, PS4, BASH_ENV, LD_PRELOAD) before this script's first line. Run it as
#   /usr/bin/env -i HOME=<home> PATH=/usr/bin:/bin /bin/bash <its absolute path> COMMIT …
# Nor does it hold off a worker live while it runs: the scratch checkout, its vs-heavy, the fresh caches and the products
# are the user's to write until they are copied and recorded (the security document's S9 and S11). Run it with no team
# running. Each product is read once, into the staging folder, and only that copy is checked, hashed and installed; the
# copy is hashed again before it first runs, and the checkout (untracked and ignored files too) is checked again before
# the layout, which catches a change left in place.
#
# At its end it prints that the seal holds every team until `vs config accept` (the builds folder changed, ST-D23).

# The whole script is one function, read whole before it runs: bash reads a script as it goes, so a file changed
# under a running install would otherwise change what runs next.
install_node_main() {
    # What the caller's shell left that would shape a command: functions it exported, its PATH, its IFS. (Not all of
    # it: an exported `local` or `builtin`, or SHELLOPTS, runs before this; the header says how to run it.)
    local name
    for name in $(builtin compgen -A function); do
        case $name in
            install_node_main|install_node_drop_partial) ;;
            *) builtin unset -f -- "$name" ;;
        esac
    done
    builtin unset -v BASH_ENV ENV CDPATH GLOBIGNORE
    IFS=$' \t\n'
    PATH=/usr/bin:/bin
    export PATH
    umask 022
    set -u -o pipefail

    # The repository: today's `origin`, a constant (ST-D10). Never read from a checkout's remote.
    local -r repository=acastellana/vibeswitcher
    local -r workflows=("v2 linux" "v2 macos")
    local -r interpreter=/lib64/ld-linux-x86-64.so.2
    # What swift_static's static-stdlib-args.lnk links dynamically (ST-D12; S4c's spike, 2026-11-16, measured exactly
    # this set on each of the five release products).
    local -r allowed_needed=" libc.so.6 libm.so.6 libstdc++.so.6 libgcc_s.so.1 ld-linux-x86-64.so.2 "
    # The build's products, by their build names; the cli is installed as `vibeswitcher` (BuildRecord.installedNames).
    local -r products=(vibeswitcher-host vibeswitcher-server vibeswitcher-cli vibeswitcher-hook vibeswitcher-mcp)

    local early="" early_ours=0
    # fail CODE TEXT: TEXT on stderr, the early folder removed while on_exit can't yet, exit CODE.
    fail() {
        printf 'install-node: %s\n' "${2//$'\n'/ }" >&2
        if (( early_ours )) && [[ -n $early ]]; then /bin/rm -rf -- "$early"; fi
        exit "$1"
    }
    trap 'fail 130 "interrupted"' INT TERM HUP

    # --- 1. Arguments ------------------------------------------------------------------------------------------------
    local commit="" prefix="" prefix_given=0 repo="" toolchain=/opt/swift-6.4.2 gh=/usr/bin/gh gh_given=0
    local test_origin="" test_products="" test_hold=""
    while (( $# )); do
        case $1 in
            --prefix|--repo|--toolchain|--gh|--test-origin|--test-products|--test-hold)
                (( $# >= 2 )) && [[ -n $2 ]] || fail 64 "$1 needs a value"
                case $1 in
                    --prefix) prefix=$2; prefix_given=1 ;;
                    --repo) repo=$2 ;;
                    --toolchain) toolchain=$2 ;;
                    --gh) gh=$2; gh_given=1 ;;
                    --test-origin) test_origin=$2 ;;
                    --test-products) test_products=$2 ;;
                    --test-hold) test_hold=$2 ;;
                esac
                shift 2 ;;
            -h|--help) /usr/bin/sed -n '2,44p' "${BASH_SOURCE[0]}" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
            -*) fail 64 "unknown option $1" ;;
            *) [[ -z $commit ]] || fail 64 "one COMMIT only (also given: $1)"; commit=$1; shift ;;
        esac
    done
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || fail 64 "usage: install-node.sh COMMIT [--prefix DIR] [--repo DIR] [--toolchain DIR], COMMIT 40 lowercase hex digits"

    local entry home
    entry=$(/usr/bin/getent passwd "$(/usr/bin/id -u)") || fail 1 "getent passwd has no entry for this user"
    IFS=: read -r _ _ _ _ _ home _ <<< "$entry"
    [[ $home == /* ]] || fail 1 "getent passwd gives no home folder"
    local -r default_prefix=$home/.vibeswitcher/v2/builds
    [[ -n $prefix ]] || prefix=$default_prefix
    [[ $prefix == /* ]] || prefix=$PWD/$prefix
    prefix=${prefix%/}

    if (( gh_given )) || [[ -n $test_origin || -n $test_products || -n $test_hold ]]; then
        (( prefix_given )) || fail 64 "--gh, --test-origin, --test-products and --test-hold need --prefix, a scratch folder"
        local real default_real vibeswitcher_real
        real=$(/usr/bin/realpath -m -- "$prefix") || fail 64 "can't resolve --prefix $prefix"
        default_real=$(/usr/bin/realpath -m -- "$default_prefix") || fail 64 "can't resolve $default_prefix"
        vibeswitcher_real=$(/usr/bin/realpath -m -- "$home/.vibeswitcher") || fail 64 "can't resolve $home/.vibeswitcher"
        [[ $real != "$default_real" ]] || fail 64 "--prefix $prefix is the account's builds folder: the test flags need a scratch one"
        if [[ -e $prefix && -e $default_prefix ]] \
            && [[ $(/usr/bin/stat -L -c '%d:%i' -- "$prefix") == "$(/usr/bin/stat -L -c '%d:%i' -- "$default_prefix")" ]]; then
            fail 64 "--prefix $prefix is the account's builds folder: the test flags need a scratch one"
        fi
        case $real/ in
            "$vibeswitcher_real"/*) fail 64 "--prefix $prefix is inside $home/.vibeswitcher: the test flags need a scratch folder" ;;
        esac
        case $prefix/ in
            "$home/.vibeswitcher"/*) fail 64 "--prefix $prefix is inside $home/.vibeswitcher: the test flags need a scratch folder" ;;
        esac
    fi

    # Every git: nothing from the caller's environment, the system's or the user's config, replace refs, hooks or the
    # fsmonitor; https only (file:// too under --test-origin). HOME is a folder no process of the user's can make, so
    # neither git's ~/.config/git (attributes, ignore) nor curl's ~/.netrc is read (the courtesy check copies in the
    # account's ignore file, below, as data).
    local -r git_home=/nonexistent
    local git_test=()
    [[ -z $test_origin ]] || git_test=(-c protocol.file.allow=always)
    git_run() {
        /usr/bin/env -i HOME="$git_home" PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 /usr/bin/git -c core.hooksPath=/dev/null \
            -c core.fsmonitor=false -c protocol.allow=never -c protocol.https.allow=always \
            ${git_test[@]+"${git_test[@]}"} "$@"
    }
    jq_run() { /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/jq "$@"; }

    # --- 2. The courtesy check: the checkout is clean (an install of a commit you meant to amend) -------------------
    # Nothing of the checkout's own git configuration acts (the security follow-ups' item 25): its .git/config can name
    # a filter.<x>.clean or .process command its attributes apply to a file, which a diff runs as the user. So git runs
    # on a git folder of the script's own: a configuration of its own (with the few settings below, which say how a
    # file's bytes and mode are read and name no command, read as data from the checkout's), HEAD the checkout's,
    # resolved by hand, a copy of its index, its objects (their alternates with them) by GIT_OBJECT_DIRECTORY, and the
    # checkout as the work tree. Submodules aren't looked into: a submodule's own git folder would be read.
    # The early folder (removed by fail until on_exit can) holds that git folder, then the fresh repository (step 4).
    early=$(/usr/bin/mktemp -d /tmp/install-node-early.XXXXXX) || fail 1 "can't make a scratch folder under /tmp"
    early_ours=1
    local nocheckout top gitdir common head ref line
    if [[ -n $repo ]]; then
        nocheckout="--repo $repo isn't a git checkout with a commit"
    else
        nocheckout="$PWD isn't in a git checkout: give --repo"
    fi
    # The checkout: the nearest folder up from --repo (or the current folder) with a .git, a folder or a linked
    # worktree's `gitdir:` file; its shared git folder from `commondir`.
    top=$(/usr/bin/realpath -e -- "${repo:-$PWD}" 2> /dev/null) || fail 64 "$nocheckout"
    while [[ ! -e $top/.git ]]; do
        [[ $top != / ]] || fail 64 "$nocheckout"
        top=${top%/*}
        top=${top:-/}
    done
    gitdir=$top/.git
    if [[ -f $top/.git ]]; then
        IFS= read -r line < "$top/.git" || fail 64 "$nocheckout"
        [[ $line == "gitdir: "?* ]] || fail 64 "$nocheckout"
        gitdir=${line#gitdir: }
        [[ $gitdir == /* ]] || gitdir=$top/$gitdir
    fi
    [[ -d $gitdir && -f $gitdir/HEAD ]] || fail 64 "$nocheckout"
    common=$gitdir
    if [[ -f $gitdir/commondir ]]; then
        IFS= read -r line < "$gitdir/commondir" || fail 64 "$nocheckout"
        if [[ $line == /* ]]; then common=$line; else common=$gitdir/$line; fi
    fi
    # HEAD: a hash, or a branch's, from its loose ref or packed-refs.
    IFS= read -r head < "$gitdir/HEAD" || head=""
    if [[ $head == "ref: refs/"* ]]; then
        ref=${head#ref: }
        head=""
        if [[ $ref == *..* ]]; then
            :
        elif [[ -f $common/$ref ]]; then
            IFS= read -r head < "$common/$ref" || head=""
        elif [[ -f $common/packed-refs ]]; then
            head=$(/usr/bin/awk -v r="$ref" '$2 == r { print $1; exit }' "$common/packed-refs")
        fi
    fi
    [[ $head =~ ^[0-9a-f]{40}$ ]] || fail 64 "$nocheckout (its HEAD names no commit the script can read)"
    local -r check=$early/check
    /bin/mkdir -m 700 -- "$check" "$check/refs" "$check/info" || fail 1 "can't make $check"
    printf '%s\n' "$head" > "$check/HEAD" \
        && printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n' > "$check/config" \
        || fail 1 "can't write $check"
    local key value
    # `git config --file` reads the one file as data and follows no include.
    for key in core.filemode core.symlinks core.ignorecase core.autocrlf core.eol core.checkstat core.trustctime; do
        value=$(git_run -C / config --file "$common/config" --get "$key" 2> /dev/null) || continue
        git_run -C / config --file "$check/config" "$key" "$value" || fail 65 "can't tell whether $top is clean (its $key)"
    done
    if [[ -f $gitdir/index ]]; then
        # With its own time (`-p`): git takes an entry whose stat matches for unchanged only when the index is newer than
        # the entry, else it compares the bytes ("racily clean"). A copy made now was always newer, so a same-size change
        # in the entry's second passed (2026-11-22, InstallTests' aRacilyCleanChangeIsStillFound).
        /bin/cp -p -- "$gitdir/index" "$check/index" || fail 65 "can't tell whether $top is clean (can't copy its index)"
    fi
    for line in "$gitdir"/sharedindex.*; do
        [[ ! -f $line ]] || /bin/cp -- "$line" "$check/" || fail 65 "can't tell whether $top is clean (can't copy $line)"
    done
    if [[ -f $common/info/exclude ]]; then
        /bin/cp -- "$common/info/exclude" "$check/info/exclude" || fail 65 "can't tell whether $top is clean (can't copy its info/exclude)"
    fi
    # The account's own ignore file, as the user's `git status` under this HOME reads it: core.excludesFile from
    # ~/.config/git/config, then ~/.gitconfig (the later wins), else ~/.config/git/ignore. Read as data (no include
    # followed) and copied in: an ignore pattern names no command, and at worst hides a file from this courtesy check,
    # which the build doesn't rely on (it builds a fresh checkout of its own).
    local user_home=${HOME:-$home} excludes="" config
    [[ $user_home == /* ]] || user_home=$home
    for config in "$user_home/.config/git/config" "$user_home/.gitconfig"; do
        [[ -f $config ]] || continue
        value=$(git_run -C / config --file "$config" --get core.excludesFile 2> /dev/null) && excludes=$value
    done
    case $excludes in
        "") excludes=$user_home/.config/git/ignore ;;
        "~/"*) excludes=$user_home/${excludes#"~/"} ;;
        /*) ;;
        *) excludes="" ;;
    esac
    local check_excludes=()
    if [[ -n $excludes && -f $excludes ]]; then
        /bin/cp -- "$excludes" "$check/excludes" || fail 65 "can't tell whether $top is clean (can't copy $excludes)"
        check_excludes=(-c "core.excludesFile=$check/excludes")
    fi
    check_git() {
        /usr/bin/env -i HOME="$git_home" PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 GIT_DIR="$check" GIT_WORK_TREE="$top" \
            GIT_OBJECT_DIRECTORY="$common/objects" /usr/bin/git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
            -c protocol.allow=never ${check_excludes[@]+"${check_excludes[@]}"} -C "$top" "$@"
    }
    check_git rev-parse --verify -q "$head^{commit}" > /dev/null || fail 64 "$nocheckout"
    local changed untracked dirty
    changed=$(check_git diff --name-only --no-ext-diff --no-textconv --ignore-submodules=all HEAD --) \
        || fail 65 "can't tell whether $top is clean (git diff failed)"
    untracked=$(check_git ls-files --others --exclude-standard) \
        || fail 65 "can't tell whether $top is clean (git ls-files failed)"
    /bin/rm -rf -- "$check"
    dirty=$(printf '%s\n%s\n' "$changed" "$untracked" | /usr/bin/sed '/^$/d' | /usr/bin/head -n 5 | /usr/bin/paste -sd ' ')
    [[ -z $dirty ]] || fail 65 "$top isn't clean: $dirty (commit or remove, then install)"

    # --- 3. The toolchain: root's all the way up, nothing in it the user can write -----------------------------------
    # root_only PATH: PATH and every folder up to / owned by root and writable by nobody else, or the first that isn't.
    root_only() {
        local path=$1 info owner mode
        while :; do
            info=$(/usr/bin/stat -L -c '%u %a' -- "$path" 2> /dev/null) || { printf '%s (missing)' "$path"; return 1; }
            owner=${info% *}
            mode=${info#* }
            if [[ $owner != 0 ]] || (( 8#$mode & 8#022 )); then printf '%s (owner uid %s, mode %s)' "$path" "$owner" "$mode"; return 1; fi
            [[ $path == / ]] && return 0
            path=${path%/*}
            [[ -n $path ]] || path=/
        done
    }
    local swift=""
    if [[ -z $test_products ]]; then
        [[ $toolchain == /* ]] || fail 68 "--toolchain $toolchain isn't an absolute path"
        toolchain=${toolchain%/}
        [[ -d $toolchain ]] || fail 68 "the toolchain $toolchain isn't there (the bootstrap path's M3)"
        local resolved writable found
        resolved=$(/usr/bin/realpath -e -- "$toolchain") || fail 68 "can't resolve the toolchain $toolchain"
        [[ $resolved == "$toolchain" ]] || fail 68 "the toolchain $toolchain goes through a link (to $resolved)"
        writable=$(root_only "$toolchain") \
            || fail 68 "the user can write the toolchain $toolchain: $writable isn't root's alone"
        found=$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/find "$toolchain" \( ! -user root -o \( ! -type l -perm /022 \) \) -print -quit 2>&1)
        [[ -z $found ]] || fail 68 "the user can write the toolchain $toolchain: $found"
        swift=$toolchain/usr/bin/swift
        [[ -f $swift && -x $swift ]] || fail 68 "the toolchain $toolchain has no usr/bin/swift"
    else
        # --test-products stands for the build: checked with the local refusals.
        [[ -f $test_products/swift-version ]] || fail 64 "--test-products $test_products has no swift-version"
        for name in "${products[@]}"; do
            [[ -f $test_products/$name && ! -L $test_products/$name ]] \
                || fail 69 "$name: $test_products/$name isn't a regular file"
        done
    fi

    # One install at a time on the prefix: the staging folder and current.new have fixed names. The lock is on the
    # prefix folder itself (no file of its own in the builds folder), held by this shell's descriptor until it exits.
    local -r final=$prefix/$commit
    local -r partial=$final.partial
    /bin/mkdir -p -- "$prefix" || fail 1 "can't make $prefix"
    local lock
    exec {lock}< "$prefix" || fail 1 "can't open $prefix"
    /usr/bin/flock -n "$lock" || fail 1 "another install is running on $prefix: try again once it has ended"
    # A folder for COMMIT already. Nothing in it is trusted (its build-info is anyone's to write): one installs records
    # is installed, and current never moves back to it here (`vs switch` runs an older build); any other (an install
    # that stopped between its rename and step 11, or a folder put there by someone else) is removed by the user and
    # the commit installed afresh, fetched, checked and built again.
    if [[ -e $final || -L $final ]]; then
        if [[ -e $prefix/current || -L $prefix/current ]] && /usr/bin/grep -q -- "^$commit " "$prefix/installs" 2> /dev/null; then
            fail 1 "$final is there already: $commit is installed"
        fi
        fail 1 "$final is there already, but no install recorded it as current's: remove it, then install"
    fi

    # Once a build is installed, only its copy of this script installs the next (ST-D9).
    local current_commit=""
    if [[ -e $prefix/current || -L $prefix/current ]]; then
        local current_real prefix_real self_real expected_self
        prefix_real=$(/usr/bin/realpath -e -- "$prefix") || fail 66 "can't resolve $prefix"
        current_real=$(/usr/bin/realpath -e -- "$prefix/current") || fail 66 "$prefix/current names nothing"
        [[ $current_real =~ ^"$prefix_real"/[0-9a-f]{40}$ ]] || fail 66 "$prefix/current isn't a build folder of $prefix: $current_real"
        current_commit=$(jq_run -r '.commit // empty' "$current_real/build-info" 2> /dev/null) \
            || fail 66 "can't read $prefix/current/build-info"
        [[ $current_commit == "${current_real##*/}" ]] || fail 66 "$prefix/current/build-info names ${current_commit:-no commit}, not its folder's ${current_real##*/}"
        self_real=$(/usr/bin/realpath -e -- "${BASH_SOURCE[0]}") || fail 66 "can't resolve this script's path"
        expected_self=$(/usr/bin/realpath -e -- "$prefix/current/Resources/install-node.sh" 2> /dev/null) \
            || fail 66 "$prefix/current/Resources/install-node.sh isn't there: the next install runs the installed build's copy"
        [[ $self_real == "$expected_self" ]] \
            || fail 66 "a build is installed: the next install runs only as $prefix/current/Resources/install-node.sh, not $self_real"
    fi

    # --- 4. A fresh repository, and the fetch ---------------------------------------------------------------------
    local -r fresh=$early/repo
    git_run init -q --template= "$fresh" || fail 1 "git init $fresh failed"

    # The token, read once from gh's own store with nothing of the caller's: a local read, no network call (ST-D10).
    local token
    token=$(/usr/bin/env -i HOME="$home" PATH=/usr/bin:/bin "$gh" auth token -h github.com 2> /dev/null) || token=""
    [[ -n $token ]] || fail 1 "gh has no token for github.com (the bootstrap path's M2: gh auth login)"
    # HOME and GH_CONFIG_DIR: a folder no process of the user's can make (inside root's /), so no config.yml (an
    # http_unix_socket that would answer the CI check) is read; gh 2.45 runs `api` and `run list` without one.
    gh_run() {
        /usr/bin/env -i HOME=/nonexistent PATH=/usr/bin:/bin GH_CONFIG_DIR=/nonexistent GH_TOKEN="$token" \
            GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 "$gh" "$@"
    }

    local url fetch=()
    if [[ -n $test_origin ]]; then
        url=$test_origin
    else
        url=https://github.com/$repository.git
        # A private repository's fetch authenticates through gh, with the token above and nothing else of the user's.
        fetch=(-c credential.helper= -c "credential.helper=!'$gh' auth git-credential")
    fi
    fetch_git() {
        /usr/bin/env -i HOME="$git_home" PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 GH_CONFIG_DIR=/nonexistent GH_TOKEN="$token" /usr/bin/git \
            -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.allow=never -c protocol.https.allow=always \
            ${git_test[@]+"${git_test[@]}"} ${fetch[@]+"${fetch[@]}"} -C "$fresh" fetch -q --no-tags "$url" "$@"
    }
    fetch_git "+refs/heads/v2:refs/remotes/origin/v2" || fail 1 "the fetch of v2 from $url failed"
    fetch_git "$commit" || fail 1 "the fetch of $commit from $url failed"
    [[ $(git_run -C "$fresh" cat-file -t "$commit" 2> /dev/null) == commit ]] || fail 1 "$url gave no commit $commit"
    if [[ -n $current_commit && $current_commit != "$commit" ]]; then
        fetch_git "$current_commit" || fail 1 "the fetch of the installed build's $current_commit from $url failed"
    fi

    # --- 5. Provenance: this script and its libraries are the expected commit's, byte for byte (ST-D9) -------------
    local expected=${current_commit:-$commit} self here blob scratch_lib=""
    self=$(/usr/bin/realpath -e -- "${BASH_SOURCE[0]}") || fail 66 "can't resolve this script's path"
    here=${self%/*}
    # blob PATH: the expected commit's PATH, byte for byte (the x keeps its last line ends), in $blob; held in memory,
    # never in a file another process could change between the comparison and the source.
    read_blob() {
        blob=$(git_run -C "$fresh" cat-file blob "$expected:$1" 2> /dev/null && printf x) || return 1
        blob=${blob%x}
    }
    read_blob scripts/install-node.sh || fail 66 "$expected has no scripts/install-node.sh"
    /usr/bin/cmp -s -- "$self" <(printf '%s' "$blob") \
        || fail 66 "$self isn't $expected's scripts/install-node.sh: run the copy that commit holds"
    for name in scratch.sh swift-jobs.sh; do
        read_blob "scripts/lib/$name" || fail 66 "$expected has no scripts/lib/$name"
        /usr/bin/cmp -s -- "$here/lib/$name" <(printf '%s' "$blob") \
            || fail 66 "$here/lib/$name isn't $expected's scripts/lib/$name: run the copy that commit holds"
        [[ $name != scratch.sh ]] || scratch_lib=$blob
    done
    # The verified blob, through a pipe: never the file beside this script, nor a copy of it on disk.
    # shellcheck source=lib/scratch.sh
    source <(printf '%s' "$scratch_lib") || fail 1 "can't read $expected's scripts/lib/scratch.sh"
    on_exit "/bin/rm -rf -- '$early'"
    early_ours=0
    scratch_tmpdir install-node
    /bin/mkdir -m 700 "$tool_scratch/home" || fail 1 "can't make $tool_scratch/home"
    # What every swift run gets, and nothing else: the scratch HOME, the toolchain's PATH, and the TMPDIR scratch_tmpdir
    # set (passed on by name: only the helper sets it), where SwiftPM's leftovers are removed with the scratch folder.
    local tool_env=(HOME="$tool_scratch/home" PATH="$toolchain/usr/bin:/usr/bin:/bin")
    name=TMPDIR
    tool_env+=("$name=${!name}")

    # The toolchain says the commit's .swift-version.
    local swift_version_file
    if [[ -z $test_products ]]; then
        local wanted said
        wanted=$(git_run -C "$fresh" cat-file blob "$commit:.swift-version" 2> /dev/null) || fail 68 "$commit has no .swift-version"
        said=$(/usr/bin/env -i "${tool_env[@]}" "$swift" --version 2> /dev/null) || fail 68 "$swift --version failed"
        [[ $said == *"Swift version $wanted "* ]] || fail 68 "the toolchain $toolchain isn't Swift $wanted (the commit's .swift-version): $said"
        swift_version_file=$tool_scratch/swift-version
        printf '%s\n' "$said" > "$swift_version_file" || fail 1 "can't write $swift_version_file"
    else
        swift_version_file=$test_products/swift-version
    fi

    # --- 6. On v2, and both runners passed (ST-D10) ------------------------------------------------------------------
    git_run -C "$fresh" merge-base --is-ancestor "$commit" refs/remotes/origin/v2 \
        || fail 67 "$commit isn't on v2 at $url"
    local answer state
    answer=$(gh_run api "repos/$repository/compare/$commit...v2") || fail 1 "gh api repos/$repository/compare failed"
    state=$(printf '%s' "$answer" | jq_run -r '.status // empty') || fail 1 "can't read GitHub's compare of $commit with v2"
    case $state in
        identical|ahead) ;;
        *) fail 67 "GitHub's compare of $commit with v2 says ${state:-nothing}, not identical or ahead: $commit isn't on v2" ;;
    esac
    answer=$(gh_run run list -R "$repository" --commit "$commit" -L 100 \
        --json databaseId,createdAt,workflowName,headSha,status,conclusion,event) \
        || fail 1 "gh run list -R $repository failed"
    local workflow latest
    for workflow in "${workflows[@]}"; do
        # The run with the highest databaseId of that workflow on that head (a re-run updates its run in place).
        latest=$(printf '%s' "$answer" | jq_run -r --arg w "$workflow" --arg c "$commit" '
            [.[] | select(.workflowName == $w and .headSha == $c and (.event == "push" or .event == "workflow_dispatch"))]
            | max_by(.databaseId) | if . == null then "no run" else "run \(.databaseId) \(.status)/\(.conclusion)" end') \
            || fail 1 "can't read gh run list's answer"
        [[ $latest == *" completed/success" ]] || fail 67 "CI: $workflow's latest run on $commit is $latest, not completed/success"
    done

    # --- 7. The checkout, in the fresh repository -----------------------------------------------------------------
    local -r src=$tool_scratch/src
    git_run -C "$fresh" worktree add -q --detach "$src" "$commit" 2> /dev/null || fail 1 "git worktree add of $commit failed"
    local tree
    tree=$(git_run -C "$src" rev-parse "HEAD^{tree}") || fail 1 "can't read the checkout's tree"
    printf 'checked out %s tree %s\n' "$commit" "$tree"

    # --- 8. The build (ST-D11): the fetched commit's vs-heavy, fresh caches, nothing of the caller's environment -----
    local bin
    if [[ -z $test_products ]]; then
        # No -Xswiftc -no-toolchain-stdlib-rpath (ST-D11 had it; S4c's spike, 2026-11-16): it reaches the package's
        # build-tool plugins too, which link the toolchain's stdlib dynamically and then can't load libswiftCore.so, and
        # the build fails. The static products get no toolchain RUNPATH without it; the link check below says so.
        local flags=(-c release --build-system native --static-swift-stdlib --disable-local-rpath
            --only-use-versions-from-resolved-file --package-path "$src"
            --scratch-path "$tool_scratch/build" --cache-path "$tool_scratch/cache"
            --config-path "$tool_scratch/config" --security-path "$tool_scratch/security")
        # vs-heavy gets only what it needs: PATH, the account's HOME (where it reads the slots' count), TMPDIR, and the
        # run's VIBESWITCHER_TEST_LOCK* (under a holder it takes no second slot). The build gets only tool_env, and -j
        # from the VS_HEAVY_CORES vs-heavy sets.
        local heavy_env=(PATH=/usr/bin:/bin HOME="$home")
        for name in $(builtin compgen -e); do
            case $name in
                TMPDIR|VIBESWITCHER_TEST_LOCK*) heavy_env+=("$name=${!name}") ;;
            esac
        done
        /usr/bin/env -i "${heavy_env[@]}" "$src/Resources/bin/vs-heavy" --as scripts/install-node.sh /bin/bash -c '
            cores=${VS_HEAVY_CORES:-}
            exec /usr/bin/env -i "$1" "$2" "$3" "$4" build "${@:5}" ${cores:+-j "$cores"}' \
            install-node "${tool_env[@]}" "$swift" "${flags[@]}" \
            || fail 1 "the build of $commit failed"
        bin=$(/usr/bin/env -i "${tool_env[@]}" "$swift" build --show-bin-path "${flags[@]}" 2> /dev/null | /usr/bin/tail -n 1) \
            || fail 1 "can't find the build's products"
    else
        bin=$test_products
    fi

    # --- 9. The products, copied once into the staging folder, and the linked-library check there (ST-D12) ----------
    # Each product is read once by its path (the security follow-ups' item 28): copied into <commit>.partial/bin, this
    # run's own folder (0700 until the layout is done), and everything after (the link check, the hashes,
    # install-record, the rename) is of that copy, never of the products' folder again. The copy is hashed before its
    # check and again after it.
    local writable
    writable=$(root_only "$interpreter") || fail 69 "the interpreter $interpreter isn't root's alone: $writable"
    [[ ! -e $final && ! -L $final ]] || fail 1 "$final is there already: $commit is installed"
    /bin/rm -rf -- "$partial"
    # A refusal from here on leaves no half-made build behind.
    install_partial=$partial
    on_exit install_node_drop_partial
    /bin/mkdir -m 700 -- "$partial" "$partial/bin" || fail 1 "can't make $partial"
    local product file installed headers dynamic lib listing target needed missing
    local -A product_sha=()
    for product in "${products[@]}"; do
        installed=$product
        [[ $product == vibeswitcher-cli ]] && installed=vibeswitcher
        [[ -f $bin/$product && ! -L $bin/$product ]] || fail 69 "$product: $bin/$product isn't a regular file"
        file=$partial/bin/$installed
        /bin/cp -- "$bin/$product" "$file" || fail 1 "can't copy $product into $partial/bin"
        [[ -f $file && ! -L $file ]] || fail 69 "$product: its copy $file isn't a regular file"
        line=$(/usr/bin/sha256sum -- "$file") || fail 1 "$product: can't hash $file"
        product_sha[$product]=${line%% *}
        headers=$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/readelf -lW "$file" 2> /dev/null) \
            || fail 69 "$product: readelf -l can't read $file"
        line=$(printf '%s\n' "$headers" | /usr/bin/sed -n 's/.*\[Requesting program interpreter: \(.*\)\]$/\1/p')
        [[ $line == "$interpreter" ]] || fail 69 "$product: its interpreter is ${line:-none}, not $interpreter"
        dynamic=$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/readelf -dW "$file" 2> /dev/null) \
            || fail 69 "$product: readelf -d can't read $file"
        while IFS= read -r line; do
            case $line in
                *"(RPATH)"*|*"(RUNPATH)"*|*"(AUDIT)"*|*"(DEPAUDIT)"*)
                    lib=${line#*\[}
                    line=${line#*(}
                    fail 69 "$product: ${line%%)*} ${lib%\]}, in $file" ;;
            esac
        done <<< "$dynamic"
        needed=" "
        while IFS= read -r line; do
            [[ $line == *"(NEEDED)"* ]] || continue
            lib=${line#*\[}
            lib=${lib%\]}
            [[ $lib != */* ]] || fail 69 "$product: NEEDED $lib names a path, in $file"
            [[ $allowed_needed == *" $lib "* ]] || fail 69 "$product: NEEDED $lib, outside$allowed_needed(in $file)"
            needed+="$lib "
        done <<< "$dynamic"
        # The set exactly (ST-D12): nothing missing either.
        missing=""
        for lib in $allowed_needed; do
            [[ $needed == *" $lib "* ]] || missing+=" $lib"
        done
        [[ -z $missing ]] || fail 69 "$product: NEEDED lacks$missing (the set is exactly$allowed_needed), in $file"
        # Resolved by the loader itself, never ldd (which runs the binary's own interpreter).
        listing=$(/usr/bin/env -i PATH=/usr/bin:/bin "$interpreter" --list "$file" 2> /dev/null) \
            || fail 69 "$product: $interpreter --list can't resolve $file"
        while IFS= read -r line; do
            line=${line#"${line%%[![:space:]]*}"}
            case $line in
                *" => not found"*) fail 69 "$product: ${line%% *} isn't found" ;;
                *" => "*) target=${line#* => }; target=${target% (*} ;;
                /*) target=${line% (*} ;;
                *) continue ;;
            esac
            writable=$(root_only "$target") || fail 69 "$product: it loads $target, which the user can write: $writable"
            target=$(/usr/bin/realpath -e -- "$target") || fail 69 "$product: can't resolve $target"
            writable=$(root_only "$target") || fail 69 "$product: it loads $target, which the user can write: $writable"
        done <<< "$listing"
        # What was checked, to compare with what build-info records: the copy, unchanged through its check.
        line=$(/usr/bin/sha256sum -- "$file") || fail 1 "$product: can't hash $file"
        [[ ${line%% *} == "${product_sha[$product]}" ]] \
            || fail 69 "$product: its copy $file changed during its check (sha256 ${line%% *}, not ${product_sha[$product]})"
    done

    # The test hold (--test-hold, a scratch prefix only): what a worker could change here, a test changes.
    if [[ -n $test_hold && -p $test_hold/checked.go ]]; then
        local go
        printf 'src=%s\npartial=%s\nbin=%s\n' "$src" "$partial" "$bin" > "$test_hold/checked.at.new" \
            && /bin/mv -- "$test_hold/checked.at.new" "$test_hold/checked.at" \
            && exec {go}<> "$test_hold/checked.go" || fail 1 "--test-hold: can't hold in $test_hold"
        IFS= read -r -t 120 -u "$go" line || fail 1 "--test-hold: no line on $test_hold/checked.go in 120 s"
        exec {go}<&-
    fi

    # The checkout is still the commit's: its HEAD, its tree, no tracked file changed and no file added, untracked or
    # ignored (a change left in place since the "checked out" line; the security follow-ups' item 27).
    [[ $(git_run -C "$src" rev-parse HEAD 2> /dev/null) == "$commit" \
        && $(git_run -C "$src" rev-parse "HEAD^{tree}" 2> /dev/null) == "$tree" ]] \
        || fail 1 "the checkout in $src isn't $commit tree $tree any more"
    changed=$(git_run -C "$src" status --porcelain --untracked-files=all --ignored --ignore-submodules=none 2> /dev/null) \
        || fail 1 "can't tell whether the checkout in $src changed"
    [[ -z $changed ]] || fail 1 "the checkout in $src changed since it was checked out: ${changed%%$'\n'*}"

    # --- 10. The layout: <prefix>/<commit>.partial, its record, then the rename (under the lock) -----------------------
    /bin/mkdir -m 755 -- "$partial/Resources" "$partial/Resources/bin" "$partial/Resources/lib" \
        || fail 1 "can't make $partial/Resources"
    for file in "$src"/Resources/bin/vs-*; do
        [[ -f $file && ! -L $file ]] || fail 1 "$commit's ${file#"$src/"} isn't a regular file"
        /bin/cp -- "$file" "$partial/Resources/bin/" && /bin/chmod 0755 -- "$partial/Resources/bin/${file##*/}" \
            || fail 1 "can't copy ${file#"$src/"} into $partial"
    done
    /bin/cp -- "$src/scripts/install-node.sh" "$partial/Resources/install-node.sh" \
        && /bin/chmod 0755 -- "$partial/Resources/install-node.sh" \
        && /bin/cp -- "$src/scripts/lib/scratch.sh" "$src/scripts/lib/swift-jobs.sh" "$partial/Resources/lib/" \
        || fail 1 "can't copy the install script and its libraries into $partial"
    # Before anything in the staging folder runs (the security follow-ups' item 26): each program is still the copy the
    # link check hashed, by its own hash here, never by what the build's command line says of itself.
    for product in "${products[@]}"; do
        installed=$product
        [[ $product == vibeswitcher-cli ]] && installed=vibeswitcher
        file=$partial/bin/$installed
        [[ -f $file && ! -L $file ]] || fail 1 "$file isn't a regular file any more: refused before it runs"
        /bin/chmod 0755 -- "$file" || fail 1 "can't make $file 0755"
        line=$(/usr/bin/sha256sum -- "$file") || fail 1 "can't hash $file"
        [[ ${line%% *} == "${product_sha[$product]}" ]] \
            || fail 1 "$file changed since its check (sha256 ${line%% *}, not ${product_sha[$product]}): refused before it runs"
    done
    local recorded
    recorded=$(/usr/bin/env -i HOME="$tool_scratch/home" PATH=/usr/bin:/bin "$partial/bin/vibeswitcher" install-record \
        "$partial" --commit "$commit" --swift-version-output "$swift_version_file" --resolved "$src/Package.resolved" 2>&1) \
        || fail 1 "the build's record wasn't written: ${recorded//$'\n'/ }"
    [[ -f $partial/build-info ]] || fail 1 "install-record wrote no $partial/build-info"
    # build-info records what the link check checked, and only that.
    local count sha
    count=$(jq_run -r '.binaries | length' "$partial/build-info" 2> /dev/null) || fail 1 "can't read $partial/build-info"
    [[ $count == "${#products[@]}" ]] || fail 1 "$partial/build-info records $count programs, not ${#products[@]}"
    for product in "${products[@]}"; do
        installed=$product
        [[ $product == vibeswitcher-cli ]] && installed=vibeswitcher
        sha=$(jq_run -r --arg n "$installed" '.binaries[$n] // empty' "$partial/build-info" 2> /dev/null) \
            || fail 1 "can't read $partial/build-info"
        [[ $sha == "${product_sha[$product]}" ]] \
            || fail 1 "$partial/build-info records $installed as ${sha:-nothing}, not the checked ${product_sha[$product]}"
    done
    [[ ! -e $final && ! -L $final ]] || fail 1 "$final is there already: $commit is installed"
    /bin/chmod 0755 -- "$partial" "$partial/bin" || fail 1 "can't make $partial 0755"
    /bin/mv -T -- "$partial" "$final" || fail 1 "can't rename $partial to $final"
    install_partial=""

    # --- 11. installs, then current by a link renamed over it ---------------------------------------------------------
    printf '%s %s\n' "$commit" "$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$prefix/installs" \
        || fail 1 "can't append to $prefix/installs"
    /bin/rm -f -- "$prefix/current.new"
    /bin/ln -s -- "$commit" "$prefix/current.new" && /bin/mv -T -- "$prefix/current.new" "$prefix/current" \
        || fail 1 "can't point $prefix/current at $commit"
    printf 'installed %s in %s; current names it (`vs switch %s` runs it on a running node)\n' "$commit" "$final" "$commit"
    printf 'the seal holds every team until `vs config accept` (the builds folder changed)\n'
}
# On exit (on_exit): the build folder being made, unless it was renamed into place.
install_node_drop_partial() {
    if [[ -n ${install_partial:-} && -d $install_partial && ! -L $install_partial ]]; then /bin/rm -rf -- "$install_partial"; fi
    return 0
}
install_node_main "$@"; exit $?
