# Sourced by the scripts that run the tests (test.sh, test-under-load.sh), so that every test process starts from the
# same umask and none of a team session's variables, whoever starts the run: a terminal, a worker's session, or the
# lead's tool server for a merge or an audit, which hands down what it was started with itself. On 2026-11-19 the Linux
# node's merge gate (the tool server under the node's systemd unit, umask 002, the lead's environment) failed a full
# run with 271 issues in 16 suites the branch under test didn't touch. What it carried, and what a test made of it:
# - umask 002, the unit's: a folder a test makes with the default mode is then group-writable (0775), and the wallet's
#   local link refuses a folder others can write ("Library can be written by others": WalletLocalLinkTests,
#   SessionTempTests). 022 here, a terminal's and the Mac's. The check itself is the product's and stays as it is.
# - VIBESWITCHER_SESSION, every session's marker (`HostedSession.environment`): the user's voice is never a process
#   that carries it (`Voice.judge`), and a test speaking to its scratch node as the user is such a process.
# - VIBESWITCHER_CODEX_WORKERS=0, the node's lead's (`LeadStart`): read once as "Codex workers are switched off"
#   (`LeadLaunch.codexWorkersUsable`), by every test of a Codex worker.
# - the rest of what a team's session is given, which a test's own sessions get from the test alone: its role
#   (VIBESWITCHER_ROLE, `LeadLaunch.prepare`), the lead's program and model (VIBESWITCHER_CLAUDE, `RoleProgram`;
#   VIBESWITCHER_LEAD_MODEL, which the lead's toolset reads from its own environment), and a boxed session's door
#   (VIBESWITCHER_DOOR, `SandboxPlanner`), through which a helper reaches the real host: no test speaks to that one.
# What stays: VIBESWITCHER_HOME, which each script sets or unsets itself (the run's scratch home); vs-heavy's own
# (VIBESWITCHER_HEAVY_*, VIBESWITCHER_TEST_LOCK*) and the width's (VIBESWITCHER_TESTS_PER_CORE), which place and size
# the run and say nothing to a test; PATH, HOME and TMPDIR, the scripts' own business.
#
# The variables go only from what runs the tests, not from the script: the script, the vs-heavy it runs them under and
# that one's supervisor keep VIBESWITCHER_SESSION. A session's end finds what its Bash tool started by that marker
# (`SessionStrays.carrying`) and signals it, and vs-heavy's supervisor then ends the tests' tree; a script that had
# dropped the marker from all of them would leave a run going, its slot held, after its session was gone.
#
# known_umask: umask 022, for the script itself from its first lines (it makes the run's scratch home).
# clean_test_environment: the umask and the variables unset, in the shell that then starts test processes and nothing
#   else: the command vs-heavy runs (exported for that bash), a subshell around one test file or one run.
# team_session_unsets: the same variables as `env`'s arguments ("-u NAME" each, unquoted), for a command that must be
#   started in its caller's place (`env $(team_session_unsets) COMMAND… &` keeps COMMAND's pid in `$!`).

# The variables a team's session carries (above), one list.
team_session_variables() {
    echo VIBESWITCHER_SESSION VIBESWITCHER_ROLE VIBESWITCHER_CODEX_WORKERS VIBESWITCHER_CLAUDE VIBESWITCHER_LEAD_MODEL \
        VIBESWITCHER_DOOR
}

known_umask() { umask 022; }

clean_test_environment() {
    umask 022
    unset $(team_session_variables)
    # Not on to the tests: they see the environment a clean run has (as module-cache.sh's swift does with its own).
    export -n -f team_session_variables clean_test_environment
}

team_session_unsets() {
    local name
    for name in $(team_session_variables); do printf -- '-u %s ' "$name"; done
}

# For the bash vs-heavy runs the tests in (test.sh), which takes both from its environment.
export -f team_session_variables clean_test_environment
