#!/bin/bash
# The Mac's install of the node's next build (scripts/install-node.sh's guarantees with the Mac's tools; that script is
# Linux's and stays so): COMMIT, fetched by its hash from GitHub into a fresh repository, built with the developer
# folder's Swift, its products checked (Mach-O executables, arm64 or x86_64 slices, nothing loaded from outside the
# system's own folders), each staged copy signed with the Hardened Runtime (lib/mac-sign.sh) before its first hash,
# laid out under the builds folder with its record, `current` naming it; then the LaunchAgent (`vibeswitcher
# agent-plist`) written beside the builds for the user to load: the launchctl lines are printed, never run. `start` on
# the Mac is still refused (`NodeSystem.macUnbuilt`): this is for a real-Mac trial (docs/process/v2-mac-tasks.md).
#
# scripts/install-node-mac.sh COMMIT [--prefix DIR] [--repo DIR] [--developer-dir DIR]
#   COMMIT              40 lowercase hex digits: a commit on v2 that both CI runners (`v2 linux`, `v2 macos`) passed
#   --prefix DIR        the builds folder (default: <your home from the user database>/.vibeswitcher/v2/builds)
#   --repo DIR          your checkout, only for the courtesy check that it is clean (default: the current folder's)
#   --developer-dir DIR the developer folder whose Swift builds (default: `xcode-select -p`); root's all the way up,
#                       its toolchain and SDK writable by no one else
# Test-only (the dry run, scripts/ci/macos-install-dry-run.sh), each refused unless --prefix names a scratch folder (not
# the default one, and not inside <home>/.vibeswitcher); with any of them no LaunchAgent is written:
#   --test-origin URL          fetch from URL (file:// allowed) instead of GitHub
#   --test-ci-answer FILE      GitHub isn't asked: FILE's first line stands for its answer, `green` (both runners
#                              passed and the commit is on v2 there) or anything else (refused, 67)
#   --test-unchecked-toolchain build with --developer-dir without checking who owns it (a hosted runner's Xcode)
#   --test-products DIR        copy DIR's products instead of building; DIR/swift-version stands for `swift --version`
#
# Exit codes as install-node.sh's: 0 installed; 64 usage; 65 your checkout isn't clean; 66 provenance; 67 COMMIT isn't on
# v2 or CI didn't pass it; 68 the toolchain; 69 the products' check (or their signing); 1 anything else.
#
# What it trusts: as install-node.sh (its header says why): nothing in --repo or your git configuration, every git under
# `env -i`; GitHub's answers through /usr/bin/curl (root's, sealed by the system) with the token gh keeps in your login
# keychain, never through a gh binary (on the Mac it is Homebrew's, the user's to replace); this script and its
# libraries checked against the expected commit's blobs and sourced from the blob (COMMIT on the first install; then the
# commit current/build-info names, and it runs only as <prefix>/current/Resources/install-node-mac.sh). It runs under
# /bin/bash 3.2: run it as
#   /usr/bin/env -i HOME=<home> PATH=/usr/bin:/bin /bin/bash <its absolute path> COMMIT …
#
# Only a real Mac confirms (docs/process/v2-mac-tasks.md): the keychain read of gh's token, GitHub's answers, an App
# Store Xcode passing the toolchain check, launchd taking the written agent, and the installed host starting from it.
#
# The whole script is one function, read whole before it runs.
install_node_mac_main() {
    local name
    for name in $(builtin compgen -A function); do
        case $name in
            install_node_mac_main|install_node_mac_drop_partial|install_node_mac_unlock) ;;
            *) builtin unset -f -- "$name" ;;
        esac
    done
    builtin unset -v BASH_ENV ENV CDPATH GLOBIGNORE
    IFS=$' \t\n'
    PATH=/usr/bin:/bin
    export PATH
    umask 022
    set -u -o pipefail

    local -r repository=acastellana/vibeswitcher
    local -r products="vibeswitcher-host vibeswitcher-server vibeswitcher-cli vibeswitcher-hook vibeswitcher-mcp"
    local -r agent_file=dev.vibeswitcher.node.plist

    local early="" early_ours=0
    fail() {
        printf 'install-node-mac: %s\n' "${2//$'\n'/ }" >&2
        if (( early_ours )) && [[ -n $early ]]; then /bin/rm -rf -- "$early"; fi
        # Before on_exit holds it: the lock this run took.
        if (( early_ours )) && [[ ${install_lock_ours:-0} == 1 ]]; then /bin/rm -f -- "$install_lock"; fi
        exit "$1"
    }
    trap 'fail 130 "interrupted"' INT TERM HUP

    # --- 1. Arguments ------------------------------------------------------------------------------------------------
    local commit="" prefix="" prefix_given=0 repo="" developer_dir="" test_origin="" test_ci="" test_unchecked=0
    local test_products=""
    while (( $# )); do
        case $1 in
            --prefix|--repo|--developer-dir|--test-origin|--test-ci-answer|--test-products)
                (( $# >= 2 )) && [[ -n $2 ]] || fail 64 "$1 needs a value"
                case $1 in
                    --prefix) prefix=$2; prefix_given=1 ;;
                    --repo) repo=$2 ;;
                    --developer-dir) developer_dir=$2 ;;
                    --test-origin) test_origin=$2 ;;
                    --test-ci-answer) test_ci=$2 ;;
                    --test-products) test_products=$2 ;;
                esac
                shift 2 ;;
            --test-unchecked-toolchain) test_unchecked=1; shift ;;
            -h|--help) /usr/bin/sed -n '2,38p' "${BASH_SOURCE[0]}" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
            -*) fail 64 "unknown option $1" ;;
            *) [[ -z $commit ]] || fail 64 "one COMMIT only (also given: $1)"; commit=$1; shift ;;
        esac
    done
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || fail 64 "usage: install-node-mac.sh COMMIT [--prefix DIR] [--repo DIR] [--developer-dir DIR], COMMIT 40 lowercase hex digits"
    [[ $(/usr/bin/uname -s) == Darwin ]] || fail 64 "this is the Mac's install: on Linux, scripts/install-node.sh"

    # The home from the user database (`id -P`: name:password:uid:gid:class:change:expire:gecos:home:shell), never HOME.
    local entry home
    entry=$(/usr/bin/id -P) || fail 1 "the user database has no entry for this user"
    IFS=: read -r _ _ _ _ _ _ _ _ home _ <<< "$entry"
    [[ $home == /* ]] || fail 1 "the user database gives no home folder"
    local -r default_prefix=$home/.vibeswitcher/v2/builds
    [[ -n $prefix ]] || prefix=$default_prefix
    [[ $prefix == /* ]] || prefix=$PWD/$prefix
    prefix=${prefix%/}

    # resolve PATH: PATH with its links resolved, the part that isn't there yet as written (realpath -m's answer).
    resolve() {
        local path=$1 rest="" up
        while [[ ! -e $path ]]; do
            [[ $path == / || -z $path ]] && { printf '%s' "$1"; return 0; }
            rest=/${path##*/}$rest
            path=${path%/*}
            [[ -n $path ]] || path=/
        done
        up=$(/bin/realpath -- "$path") || return 1
        [[ $up == / ]] && up=""
        printf '%s%s' "$up" "$rest"
    }
    local testing=0
    if [[ -n $test_origin || -n $test_ci || -n $test_products ]] || (( test_unchecked )); then
        testing=1
        (( prefix_given )) || fail 64 "the test flags need --prefix, a scratch folder"
        local real default_real vibeswitcher_real
        real=$(resolve "$prefix") || fail 64 "can't resolve --prefix $prefix"
        default_real=$(resolve "$default_prefix") || fail 64 "can't resolve $default_prefix"
        vibeswitcher_real=$(resolve "$home/.vibeswitcher") || fail 64 "can't resolve $home/.vibeswitcher"
        [[ $real != "$default_real" ]] || fail 64 "--prefix $prefix is the account's builds folder: the test flags need a scratch one"
        if [[ -e $prefix && -e $default_prefix ]] \
            && [[ $(/usr/bin/stat -L -f '%d:%i' -- "$prefix") == "$(/usr/bin/stat -L -f '%d:%i' -- "$default_prefix")" ]]; then
            fail 64 "--prefix $prefix is the account's builds folder: the test flags need a scratch one"
        fi
        case $real/ in
            "$vibeswitcher_real"/*) fail 64 "--prefix $prefix is inside $home/.vibeswitcher: the test flags need a scratch folder" ;;
        esac
        case $prefix/ in
            "$home/.vibeswitcher"/*) fail 64 "--prefix $prefix is inside $home/.vibeswitcher: the test flags need a scratch folder" ;;
        esac
    fi
    [[ -x /usr/bin/jq ]] || fail 1 "/usr/bin/jq isn't there (macOS 15 or later has it)"

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
    sha_of() {
        local line
        line=$(/usr/bin/shasum -a 256 -- "$1") || return 1
        printf '%s' "${line%% *}"
    }

    # --- 2. The courtesy check: the checkout is clean (install-node.sh's step 2, the same git folder of its own) -------
    early=$(/usr/bin/mktemp -d /tmp/install-node-mac-early.XXXXXX) || fail 1 "can't make a scratch folder under /tmp"
    early_ours=1
    local nocheckout top gitdir common head ref line
    if [[ -n $repo ]]; then
        nocheckout="--repo $repo isn't a git checkout with a commit"
    else
        nocheckout="$PWD isn't in a git checkout: give --repo"
    fi
    top=$(/bin/realpath -- "${repo:-$PWD}" 2> /dev/null) || fail 64 "$nocheckout"
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
    for key in core.filemode core.symlinks core.ignorecase core.autocrlf core.eol core.checkstat core.trustctime core.precomposeunicode; do
        value=$(git_run -C / config --file "$common/config" --get "$key" 2> /dev/null) || continue
        git_run -C / config --file "$check/config" "$key" "$value" || fail 65 "can't tell whether $top is clean (its $key)"
    done
    if [[ -f $gitdir/index ]]; then
        /bin/cp -- "$gitdir/index" "$check/index" || fail 65 "can't tell whether $top is clean (can't copy its index)"
    fi
    for line in "$gitdir"/sharedindex.*; do
        [[ ! -f $line ]] || /bin/cp -- "$line" "$check/" || fail 65 "can't tell whether $top is clean (can't copy $line)"
    done
    if [[ -f $common/info/exclude ]]; then
        /bin/cp -- "$common/info/exclude" "$check/info/exclude" || fail 65 "can't tell whether $top is clean (can't copy its info/exclude)"
    fi
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
    dirty=$(printf '%s\n%s\n' "$changed" "$untracked" | /usr/bin/sed '/^$/d' | /usr/bin/head -n 5 | /usr/bin/paste -sd ' ' -)
    [[ -z $dirty ]] || fail 65 "$top isn't clean: $dirty (commit or remove, then install)"

    # --- 3. The toolchain: the developer folder root's all the way up, its toolchain and SDK no one else's to write ----
    root_only() {
        local path=$1 info owner mode
        while :; do
            info=$(/usr/bin/stat -L -f '%u %Lp' -- "$path" 2> /dev/null) || { printf '%s (missing)' "$path"; return 1; }
            owner=${info% *}
            mode=${info#* }
            if [[ $owner != 0 ]] || (( 8#$mode & 8#022 )); then printf '%s (owner uid %s, mode %s)' "$path" "$owner" "$mode"; return 1; fi
            [[ $path == / ]] && return 0
            path=${path%/*}
            [[ -n $path ]] || path=/
        done
    }
    local swift="" toolchain="" sdk=""
    if [[ -z $test_products ]]; then
        [[ -n $developer_dir ]] || developer_dir=$(/usr/bin/xcode-select -p 2> /dev/null) || fail 68 "xcode-select names no developer folder"
        [[ $developer_dir == /* ]] || fail 68 "the developer folder $developer_dir isn't an absolute path"
        developer_dir=${developer_dir%/}
        local resolved writable found
        resolved=$(/bin/realpath -- "$developer_dir" 2> /dev/null) || fail 68 "the developer folder $developer_dir isn't there"
        [[ $resolved == "$developer_dir" ]] || fail 68 "the developer folder $developer_dir goes through a link (to $resolved)"
        toolchain=$developer_dir/Toolchains/XcodeDefault.xctoolchain
        [[ -d $toolchain ]] || toolchain=$developer_dir
        sdk=$developer_dir/Platforms/MacOSX.platform/Developer/SDKs
        [[ -d $sdk ]] || sdk=$developer_dir/SDKs
        swift=$toolchain/usr/bin/swift
        [[ -f $swift && -x $swift ]] || fail 68 "the developer folder $developer_dir has no swift ($swift)"
        if (( ! test_unchecked )); then
            writable=$(root_only "$toolchain") \
                || fail 68 "the user can write the toolchain $toolchain: $writable isn't root's alone"
            for line in "$toolchain" "$sdk"; do
                [[ -d $line ]] || continue
                found=$(/usr/bin/find "$line" \( ! -user root -o \( ! -type l -perm +022 \) \) -print 2>&1 | /usr/bin/head -n 1)
                [[ -z $found ]] || fail 68 "the user can write the developer folder $developer_dir: $found"
            done
        fi
    else
        [[ -f $test_products/swift-version ]] || fail 64 "--test-products $test_products has no swift-version"
        for name in $products; do
            [[ -f $test_products/$name && ! -L $test_products/$name ]] \
                || fail 69 "$name: $test_products/$name isn't a regular file"
        done
    fi

    # One install at a time on the prefix: shlock's file beside the builds (its pid in it; one whose process has gone is
    # taken over), removed on exit.
    local -r final=$prefix/$commit
    local -r partial=$final.partial
    /bin/mkdir -p -- "$prefix" || fail 1 "can't make $prefix"
    install_lock=$prefix/.install.lock
    /usr/bin/shlock -f "$install_lock" -p $$ || fail 1 "another install is running on $prefix: try again once it has ended"
    install_lock_ours=1
    if [[ -e $final || -L $final ]]; then
        if [[ -e $prefix/current || -L $prefix/current ]] && /usr/bin/grep -q -- "^$commit " "$prefix/installs" 2> /dev/null; then
            fail 1 "$final is there already: $commit is installed"
        fi
        fail 1 "$final is there already, but no install recorded it as current's: remove it, then install"
    fi

    # Once a build is installed, only its copy of this script installs the next.
    local current_commit=""
    if [[ -e $prefix/current || -L $prefix/current ]]; then
        local current_real prefix_real self_real expected_self
        prefix_real=$(/bin/realpath -- "$prefix") || fail 66 "can't resolve $prefix"
        current_real=$(/bin/realpath -- "$prefix/current" 2> /dev/null) || fail 66 "$prefix/current names nothing"
        [[ $current_real =~ ^"$prefix_real"/[0-9a-f]{40}$ ]] || fail 66 "$prefix/current isn't a build folder of $prefix: $current_real"
        current_commit=$(jq_run -r '.commit // empty' "$current_real/build-info" 2> /dev/null) \
            || fail 66 "can't read $prefix/current/build-info"
        [[ $current_commit == "${current_real##*/}" ]] || fail 66 "$prefix/current/build-info names ${current_commit:-no commit}, not its folder's ${current_real##*/}"
        self_real=$(/bin/realpath -- "${BASH_SOURCE[0]}") || fail 66 "can't resolve this script's path"
        expected_self=$(/bin/realpath -- "$prefix/current/Resources/install-node-mac.sh" 2> /dev/null) \
            || fail 66 "$prefix/current/Resources/install-node-mac.sh isn't there: the next install runs the installed build's copy"
        [[ $self_real == "$expected_self" ]] \
            || fail 66 "a build is installed: the next install runs only as $prefix/current/Resources/install-node-mac.sh, not $self_real"
    fi

    # --- 4. A fresh repository, and the fetch ---------------------------------------------------------------------
    local -r fresh=$early/repo
    git_run init -q --template= "$fresh" || fail 1 "git init $fresh failed"
    # The token gh keeps in the login keychain (service gh:github.com; `go-keyring-base64:` and base64, or as is): read
    # only for GitHub, never under --test-ci-answer with a file:// origin.
    local token="" auth_count=0
    if [[ -z $test_ci || -z $test_origin ]]; then
        token=$(/usr/bin/security find-generic-password -s gh:github.com -w 2> /dev/null) || token=""
        if [[ $token == go-keyring-base64:* ]]; then
            token=$(printf '%s' "${token#go-keyring-base64:}" | /usr/bin/base64 -D 2> /dev/null) || token=""
        fi
        [[ $token =~ ^[A-Za-z0-9_]+$ ]] || fail 1 "the login keychain holds no GitHub token of gh's (gh auth login, keeping it in the keychain)"
        auth_count=1
    fi
    local url
    if [[ -n $test_origin ]]; then url=$test_origin; else url=https://github.com/$repository.git; fi
    # The token reaches git as an extra header through its environment (GIT_CONFIG_*), never its arguments.
    local basic=""
    (( auth_count )) && basic=$(printf 'x-access-token:%s' "$token" | /usr/bin/base64)
    fetch_git() {
        local auth=()
        (( auth_count )) && [[ -z $test_origin ]] \
            && auth=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader "GIT_CONFIG_VALUE_0=Authorization: Basic $basic")
        /usr/bin/env -i HOME="$git_home" PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 ${auth[@]+"${auth[@]}"} /usr/bin/git \
            -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.allow=never -c protocol.https.allow=always \
            -c credential.helper= ${git_test[@]+"${git_test[@]}"} -C "$fresh" fetch -q --no-tags "$url" "$@"
    }
    fetch_git "+refs/heads/v2:refs/remotes/origin/v2" || fail 1 "the fetch of v2 from $url failed"
    fetch_git "$commit" || fail 1 "the fetch of $commit from $url failed"
    [[ $(git_run -C "$fresh" cat-file -t "$commit" 2> /dev/null) == commit ]] || fail 1 "$url gave no commit $commit"
    if [[ -n $current_commit && $current_commit != "$commit" ]]; then
        fetch_git "$current_commit" || fail 1 "the fetch of the installed build's $current_commit from $url failed"
    fi

    # --- 5. Provenance: this script and its libraries are the expected commit's, byte for byte -----------------------
    local expected=${current_commit:-$commit} self here blob scratch_lib="" sign_lib=""
    self=$(/bin/realpath -- "${BASH_SOURCE[0]}") || fail 66 "can't resolve this script's path"
    here=${self%/*}
    read_blob() {
        blob=$(git_run -C "$fresh" cat-file blob "$expected:$1" 2> /dev/null && printf x) || return 1
        blob=${blob%x}
    }
    read_blob scripts/install-node-mac.sh || fail 66 "$expected has no scripts/install-node-mac.sh"
    /usr/bin/cmp -s -- "$self" <(printf '%s' "$blob") \
        || fail 66 "$self isn't $expected's scripts/install-node-mac.sh: run the copy that commit holds"
    for name in scratch.sh swift-jobs.sh mac-sign.sh; do
        read_blob "scripts/lib/$name" || fail 66 "$expected has no scripts/lib/$name"
        /usr/bin/cmp -s -- "$here/lib/$name" <(printf '%s' "$blob") \
            || fail 66 "$here/lib/$name isn't $expected's scripts/lib/$name: run the copy that commit holds"
        case $name in
            scratch.sh) scratch_lib=$blob ;;
            mac-sign.sh) sign_lib=$blob ;;
        esac
    done
    # The verified blobs, from memory: evaluated, not sourced, since /bin/bash 3.2's `source <(…)` reads nothing from a
    # process substitution (the first dry run, 2026-11-22: neither library's functions were defined).
    eval "$scratch_lib" || fail 1 "can't read $expected's scripts/lib/scratch.sh"
    declare -F scratch_tmpdir > /dev/null || fail 66 "$expected's scripts/lib/scratch.sh defines no scratch_tmpdir"
    eval "$sign_lib" || fail 1 "can't read $expected's scripts/lib/mac-sign.sh"
    declare -F mac_sign_hardened > /dev/null || fail 66 "$expected's scripts/lib/mac-sign.sh defines no mac_sign_hardened"
    on_exit "/bin/rm -rf -- '$early'"
    on_exit install_node_mac_unlock
    early_ours=0
    scratch_tmpdir install-node-mac
    /bin/mkdir -m 700 "$tool_scratch/home" || fail 1 "can't make $tool_scratch/home"
    local tool_env=(HOME="$tool_scratch/home" PATH="${toolchain:+$toolchain/usr/bin:}/usr/bin:/bin")
    [[ -z $developer_dir ]] || tool_env+=(DEVELOPER_DIR="$developer_dir")
    name=TMPDIR
    tool_env+=("$name=${!name}")

    local swift_version_file
    if [[ -z $test_products ]]; then
        local wanted said
        wanted=$(git_run -C "$fresh" cat-file blob "$commit:.swift-version" 2> /dev/null) || fail 68 "$commit has no .swift-version"
        said=$(/usr/bin/env -i "${tool_env[@]}" "$swift" --version 2> /dev/null) || fail 68 "$swift --version failed"
        [[ $said == *"Swift version $wanted "* ]] || fail 68 "the developer folder's Swift isn't $wanted (the commit's .swift-version): $said"
        swift_version_file=$tool_scratch/swift-version
        printf '%s\n' "$said" > "$swift_version_file" || fail 1 "can't write $swift_version_file"
    else
        swift_version_file=$test_products/swift-version
    fi

    # --- 6. On v2, and both runners passed ---------------------------------------------------------------------------
    git_run -C "$fresh" merge-base --is-ancestor "$commit" refs/remotes/origin/v2 \
        || fail 67 "$commit isn't on v2 at $url"
    if [[ -n $test_ci ]]; then
        IFS= read -r line < "$test_ci" || line=""
        [[ $line == green ]] || fail 67 "CI (--test-ci-answer): ${line:-nothing}, not green"
    else
        # api GET PATH: GitHub's answer through /usr/bin/curl, the token in its configuration on stdin (not its arguments).
        api() {
            printf 'header = "Authorization: Bearer %s"\n' "$token" | /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/curl -q -sS \
                --fail --proto =https --max-time 60 -K - -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
        }
        local answer state workflow latest
        answer=$(api "repos/$repository/compare/$commit...v2") || fail 1 "GitHub's compare of $commit with v2 failed"
        state=$(printf '%s' "$answer" | jq_run -r '.status // empty') || fail 1 "can't read GitHub's compare of $commit with v2"
        case $state in
            identical|ahead) ;;
            *) fail 67 "GitHub's compare of $commit with v2 says ${state:-nothing}, not identical or ahead: $commit isn't on v2" ;;
        esac
        answer=$(api "repos/$repository/actions/runs?head_sha=$commit&per_page=100") || fail 1 "GitHub's runs of $commit couldn't be read"
        for workflow in "v2 linux" "v2 macos"; do
            latest=$(printf '%s' "$answer" | jq_run -r --arg w "$workflow" --arg c "$commit" '
                [.workflow_runs[] | select(.name == $w and .head_sha == $c and (.event == "push" or .event == "workflow_dispatch"))]
                | max_by(.id) | if . == null then "no run" else "run \(.id) \(.status)/\(.conclusion)" end') \
                || fail 1 "can't read GitHub's runs of $commit"
            [[ $latest == *" completed/success" ]] || fail 67 "CI: $workflow's latest run on $commit is $latest, not completed/success"
        done
    fi

    # --- 7. The checkout, in the fresh repository -----------------------------------------------------------------
    local -r src=$tool_scratch/src
    git_run -C "$fresh" worktree add -q --detach "$src" "$commit" 2> /dev/null || fail 1 "git worktree add of $commit failed"
    local tree
    tree=$(git_run -C "$src" rev-parse "HEAD^{tree}") || fail 1 "can't read the checkout's tree"
    printf 'checked out %s tree %s\n' "$commit" "$tree"

    # --- 8. The build: the fetched commit's vs-heavy, fresh caches, nothing of the caller's environment --------------
    local bin
    if [[ -z $test_products ]]; then
        local flags=(-c release --build-system native --disable-local-rpath --only-use-versions-from-resolved-file
            --package-path "$src" --scratch-path "$tool_scratch/build" --cache-path "$tool_scratch/cache"
            --config-path "$tool_scratch/config" --security-path "$tool_scratch/security")
        local heavy_env=(PATH=/usr/bin:/bin HOME="$home")
        for name in $(builtin compgen -e); do
            case $name in
                TMPDIR|VIBESWITCHER_TEST_LOCK*|VIBESWITCHER_HEAVY_TIMEOUT) heavy_env+=("$name=${!name}") ;;
            esac
        done
        # The inner shell gets the count of tool_env and swift first: env -i takes those, then `build` and the flags.
        /usr/bin/env -i "${heavy_env[@]}" "$src/Resources/bin/vs-heavy" --as scripts/install-node-mac.sh /bin/bash -c '
            cores=${VS_HEAVY_CORES:-}
            n=$1
            shift
            exec /usr/bin/env -i "${@:1:n}" build "${@:n+1}" ${cores:+-j "$cores"}' \
            install-node-mac "$((${#tool_env[@]} + 1))" "${tool_env[@]}" "$swift" "${flags[@]}" \
            || fail 1 "the build of $commit failed"
        bin=$(/usr/bin/env -i "${tool_env[@]}" "$swift" build --show-bin-path "${flags[@]}" 2> /dev/null | /usr/bin/tail -n 1) \
            || fail 1 "can't find the build's products"
    else
        bin=$test_products
    fi

    # --- 9. The products: each copied once into the staging folder, signed there, then hashed and checked ------------
    [[ ! -e $final && ! -L $final ]] || fail 1 "$final is there already: $commit is installed"
    /bin/rm -rf -- "$partial"
    install_partial=$partial
    on_exit install_node_mac_drop_partial
    /bin/mkdir -m 700 -- "$partial" "$partial/bin" || fail 1 "can't make $partial"
    local machine product file installed archs arch libs rpaths seen i=0
    local product_sha=()
    machine=$(/usr/bin/uname -m)
    for product in $products; do
        installed=$product
        [[ $product == vibeswitcher-cli ]] && installed=vibeswitcher
        [[ -f $bin/$product && ! -L $bin/$product ]] || fail 69 "$product: $bin/$product isn't a regular file"
        file=$partial/bin/$installed
        /bin/cp -- "$bin/$product" "$file" || fail 1 "can't copy $product into $partial/bin"
        [[ -f $file && ! -L $file ]] || fail 69 "$product: its copy $file isn't a regular file"
        # Signed before its first hash: a signature changes the file.
        mac_sign_hardened "$file" 2>&1 | /usr/bin/sed 's/^/install-node-mac: /' >&2
        (( PIPESTATUS[0] == 0 )) || fail 69 "$product: its copy $file couldn't be signed with the Hardened Runtime"
        product_sha[i]=$(sha_of "$file") || fail 1 "$product: can't hash $file"
        # Mach-O, each slice arm64 or x86_64, this Mac's among them, each an executable.
        archs=$(/usr/bin/lipo -archs "$file" 2> /dev/null) || fail 69 "$product: $file isn't a Mach-O file"
        seen=0
        for arch in $archs; do
            case $arch in
                arm64|x86_64) ;;
                *) fail 69 "$product: a slice for $arch, not arm64 or x86_64, in $file" ;;
            esac
            [[ $arch == "$machine" ]] && seen=1
            /usr/bin/otool -arch "$arch" -hv "$file" 2> /dev/null | /usr/bin/grep -qw EXECUTE \
                || fail 69 "$product: its $arch slice isn't an executable, in $file"
            # What it loads: by absolute paths in the system's sealed folders only (the shared cache's), no @rpath,
            # @loader_path or @executable_path, nothing of the user's.
            libs=$(/usr/bin/otool -arch "$arch" -L "$file" 2> /dev/null | /usr/bin/tail -n +2) \
                || fail 69 "$product: otool -L can't read its $arch slice, in $file"
            while IFS= read -r line; do
                line=${line#"${line%%[![:space:]]*}"}
                [[ -n $line ]] || continue
                line=${line% (compatibility version*}
                case $line in
                    /usr/lib/*|/System/Library/Frameworks/*.framework/*) ;;
                    *) fail 69 "$product: its $arch slice loads $line, outside /usr/lib and /System/Library/Frameworks (in $file)" ;;
                esac
                [[ $line != *..* ]] || fail 69 "$product: its $arch slice loads $line, which names .. (in $file)"
            done <<< "$libs"
            # Its load commands: no run path but the system's Swift (/usr/lib/swift), no dyld environment.
            rpaths=$(/usr/bin/otool -arch "$arch" -l "$file" 2> /dev/null) || fail 69 "$product: otool -l can't read its $arch slice"
            [[ $rpaths != *LC_DYLD_ENVIRONMENT* ]] || fail 69 "$product: its $arch slice holds LC_DYLD_ENVIRONMENT, in $file"
            while IFS= read -r line; do
                line=${line#*path }
                line=${line% (offset*}
                [[ $line == /usr/lib/swift ]] || fail 69 "$product: its $arch slice holds the run path $line, in $file"
            done < <(printf '%s\n' "$rpaths" | /usr/bin/grep -A2 -w LC_RPATH | /usr/bin/grep -w path)
        done
        (( seen )) || fail 69 "$product: no slice for this Mac's $machine (only $archs), in $file"
        line=$(sha_of "$file") || fail 1 "$product: can't hash $file"
        [[ $line == "${product_sha[i]}" ]] || fail 69 "$product: its copy $file changed during its check (sha256 $line, not ${product_sha[i]})"
        i=$((i + 1))
    done

    # The checkout is still the commit's.
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
    /bin/cp -- "$src/scripts/install-node-mac.sh" "$partial/Resources/install-node-mac.sh" \
        && /bin/chmod 0755 -- "$partial/Resources/install-node-mac.sh" \
        && /bin/cp -- "$src/scripts/lib/scratch.sh" "$src/scripts/lib/swift-jobs.sh" "$src/scripts/lib/mac-sign.sh" "$partial/Resources/lib/" \
        || fail 1 "can't copy the install script and its libraries into $partial"
    i=0
    for product in $products; do
        installed=$product
        [[ $product == vibeswitcher-cli ]] && installed=vibeswitcher
        file=$partial/bin/$installed
        [[ -f $file && ! -L $file ]] || fail 1 "$file isn't a regular file any more: refused before it runs"
        /bin/chmod 0755 -- "$file" || fail 1 "can't make $file 0755"
        line=$(sha_of "$file") || fail 1 "can't hash $file"
        [[ $line == "${product_sha[i]}" ]] || fail 1 "$file changed since its check (sha256 $line, not ${product_sha[i]}): refused before it runs"
        i=$((i + 1))
    done
    local recorded
    recorded=$(/usr/bin/env -i HOME="$tool_scratch/home" PATH=/usr/bin:/bin "$partial/bin/vibeswitcher" install-record \
        "$partial" --commit "$commit" --swift-version-output "$swift_version_file" --resolved "$src/Package.resolved" 2>&1) \
        || fail 1 "the build's record wasn't written: ${recorded//$'\n'/ }"
    [[ -f $partial/build-info ]] || fail 1 "install-record wrote no $partial/build-info"
    local count sha
    count=$(jq_run -r '.binaries | length' "$partial/build-info" 2> /dev/null) || fail 1 "can't read $partial/build-info"
    [[ $count == 5 ]] || fail 1 "$partial/build-info records $count programs, not 5"
    i=0
    for product in $products; do
        installed=$product
        [[ $product == vibeswitcher-cli ]] && installed=vibeswitcher
        sha=$(jq_run -r --arg n "$installed" '.binaries[$n] // empty' "$partial/build-info" 2> /dev/null) \
            || fail 1 "can't read $partial/build-info"
        [[ $sha == "${product_sha[i]}" ]] || fail 1 "$partial/build-info records $installed as ${sha:-nothing}, not the checked ${product_sha[i]}"
        i=$((i + 1))
    done
    # BSD mv has no -T: the target is checked absent here, under the lock (a folder there would take the build in).
    [[ ! -e $final && ! -L $final ]] || fail 1 "$final is there already: $commit is installed"
    /bin/chmod 0755 -- "$partial" "$partial/bin" || fail 1 "can't make $partial 0755"
    /bin/mv -- "$partial" "$final" || fail 1 "can't rename $partial to $final"
    [[ -f $final/build-info && ! -e $final/${partial##*/} ]] || fail 1 "the rename of $partial to $final didn't make $final the build"
    install_partial=""

    # --- 11. installs, then current by a link renamed over it ---------------------------------------------------------
    printf '%s %s\n' "$commit" "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$prefix/installs" \
        || fail 1 "can't append to $prefix/installs"
    /bin/rm -f -- "$prefix/current.new"
    /bin/ln -s -- "$commit" "$prefix/current.new" && /bin/mv -fh -- "$prefix/current.new" "$prefix/current" \
        || fail 1 "can't point $prefix/current at $commit"
    printf 'installed %s in %s; current names it\n' "$commit" "$final"

    # --- 12. The LaunchAgent, for the user to load (never under the test flags) -------------------------------------
    if (( testing )); then
        printf 'no LaunchAgent written (a test install)\n'
        return 0
    fi
    local agent=$prefix/$agent_file uid
    uid=$(/usr/bin/id -u)
    /usr/bin/env -i HOME="$home" PATH=/usr/bin:/bin "$final/bin/vibeswitcher" agent-plist "$prefix" "$commit" > "$agent.new" \
        || { /bin/rm -f -- "$agent.new"; fail 1 "the LaunchAgent couldn't be made (vibeswitcher agent-plist, above)"; }
    /usr/bin/plutil -lint -s -- "$agent.new" || { /bin/rm -f -- "$agent.new"; fail 1 "the LaunchAgent $agent.new isn't a property list"; }
    /bin/mv -f -- "$agent.new" "$agent" || fail 1 "can't write $agent"
    printf 'the LaunchAgent is in %s; `start` on the Mac is still refused, so for a trial load it yourself:\n' "$agent"
    printf '  /bin/cp %s %s/Library/LaunchAgents/%s\n' "$agent" "$home" "$agent_file"
    printf '  /bin/launchctl bootstrap gui/%s %s/Library/LaunchAgents/%s\n' "$uid" "$home" "$agent_file"
    printf '  /bin/launchctl kickstart gui/%s/dev.vibeswitcher.node\n' "$uid"
    printf 'and to unload it: /bin/launchctl bootout gui/%s/dev.vibeswitcher.node\n' "$uid"
}
# On exit (on_exit): the build folder being made, unless it was renamed into place.
install_node_mac_drop_partial() {
    if [[ -n ${install_partial:-} && -d $install_partial && ! -L $install_partial ]]; then /bin/rm -rf -- "$install_partial"; fi
    return 0
}
# On exit: the install's lock, when this run took it.
install_node_mac_unlock() {
    if [[ ${install_lock_ours:-0} == 1 && -n ${install_lock:-} ]]; then /bin/rm -f -- "$install_lock"; fi
    return 0
}
install_node_mac_main "$@"; exit $?
