Steadier merge gate: flaky retry and early catch-up

Merges stop bouncing on flaky tests and late conflicts. When a merge's test run fails, the failing tests run once more. If they pass on that rerun, the merge goes ahead and the flake is recorded. A test that flakes repeatedly becomes a task. A real failure (it fails again) goes back to the worker as today. When project-lead moves and touches files a running task's branch also changes, that task's worker is told at once to merge project-lead, while the conflict is still small, instead of discovering it at merge time.

Acceptance checks:
- A merge whose test command fails once and passes on the rerun merges. The failure is recorded with the test names in a flake ledger under .vibeswitcher (or the board), and status shows it. A test drives this with a fake test command.
- A merge that fails twice is refused with the second run's output, as today. The rerun happens once, never more.
- The rerun is the failing tests only when the test command supports filtering (scripts/test.sh with swift test: decide and document), else the full command. Either way, only a passing full-suite-or-rerun result merges. Say in the report how much time a rerun costs vs today's retry by the lead.
- A test that flaked 3 times within 7 days makes record_incident-style planned task naming the test (once, not per flake).
- After a merge moves project-lead, each running task whose branch changes a file that the merge also changed gets one message to its worker: merge project-lead now, naming the files. Branches that overlap no files get nothing. A test covers both.
- Today's 17-of-29 'failed then passed on retry' figure came from the lead re-running merge by hand. Write in the report which tests failed that way, from the progress log/merge logs, and whether any is a real bug rather than a flake (fix it if it is small; else add_task text in the report).
- Affected tests while editing; the full `bash scripts/test.sh` once before reporting done; new tests pass under scripts/test-under-load.sh.

Boundaries:
- The merge path in Sources/VibeCore/LeadToolset.swift (the test run and its refusal), TestLock.swift only if needed for the rerun's slot, LeadBoard.swift/LeadRecords.swift for the flake ledger, LeadDelivery.swift for the catch-up message, scripts/test.sh only for a filtered rerun, and their tests.
- Don't weaken the gate: a merge still needs a passing test run on the rebased head. Never retry more than once, and never skip regression_command.
- Don't touch automatic merging or dispatch (task finished-work-lands), audits (Audit v3), worker done reports (evidence task) or the sandbox app task. They run in parallel near this code. Merge project-lead in early and often.

Context:
Why: over the last days 17 of 29 failing merge runs passed when rerun, and 21 merge conflicts cost 40.7 task-hours, most found only at merge time. Stripe's agent pipeline allows one CI retry, and Anthropic/OpenAI keep branches small and caught up. The user approved this as part of Lead Process v3 phase 1 on 2026-10-25.

The merge gate is in Sources/VibeCore/LeadToolset.swift ~l.1446-1600 (rebase, test command, fast-forward, the refusal text that goes back to the worker). The test command is `bash scripts/test.sh` (swift test, under the Mac-wide test lock in TestLock.swift). Merge logs and the lead's progress log are in docs/lead/progress.md and under .vibeswitcher.

House rules: never test input on real sessions; never attach debuggers; scratch HOME/defaults in tests (Scratch.defaults). The lead never pushes.

Sibling tasks running in parallel (slugs): finished-work-lands, workers-run-a-sandboxed, done-reports-carry, audit-v3-blocking.

Lead: Worktrees.swift (rebaseAndTest/runChecks) and the new MergeRerun.swift are accepted as within scope: the same-worktree rerun needs them. Keeping the flake ledger on board.json is accepted. The worker's report tool predated the evidence schema (it was an old session), so evidence in the report text is accepted for this task.
