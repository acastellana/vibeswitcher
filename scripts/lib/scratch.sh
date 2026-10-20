# Sourced by every script under scripts/ that runs swift build, swift test or swift run, or has something to do on
# exit (ScriptScratchLintTests). Each swift build, swift test or swift run leaves empty TemporaryDirectory.XXXXXX
# folders in TMPDIR that SwiftPM never removes (7 a no-op swift build, 5 a swift test --skip-build, measured
# 2026-10-20; 32,871 had piled up in the user's /var/folders/…/T/). Here they go in a scratch folder that's removed
# when the script exits, Ctrl-C too.
#
# scratch_tmpdir PREFIX: makes $tool_scratch (mktemp -d /tmp/PREFIX.XXXXXX, 0700) with tmp/ in it (0700), exports
#   TMPDIR=$tool_scratch/tmp/, and removes $tool_scratch on exit. Short: tests and the session host put sockets under
#   TMPDIR, and a socket's path is limited to 104 bytes.
# on_exit COMMAND…: what the script would have put in its own `trap … EXIT` (a second trap would replace this one's,
#   and the scratch would stay): run in order on exit, before the scratch folder goes. Every script under scripts/
#   uses it, scratch or not, so no `trap … EXIT` is ever set beside it (ScriptScratchLintTests).
# with_tmpdir DIR COMMAND…: COMMAND with TMPDIR=DIR, for a run given a TMPDIR of its own (test-under-load.sh's
#   suites). This file is the one place under scripts/ that sets TMPDIR (ScriptScratchLintTests).

tool_scratch=""
exit_hooks=()

scratch_tmpdir() {
    tool_scratch=$(mktemp -d "/tmp/$1.XXXXXX") || { echo "can't make a scratch folder under /tmp"; exit 1; }
    trap scratch_exit EXIT
    mkdir -m 700 "$tool_scratch/tmp" || exit 1
    export TMPDIR=$tool_scratch/tmp/
}

on_exit() {
    exit_hooks+=("$*")
    trap scratch_exit EXIT
}

with_tmpdir() {
    local dir=$1
    shift
    TMPDIR=$dir "$@"
}

scratch_exit() {
    local status=$? hook
    # /bin/bash 3.2 calls an empty array unbound.
    for hook in ${exit_hooks[@]+"${exit_hooks[@]}"}; do eval "$hook"; done
    # Not from the terminal: rm would ask about each read-only file a build left.
    [[ -n $tool_scratch ]] && rm -rf "$tool_scratch" < /dev/null
    return $status
}
