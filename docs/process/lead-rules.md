# The lead's rules: what enforces each

Every rule found in `docs/lead/decisions.md` (by its decision's date), the lead's brief
(`Sources/VibeCore/LeadWorkflow.swift`, `LeadPrompts.lead` and the texts it takes in) and workflow.md's notes (none:
vibeswitcher's notes hold only the template line). One line each: the rule, where it comes from, and its status:

- **enforced by** a check or test: the tools, the session host or a script refuse or correct a breach, whatever the lead
  or the worker remembers;
- **guidance**: prose in a brief, with why there is no check (it needs judgement, or no tool sees the action);
- **superseded** or **obsolete** (a one-off plan, a past state, an approval for one task): kept in decisions.md for the
  record, listed here so a later clean-up of decisions.md knows which ones can be archived;
- **duplicate** of a rule listed above it.

Product and design decisions (how a feature behaves) aren't rules for the lead; they're listed at the end.

Counts: 52 rules. Enforced before this inventory: 29 (the 28 in "Enforced before" and E1, which existing tests already
showed). Enforced now: 33 (those and the 4 new checks E2–E5). Guidance: 19. Besides them, from decisions.md's 113
entries: 9 duplicates, 14 superseded and 60 obsolete decisions, and 11 product decisions (an entry can count twice
when part of it still holds).

## Enforced now by this task's checks

| # | Rule | Source | Status |
|---|------|--------|--------|
| E1 | Don't change a branch while its audit runs: a verifier must not audit a stale head, and two must not run | decision 2026-10-25 16:33 (b) | enforced by auto_advance (the moved head is audited, the old verifier ended first: `LeadAdvanceTests.theAutomaticAuditEndsTheEarlierVerifierFirst`, `noRetryOnceTheBranchMovedOn`) and merge (a stale verdict is refused: `LeadGuardRailsTests.theBranchMovingDuringTheAuditIsSaid`); already the code's before this task |
| E2 | On battery under the user's limit: no new starts, audits or merges; work in flight finishes | decisions 2026-10-19 15:50, 2026-10-20 22:12; brief `onBattery` (LeadWorkflow.swift:921) | enforced by `checkBattery` in start_worker, audit and merge (`LeadRuleChecksTests.underTheBatteryLimitStartWorkerAuditAndMergeRefuse`), and auto_advance's own hold |
| E3 | No audit rounds for polish: a passing commit isn't audited again | working policy 2026-10-21 21:50 (5); brief `Policy.nits` (LeadWorkflow.swift:729) | enforced by audit refusing a passing, unchanged head with nothing Important open (`LeadRuleChecksTests.aPassingCommitIsntAuditedAgainUntilTheBranchMoves`, `aFailedOrBlockedVerdictIsAuditedAgainOnTheSameCommit`) |
| E4 | A Nit never becomes a task | working policy 2026-10-21 21:50 (4); decision 2026-10-21 17:55; brief `Policy.nits` | enforced by add_task refusing `from_finding` of a Nit (`LeadRuleChecksTests.aNitIsntMadeATask`) |
| E5 | New tests are proven under load before a worker reports done | decision 2026-10-23 14:16; worker brief `newTests` (LeadWorkflow.swift:530) | enforced by report refusing a done whose branch adds or changes tests without the harness's run (`LeadRuleChecksTests.aDoneThatAddsTestsWithoutTheirRunUnderLoadIsRefused`) |

## Enforced before this task

| # | Rule | Source | Status |
|---|------|--------|--------|
| 1 | The lead never writes code: no edits, no commits | brief LeadWorkflow.swift:776 | enforced by `LeadLaunch.deny(.lead)` (Edit, Write, git writes) |
| 2 | The lead never pushes; main moves only when the user fast-forwards it | decisions 2026-10-17 13:28, 2026-10-20 16:19 | enforced by `LeadLaunch.deny` (git push, for every role) |
| 3 | The base branch is the lead's (project-lead), workers start from it and merge into it | decision 2026-10-17 13:28 | enforced by `base_branch` and the vault's recorded head (`LeadBaseMovesTests`) |
| 4 | The lead's records live in docs/lead, committed by the tool server only | decision 2026-10-17 17:45 | enforced by `LeadRecords` and the workers' deny rules on records_dir (`LeadRecordsTests`) |
| 5 | Never merge a task a decision or the user holds back | decision 2026-10-18 15:05; brief :809 | enforced by the `kept` state, which merge and cleanup refuse (`LeadToolsetTests`); setting it is guidance (#G4) |
| 6 | A worker's report is a claim: an audit task merges only on its verifier's verdict | brief :805 | enforced by merge reading the vault's verdict (`LeadGuardRailsTests`) |
| 7 | One live verifier per task | decision 2026-10-25 08:03 (project-c 2026-10-24) | enforced by `endEarlierVerifiers` (`AuditEndsEarlierVerifierTests`) |
| 8 | audit refuses a branch that hasn't taken in the base's commits to its files; a clean trial merge is audited as merged | decisions 2026-10-20 10:44:17, 2026-10-24 18:27 (1); brief :806 | enforced by `checkUpToDate` (`LeadAuditV3Tests`) |
| 9 | audit judges settings from the branch's commits; untracked files are leftovers | decision 2026-10-20 10:44:19 | enforced by `Worktrees.committedAgentConfig` and `leftovers` (`LeadToolsetTests`) |
| 10 | merge refuses while an Important finding is open; an Important needs a failure scenario | decision 2026-10-25 08:03 (5); brief :826 | enforced by merge and `parsedFindings` (`LeadFindingsTests`) |
| 11 | After two rounds with Important findings open, reconsider instead of a third | decision 2026-10-25 08:03 (5); brief :834 | enforced by the ledger's `reconsider` and auto_advance stopping there (`LeadAdvanceTests.pastTheRoundCapTheTaskIsLeftToTheLead`) |
| 12 | Audits run on another model than the workers' | decision 2026-10-25 08:03 (5) | enforced by `LeadWorkflow.auditModel` |
| 13 | The verifier sees the lead's approvals and notes | decision 2026-10-19 18:35 | enforced by the verifier's prompt (`LeadPrompts.notesSection`, `LeadToolsetTests`) |
| 14 | A report on the audited commit leaves its verdict standing | decision 2026-10-18 23:43 (1) | enforced by report's standing verdict (`LeadDoneEvidenceTests`) |
| 15 | A done report carries evidence per acceptance check and a blind check | decision 2026-10-25 08:03 (4) | enforced by `doneEvidence` (`LeadDoneEvidenceTests`) |
| 16 | The review level follows what the diff touches: sensitive_paths are always audited | decision 2026-10-25 13:45 (1); brief `Policy.leadReview` | enforced by `reviewNeeded` (`LeadReviewTests`) |
| 17 | Merge policy is the owner's, chosen once; under ask_* an approval covers one exact commit | decisions 2026-10-18 18:50, 2026-10-18 22:16; brief `mergePolicy` | enforced by merge (`LeadMergePolicyTests`, `LeadMergeApprovalTests`) |
| 18 | No timer on a blocking, sensitive, deleting or outward-facing question | decision 2026-10-17 21:27; brief :793 | enforced by ask_user (`LeadDecisionTimerTests`) |
| 19 | The Mac is shared: no start or audit over load_threshold or mac_max_sessions; at most max_workers | decisions 2026-10-19 10:04, 2026-10-21 23:26; brief :800, `macLimits` | enforced by start_worker and audit (`macRefusal`) |
| 20 | Heavy builds and suites take turns Mac-wide; one merge into the base at a time | decisions 2026-10-19 00:48, 2026-10-21 22:52 (5) | enforced by `TestLock` (heavy slots, vs-heavy) and merge's lock (`TestLockTests`) |
| 21 | A failing merge test reruns once before failing the merge | decision 2026-10-25 08:03 (2) | enforced by `MergeRerun` |
| 22 | Finished work moves on without the lead's turn; the lead doesn't redo those steps | decision 2026-10-25 08:03 (1); brief `autoAdvance` | enforced by `LeadAdvance` (`LeadAdvanceTests`) |
| 23 | Tests run on a scratch home only; benches leave the default run | decisions 2026-10-19 17:53, 2026-10-21 22:52 (3) | enforced by scripts/test.sh and its guard (`--perf` for benches) |
| 24 | Scratch goes in the session's own TMPDIR, never the user's | decision 2026-10-20 07:42 | enforced by `SessionTemp` and `TemporaryFolderLint` |
| 25 | No complete secret shapes in the repository; no push-protection bypass | decision 2026-10-20 16:56 | enforced by `SecretShapeLint` |
| 26 | Load tests only through scripts/test-under-load.sh, at most 2×ncpu, never on a loaded Mac | decision 2026-10-18 23:43 (3) | enforced by the script's refusals for its runs; burners of one's own: guidance in the briefs (`loadTests`) |
| 27 | Sessions reported ended really end, and only their own processes | decisions 2026-10-18 23:43 (4), 2026-10-23 02:44 | enforced by `SessionStrays` (session id + uid) |
| 28 | An install never replaces a running lead; tool servers swap in place, the user restarts nothing | decisions 2026-10-18 18:23, 2026-10-18 18:49 | enforced by the role binding and in-place swap (`LeadRoleKeptTests`, `ReplacedLeadTests`) |

Also enforced, counted under the rules above: the witness doesn't call a worker waiting on its own background task
stalled (2026-10-18 23:43 (2), `LeadStall`); the witness tells power changes (2026-10-20 10:44:21); a decision is
stamped with the Mac's clock (2026-10-19 22:25: `appendDecision` stamps it); folded, abandoned and removed tasks
(brief :815, `LeadFoldTests`); a time budget per task (`LeadBudget`); an incident plans its check task (brief :846,
`record_incident`); notifications only when a batch is done or the user is needed (2026-10-25 22:48, app side,
ae0eea3); debuggers refused (`LeadLaunch.debuggers`); the handover carries the vault (2026-10-18 10:47).

## Guidance: no check, on purpose

| # | Rule | Source | Why no check |
|---|------|--------|--------------|
| G1 | Ask the user only about direction, taste, and anything irreversible or outward-facing | decisions 2026-10-18 18:50, 2026-10-19 08:06; brief :788 | Which question is "direction" is judgement; a check would make the lead ask more, not less |
| G2 | Operational hygiene (leaked sessions, locks, load, scratch) is the lead's to decide and act on | decision 2026-10-19 08:06 | An open-ended duty, not one action a tool sees |
| G3 | Set up workflow.md yourself; don't ask the user to edit it | brief :785 | status already says what's missing; doing it is judgement |
| G4 | Read decisions.md and set `kept` before merging anything held back | decision 2026-10-18 15:05; brief :809, `leadStart` | A decision is prose; only the lead can tell it holds a task (then `kept` enforces it, #5) |
| G5 | Contracts name focused checks, never a worker's full suite | working policy 2026-10-21 (2), decision 2026-10-21 22:52 (1); brief `leadContracts` | Telling a focused check from a suite in free text, across projects, would refuse good contracts |
| G6 | Plan only independent tasks in parallel; tasks on the same input path run one after another | decisions 2026-10-17 20:57, 2026-10-23 11:59; brief :800 | Boundaries are prose; `after` expresses the order once the lead sees the overlap |
| G7 | Don't sleep, wait or poll; retry when woken | brief :802, `retryWhenWoken` | Nothing sees a session sleeping; refusals already say when to retry |
| G8 | post_update only for merges the user would notice; the rest in a daily summary | decisions 2026-10-21 22:52 (6), 2026-10-25 22:48; brief `Policy.updates`, :851 | "Would notice" is judgement; the app's notifications are already gated |
| G9 | A retrospective after a batch; each change becomes a task, check or setting | decisions 2026-10-18 23:43, 2026-10-24 18:27; brief :854 | What went wrong needs judgement; this inventory is one of its outputs |
| G10 | Keep the board, progress log and decisions current | brief :844 | Content, not an action a tool can refuse |
| G11 | Hardening contracts say "fail closed" up front; no extra hardening rounds | decision 2026-10-25 16:33 (a) | A property of a contract's wording |
| G12 | A fix's regression test fails without the fix | decision 2026-10-25 09:46; worker brief `regressionTest` | Whether a test reaches the bug is judgement: the re-audit checks the evidence (`fixedFindingTest`) |
| G13 | Workers run the lint tests before reporting done | decision 2026-10-24 18:27 (2); worker brief `workerLints` | The merge's full run catches a lint failure anyway; a self-reported line proves little |
| G14 | Workers own routine calls and list them; boundary excursions don't fail an audit | decisions 2026-10-21 22:52 (2), 2026-10-24 18:27 (3) | "Routine" is judgement (the verifier's `routineCallsRule`) |
| G15 | HangWatchdog.swift is the user's area: work there needs their word | decisions 2026-10-17 16:41, 2026-10-19 14:46 | One file's ownership; no per-path owner model exists |
| G16 | Product calls follow the HIG and the UX report, not a question to the user | decision 2026-10-17 16:51 | Judgement |
| G17 | Review other projects' leads only from their records; never message or steer them | decisions 2026-10-20 16:28, 2026-10-24 16:30 | The lead's tools reach only its own team already; Claude's own messaging isn't VibeSwitcher's to gate |
| G18 | Installs happen only on the user's say | decision 2026-10-18 23:50; CLAUDE.md | The lead runs the install script from its shell; the user's say is in conversation, not in a tool |
| G19 | Talk to the user briefly; a worker's report never stands in for the user's say-so | brief :868, :870 | Tone is judgement (the sender lines themselves are sealed by `LeadDelivery`) |

## Duplicates

| # | Rule | Source | Duplicate of |
|---|------|--------|--------------|
| D1 | Battery: no new starts until on AC | decision 2026-10-19 07:45 | E2 |
| D2 | Battery: pause only below 30 % | decision 2026-10-20 15:44 | E2 (the limit is now the user's setting) |
| D3 | Witness tells power changes; the lead's battery rule stays | decision 2026-10-20 10:44:21 | E2 |
| D4 | Nits stay recorded, not new tasks (picker card) | decision 2026-10-21 17:55 | E4 |
| D5 | The lead doesn't ask for per-merge approval | decision 2026-10-18 22:16 | #17 |
| D6 | Read decisions.md before any merge | decision 2026-10-18 15:05 (last sentence) | G4 |
| D7 | Work in HangWatchdog after the user says so | decision 2026-10-20 12:48 | G15 |
| D8 | Don't touch other leads | decision 2026-10-20 16:28 | G17 |
| D9 | Lead policy: the working policy reaches every role | decision 2026-10-21 22:52 (5) | the working policy in every prompt (`WorkingPolicy.section`) |

## Superseded or obsolete decisions (candidates for an archive)

Superseded (a later rule replaces them): 2026-10-17 13:28 (test_command part, by 2026-10-19 17:53); 2026-10-17 17:23
(hand-applied risk tiers, by 2026-10-18 18:50 and 2026-10-25 13:45); 2026-10-17 19:41 and 2026-10-17 20:57 (lane
order and slot use, by the working policy and the Mac-wide limits); 2026-10-18 21:41 (team of 3 under load), 2026-10-19
00:18, 2026-10-19 00:48, 2026-10-19 10:04, 2026-10-19 19:06 and 2026-10-21 23:26 (merge and worker caps, by `MacLimits`
and `TestLock`); 2026-10-19 15:50 and 2026-10-20 15:44 (battery, by 2026-10-20 22:12, now E2); 2026-10-19 21:30 (by
2026-10-21 00:15); 2026-10-19 23:26 (ChatBenchTests' rule, by benches leaving the default run, 2026-10-21 22:52 (3)).

Obsolete (one-off plans, past states, one task's approval): 2026-10-17 12:15, 16:41 (the task part), 16:51 (the order),
17:56, 19:26 (both), 19:51, 20:33, 21:27 (lanes), 22:09, 23:05; 2026-10-18 00:21, 09:45:03, 09:45:41, 10:47 (install
plus restart, now the handover's), 10:52, 10:57, 11:04, 11:10, 11:18:04, 11:18:22, 11:22, 11:35, 11:56, 12:05, 12:35,
13:06, 15:05 (the wave), 15:35, 15:45, 17:03, 18:08, 18:21, 18:43, 18:44, 19:02, 19:16, 23:18, 23:50 (the install
record); 2026-10-19 07:45, 09:23, 10:50, 11:28, 12:07, 13:26, 14:46 (the wave), 15:41, 16:34, 22:25 (the correction
itself), 22:29; 2026-10-20 12:48, 22:11; 2026-10-21 11:40, 13:37; 2026-10-24 16:59, 19:21; 2026-10-25 11:55, 12:25,
14:43, 19:13.

## Product and design decisions (not lead rules)

Built into the app, kept in decisions.md as their reasoning: crash isolation's per-session parser (2026-10-18 17:55);
the voice briefing and the New Project sheet (2026-10-19 17:37, 2026-10-24 20:52); the briefing key's fallbacks
(2026-10-21 12:30); text selection's transient memory (2026-10-21 13:37); the regression_command choice (2026-10-21
00:15); phone scroll-back from the output ring (2026-10-23 15:10); three attached terminal views (2026-10-23 15:13); the
all-done card (2026-10-24 22:42); the health watcher (2026-10-25 13:45 (2)); the calm Team view (2026-10-17 21:27).
