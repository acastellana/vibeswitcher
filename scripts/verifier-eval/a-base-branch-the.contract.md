A base branch the user moves never blocks merges until a restart

A commit the user makes on the base branch, from a terminal, an IDE or their own session, never leaves merges refused until a lead restarts. It's accepted automatically when it can be attributed. Otherwise the user gets a one-click prompt they actually see, and the merge refusal names it. When the base is checked out in a worktree outside the team's, merge says exactly what to do.

Acceptance checks:
- Diagnosis written into the task report: why project-c's 2026-10-22 18:07 base move (af9036f on fair-launch, committed by the user as the lead had asked) was neither accepted automatically nor offered as a one-click prompt, and why merge refused 6 times with 'moved since the lead last left it'. Read project-c's board, progress.md, ~/.vibeswitcher/host.log and its lead transcript 1c42d24c-*.jsonl, read only.
- The fix, with a test that reproduces that case: a base move by a non-team process leads either to automatic acceptance (attributable to the user's own session, per the-user-s-own) or to a visible accept prompt in the app. The lead's refusal says which, and no lead restart is needed.
- When the base is checked out in a worktree outside .vibeswitcher (project-c: .claude/worktrees), merge's refusal names that worktree, whether it is clean, and the one action that unblocks it (test).
- The guard against unattributed moves by team sessions is unchanged, and its existing tests pass.
- The affected tests pass. The merge runs the full suite.

Boundaries:
- Sources/VibeCore/LeadBaseMoves.swift, Sources/VibeSwitcher/MainWindow/Lead/BaseMoves.swift, LeadController.swift (base-move wiring only), LeadVault*.swift and LeadToolset.swift as call sites only, the refusal text in Worktrees.swift around :540-560, and their tests.
- Read project-c's files only. Never write there, message its lead, or touch its git.

Context:
On 2026-10-22 project-c lost about 16 h. Five audited tasks waited 8.6 h on the 'moved' refusal, then on 'checked out in .claude/worktrees' until 09:56 the next day, and it ended in a forced lead handover. The user's direction of 2026-10-18 (decisions.md, 18:49): running VibeSwitcher must be seamless; the user never restarts a lead or confirms their own commits; what can't be attributed gets a one-click prompt, never a restart. Evidence: /private/tmp/claude-501/-Users-albert-dev-vibeswitcher/9f1ce4d8-7f5e-4b39-b432-f985b701d5ec/scratchpad/project-c/report.md (read only).

Lead accepts, 2026-10-24 (before audit): MainWindowController.swift (3 lines in sendToSelected handing sent text to baseMoves.typed), the onTaken Taker change and its LeadController delivery, and the BaseMovesTests deinit that drains its reads queue. These are the goal's wiring. The lead also asked for the tightening in 119adba (a typed line counts only for entries after it, within 30 s, used once).
