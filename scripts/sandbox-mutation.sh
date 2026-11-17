#!/bin/bash
# scripts/sandbox-mutation.sh [STEP...]: shows that the session sandbox's shim is tested to fail without each of its
# steps (the session sandbox plan's SB1). It builds the tests once with the shim's mutation switch
# (-Xcc -DVIBE_SANDBOX_MUTATION, into .build/sandbox-mutation, never the normal build), runs the shim's suites once
# with no step skipped, which must pass, then once per step with VIBE_SANDBOX_SKIP=<step>, which must fail. It names
# each step's result and the tests that failed, and exits 1 when a step's run passed (that step is tested by nothing),
# failed without a test naming it (a build or a crash: it proves nothing) or the baseline failed. Run it alone: another
# scripts/test.sh at the same time holds .build's database. Every run is scripts/test.sh (a scratch home), under vs-heavy as that is.
#
# The steps (shim_sandbox.c's `skipped("…")`), with the test that should catch each:
#   private        the mount tree made private      SandboxShimTests.theProgramSeesOnlyWhatThePlanMounts
#   attributes     a bind's flags (ro, nosuid…)     SandboxShimTests.aReadOnlyMountRefusesWritesAndKeepsItsLockedFlags
#   read-only      a read-only bind's ro            SandboxShimTests.aReadOnlyMountRefusesWritesAndKeepsItsLockedFlags
#   root read-only the root's own folders read-only SandboxShimTests.theProgramSeesOnlyWhatThePlanMounts
#   network        the network namespace            SandboxShimTests.anEmptyNetworkHasLoopbackAndNothingElse
#   pid            the pid namespace                SandboxShimTests.theProgramSeesOnlyItsOwnProcesses (and /proc fails)
#   death signal   init killed with its keeper      SandboxShimTests.aKilledKeeperEndsTheNamespace
#   not dumpable   init non-dumpable                SandboxShimTests.initIsNotDumpableAndCantBeTracedOrReadFromInside
#   foreground     the terminal's foreground group  SandboxShimTests.theProgramIsItsTerminalsForegroundGroupAndTheKeeperItsLeader
#   session        a run's own session              SandboxShimTests.aRunWithNoTerminalHasNone
#   capabilities   every capability dropped         SandboxShimTests.theProgramIsTheUsersUidWithNoCapabilityAndNoNewPrivileges
#   no_new_privs   no_new_privs                     every box test (the filter can't load without it)
#   descriptors    descriptors past 2 closed        SandboxShimTests.theProgramHoldsNoDescriptorButItsThree
#   filter         the seccomp filter               SandboxSeccompTests
# Logs: .build/logs/sandbox-mutation-<step>.log.
set -uo pipefail
cd "$(dirname "$0")/.."

steps=("$@")
if [[ ${#steps[@]} -eq 0 ]]; then
    steps=(private attributes read-only "root read-only" network pid "death signal" "not dumpable" foreground session
           capabilities no_new_privs descriptors filter)
fi
suites='SandboxShimTests|SandboxSeccompTests|SandboxFactsTests'
build=(--scratch-path .build/sandbox-mutation -Xcc -DVIBE_SANDBOX_MUTATION)
mkdir -p .build/logs

run() {
    local name=$1 log=.build/logs/sandbox-mutation-$1.log
    shift
    env "$@" bash scripts/test.sh "${build[@]}" --filter "$suites" >"$log" 2>&1
}

failures=0
if run baseline; then
    echo "baseline (no step skipped): passed"
else
    echo "baseline (no step skipped): FAILED, see .build/logs/sandbox-mutation-baseline.log"
    failures=1
fi
for step in "${steps[@]}"; do
    name=${step// /-}
    log=.build/logs/sandbox-mutation-$name.log
    if run "$name" VIBE_SANDBOX_SKIP="$step"; then
        echo "without '$step': every test passed: NOTHING TESTS THIS STEP"
        failures=1
        continue
    fi
    # A step counts as tested only when a test failed on it: a build that failed, a run that crashed or another
    # build holding .build (scripts/test.sh builds the default one first) proves nothing.
    failed=$(grep -oE '✘ Test [A-Za-z]+\(\)' "$log" | sed 's/✘ Test //; s/()//' | sort -u | tr '\n' ' ')
    if [[ -n $failed ]]; then
        echo "without '$step': failed: $failed"
    elif grep -q 'database is locked' "$log"; then
        echo "without '$step': COULDN'T TELL: another build held .build; run it again alone ($log)"
        failures=1
    else
        echo "without '$step': COULDN'T TELL: the build or the run failed with no test named ($log)"
        failures=1
    fi
done
exit $failures
