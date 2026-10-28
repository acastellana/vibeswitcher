# Decisions

Archived decisions: 70 entries (superseded, obsolete or now enforced by a check) are in decisions-archive.md, moved there unchanged (last on 2026-10-26).

## 2026-10-17 13:28 Base branch is project-lead, not main. Workers start from project-lead and verified work fast-forwards project-lead. main/origin/main stay untouched; moving them is a release decision for the user. test_command will be `swift build && swift test` (README's development check).

project-lead is the live product: the installed app (12:15) was built from its head (aff7317), and main is 70 commits behind and equal to origin/main. aff7317 already implements "a lead builds on the branch checked out when it first started", but this lead's tool server started at 12:12 from the previous build, which always used main. Reconnecting the server picks up that fix, so no files need editing.

## 2026-10-17 16:41 The chat layout hang is taken by a lead worker (fix-the-chat-layout) right away, ahead of the rest of phase 2. The user's own session keeps HangWatchdog.swift, and lead workers stay out of it. Evaluation runs must set CFFIXED_USER_HOME as well as HOME to isolate from ~/.vibeswitcher.

A 13-minute main-thread hang happened live at 16:26 on the current build, triggered by opening the chat for this lead's transcript. That contradicts the other session's 'no real hangs since 10:48', and it's the worst user-facing defect found so far. NSHomeDirectory ignores $HOME on macOS (engineering finding E-30), so HOME alone doesn't isolate test runs.

## 2026-10-17 16:51 Phase 2 order, one worker per area so files don't collide: (1) chat hang and the lead's self-configuration (running); (2) session detection; (3) standard Mac keys (⌘W closes the window, End Session moves elsewhere and always confirms; full Edit menu); (4) the lead's worker-state bugs and question withdrawal; (5) first run and one Settings window; (6) accessibility, after the chat fix lands. Security fixes get top priority as soon as that report is verified. Product calls are made by the HIG and the UX report, not by asking the user.

The user asked the lead to decide big-picture questions itself. Ordering by user impact, with no two workers in the same files, avoids rebase conflicts. ⌘W ending sessions risks data loss and breaks a universal Mac convention.

## 2026-10-17 17:45 The lead's decisions.md and progress.md move into the repository (docs/lead/ by default) and are committed to the base branch automatically by the tool server, touching only those files. board.json, workflow.md and run/ stay local and git-ignored.

User's call. The project's reasoning should survive a lost .vibeswitcher folder, another machine or a new lead, and be visible to teammates. The board holds transient state (sessions, PIDs, questions) and stays local.

## 2026-10-17 21:27 The pipeline-lane design is replaced by a calm one-line-per-task Team view with AI plain-language summaries (headless `claude -p`, small model, cached and throttled, can be switched off) and a fading feed of the lead's decisions. Questions get proposals with a 10-minute default timer, where silence means the lead goes ahead. Risky or blocking questions never get a timer.

The user found the lanes noisy and space-hungry and wants a glanceable high-level view in which past things fade out. The timer keeps work moving without the user having to answer, and the risky-question exclusion keeps irreversible calls with the user.

## 2026-10-18 17:55:49 Accepted the crash-isolation cost: one parser process per session, adding about 3.5 MB of footprint per session (about 130 MB at 37 sessions) and no idle CPU. The parser keeps the 5,000-line scrollback.

Measured on release builds, the host plus parsers use 42 MB of footprint at 10 idle sessions, against 9 MB before. In exchange, one session's parser trap or stall no longer takes down every session. The phone's transcript view asks for 5,000 lines, and the raw replay can't stand in for the scrollback, so it isn't cut to 1,000.

## 2026-10-18 18:20:47 merges-and-worker-limits may add a test_timeout_min key (default 45) to workflow.md: it's parsed in LeadWorkflow.swift and can be set through configure. LeadWorkflow.swift and configure's entry have been added to its boundaries.

E-17 asks for the merge's test-time bound to be configurable, and workflow.md is where every other workflow setting already lives. The edit is one key, one parse line and one configure entry, each with tests.

## 2026-10-18 18:23:05 An install must not replace a running lead. The lead session that is live keeps its role and conversation, and a new lead starts only when none is live or when the user asks for one, after a confirmation. This is task a-running-lead-keeps, started now. It changes the guard rails' role binding, so it's shown to the user before merging. Install plans stop telling the user to restart the lead from the app.

At the 18:10 install, the films lead lost its role mid-conversation. The user's answer ('Do what we need to do') and its decisions never reached the board, and the refusal pointed to /mcp, which can't give the role back. The earlier claim that 'the transfer worked' was only true of the sessions, not of the leads.

## 2026-10-18 18:49:28 Direction from the user: running VibeSwitcher must be seamless. The user never restarts a lead, runs /mcp, or confirms their own commits. Three tasks deliver it: (1) a-running-lead-keeps: installs never replace a running lead, the team keeps its grants, and when a new lead does start it's adopted rather than replacing. (2) tool-servers-update-in: every vibeswitcher-mcp swaps itself for the new build in place (exec between requests, same stdio and grant). (3) the-user-s-own: a base move made by the user's own (non-team) sessions is accepted automatically, provided the session is identified by what the host can verify. Anything else falls back to a one-click prompt in the app, never a restart. The current a92a8dc block is cleared once, at the end: the user does one restart and then one install, after which none are needed. The three are shown to the user together before merging, because they change guard rails.

The user said: "all of this restarting the leaders … is just too complex … do whatever you need to do to make this seamless". The guard rail against unaudited base moves stays, but it learns to tell the user's own commits from the team's. Commits it can't attribute still need a click, never a restart. One last restart can't be avoided, because these fixes have to merge through the very check they replace.

## 2026-10-18 18:50:08 Merge policy for vibeswitcher, set by the user: the lead merges audited work by itself, including guard-rail, security and hook-installer changes, and doesn't ask per merge. It then posts an update saying what changed, how it was checked, the risk and how to revert. This replaces the 2026-10-17 17:23 hand-applied risk tiers. The user is asked only about direction, taste, and anything irreversible or outward-facing (pushing, publishing, deleting work). The lead also checks in with the user proactively and runs a short retrospective now and then.

The user said asking them about every merge is annoying and mostly pointless. Merge behaviour is something the lead should agree with the project owner once, and then the lead should be proactive: ask how they want things done, check how things are going, and run retrospectives.

## 2026-10-18 22:16:10 New lead (22:12). merge_policy is now written as auto in workflow.md, per the user's 18:50 choice; the policy question is settled and never asked again. Merge order changes from the 21:41 plan: nothing merges while the Mac is under the pastedeliverytests-hold verifier's deliberate load (96 `yes` processes, load 160–190); when that audit passes, pastedeliverytests-hold merges first (test-only, one file), because its fix removes the flaky test that failed tool-servers-update's merge and would flake every other merge; then tool-servers-update, the-user-s-own, a-running-lead-keeps, the-witness-doesn-t (expect a LeadWitness conflict), merges-and-worker-limits. stale-git-index-lock reruns its last full check only once the 1-minute load is under 40. Sessions of four merged tasks (no-silent-data-loss, tests-stay-green-under, input-is-never-cut, a-successful-handover-is) are cleaned up now to free memory.

Every merge runs the full suite, and PasteDeliveryTests fails under load; landing its fix first makes the other five merges reliable. The verifier's heavy-load phase is finite and ends before its full-suite runs. Earlier tonight memory pressure killed workers and a 15-minute hang hit the user, so idle sessions of merged tasks shouldn't stay alive.

## 2026-10-18 23:43:32 Retrospective changes (2026-10-19 00:10): (1) audit evidence must survive a worker's report on an unchanged commit (task "Audit evidence survives a worker report on the same commit"); until it lands, the lead tells workers to answer non-code requests with progress(text:), never report(summary:). (2) The witness must not call a worker stalled while it waits on its own background task (task of that name). (3) Load tests run only through scripts/test-under-load.sh, capped at 2×ncpu, refusing an already loaded Mac (task "One load harness"); until it lands, every contract and audit that involves load says "at most 2×ncpu load processes, stopped by pid afterwards, never when the 1-minute load is already above 2×ncpu". (4) Sessions reported ended must really end (task ended-sessions-really, started).

Each cost real time tonight: a reset audit cost 25 minutes and two verifier runs; a false stall woke the lead for nothing; a verifier's 96-process load slowed every other session for 25 minutes; seven leaked sessions hold 2.4 GB on a Mac that ran out of memory twice today. A rule in a note is forgotten by the next lead; a check isn't.

## 2026-10-19 08:06:04 From the user (2026-10-19 08:05, answering the leaked-sessions question): operational hygiene is the lead's to decide, carefully and holistically, not the user's: leaked or stale sessions, stale lock files, load and memory on the Mac, scratch leftovers. The lead acts (from its own shell when the tools can't, with each target re-verified first) and reports what it did; it asks the user only for direction, taste, and anything irreversible or outward-facing. The seven leaked sessions are ended by the lead now with SIGHUP, each pid checked against its task's session command line before the signal.

The user's words: "This is the type of thing that you should be able to decide yourself in a careful manner and thinking holistically." The question sat seven hours for an action that was safe to take: idle sessions of merged tasks, confirmed by ps, that no tool could end.

## 2026-10-19 17:37:49 Product choices made by the lead on 2026-10-19 19:3x for the user's two feature requests, without asking (reversible, in branches, audited before merge): (1) the voice briefing is one "Brief me" button in the window toolbar and the menu bar popover, 70–90 words written by the same headless Claude path as the team one-liners, in a language chosen in Settings (default the Mac's first preferred language), spoken by ElevenLabs when an API key is set in Settings (kept in the Keychain) and by the Mac's own voice otherwise; the text is redacted before any model or network call and leaves the Mac only on the button; the phone gets the same button in a follow-up task. (2) The New Project sheet takes a name, a location prefilled from a new "Projects folder" setting (default ~/dev), git init with README, .gitignore and a first commit on the default branch, and a "Then" choice (nothing, open a session with a preset, start the lead with a first goal); no license or template pickers and no GitHub creation unless the user asks. Verifier 2.0 part 2 merged with audit_finders left at 1; the lead will try 2 on a sensitive-path task after the next install and record the cost.

The user asked for the features and left the details open ("I don't know if there need to be any other settings"); these are the smallest versions that do the job, and the user can ask for more once they see them.

## 2026-10-19 17:53:47 test_command is now `bash scripts/test.sh` (set 2026-10-19 20:3x). The script, from home-or-vibeswitcher, runs `swift build && swift test` on a fresh scratch HOME, CFFIXED_USER_HOME, VIBESWITCHER_HOME and TMPDIR under /tmp that it removes on exit. Reason: the same branch adds a guard that refuses to run the tests against the real ~/.vibeswitcher, and the lead's running tool server (older than today's merge-runner scratch-HOME fix) ran the merge's tests on the real home, so the merge was refused by that guard. With the wrapper, every merge, worker and verifier run is isolated whatever server runs it. home-or-vibeswitcher must merge first (it carries the script); every later branch is rebased onto it.

A merge that writes into the user's real app folder was today's recurring incident class (app.log lines, Keychain dialogs); the guard is right to refuse, and the wrapper makes the isolation the default rather than something each caller remembers.

## 2026-10-19 18:35:39 Lead policy from 2026-10-19 22:1x: when the lead accepts an edit outside a task's listed files (by message to the worker or on its own judgement), it appends that acceptance to the task's context (update_task) before calling audit, so the verifier can see it. Reason: two same-commit re-audits today (a-new-project-button, the-phone-gets-the) were caused by approvals the verifier couldn't see. The task the-verifier-sees-the makes the verifier's prompt carry the lead's notes and messages, after which the policy still holds as a habit.

A verifier judges from the contract and the board; an approval that lives only in a message to the worker doesn't count for it, and a repeated full audit costs 20–30 minutes of a loaded Mac each time.

## 2026-10-20 07:42:51 Swift tool runs (scripts and the lead's, workers' and verifiers' sessions) get a scratch TMPDIR of their own that is removed afterwards; the lead cleans the leaked empty TemporaryDirectory.* folders in the user's temp folder once by hand.

2026-10-20 07:4x: 32,871 empty TemporaryDirectory.XXXXXX folders had piled up in the user's $TMPDIR; measured: SwiftPM leaves ~7 per swift build and ~5 per swift test, and only scripts/test.sh redirected TMPDIR. Per-session scratch stops ad hoc runs (benches, settle matrices) from leaking into the user's folder and lets cleanup and the disk witness account for them per task.

## 2026-10-20 10:44:17 audit runs a trial merge onto the lead's branch first and refuses a conflicting branch naming the files (task audit-refuses-a-branch-2).

2026-10-20 retrospective: a-role-session-s passed a complete audit and only then was found to conflict with work merged meanwhile, costing a resolution round and a second verifier.

## 2026-10-20 10:44:19 audit judges settings changes from the branch's commits, reports untracked files in the worktree as leftovers, and workers keep scratch in their session TMPDIR, never inside the worktree (task audit-tells-untracked).

2026-10-20 retrospective: untracked bench scratch homes (.scratch/…/.claude/…) in the chat-paging worktree were taken for settings changes; the verifier started with settings off and waited on a trust question the lead had to end.

## 2026-10-20 10:44:21 The witness tells the lead about power changes (on battery with level and estimate, back on AC) and status shows the state; the lead's rule stays: on battery no new starts or merges, in-flight work finishes, resume on power (task the-witness-tells-the).

2026-10-20 retrospective: three battery switches in 12 h were handled only through the lead's own shell watches, which a replacement lead after a handover would not have.

## 2026-10-20 16:19:43 GitHub's main is fast-forwarded from project-lead by the user when they ask (a8d93c2 → 9dca1f7 on 2026-10-20 at 16:2x; project-lead now tracks origin/project-lead); the lead never pushes (its shell is denied) and hands the user the exact command. The redaction tests' made-up Slack-webhook fixture (commit b99cd4c) was allowed through GitHub push protection by the user as "used in tests"; task pushes-never-trip-github keeps it from recurring.

The user asked "push to gh" and "lets merge to main"; main was a straight ancestor, so a fast-forward kept history linear and the checkout on project-lead for the workers.

## 2026-10-20 16:28:07 The lead does not message or otherwise touch the other projects' leads (genswap, TGE-ANALYSIS) for now: no SendMessage to them, no reviewing or reporting on their sessions; cross-project hygiene is left to the user and those leads.

The user's instruction on 2026-10-20 at 16:5x ("i dont want you to touch the othr leads for now") after the lead informed both leads about the end-of-day wrap-up.

## 2026-10-20 16:56:08 No GitHub push-protection bypass, ever: fixtures that must look like real secrets are assembled at run time from pieces, docs elide the prefixes, and a repo-wide lint keeps complete shapes out of every file; no .github/secret_scanning.yml. The three commits of the failed attempt (2554086, 9a2c0b9, fff5c70) are dropped from project-lead by a reset to 9dca1f7 (which GitHub already has), run by the user.

2026-10-20 17:0x: the user refused a second 'allow me to expose this secret' click ('This is unacceptable'); GitHub matches shapes regardless of EXAMPLE markers, and the ignore config can't land on main through a push it blocks.

## 2026-10-20 22:12:05 The battery hold is level-based and a user setting: leads pause starts, audits and merges only while the battery is under the user's limit (default 50 %), not at every unplug; task battery-hold-only-below implements it, and until it lands the lead applies the 50 % line by hand to the witness's messages.

The user on 2026-10-20 at 21:2x: they plug and unplug often, and a hold at 100 % costs workers their context for nothing; the earlier 30 % practice becomes the setting's default of 50 %.

## 2026-10-21 00:15:37 The chat settle matrix passed 64/64 at 12/12 on a quiet Mac (2026-10-20 23:23–00:03, docs/eval/chat-bench-settle-2026-10-20.md, pending audit). regression_command is not set to the full matrix: at 37–40 minutes per run it would make every merge ten times slower. Recommendation for the user, to settle in the morning: a short regression command per merge (`chat-bench-settle.sh -n 3` on the 8 top/middle × 1200/1728 × LIVE/STACK cases, about 3 minutes, judged with the merge's load gate) and the full matrix on demand or nightly; the lead's current tools have no regression_command parameter, so it is set after the next lead restart.

The matrix is the evidence the earlier decision asked for, but its cost per merge is the wrong trade; the 8-case subset is where every real finding came from (top/1728 page 2, the two-heights artifact), and 11 of 768 runs still needed the starved allowance when six jobs hit the same phase together, which the full matrix would turn into merge noise.

## 2026-10-21 12:30:57 The briefing's ElevenLabs key falls back to ELEVENLABS_API_KEY from the user's login shell, then ~/.config/elevenlabs/key.env, when no key is saved in the Keychain. Settings shows the source by name, never the value, and offers 'Save to Keychain'.

The user asked why the app asks for a key that's already in their environment. A Finder-launched app doesn't inherit shell variables, but the app already reads the login-shell environment for sessions. A typed key still wins, so nothing changes for users without the variable.

## 2026-10-21 17:55:46 The picker card's settling work stops after picker-card-the-two. Its two remaining Nits (in the app, ScreenRead.at is the call time; the refusal notice says "changed; here it is now" for one read while the card still shows the old question) stay recorded on the task, not as new tasks.

Four rounds have closed every case that put half-drawn text on the card. What's left changes, at worst, a notice for one 0.15 s read. Further rounds cost more than they protect until the user reports a visible problem.

## 2026-10-21 21:50:31 Working policy from the user, 2026-10-21 17:5x, effective now: (1) One agent owns each change through completion. Separate reviewers (audit) only for security, irreversible operations, or complex changes. (2) Run the affected tests while editing, then the full suite once before merging; repeat only when new changes justify it. (3) Parallelize independent implementation work; serialize expensive builds and tests so workers don't compete for CPU. (4) Fix material bugs; cosmetic observations don't become tasks or block delivery. (5) Stop when the requested behaviour works and the relevant checks pass; no recursive audit loop without a concrete unresolved concern. Until the tools support skipping audits (task one-agent-owns-each), the lead asks for light audits on low-risk work (diff plus affected tests plus one suite, no benches or screenshots unless the change is about them), never re-audits for nits, and contracts ask for one suite run, not two.

The user's direction after the lead's introspection: about five full suites per change, re-audit loops (text selection took four rounds), nit follow-up chains (four picker-card tasks), and CPU contention between parallel suites made the team slower than a single Claude Code session, and hit the weekly usage limit.

## 2026-10-21 22:52:33 Additions to the working policy after the lead's review (2026-10-21 23:0x): (1) The merge's run is the one full suite; workers run affected tests, and the full suite only when they touch shared test or build infrastructure. (2) Workers own routine calls, including small goal-tied boundary excursions, and list them in their report; they ask the lead only about direction, scope, or risky steps. (3) Timing benches leave the default test run (`--perf`), so merges don't fail on load. (4) Worktrees build warm. (5) The policy reaches every project's leads, workers and verifiers through the app: an editable policy text in every prompt, a witness message to running leads, and a Mac-wide `vs-heavy` lock for any project. (6) The lead posts updates only for merges the user would notice; the rest go into a daily summary.

Remaining causes of slowness after the first policy pass: one extra full suite per task in the worker, merge gates failing on load-sensitive benches, about 2 minutes of clean build per worktree, routine worker questions round-tripping through the lead, and the lead's own update volume. The user asked for the policy to reach the other leads and future ones; the user also asked the lead not to touch other leads directly, so delivery goes through the app.

## 2026-10-23 02:44:18 Ending a session ends only processes of the same uid carrying that session's VIBESWITCHER_SESSION id, plus at cleanup processes whose cwd is inside the removed worktree. Existing orphans on the Mac are not swept automatically; the user decides about those.

The narrowest scope that catches everything an agent starts (the env var is inherited even through setsid) while never touching another session's, another project's or the user's own processes. Reversible: it can be widened later.

## 2026-10-23 11:59:01 Tasks that change the same input path (PhoneAccess / HostClient.send / the per-session send queue) run one after another, never in parallel; the later one starts from project-lead after the earlier merges.

On 2026-10-23 composer-messages-don-t and the phone tasks both edited PhoneAccess's send path; each conflict needed a rework and a re-audit of a sensitive path.

## 2026-10-23 14:16:18 New tests must be proven under load (scripts/test-under-load.sh) before a worker reports done; tests wait on real events, never fixed sleeps or wall-clock windows. Enforced through the worker brief and a test of its text (task: new tests proven under load).

Three new tests on 2026-10-23 passed in their workers and failed in loaded merge runs, each costing a ~30 min merge and a rework.

## 2026-10-23 15:10:34 Phone scroll-back reaches as far as the host's 8 MB output ring (served on demand by a one-off parser), not the 5,000 lines a parser used to collect over its life; the per-session parser keeps 200 lines.

Memory audit P1: parsers held 352 MB. After any handover or install the reach was already the ring; keeping the old reach would mean forking SwiftTerm. Revisit if the user misses history on long, spinner-heavy sessions.

## 2026-10-23 15:13:15 The app keeps at most 3 terminal views attached and releases a view after 5 minutes off screen (not 30 s); visible scrollback stays 10,000 lines.

The 3-view cap gives most of the saving (290 → ~110–140 MB in the 12-session bench); a 30 s release saved ~50 MB more but would drop a session's long scrollback whenever the user steps away briefly.

## 2026-10-24 16:30:16 The 2026-10-20 16:28 hold on reviewing other projects' leads is lifted for reviewing only: the lead reviews genswap's, TGE-ANALYSIS's and films' lead and worker sessions from their transcripts, boards and lead records. It doesn't message, steer or change anything in those projects. What the review finds becomes VibeSwitcher tasks or advice to the user, never actions in those projects.

The user asked on 2026-10-24 at about 16:3x for an examination of how the other projects' leads are performing: overkill, mistakes, self-improvement. The earlier instruction 'don't touch the other leads' still holds for contacting or steering them.

## 2026-10-24 18:27:33 Retrospective of the 2026-10-24 review-fix batch (6 tasks, all merged in about 4 h, no reverts). Changes: (1) audit takes a branch whose trial merge is clean, and ends the task's own idle worker to make room for its verifier (task audit-takes-a-branch). (2) Workers run the lint tests before reporting done (task workers-run-the-project-s). (3) Already running: boundary excursions a worker reports don't fail an audit, and dismissed findings don't force a re-audit (boundary-excursions-a). Until (1) lands, the lead stops a finished worker whose audit is refused for Mac room, and has branches catch up once, after the last of a run of merges, not after each.

About 8 extra worker turns went to conflict-free catch-up merges. Idle finished workers held 4 to 5 of 10 Mac slots and blocked verifiers. One audit failed only on a missing lead note, and one only on a lint a filtered run doesn't cover. The audits also caught three real defects: records that merged cleanly kept the branch's copy, a team command in flight could pass as the user's, and the limits file was writable by agents.

## 2026-10-24 20:52:03 New Project… always creates the git repository with its first commit and starts the project lead. The sheet no longer offers "Nothing" or "Open a session" as next steps, and has no git toggle.

The user said a new project "always needs to start as a full fledged leader".

## 2026-10-24 22:42:24 All-done signal is app-side: VibeSwitcher detects from board.json that the board went from open work to clear, with at least one merge, and puts a green "All tasks finished" card in the lead's chat. The card has a plain-words summary written by headless Claude through Briefing's redaction, falling back to a written summary when the model is unavailable or AI summaries are off. A green check shows on the lead's sidebar row until the user opens that lead. No sound or push for now.

The user asked for a clear signal plus a simple-terms AI summary when all tasks finish. Detecting it in the app makes it reliable without depending on the lead. Reusing Briefing keeps secrets out of the prompt and respects the user's AI-summaries setting.

## 2026-10-25 08:03:22 Lead Process v3, phases 1 and 2, are being built: (1) finished-work-lands: done work merges or gets its audit, and planned tasks start, without waiting for the lead's turn. Merges land overnight too. (2) steadier-merge-gate: one rerun of failing tests at merge, a flake ledger, and early catch-up messages when project-lead overlaps a running branch. (3) workers-run-a-sandboxed: workers run an isolated copy of the app and screenshot it. (4) done-reports-carry: done reports need evidence per acceptance check, plus a blind self-check. (5) audit-v3-blocking: Important findings need a failure scenario, workers fix or answer them, re-roll after 2 rounds, and the verifier runs on a different model. All five run in parallel. Four are audited (guard rails, isolation, concurrency); the evidence task is review none.

The user answered 'Start Phases 1 and 2 together' on 2026-10-25. Data from 2026-10-22..25: 59% of task time was finished work waiting for the lead, about 1.15 of 5 worker slots were used, 17 of 29 failing merges passed on retry, 21 conflicts cost 40.7 task-hours, about 30% of Important findings were dismissed, and the user found 35 bugs by hand. The design follows OpenAI's Symphony and harness write-ups, Anthropic's risk-tiered review, and the research on self-review and fix-loop decay. Overnight merges were taken as included: the merge policy is auto, and nothing reaches the app before the user installs.

## 2026-10-25 09:46:35 From the retrospective of the Lead Process v3 batch: a fix's regression test must be shown to fail without the fix. The worker's evidence shows it, and the re-audit checks it; task a-fix-s-regression. No change for the load waits: the room messages handled them.

finished-work-lands F1's two new tests would have passed on the old code too. The verifier couldn't prove it because a scratch-export command was denied. Without such proof a "fixed" finding has no guard against the bug coming back.

## 2026-10-25 13:45:22 Two changes from the user's 'you decide' on Anthropic's posts (redesigning source control; employment at Anthropic), 2026-10-25. (1) The review level follows what a diff touches. vibeswitcher's sensitive_paths now adds the guard-rail files to the defaults: Sources/VibeHost and vibeswitcher-host, LeadVault*, LeadLaunch, LeadAdvance, Steer, Worktrees, MergeRerun, TestLock, Redaction, HookInstaller, RemoteAccess, RemoteServer, PhoneAccess, Sandbox, build-app.sh and setup-signing.sh. Any branch touching them is audited whatever its task says. LeadToolset.swift is left out, since nearly every task touches it. (2) An app-health watcher (task a-watcher-tells-the) sends vibeswitcher's lead deterministic digests of new hangs, crashes and trends. A third idea, batched merge testing with automatic bisect and revert, waits for a day of merge-queue wait data.

Anthropic's approval rules tell comment-only changes apart from sensitive logic, and its 'superfan' agents watch components. Today the lead filed a permissions change at review none, and its audit (after a manual raise) found three escapes. The one-off log review found four real bugs that nothing had reported.

## 2026-10-25 16:33:34 Lead habits from the 2026-10-25 retrospective: (a) Every hardening or security task's contract states up front to fail closed on unusual or unparseable input instead of handling each case, and to do no further hardening rounds unless a check fails. (b) The lead doesn't ask for changes on a branch whose audit is running; it waits for the verdict, then sends them, so no audit runs on a stale head.

planted-git-hooks-or's blind checks kept finding deeper include and path corner cases. Its worker stopped mid-fix twice, costing about 1.5 h, until the lead cut it to fail-closed. A mid-audit request on the same task left a verifier auditing the old head.

## 2026-10-25 22:48:39 Notifications and messages to the user: only when a batch is completely done, or when the user is needed (a question, a password or install, a breakage). The lead writes to the user only in those two cases. Routine events (merges, workers asking, starts) get one line at most in the terminal, or none, and are collected into the batch summary. Task notifications-only-when carries the app side.

The user, 2026-10-25: "me molestan tantas notificaciones y no saber realmente cuando tengo que mirar" (all these notifications bother me, and I never really know when I have to look), then "quiero notificaciones cuando se ha completado del todo o cuando se me require por lo que sea" (notifications when it's fully done, or when I'm needed for whatever reason).

## 2026-10-26 02:06:07 No copy-of-the-build start for worktrees (a-fresh-worktree-starts abandoned). The only cheaper path left is SwiftTerm as a prebuilt binary target. That's not planned: it saves about 72 of 208 compile steps but adds an xcframework to maintain.

The worker measured it on 2026-10-26. A fresh worktree's first swift build takes 91 s for 208 steps at load 28. A `cp -c` clone of an up-to-date .build still rebuilds all 208, because swift-driver disables incremental compilation when arguments change: absolute paths and -package-name are in master.priors and llbuild's build.db. Only .build/checkouts survives, saving about 5 s, and its alternates point into the source worktree. The earlier a-new-worktree-builds (727f29d) already shares the SDK module cache, the one part that does carry over.

## 2026-10-26 08:25:23 Lifted the hold on the-app-s-memory and merged it: FootprintRelief runs only while the app isn't frontmost.

The hold was for the malloc-lock stall (183–572 ms with 8 MB slack, on a loaded Mac). Now that the relief only runs in the background, at 24 MB slack its longest run measured 42 ms. The leak fix (d6ecc41, HostConnection.finish clears its handlers) stays as it was.

## 2026-10-26 08:42:36 Installed project-lead at b91fa2e on 2026-10-26 08:42, on battery at 82%. It brings the whole batch: notifications, the memory leak, time budgets, receipts, CLAUDE.md, rule checks, flake fixes and switch fixes.

The user answered 133FA6B0 with "Install now". Checked: the host is still pid 31589, the app relaunched as pid 12647, and the lead's tool server (pid 10199) switched in place to the new binary (inode 304239769) and holds advancing.lock again.

## 2026-10-26 11:01:23 Context files and roles. (a) AGENTS.md holds only rules and commands agents can't discover; CLAUDE.md is `@AGENTS.md`; no repository overview. (b) A security focus goes into the verifier prompt for sensitive or raised branches, not a second finder, measured with scripts/verifier-eval.sh on real past misses. (c) No scheduled gardener agent; size-triggered housekeeping only (archive_decisions). No idle-time bug sweeps.

The user's convention is that CLAUDE.md points to AGENTS.md, and they note that AGENTS.md content has been hurting performance. ETH Zurich (arXiv 2602.11988): overviews don't help; instructions are followed; context files add about 20% cost. With 2 finders, a finding raised only by the security finder would be unconfirmed and never block. The working policy also rules out audit loops without a concrete concern, which a scheduled bug sweep would be.

## 2026-10-26 13:57:12 Installed project-lead at e6278af on 2026-10-26 13:56. It brings the risk check, REVIEW.md, the security checklist, revert, the slim AGENTS.md, archive_decisions and the hang stacks. Then archived 70 superseded or obsolete decisions; decisions.md keeps 47.

The user answered F770E6F6 with "Install now". Checked: the host is still pid 31589, the app relaunched as pid 97924, and the lead's tool server switched in place to inode 307525655 and holds advancing.lock. The archive list is docs/process/lead-rules.md's superseded and obsolete entries, minus the ones only partly superseded.

## 2026-10-26 21:09:21 Installed project-lead at 325207e on 2026-10-26 21:08 (battery 52 %): revert follow-ups, the verifier eval set, the README fix.

The user answered A1BE83E7 "Install now". Verified: host pid 31589 unchanged, app relaunched as pid 62220, the lead's tool server (pid 10199) switched in place to inode 309016916 and holds advancing.lock.

## 2026-10-27 11:12:24 Installed project-lead at 1236e30 on 2026-10-27 11:12; the user ran the install. It brings the phone's lead/team UI and answers, the lead-chat freeze fix (chip strip, focus loop, Team rows cache) and the time-budget off-main fix. The lead's earlier attempt at 05:2x failed to sign with errSecInternalComponent, with the Mac locked and no keychain prompt possible.

The user answered E6FC9C18 "Install now" and ran it themselves after the failed try. Verified: host pid 31589 unchanged, app pid 80943, lead tool server switched to inode 312283634 and holds advancing.lock. Next: watch the health watcher's freeze reports with this lead's chat open to confirm the fix; Spaces.currentDesktops (a window-server call on main in SessionStore.apply) is the next suspect if freezes remain.

## 2026-10-27 15:22:53 Installed the status-first sidebar icons and folder-starts-lead batch at 15:21 on 2026-10-27, at the user's answer to F2AF00BC. The host (pid 31589) and the tool servers kept running. The app logo is one task, app-logo-concepts-first: concepts first, the user picks, then the same worker wires the pick in. It has auto_advance off and an audit, because it touches build-app.sh.

The logo is a taste call, so the user chooses from rendered options. One agent owns it end to end. Phase 1 must not be merged on its own, so auto_advance is off.

## 2026-10-27 15:58:02 Which logo? (The four concepts are in the update.) → A · Stack

The lead proposed it with a 30 min timer and the user didn't answer in time, so it went ahead (question 33419991). Why it was asked: The worker is waiting on the pick to make it the app and phone icon.

## 2026-10-27 16:45:16 Installed the new app logo (A · Stack) at 16:45 on 2026-10-27, at the user's answer to E37EB3C9. The host (pid 31589) kept running, and the installed Info.plist has CFBundleIconFile = AppIcon. Nothing has been pushed: project-lead is 50 commits ahead of origin/project-lead and of origin/main (dc2b9e3).

The user asked for the install. The lead never pushes; the user does.

## 2026-10-27 18:12:00 PR #1 (host security boundaries) lands through project-lead as task land-pr-1-host. The PR's commit is applied with its authorship kept, the review's fixes go on top, and it gets a full audit and the merge gate; the user then pushes and closes the PR. On OSC 52, terminal clipboard writes are allowed only from the focused, visible pane, and refused from hidden terminals, replays and background panes.

The user said "review and work towards merge". The PR touches sensitive paths (the host, the vault, build-app.sh) and would break Apple Events under Hardened Runtime as written. Allowing OSC 52 from the focused pane keeps nvim and tmux copying working, while closing the hidden-output attack the PR targets. The user can still choose to block it entirely.

## 2026-10-27 20:14:32 Same setback twice: the lead restarted an audit that auto_advance's verifier was already running, ending it. The fix is a check in the tool (task audit-must-not-end), not a note. Until it lands, the lead reads board(task) for a running verifier before calling audit on an auto_advance task. Today's freeze storm (20 freezes of 2–25 s with stakegen's long lead chat) is one task, lead-chat-freezes-of, with an accessibility bench as its regression check; the incident's own task is folded into it.

Rule 10: a setback that happens twice gets a check. Freezes that long are material. The bench in that task is the check that runs before merge, so a second task would duplicate it.

## 2026-10-27 21:15:52 Don't restart an audit or a worker on a witness "agent quit" report until `ps` confirms the agent's claude process is gone. On 2026-10-27 such reports were false: the agent was alive and waiting on a background load run. The fix is task turn-this-incident-into-3.

Two verifier runs on PR #1 were reported as quit; one was alive and the lead killed it, which wasted about 7 minutes of verifier work and load-run time. The witness check is wrong under Claude Code's background commands.

## 2026-10-28 08:00:12 Installed project-lead at 30e58fd on 2026-10-28 at 07:58, at the user's answer to C2D62447. It includes PR #1's host security, the board-read freeze fixes, the message-delivery check and the audit guard. The host handed over in place (pid 31589, build 1793170724), the app proved itself and sees all 23 sessions, and the app is signed runtime with apple-events. A regression followed: the Mac-wide census counts only the lead's own team, fixed by task turn-this-incident-into-5, started at once. Until it merges, the lead counts other projects' team sessions with ps before starting work.

The user asked for the install. The census regression comes from PR #1's filtered hello and defeats the shared Mac-wide limit, so it takes priority over the other planned work.

