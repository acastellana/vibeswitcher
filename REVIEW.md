# Review rules for VibeSwitcher

## Important
Each rule: its id, the rule, its Trigger (what in a diff makes it apply; "any diff": it always does) and its Source
(where it came from, found with `git log -S` on its line; "source unknown" when nothing names one).

- **R1** A host call, git, disk read, lock or wait on the main thread: give the call path from the UI event to it.
  Trigger: app code (Sources/VibeSwitcher/, @MainActor, DispatchQueue.main, a SwiftUI body) that calls the host, git,
  a process, FileManager, a lock or a wait.
  Source: source unknown (2240cd4d, carried from 80530b88's "main-thread stalls"; no incident named).
- **R2** An AppKit object (NSFont, attributed string, view) two threads can reach: a shared NSFont leaked and raced once.
  Trigger: NSFont, NSAttributedString or an NSView made, cached or used off the main thread, or kept in a shared cache.
  Source: likely selecting-text-in-the F5, a data race on a shared NSFont (verifier-eval.md, 2026-10-21).
- **R3** One session's state kept in a value all sessions share: switch to another session and back, and check it resets.
  Trigger: a stored property of an object that serves every session (ChatSync, ChatModel, MainWindow/) holding
  per-session state.
  Source: a-slash-command-that F1: noMenuSince, one value for all sessions, never reset on a switch (2026-10-21).
- **R4** A queue or buffer fed by a session's output or the user's input with no bound.
  Trigger: an array, Data, queue or outbox appended from a session's output or typed input (HostedSession, the parser
  link, ChatSync, ChatModel, the steer inbox, RemoteServer).
  Source: likely the memory audit of 2026-10-22, findings 5 and 6: the parser link's outbox copy, the open chat's
  uncapped log (docs/eval/memory-2026-10-22.md).
- **R5** A test that passes alone but fails in the full suite or under scripts/test-under-load.sh, or that waits on a pipe,
  process or file with no time limit.
  Trigger: a new or changed test (Tests/), or a test helper's wait on a pipe, process or file.
  Source: likely ending-a-session-ends F1 and F2: a new test failing in the suite, one reading a running process's
  terminationReason (2026-10-23).
- **R6** A test that reaches the real home: ~/.vibeswitcher, the host socket, the Mac-wide test lock (a default argument
  counts), real sessions or real windows.
  Trigger: a new or changed test (Tests/), or a default argument in Sources/ that resolves to the real home, the host
  socket or the Mac-wide test lock.
  Source: likely 36dd4511 (2026-10-22): rebaseAndTest and auditRun defaulted to the Mac-wide lock, so tests waited on
  real builds.
- **R7** A secret, token, pairing code or session screen in a log line, an error text or a headless Claude prompt.
  Trigger: a log line, error text or headless Claude prompt the diff adds or changes, or a change to Redaction.
  Source: source unknown (2240cd4d, carried from 80530b88's "secrets in logs"; no incident named).
- **R8** A change to a role's allow or deny rules: try each allowed command with options that read or write elsewhere
  (--remote, --exec, --add-file, -o, a symlinked folder). One escape is Important.
  Trigger: a role's allow or deny rules (LeadLaunch.swift, .claude/settings*).
  Source: a-fix-s-regression F1-F3: git archive --remote/--exec, --add-file and a symlinked folder escaped (2026-10-25).
- **R9** Branch code that merge runs (test scripts, the harness) able to reach host.sock, the vault or the lead's files.
  Trigger: test scripts (scripts/test*), the test harness, test_command or init_command handling, or what merge passes
  to the processes it starts (environment, file descriptors).
  Source: likely auto-advance-s-reports F1: a merge's test-command children count as the lead at the vault (decision
  2026-10-25 12:25:44).
- **R10** A setting or hold read once, then acted on after a step that takes minutes (a merge, a test run).
  Trigger: code that reads a workflow setting, a hold or a task's state, then merges, runs tests or audits.
  Source: finished-work-lands F1: auto_advance and the hold read once per pass (LeadAdvance.swift, 2026-10-25).
- **R11** A run that crashed or was stopped, treated as one that finished: what does the next step do with its partial result?
  Trigger: code that reads a process's, test run's, audit's or session's result or exit status.
  Source: steadier-merge-gate F1: a crashed run reran with --filter, so the rest of the suite never ran (52dca29a).
- **R12** An operation still running when the code decides (a command in flight, a merge mid-way): who counts it, and as what?
  Trigger: code that classifies or counts operations by their state (base moves, the merge queue, counts and limits).
  Source: a-base-branch-the F2: a team's git command still running didn't mark the base move as the team's (52dca29a).
- **R13** One branch of a path handled (clean but not conflicted, found but not missing): walk the other.
  Trigger: a condition on an outcome the diff adds or changes (an if, guard or switch: clean or conflicted, found or
  missing, success or error).
  Source: lead-record-commits F1: only conflicted records took the base's version, so a cleanly merged one kept the
  branch's edits (52dca29a).

## Nit, never more
- Copy, naming, comments, blank lines, a doc comment that slid off its function, line length.

## Report
- Each finding: file:line from the repository root, and the command or the code that shows it.
- An Important finding gives its failure scenario: this input or state gives this wrong result, stall or crash.
- Last line: the count by severity ("2 Important, 1 Nit"), or "no issues".
