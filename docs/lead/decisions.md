# Decisions

Archived decisions: 99 entries (superseded, obsolete or now enforced by a check) are in decisions-archive.md, moved there unchanged (last on 2026-10-31).

## 2026-10-17 17:45 The lead's decisions.md and progress.md move into the repository (docs/lead/ by default) and are committed to the base branch automatically by the tool server, touching only those files. board.json, workflow.md and run/ stay local and git-ignored.

User's call. The project's reasoning should survive a lost .vibeswitcher folder, another machine or a new lead, and be visible to teammates. The board holds transient state (sessions, PIDs, questions) and stays local.

## 2026-10-17 21:27 The pipeline-lane design is replaced by a calm one-line-per-task Team view with AI plain-language summaries (headless `claude -p`, small model, cached and throttled, can be switched off) and a fading feed of the lead's decisions. Questions get proposals with a 10-minute default timer, where silence means the lead goes ahead. Risky or blocking questions never get a timer.

The user found the lanes noisy and space-hungry and wants a glanceable high-level view in which past things fade out. The timer keeps work moving without the user having to answer, and the risky-question exclusion keeps irreversible calls with the user.

## 2026-10-18 17:55:49 Accepted the crash-isolation cost: one parser process per session, adding about 3.5 MB of footprint per session (about 130 MB at 37 sessions) and no idle CPU. The parser keeps the 5,000-line scrollback.

Measured on release builds, the host plus parsers use 42 MB of footprint at 10 idle sessions, against 9 MB before. In exchange, one session's parser trap or stall no longer takes down every session. The phone's transcript view asks for 5,000 lines, and the raw replay can't stand in for the scrollback, so it isn't cut to 1,000.

## 2026-10-18 18:23:05 An install must not replace a running lead. The lead session that is live keeps its role and conversation, and a new lead starts only when none is live or when the user asks for one, after a confirmation. This is task a-running-lead-keeps, started now. It changes the guard rails' role binding, so it's shown to the user before merging. Install plans stop telling the user to restart the lead from the app.

At the 18:10 install, the films lead lost its role mid-conversation. The user's answer ('Do what we need to do') and its decisions never reached the board, and the refusal pointed to /mcp, which can't give the role back. The earlier claim that 'the transfer worked' was only true of the sessions, not of the leads.

## 2026-10-18 18:49:28 Direction from the user: running VibeSwitcher must be seamless. The user never restarts a lead, runs /mcp, or confirms their own commits. Three tasks deliver it: (1) a-running-lead-keeps: installs never replace a running lead, the team keeps its grants, and when a new lead does start it's adopted rather than replacing. (2) tool-servers-update-in: every vibeswitcher-mcp swaps itself for the new build in place (exec between requests, same stdio and grant). (3) the-user-s-own: a base move made by the user's own (non-team) sessions is accepted automatically, provided the session is identified by what the host can verify. Anything else falls back to a one-click prompt in the app, never a restart. The current a92a8dc block is cleared once, at the end: the user does one restart and then one install, after which none are needed. The three are shown to the user together before merging, because they change guard rails.

The user said: "all of this restarting the leaders … is just too complex … do whatever you need to do to make this seamless". The guard rail against unaudited base moves stays, but it learns to tell the user's own commits from the team's. Commits it can't attribute still need a click, never a restart. One last restart can't be avoided, because these fixes have to merge through the very check they replace.

## 2026-10-18 18:50:08 Merge policy for vibeswitcher, set by the user: the lead merges audited work by itself, including guard-rail, security and hook-installer changes, and doesn't ask per merge. It then posts an update saying what changed, how it was checked, the risk and how to revert. This replaces the 2026-10-17 17:23 hand-applied risk tiers. The user is asked only about direction, taste, and anything irreversible or outward-facing (pushing, publishing, deleting work). The lead also checks in with the user proactively and runs a short retrospective now and then.

The user said asking them about every merge is annoying and mostly pointless. Merge behaviour is something the lead should agree with the project owner once, and then the lead should be proactive: ask how they want things done, check how things are going, and run retrospectives.

## 2026-10-18 23:43:32 Retrospective changes (2026-10-19 00:10): (1) audit evidence must survive a worker's report on an unchanged commit (task "Audit evidence survives a worker report on the same commit"); until it lands, the lead tells workers to answer non-code requests with progress(text:), never report(summary:). (2) The witness must not call a worker stalled while it waits on its own background task (task of that name). (3) Load tests run only through scripts/test-under-load.sh, capped at 2×ncpu, refusing an already loaded Mac (task "One load harness"); until it lands, every contract and audit that involves load says "at most 2×ncpu load processes, stopped by pid afterwards, never when the 1-minute load is already above 2×ncpu". (4) Sessions reported ended must really end (task ended-sessions-really, started).

Each cost real time tonight: a reset audit cost 25 minutes and two verifier runs; a false stall woke the lead for nothing; a verifier's 96-process load slowed every other session for 25 minutes; seven leaked sessions hold 2.4 GB on a Mac that ran out of memory twice today. A rule in a note is forgotten by the next lead; a check isn't.

## 2026-10-19 08:06:04 From the user (2026-10-19 08:05, answering the leaked-sessions question): operational hygiene is the lead's to decide, carefully and holistically, not the user's: leaked or stale sessions, stale lock files, load and memory on the Mac, scratch leftovers. The lead acts (from its own shell when the tools can't, with each target re-verified first) and reports what it did; it asks the user only for direction, taste, and anything irreversible or outward-facing. The seven leaked sessions are ended by the lead now with SIGHUP, each pid checked against its task's session command line before the signal.

The user's words: "This is the type of thing that you should be able to decide yourself in a careful manner and thinking holistically." The question sat seven hours for an action that was safe to take: idle sessions of merged tasks, confirmed by ps, that no tool could end.

## 2026-10-19 18:35:39 Lead policy from 2026-10-19 22:1x: when the lead accepts an edit outside a task's listed files (by message to the worker or on its own judgement), it appends that acceptance to the task's context (update_task) before calling audit, so the verifier can see it. Reason: two same-commit re-audits today (a-new-project-button, the-phone-gets-the) were caused by approvals the verifier couldn't see. The task the-verifier-sees-the makes the verifier's prompt carry the lead's notes and messages, after which the policy still holds as a habit.

A verifier judges from the contract and the board; an approval that lives only in a message to the worker doesn't count for it, and a repeated full audit costs 20–30 minutes of a loaded Mac each time.

## 2026-10-20 07:42:51 Swift tool runs (scripts and the lead's, workers' and verifiers' sessions) get a scratch TMPDIR of their own that is removed afterwards; the lead cleans the leaked empty TemporaryDirectory.* folders in the user's temp folder once by hand.

2026-10-20 07:4x: 32,871 empty TemporaryDirectory.XXXXXX folders had piled up in the user's $TMPDIR; measured: SwiftPM leaves ~7 per swift build and ~5 per swift test, and only scripts/test.sh redirected TMPDIR. Per-session scratch stops ad hoc runs (benches, settle matrices) from leaking into the user's folder and lets cleanup and the disk witness account for them per task.

## 2026-10-20 16:56:08 No GitHub push-protection bypass, ever: fixtures that must look like real secrets are assembled at run time from pieces, docs elide the prefixes, and a repo-wide lint keeps complete shapes out of every file; no .github/secret_scanning.yml. The three commits of the failed attempt (2554086, 9a2c0b9, fff5c70) are dropped from project-lead by a reset to 9dca1f7 (which GitHub already has), run by the user.

2026-10-20 17:0x: the user refused a second 'allow me to expose this secret' click ('This is unacceptable'); GitHub matches shapes regardless of EXAMPLE markers, and the ignore config can't land on main through a push it blocks.

## 2026-10-20 22:12:05 The battery hold is level-based and a user setting: leads pause starts, audits and merges only while the battery is under the user's limit (default 50 %), not at every unplug; task battery-hold-only-below implements it, and until it lands the lead applies the 50 % line by hand to the witness's messages.

The user on 2026-10-20 at 21:2x: they plug and unplug often, and a hold at 100 % costs workers their context for nothing; the earlier 30 % practice becomes the setting's default of 50 %.

## 2026-10-21 12:30:57 The briefing's ElevenLabs key falls back to ELEVENLABS_API_KEY from the user's login shell, then ~/.config/elevenlabs/key.env, when no key is saved in the Keychain. Settings shows the source by name, never the value, and offers 'Save to Keychain'.

The user asked why the app asks for a key that's already in their environment. A Finder-launched app doesn't inherit shell variables, but the app already reads the login-shell environment for sessions. A typed key still wins, so nothing changes for users without the variable.

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

## 2026-10-24 16:30:16 The 2026-10-20 16:28 hold on reviewing other projects' leads is lifted for reviewing only: the lead reviews project-c's, TGE-ANALYSIS's and films' lead and worker sessions from their transcripts, boards and lead records. It doesn't message, steer or change anything in those projects. What the review finds becomes VibeSwitcher tasks or advice to the user, never actions in those projects.

The user asked on 2026-10-24 at about 16:3x for an examination of how the other projects' leads are performing: overkill, mistakes, self-improvement. The earlier instruction 'don't touch the other leads' still holds for contacting or steering them.

## 2026-10-24 18:27:33 Retrospective of the 2026-10-24 review-fix batch (6 tasks, all merged in about 4 h, no reverts). Changes: (1) audit takes a branch whose trial merge is clean, and ends the task's own idle worker to make room for its verifier (task audit-takes-a-branch). (2) Workers run the lint tests before reporting done (task workers-run-the-project-s). (3) Already running: boundary excursions a worker reports don't fail an audit, and dismissed findings don't force a re-audit (boundary-excursions-a). Until (1) lands, the lead stops a finished worker whose audit is refused for Mac room, and has branches catch up once, after the last of a run of merges, not after each.

About 8 extra worker turns went to conflict-free catch-up merges. Idle finished workers held 4 to 5 of 10 Mac slots and blocked verifiers. One audit failed only on a missing lead note, and one only on a lint a filtered run doesn't cover. The audits also caught three real defects: records that merged cleanly kept the branch's copy, a team command in flight could pass as the user's, and the limits file was writable by agents.

## 2026-10-24 20:52:03 New Project… always creates the git repository with its first commit and starts the project lead. The sheet no longer offers "Nothing" or "Open a session" as next steps, and has no git toggle.

The user said a new project "always needs to start as a full fledged leader".

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

## 2026-10-26 11:01:23 Context files and roles. (a) AGENTS.md holds only rules and commands agents can't discover; CLAUDE.md is `@AGENTS.md`; no repository overview. (b) A security focus goes into the verifier prompt for sensitive or raised branches, not a second finder, measured with scripts/verifier-eval.sh on real past misses. (c) No scheduled gardener agent; size-triggered housekeeping only (archive_decisions). No idle-time bug sweeps.

The user's convention is that CLAUDE.md points to AGENTS.md, and they note that AGENTS.md content has been hurting performance. ETH Zurich (arXiv 2602.11988): overviews don't help; instructions are followed; context files add about 20% cost. With 2 finders, a finding raised only by the security finder would be unconfirmed and never block. The working policy also rules out audit loops without a concrete concern, which a scheduled bug sweep would be.

## 2026-10-27 21:15:52 Don't restart an audit or a worker on a witness "agent quit" report until `ps` confirms the agent's claude process is gone. On 2026-10-27 such reports were false: the agent was alive and waiting on a background load run. The fix is task turn-this-incident-into-3.

Two verifier runs on PR #1 were reported as quit; one was alive and the lead killed it, which wasted about 7 minutes of verifier work and load-run time. The witness check is wrong under Claude Code's background commands.

## 2026-10-28 13:41:29 The audit's uncommitted agent-config scan stays strict: no ignore rule of any kind exempts a file. Trust questions caused by our own tools are fixed at the source, so no script or test writes a checkout with AGENTS.md/CLAUDE*.md/.claude/.mcp.json inside a worktree. verifier-trust-check was re-rolled on that contract; the old branch is archive/verifier-trust-check-1.

Each attempt to exempt git-ignored folders opened a new way for a worker to hide instructions from the verifier (a self-made .gitignore or exclude, then pathspec magic ':/' making git name the committed rule). That's a security boundary, so the narrow, source-side fix is the safe one.

## 2026-10-28 18:59:49 From 2026-10-28, the lead names the user's other projects only generically in anything that lands in this repository: decisions, progress, incidents, task titles and contexts. It writes 'project-b' or 'project-c', or "another project's lead", never their real names. A lint planned in scrub-the-names-of enforces it. Heavy slots stay at 3 (the user's choice), so load is controlled through the-mac-hit-load's scheduling fix instead.

The repository is public. The user asked to scrub the other projects' names everywhere, the lead's records included, and the lead's records and task titles keep growing. The user declined lowering heavy slots.

## 2026-10-29 09:16:33 Speech-to-text uses OpenAI transcription only, at the user's choice (48B0C4E4). It's push-to-talk in the Mac and phone composers, the key is kept in the Keychain on the Mac only, the phone's audio is relayed through the paired Mac, the text is inserted for review and never auto-sent, and a one-time note says audio goes to OpenAI.

The user picked accuracy with code words over on-device privacy. Keeping the key on the Mac and never auto-sending keeps the risk small.

## 2026-10-29 09:22:09 From 2026-10-29 the base branch is main (configure base_branch). Workers start from main, verified work merges into main, and a push is just `git push origin main`. project-lead is retired (the user deletes it locally and on GitHub), along with the leftover branches chat-view, agent-fix-chat-pre-rebase-30ba453 and archive/verifier-trust-check-1.

The user said "Yes to both". project-lead only mirrored main, and every push had to fast-forward main by hand; one branch is simpler.

## 2026-10-30 15:08:14 When a task's acceptance asks for sandbox shots of a state the sandbox can't yet reach, its boundaries include Sources/VibeSwitcher/Sandbox.swift and scripts/sandbox-app.sh for new driver commands only. Those files stay sensitive paths, so the task is audited anyway.

Five tasks today (a-claude-dictation-that, 7-s-freeze-measuring, dictation-per-session, silence-the-mac-s, starting-a-lead-with) added sandbox commands outside their boundaries in order to take their acceptance shots. One audit came back "suspect" for it, which cost a second round. Naming the files up front saves those rounds.

## 2026-10-31 00:48:03 Before planning a task for an app-health freeze, read the main thread's top-of-stack spread in its .txt. If it's clustered (a few PCs with hundreds of samples each), it's starvation or paging: no task. Plan a task only when the spread shows real work, and once hang-reports-say-when lands, its verdict decides.

Three freeze investigations (7-s-freeze-measuring, accessibility-graph, 9-s-swiftui-layout) each spent a worker to find the main thread barely running, either on a loaded Mac or paging back in after a long idle. The PC spread showed it from the start.

## 2026-10-31 10:33:52 A worker runs the full suite once before reporting done when its change adds new public names, renames API, or touches anything source-scanning lints read (as well as when it touches test or build infrastructure). Otherwise the merge's run stays the one full suite.

silence-the-mac-s skipped the full suite and its `restore()` tripped TeamArchiveTests' source scan. Only the audit's full run caught it, which cost a round.

## 2026-10-31 10:33:53 When the base branch or the default branch changes, tell the user right away that existing clones need a one-time switch, and give the command.

After the 2026-10-29 move to main, someone with an older clone pulled and didn't get the latest, which surprised the user.

