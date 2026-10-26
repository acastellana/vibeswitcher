Ending a session ends what its agent started

When a worker's, verifier's or user's session ends (stop_worker, cleanup, role sweep, End Session), the processes its agent started end too, including Bash-tool commands in their own process groups, run_in_background servers and setsid'd children reparented to launchd. Today terminate() signals only the shell's group and the terminal's foreground group, so dev servers and suites run on for days in deleted worktrees (seen: node serve.mjs on :8833 for 3 days 16 h, npm run serve for 4 days). Scope (lead's decision): only processes of the same uid that carry that session's VIBESWITCHER_SESSION=<id> in their environment, plus, at cleanup, processes whose cwd is inside the worktree being removed. Nothing else.

Acceptance checks:
- Scratch-host test: a session runs `perl -e 'setsid; sleep 300' &` (and a plain background job in its own group); after the session is ended, both are gone within 10 s
- Test: cleanup of a worktree ends a process whose cwd is inside it and leaves one whose cwd is elsewhere
- Test: a process of another session (different VIBESWITCHER_SESSION) and one with no such variable are never signalled
- TERM first, KILL at the 5 s mark, as terminate does today
- bash scripts/test.sh passes

Boundaries:
- Sources/VibeHost (HostedSession.terminate, HostServer.endOrphans), the cleanup path in Sources/VibeCore, and tests
- Same uid only; never a process without the ended session's id (or, at cleanup, without a cwd in the removed worktree)
- Never signal real sessions or other projects' processes from tests: scratch hosts and children the test started only
- Don't add a sweep of today's existing orphans on the real Mac; the user decides about those

Context:
Process audit 2026-10-22, finding #1 (docs/eval/processes-2026-10-22.md on project-lead once merged, else `git show agent/audit-2026-10-22-3:docs/eval/processes-2026-10-22.md`). HostedSession.swift:663-671 (terminate), HostServer.swift:700-715 (endOrphans covers parsers and tool servers only), HostedSession.environment :105 sets VIBESWITCHER_SESSION. Reading another process's environment: KERN_PROCARGS2, same uid. Review audit: it kills processes.
