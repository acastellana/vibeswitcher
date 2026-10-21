# Sourced by the scripts that run swift build or swift test (scripts/test.sh, scripts/build-app.sh): one build or test
# run at a time on this Mac. Two workers' suites side by side starved each other and the benches (3–4 min each at load
# 30–50, measured 2026-10-21), so the second waits, saying for whom. merge and an audit's shared run take the same
# lock (`TestLock` in VibeCore) around their test command.
#
# The lock is a flock on $VIBESWITCHER_TEST_LOCK_DIR/test-build.lock (default /private/tmp/vibeswitcher-<uid>/), held on
# the script's fd 9: the kernel lets go of it when the script exits, Ctrl-C and kill -9 too, so a run that died leaves
# no lock behind (its .holder note says who held it last; the next holder writes its own). macOS has no flock(1):
# /usr/bin/perl takes it on fd 9 and exits, and the lock stays with the script's fd.
#
# test_lock WHAT: waits for the lock (saying once who holds it), then holds it until test_unlock or the script exits,
#   and exports VIBESWITCHER_TEST_LOCK naming it: a run under one that holds it (the merge's test command, a test that
#   runs a script) doesn't wait for its own ancestor. Run swift with `9>&-`: nothing it leaves running keeps the lock.
# test_unlock: lets go of it.

test_lock_dir=${VIBESWITCHER_TEST_LOCK_DIR:-/private/tmp/vibeswitcher-$(id -u)}
test_lock_file=$test_lock_dir/test-build.lock
# 1 while this script holds it (not when an ancestor does).
test_lock_held=0

# flock on fd 9; with "nb", only if it's free (status 1 when it isn't).
test_lock_fd9() {
    /usr/bin/perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or exit 2; flock($fh, LOCK_EX | ($ARGV[0] ? LOCK_NB : 0)) or exit 1' "${1:+1}"
}

test_lock() {
    local what=$1 start=$SECONDS
    [[ ${VIBESWITCHER_TEST_LOCK:-} == "$test_lock_file" ]] && return 0
    mkdir -p -m 700 "$test_lock_dir" || { echo "$what: can't make $test_lock_dir for the test and build lock"; return 1; }
    # /private/tmp is everyone's: a folder someone else made there (or a link) isn't taken as this user's.
    [[ -O $test_lock_dir && ! -L $test_lock_dir ]] || { echo "$what: $test_lock_dir isn't a folder of yours: the test and build lock can't be kept there"; return 1; }
    exec 9>> "$test_lock_file" || { echo "$what: can't open $test_lock_file"; return 1; }
    if ! test_lock_fd9 nb; then
        echo "$what: waiting for the Mac-wide test and build lock ($test_lock_file), held by $(cat "$test_lock_file.holder" 2> /dev/null || echo "a run that didn't say who it is")."
        test_lock_fd9 || { echo "$what: couldn't take the test and build lock"; return 1; }
        echo "$what: took the test and build lock after $((SECONDS - start)) s."
    fi
    echo "pid $$, $what in $PWD, since $(date +%H:%M:%S)" > "$test_lock_file.holder"
    test_lock_held=1
    export VIBESWITCHER_TEST_LOCK=$test_lock_file
}

test_unlock() {
    [[ $test_lock_held == 1 ]] || return 0
    exec 9>&-
    test_lock_held=0
    unset VIBESWITCHER_TEST_LOCK
}
