# The one way a script or test of this project calls the `security` tool (KeychainCallLintTests): on a scratch
# keychain file only, never the user's. 2026-11-26: a worker's probe let its scratch keychain auto-lock after the
# default 300 s, and the next `security add-generic-password` waited on an unlock dialog on the user's screen (twice);
# other probes left the user's login keychain locked, with a stream of real password prompts.
# Source it after scripts/lib/scratch.sh (on_exit).
#
# scratch_keychain [DIR]: makes $scratch_keychain, DIR/vs-scratch.keychain-db (DIR: $tool_scratch from scratch_tmpdir,
#   or a test's own Scratch folder), with a throwaway password (-p), and in the same step no lock timeout and no lock
#   on sleep (set-keychain-settings with no options), so it's never locked; deleted on exit. Every call runs on a
#   scratch HOME beside it (DIR/vs-keychain-home), so it's never added to the user's search list and the user's
#   default and login keychains are never read or changed.
# keychain_call SUBCOMMAND ARGS…: security SUBCOMMAND ARGS… with stdin closed, killed after $keychain_call_timeout
#   seconds (default 10; status 124 then). It runs only a call that names $scratch_keychain and is one of the item
#   subcommands below, with no -T (an access list without security on it asks you on the next read); anything else is
#   refused, status 2, before security runs: what takes the default keychain or the search list, locks, unlocks,
#   passwords, partition lists, trust settings, ACLs.

scratch_keychain=""
scratch_keychain_home=""
scratch_keychain_password=""
keychain_call_timeout=${keychain_call_timeout:-10}

# security "$@" on the scratch HOME, stdin closed, killed by SIGALRM after the timeout (an alarm outlives exec).
scratch_keychain_run() {
    local status
    HOME="$scratch_keychain_home" CFFIXED_USER_HOME="$scratch_keychain_home" \
        /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$keychain_call_timeout" security "$@" < /dev/null
    status=$?
    if [[ $status -eq 142 ]]; then
        echo "security $1 timed out after $keychain_call_timeout s (killed)" >&2
        return 124
    fi
    return $status
}

scratch_keychain() {
    local dir=${1:-$tool_scratch}
    if [[ -z $dir || ! -d $dir ]]; then
        echo "scratch_keychain: no scratch folder (call scratch_tmpdir first, or pass one)" >&2
        return 2
    fi
    if [[ -n $scratch_keychain ]]; then
        echo "scratch_keychain: $scratch_keychain is already made" >&2
        return 2
    fi
    scratch_keychain_home="$dir/vs-keychain-home"
    mkdir -p -m 700 "$scratch_keychain_home/Library/Preferences" "$scratch_keychain_home/Library/Keychains" || return 1
    scratch_keychain="$dir/vs-scratch.keychain-db"
    # Throwaway: the keychain holds nothing of the user's. od reads its 12 bytes and ends (no SIGPIPE under pipefail).
    scratch_keychain_password=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
    on_exit scratch_keychain_delete
    # Made unlocked, then at once no timeout and no lock on sleep: nothing runs on it before both are done.
    if ! scratch_keychain_run create-keychain -p "$scratch_keychain_password" "$scratch_keychain" ||
        ! scratch_keychain_run set-keychain-settings "$scratch_keychain"; then
        echo "scratch_keychain: couldn't make $scratch_keychain unlocked with no timeout" >&2
        scratch_keychain_delete
        return 1
    fi
}

scratch_keychain_delete() {
    [[ -n $scratch_keychain ]] || return 0
    scratch_keychain_run delete-keychain "$scratch_keychain" 2> /dev/null
    rm -f "$scratch_keychain"
    scratch_keychain=""
}

keychain_call() {
    local subcommand=${1:-} arg named=""
    if [[ -z $scratch_keychain ]]; then
        echo "keychain_call: no scratch keychain (call scratch_keychain first)" >&2
        return 2
    fi
    case $subcommand in
        add-generic-password | find-generic-password | delete-generic-password | add-internet-password | \
            find-internet-password | delete-internet-password | find-certificate | find-identity | show-keychain-info) ;;
        *)
            echo "keychain_call: security ${subcommand:-(none)} is refused: it can take the default keychain, the search list or a password prompt" >&2
            return 2
            ;;
    esac
    shift
    for arg in "$@"; do
        [[ $arg == "$scratch_keychain" ]] && named=1
        if [[ $arg == -T* ]]; then
            echo "keychain_call: -T is refused: an access list without security on it asks you on the next read" >&2
            return 2
        fi
    done
    if [[ -z $named ]]; then
        echo "keychain_call: security $subcommand doesn't name $scratch_keychain: it would take the default keychain" >&2
        return 2
    fi
    scratch_keychain_run "$subcommand" "$@"
}
