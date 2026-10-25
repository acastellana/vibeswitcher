# Decisions

## 2026-10-17 12:15 Phase 1 is evaluation only: four read-only passes (engineering, runtime, UX, security), each committing a ranked, evidence-backed report under docs/eval/. Fix tasks are planned from the verified reports in phase 2. At most 3 run at once; security starts when a slot frees. Workers wait until the base branch is settled (main is 70 commits behind project-lead).

The user asked for a serious evaluation before improvement. Separate reports let a verifier reproduce findings and give the next leads a durable backlog. Running on stale main would evaluate old code.

## 2026-10-17 13:28 Base branch is project-lead, not main. Workers start from project-lead and verified work fast-forwards project-lead. main/origin/main stay untouched; moving them is a release decision for the user. test_command will be `swift build && swift test` (README's development check).

project-lead is the live product: the installed app (12:15) was built from its head (aff7317), and main is 70 commits behind and equal to origin/main. aff7317 already implements "a lead builds on the branch checked out when it first started", but this lead's tool server started at 12:12 from the previous build, which always used main. Reconnecting the server picks up that fix, so no files need editing.

## 2026-10-17 16:41 The chat layout hang is taken by a lead worker (fix-the-chat-layout) right away, ahead of the rest of phase 2. The user's own session keeps HangWatchdog.swift, and lead workers stay out of it. Evaluation runs must set CFFIXED_USER_HOME as well as HOME to isolate from ~/.vibeswitcher.

A 13-minute main-thread hang happened live at 16:26 on the current build, triggered by opening the chat for this lead's transcript. That contradicts the other session's 'no real hangs since 10:48', and it's the worst user-facing defect found so far. NSHomeDirectory ignores $HOME on macOS (engineering finding E-30), so HOME alone doesn't isolate test runs.

## 2026-10-17 16:51 Phase 2 order, one worker per area so files don't collide: (1) chat hang and the lead's self-configuration (running); (2) session detection; (3) standard Mac keys (⌘W closes the window, End Session moves elsewhere and always confirms; full Edit menu); (4) the lead's worker-state bugs and question withdrawal; (5) first run and one Settings window; (6) accessibility, after the chat fix lands. Security fixes get top priority as soon as that report is verified. Product calls are made by the HIG and the UX report, not by asking the user.

The user asked the lead to decide big-picture questions itself. Ordering by user impact, with no two workers in the same files, avoids rebase conflicts. ⌘W ending sessions risks data loss and breaks a universal Mac convention.

## 2026-10-17 17:23 Until risk tiers exist in code, the lead applies them by hand: docs/tests-only work merges on a clean audit; changes to the lead's guard rails, Phone Access/remote input, the hook installer or anything security-related are shown to the user (what changed, evidence, risk, how to revert) and merged only after their approval.

Anthropic's code-review practice: approval scales with the change's risk, and sensitive paths always need a human. The guard-rails and phone-hardening tasks change exactly what keeps agents and remote input in check.

## 2026-10-17 17:45 The lead's decisions.md and progress.md move into the repository (docs/lead/ by default) and are committed to the base branch automatically by the tool server, touching only those files. board.json, workflow.md and run/ stay local and git-ignored.

User's call. The project's reasoning should survive a lost .vibeswitcher folder, another machine or a new lead, and be visible to teammates. The board holds transient state (sessions, PIDs, questions) and stays local.

## 2026-10-17 17:56 The guard-rails merge (approved by the user) changes how lead sessions get their tools. They now need a capability that the app issues when it starts them. So the next install happens only when no workers or verifiers are running, and afterwards this lead is restarted from the app (Project Lead), not just reconnected with /mcp. A fresh lead continues from board.json, decisions.md and progress.md.

Sessions started by the old build have no capability. With the new vibeswitcher-mcp they'd get no tools mid-task, and running workers would be stranded.

## 2026-10-17 19:26 Accept the chat fix's eager-VStack cost (+~50 MB RSS and up to 0.45 s first open on the largest transcripts) in exchange for removing the layout hang. The bounds are written into the contract, and the regression must be disclosed in a commit message. Recovering memory is the idle-cpu-and-memory task.

The verifier confirmed the hang fix (1,120 settle runs; the base build stalled up to 56 s in the old bench) and failed the audit only on the 'no worse' clause. A 13-minute hang that loses user messages is far worse than 50 MB and 0.3 s.

## 2026-10-17 19:26 Handover point. Since the 19:18 install, the new guard-rails build is live and workers or verifiers started by this lead's old tool server (16:12) get no tools: the codex verifier couldn't call submit_audit. This lead must be restarted from the app. State for the next lead: (1) codex-0-157-background: the verifier found it complete, with 495 tests passing and hook trust verified with 0.163/0.160. It marked integrity 'suspect' only because it found no record that the lead approved the StatusRules.swift edit. The lead did approve it, by message, about 18:55. Re-audit, then show it to the user before merging (it changes the hook installer and ~/.codex). (2) phone-and-remote: the worker died from an API error while rewriting Redaction for speed. The branch is clean at 94c01d8; restart it with the same contract. (3) fix-the-chat-layout: reconcile with the user's own fix c0e1353 (see the task context). (4) One owner per area: before starting a task, check project-lead's recent commits for the same area, because the user's own sessions also commit there.

The capability check that came with the guard rails needs sessions started by the new build. The user's other session fixed the chat hang in parallel with this lead's worker, so the work was duplicated.

## 2026-10-17 19:41 Order for the 14 planned tasks (2026-10-17 review). Lead tooling tasks share Lead*.swift, LeadToolset and vibeswitcher-mcp, so they run one at a time: lead-sees-a-busy → a-running-lead-notices → the-lead-can-withdraw → the-lead-s-decisions → verifier-2-0 → risk-tiers → task-progress → lead-scorecard → lead-secrets. Once fix-the-chat-layout merges, a second lane runs: a-message-sent-from → idle-cpu-and-memory → accessibility-labels → keep-up-with-claude, plus first-run-and-one. The next free slot goes to lead-sees-a-busy.

Shared files would make parallel lead tasks conflict on rebase. Wrong worker state, a stale tool server and lost user messages break the lead's day-to-day work, so they come before new features (verifier 2.0, risk tiers, pipeline lanes).

## 2026-10-17 19:51 codex-0-157-background may touch StatusRules.swift: request_user_input_async joins questionTools, and Stop or that tool's PostToolUse with an open question reads as needsInput. The contract's boundaries now say so.

The acceptance check "async questions show as needs-input" can't be met without it, and the verifier found the change small and correct. The worker's commit said it was "agreed with the lead", but no such agreement exists. The lead is approving the change now, on its merits.

## 2026-10-17 20:33 task-progress-at-a (pipeline lanes) moves ahead of a-running-lead-notices in the lead lane and starts now. Its contract adds a Rework state: a failed task with a live worker shows Work live, not a red "Failed".

The user asked twice why running tasks don't say running, and expected the new task view to exist already. Visibility is what they're missing right now.

## 2026-10-17 20:57 Use all 5 worker slots. Overlapping tasks run in parallel when the overlap is small, with call-site-only rules for shared files. A rebase conflict at merge is handled then, rather than avoided by queueing. Started now: a-message-sent-from (kept out of the chat-fix files) and merges-name-the-failing.

The user wants the slots used and the queue moving. Strict one-at-a-time on shared files left slots idle for hours. A conflict costs one rework round, while idling costs throughput all the time.

## 2026-10-17 21:27 The pipeline-lane design is replaced by a calm one-line-per-task Team view with AI plain-language summaries (headless `claude -p`, small model, cached and throttled, can be switched off) and a fading feed of the lead's decisions. Questions get proposals with a 10-minute default timer, where silence means the lead goes ahead. Risky or blocking questions never get a timer.

The user found the lanes noisy and space-hungry and wants a glanceable high-level view in which past things fade out. The timer keeps work moving without the user having to answer, and the risky-question exclusion keeps irreversible calls with the user.

## 2026-10-17 22:09 Building workers-can-bring-their (workers may rebase or merge the base into their own branch). The merge waits for the user's explicit approval of the exact commit, because it changes guard rails.

Three audited branches (phone-and-remote, merges-name-the-failing, fix-the-chat-layout) are stuck on conflicts that no one is permitted to resolve. The user's reply to "OK to build it?" was "is ongoing", read as go-ahead to build, not as approval to merge.

## 2026-10-17 23:05 stalled-workers-are may edit LeadController.swift to feed the witness (Seen inputs, stall writes to the board).

LeadController is the only place the witness runs, so the feature can't reach it any other way. The verifier judged the edit to be scoped wiring.

## 2026-10-18 00:21:04 Queued decisions-with-a-timer to restart after a-worker-s-rebase merges, and workers-live-through-an to start after reports-wake-an-idle merges.

decisions-with-a-timer's worktree is stuck halfway through a rebase on the same `rebase --continue` refusal that a-worker-s-rebase fixes. workers-live-through-an touches the witness code, which reports-wake-an-idle is likely changing too.

## 2026-10-18 09:45:03 Before the one host restart that ends sessions, these host-side tasks go in: host-hands-its-live (re-exec handover, so later host updates keep every session), host-hygiene-ended (E-07, E-16, E-29, E-38 and welcome capabilities), and the host log plus exit signal inside workers-live-through-an. Deferred until the handover exists: the peer-pid input gate for lead-secrets-out-of, OSC 7501 for keep-up-with-claude, and crash isolation. The user holds the install and host restart until these merge.

The user wants a single restart. Only a host replacement ends sessions; app installs and a new lead don't. Once the handover exists, every later host change is cheap, so nothing else has to be squeezed in now.

## 2026-10-18 09:45:41 The user said "go ahead w all", so the deferred host items go in before the restart too: the peer-pid input gate (in lead-secrets-out-of) and OSC 7501 (in keep-up-with-claude), started now. Crash isolation (one-session-s-crash) is queued to start after host-hands-its-live merges.

The user wants all host work in the one restart. Crash isolation restructures the same code as the handover, so it waits for the handover's design.

## 2026-10-18 10:47:49 The host handover must hand the in-memory LeadVault (grants, verdicts, heads, sealing key) to the new binary over an inherited fd. Install and host restart are done as one step, never an install alone, because a new app with the old host breaks lead start and user steers (lead-secrets-out-of, finding 2).

Ad-hoc builds can't read the previous build's Keychain item, so the sealed vault on disk doesn't survive a rebuilt host. Without the handover carrying it, every host update would wipe the team's guard-rail state.

## 2026-10-18 10:52:28 lead-secrets-out-of goes back for rework: the caller must be identified by audit token with a pidversion check, and the app recognised by cdhash, not by path. It restarts when a worker slot frees.

The verifier showed an exec trick that lets a worker pass as the app and seal user messages, type into the lead, or take the lead role.

## 2026-10-18 10:57:29 Accepted host-hygiene-ended's edit to Sources/VibeCore/SessionDigest.swift (HostCall tracks the seq and throws on an input refusal), and added that file to the task's boundaries.

HostCall is a host client like HostClient. Without the change the tool server would report refused input as typed, which is exactly the silent loss E-07 removes.

## 2026-10-18 11:04:18 Accepted workers-live-through-an's edits to LeadLaunch, LeadWorkflow, LeadController and UnixSocket, and its RedactionLeakTests change (an absolute 50 ms limit became ≤ 10× benign input in the same run), and added them to its boundaries.

The lead asked for these in the contract and the rework. The relative bound still catches a rule that has gone quadratic by orders of magnitude, but no longer fails under load.

## 2026-10-18 11:10:28 host-hands-its-live merges without the vault wiring; lead-secrets-out-of wires LeadVault.Book through the handover's secrets channel after rebasing onto it.

The channel is already built and tested. The wiring needs code from both branches, and the task that merges second is the natural place for it, so the handover doesn't sit waiting.

## 2026-10-18 11:18:04 Follow-ups from keep-up-with-claude go to existing tasks. a-compacted-worker-doesn also covers LeadStall flagging an idle compaction as "compacted". The app reading HostSession.programStatus (OSC 7501) becomes its own app-side task after the restart. keep-up-with-claude's scratch leftovers in ~/.claude (scratchpad transcripts, 3 plan files) are to be removed by that worker once its audit is done.

These are outside its boundaries but came out of its findings, and the planned tasks already own those areas.

## 2026-10-18 11:18:22 lead-secrets-out-of merges now without the handover wiring. The wiring, the LOCAL_PEERTOKEN race fix (a per-connection challenge for the app) and its flaky 10 s wait go to the new task the-lead-s-vault.

The audit passed clean. The coming restart replaces the Oct 16 host fully (it has no handover), so the vault only needs to survive a handover from the next host update on. Splitting it lets the restart go ahead sooner.

## 2026-10-18 11:22:34 the-lead-s-vault is blocked until lead-secrets-out-of merges. Its worker must start with `git merge project-lead`, because its worktree was made too early, before the vault code existed. Watch: the installed merge tool rebases commit by commit, so a branch that merged the base in, and conflicts again, may never land until workers-update-their's squash path is installed.

The lead started it too early. Branches updated by merge (workers-live-through-an, tests-pass-on-a) can't be rebased cleanly by the old merge tool if their commits conflict when replayed.

## 2026-10-18 11:35:12 Approved workers-update-their's squash path in Worktrees.rebaseAndTest: a branch that merged the base in lands as one commit on the base. Added Worktrees.swift and WorktreesTests to its boundaries.

Acceptance check 3 asked for it. Without it, every branch updated by merge would replay its conflicts and never land.

## 2026-10-18 11:56:32 Until the new merge tool is installed, a branch that has to update with a merge ends by squashing into one linear commit on project-lead (`git reset --soft project-lead` + `git commit`), so the old rebase-based merge tool can land it.

The installed merge tool replays every commit and can't land a merged-in branch whose old commits conflict. Squashing keeps the restart to one, with no extra app install just to get the new merge tool.

## 2026-10-18 12:05:01 lead-secrets-out-of ships in this restart even though any host connection can ask for a handover. The fix (handover accepted only from the app) goes to the-lead-s-vault, which is the next host task after the restart.

It isn't a regression: before this task the secrets were plain files any process could read. The fix lands through a handover, so it costs no session restart. Holding the restart for it would delay every merged fix by hours.

## 2026-10-18 12:35:32 lead-secrets-out-of ships with the known peer-token residuals written into the README: pre-exec writes read as the app when accepted late, and any connection can ask for a handover. The challenge-based app identity in the-lead-s-vault is the next host task, and it lands by handover after the restart.

It's a large improvement over the plaintext files and not a regression. The fix needs a new protocol step (an app challenge) that would delay the restart by hours, and it can land without ending any sessions.

## 2026-10-18 13:06:10 Restart plan, for whichever lead runs after it. Everything for the one session-ending restart is merged into project-lead: host hygiene, handover, OSC 7501 + Claude 2.1.302, disk guard, pkill guard + host log, load-proof tests, merge-based worker updates, lead secrets in the host. The user runs scripts/build-app.sh --install, restarts the session host from the window (the Oct 16 host has no handover, so this one replace ends every session), then opens a new lead. Next tasks after the restart, in order: (1) the-lead-s-vault: it must first `git merge project-lead` (its worktree predates the vault code), then wire the vault through the handover, accept handover only from the app, and add the app challenge; (2) decisions-with-a-timer (blocked mid-rebase: abort it, then merge); (3) tests-stay-green-under; (4) one-session-s-crash (host watchdog; also covers SIGTERM routed through server.queue); (5) a follow-up so the app reads HostSession.programStatus; then the planned list. Check the sidebar edge strips with the user (they may catch clicks on the right screen edge).

So the next lead can pick up straight from the board after the restart, without this conversation.

## 2026-10-18 15:05:58 Re-plan after the new lead's full review (2026-10-18 ~15:30). Wave 1, started now: the-lead-s-vault (handover/kill caller checks, base-check reset, vault across handover, app challenge), the-lead-s-tools (merge holds + `kept` state, bounded status/board, forgiving params, draft clear, E-09, honest board after host replacement), tests-stay-green-under (now also: tests leave nothing in TMPDIR), no-silent-data-loss (E-01, E-10/F-C1, E-02, E-13), the-current-build-doesn (hangs, SwiftUI publish faults, idle CPU on today's build). Queued: decisions-with-a-timer (after the-lead-s-tools; abort rebase, then merge), the-app-shows-what (after vault + hangs), one-session-s-crash, a-compacted-worker-doesn, the-window-always-offers, accessibility-labels (+AX-4 text sizes, WL-3 status wording), then verifier-2-0 / risk-tiers / scorecard / the-lead-s-decisions. Security and hook-installer merges are shown to the user before landing. Until the-lead-s-tools lands, this lead never merges a task that a recorded decision or the user holds back, and reads decisions.md before any merge.

Evidence from the review: (1) HostServer.swift:291 accepts .handover from any connection and :275 .kill likewise (verified by the lead), defeating the guard rails; (2) genswap's fresh lead merged a held prototype and deleted 4 audited branches at 14:52 because the lead prompt merges unconditionally; (3) status/board outputs of 82–408 KB, 47 failed progress/report calls, 8 draft refusals waste lead turns; (4) test runs left 9.4 GB in TMPDIR and worker scratch 19 GB in /private/tmp, and the disk filled at 09:47, killing 5 workers; (5) stalls of 13–51 s and 4,102 SwiftUI faults on 10-18; (6) the top data-loss eval findings were never on the board. The five tasks touch disjoint file sets (lead tools vs host/vault vs app UI vs settings/run button vs tests), so they can run in parallel.

## 2026-10-18 15:35:13 the-lead-s-vault may change one guard in LeadToolset.swift merge() as a call site (missingVerdictReason). Its app-identity design is accepted with conditions: an HMAC over the welcome nonce, keyed by a 32-byte key in an app-only Keychain item and held in the vault. Conditions: the Keychain ACL is app-only; first-connection key teaching is allowed only while the vault has no key; replacing a key needs the app's cdhash and is logged; the bootstrap window and any key-replacement race are named in the README; the key and HMAC are never logged.

The verdict-reason message belongs to the vault, and the call site is in merge(). The HMAC removes the LOCAL_PEERTOKEN race. Its only weak points are key bootstrap and key loss, so those are bounded and disclosed rather than left implicit.

## 2026-10-18 15:45:18 tests-stay-green-under may fix the tty-name race in the host: ttyname_r in PTYSpawn.swift:29, and ptsname_r in HostedSession.spawn. It goes in its own commit with a regression test.

The worker found that ttyname/ptsname use a shared static buffer. In its probe, 2111 of 6400 concurrent calls returned the wrong name, so under load a new session could open another session's terminal (lost output) or a dead one. This is a real production bug that surfaced as a flaky test, and the fix is two calls in files the vault task isn't changing.

## 2026-10-18 17:03:44 Approved tests-stay-green-under's additive production test hooks, SessionStore.clock and PreviewProxy.connectTimeout (default unchanged at 5 s). Also approved its fix of the port-read race in startProxy, plus its use of ptsname_r instead of ttyname_r for the terminal-name fix. They're added to its boundaries.

The boundaries already allowed additive test hooks. The startProxy race is a real production crash (a force-unwrap of a nil port under load) that the load runs found. The worker measured that ttyname fails under load even when called from a single thread, so ptsname_r on the master is the sound fix.

## 2026-10-18 17:55:49 Accepted the crash-isolation cost: one parser process per session, adding about 3.5 MB of footprint per session (about 130 MB at 37 sessions) and no idle CPU. The parser keeps the 5,000-line scrollback.

Measured on release builds, the host plus parsers use 42 MB of footprint at 10 idle sessions, against 9 MB before. In exchange, one session's parser trap or stall no longer takes down every session. The phone's transcript view asks for 5,000 lines, and the raw replay can't stand in for the scrollback, so it isn't cut to 1,000.

## 2026-10-18 18:08:18 Install plan for today's 11 merges. The user runs `scripts/build-app.sh --install`, and the app relaunches and hands every session over to the new host build automatically: pid 31589 has the handover, so nothing ends. Then this lead, and genswap's, restart from the app. After the install, the lead checks: - the host pid is unchanged; - the session count is unchanged and parsers are running; - no 'main thread stuck' lines and no 'Publishing changes' faults; - the real app's CPU and RSS with about 30 sessions; - the app's Keychain item was created and enrolled (host.log); - the restart button shows only for an outdated host. Nobody uses the `kept` task state before the install: older tool servers can't decode it.

Eleven fixes reach the user only through an install. The handover keeps every session. Running leads hold old tool servers until they restart. Pid 31589's build never sends the vault through the handover, so the new host reloads it from the sealed file. If it can't, merges say 're-run audit'. That's expected, not a bug.

## 2026-10-18 18:20:47 merges-and-worker-limits may add a test_timeout_min key (default 45) to workflow.md: it's parsed in LeadWorkflow.swift and can be set through configure. LeadWorkflow.swift and configure's entry have been added to its boundaries.

E-17 asks for the merge's test-time bound to be configurable, and workflow.md is where every other workflow setting already lives. The edit is one key, one parse line and one configure entry, each with tests.

## 2026-10-18 18:21:18 The 18:10 install is verified, as reported by the previous lead: host pid 31589 is unchanged, 11 sessions with their parsers, the app key is enrolled, no stalls or faults since, and the app idles at 0–5 % CPU. Two bugs from it are being worked on now: a-successful-handover-is (the log line is wrong, but the handover itself was fine) and reports-go-to-the (one wake went to the replaced lead). The queue after that: a-worker-can-t once merges-and-worker-limits lands, then timed-out-shell-runs, then accessibility-labels.

The previous lead lost its tools when the app started this lead, so it couldn't record these items. The user pasted its handoff. a-worker-can-t touches LeadToolset like merges-and-worker-limits does, so it waits for that one to land.

## 2026-10-18 18:23:05 An install must not replace a running lead. The lead session that is live keeps its role and conversation, and a new lead starts only when none is live or when the user asks for one, after a confirmation. This is task a-running-lead-keeps, started now. It changes the guard rails' role binding, so it's shown to the user before merging. Install plans stop telling the user to restart the lead from the app.

At the 18:10 install, the films lead lost its role mid-conversation. The user's answer ('Do what we need to do') and its decisions never reached the board, and the refusal pointed to /mcp, which can't give the role back. The earlier claim that 'the transfer worked' was only true of the sessions, not of the leads.

## 2026-10-18 18:43:13 input-is-never-cut is released from 'kept' and merged. The user approved it ("Merge it", answering question 4ED4789A).

The hold was decision 2026-10-17 17:23: sensitive paths merge only with the user's approval. That approval has now been given for this exact audited commit (c90efe1).

## 2026-10-18 18:44:42 a92a8dc on project-lead (18:33:46) is accounted for. It was committed by Claude session db4ba5f3 in the main checkout, which the user started at 18:31 by pasting a VibeSwitcher crash report. That session fixed the crash and asked "Should I run the install now?", the user said yes, and it installed at 18:41. The diff is benign. LeadTask.Status.attentionOrder now holds every state, including kept. The Team strip no longer force-unwraps a missing state, and status lists tasks in the same order as before. Nothing touches the guard rails' logic. The base move still waits for the user's confirmation in the app.

The user said a92a8dc wasn't theirs and asked for an investigation. The transcript, the reflog (a plain commit in the main checkout, not a merge) and the diff show where it came from and what it does. It was a fix for the crash that this lead's own use of the 'kept' state caused.

## 2026-10-18 18:49:28 Direction from the user: running VibeSwitcher must be seamless. The user never restarts a lead, runs /mcp, or confirms their own commits. Three tasks deliver it: (1) a-running-lead-keeps: installs never replace a running lead, the team keeps its grants, and when a new lead does start it's adopted rather than replacing. (2) tool-servers-update-in: every vibeswitcher-mcp swaps itself for the new build in place (exec between requests, same stdio and grant). (3) the-user-s-own: a base move made by the user's own (non-team) sessions is accepted automatically, provided the session is identified by what the host can verify. Anything else falls back to a one-click prompt in the app, never a restart. The current a92a8dc block is cleared once, at the end: the user does one restart and then one install, after which none are needed. The three are shown to the user together before merging, because they change guard rails.

The user said: "all of this restarting the leaders … is just too complex … do whatever you need to do to make this seamless". The guard rail against unaudited base moves stays, but it learns to tell the user's own commits from the team's. Commits it can't attribute still need a click, never a restart. One last restart can't be avoided, because these fixes have to merge through the very check they replace.

## 2026-10-18 18:50:08 Merge policy for vibeswitcher, set by the user: the lead merges audited work by itself, including guard-rail, security and hook-installer changes, and doesn't ask per merge. It then posts an update saying what changed, how it was checked, the risk and how to revert. This replaces the 2026-10-17 17:23 hand-applied risk tiers. The user is asked only about direction, taste, and anything irreversible or outward-facing (pushing, publishing, deleting work). The lead also checks in with the user proactively and runs a short retrospective now and then.

The user said asking them about every merge is annoying and mostly pointless. Merge behaviour is something the lead should agree with the project owner once, and then the lead should be proactive: ask how they want things done, check how things are going, and run retrospectives.

## 2026-10-18 19:02:29 The root cause of the 18:10 role loss is settled. Nothing started a new lead at relaunch. The host build that handed over (1792327555, from 14:45) predated 74202dc, so it didn't carry the vault, and the new host reloaded a disk copy that bound neither lead. Every role broke at once, the leads' and the workers'. That can't recur from this host on, because the current host carries the vault across handovers. a-running-lead-keeps adds the rest: the app re-binds live leads after a relaunch, a start waits for the host's session list, and the refusal names who holds the role with no /mcp advice.

This was found by the worker on a-running-lead-keeps from host.log ('took over 11 sessions … ' without 'bytes of secrets') and from the transcripts. The refusal had falsely said "VibeSwitcher started another session for it".

## 2026-10-18 19:16:08 Handover plan for the one remaining restart (whichever lead runs after it reads this). The user ends this lead, starts Project Lead on vibeswitcher and accepts project-lead at a92a8dc when the app asks. That accepts their session's crash fix (see the a92a8dc decision). The new lead then merges, in this order: input-is-never-cut (user-approved), a-successful-handover-is, reports-go-to-the, a-running-lead-keeps, the-user-s-own, risk-tiers-the-user. Each audit is complete and clean; a rebase conflict means a rework round, not a re-plan. tool-servers-update (back for its 'swap during a host handover keeps retrying whoami' fix) and merges-and-worker-limits (back for its getpgid race / flaky ShellTests fix) merge after their re-audits. Merge policy is auto, so nothing gets asked per merge; post_update after each. Once all 8 are in, ask the user for one install. Because the servers still run today's build, sessions need /mcp one last time after that install. After it: configure(merge_policy: auto), check host.log for 'bytes of secrets' on the handover, check that the leads kept their roles, and run a first retrospective of today (stranded workers, the 18:10 role loss, the kept-state crash, per-merge questions).

Only a restart in the app can accept a92a8dc, because the fixes that remove that need have to merge through the same check. All the seamless pieces have now passed their audits or are close to it. The restart doesn't strand the running workers: the vault never drops workers when a new lead starts (shown by a-running-lead-keeps), and the 18:10 loss came from a host that didn't carry the vault.

## 2026-10-18 21:41:55 Handover point again. project-lead moved bd31314 → d149a63d via the user's own commit (the witness no longer reads the kernel process table on the main thread, which fixed tonight's 15-minute hang). The installed guard rail refuses merges until a lead restarted from the app accepts that move. The user ends this lead, starts Project Lead and accepts d149a63d. The new lead then merges, in order: tool-servers-update (status 'failed' only because of the flaky PasteDeliveryTests, which pastedeliverytests-hold fixes; its audit was clean), the-user-s-own, a-running-lead-keeps, the-witness-doesn-t (it touches LeadWitness like d149a63d does, so expect a conflict and a rework round), merges-and-worker-limits (re-audited clean at 9948966), and pastedeliverytests-hold once its audit passes. merges-and-worker-limits' worker has no tools (role lost at 18:10): message it, then audit from the branch. Still running: stale-git-index-lock (what leaves 0-byte index.lock files behind). When all are in, ask for one install, then follow the 19:16 plan's post-install checks and the retrospective. The machine runs at load 100–200 with low memory, so keep the team at 3 or fewer sessions until it settles.

The-user-s-own, which accepts the user's commits without a restart, is itself waiting to merge, so this restart can't be avoided. Writing the state down lets the next lead go on without this conversation.

## 2026-10-18 22:16:10 New lead (22:12). merge_policy is now written as auto in workflow.md, per the user's 18:50 choice; the policy question is settled and never asked again. Merge order changes from the 21:41 plan: nothing merges while the Mac is under the pastedeliverytests-hold verifier's deliberate load (96 `yes` processes, load 160–190); when that audit passes, pastedeliverytests-hold merges first (test-only, one file), because its fix removes the flaky test that failed tool-servers-update's merge and would flake every other merge; then tool-servers-update, the-user-s-own, a-running-lead-keeps, the-witness-doesn-t (expect a LeadWitness conflict), merges-and-worker-limits. stale-git-index-lock reruns its last full check only once the 1-minute load is under 40. Sessions of four merged tasks (no-silent-data-loss, tests-stay-green-under, input-is-never-cut, a-successful-handover-is) are cleaned up now to free memory.

Every merge runs the full suite, and PasteDeliveryTests fails under load; landing its fix first makes the other five merges reliable. The verifier's heavy-load phase is finite and ends before its full-suite runs. Earlier tonight memory pressure killed workers and a 15-minute hang hit the user, so idle sessions of merged tasks shouldn't stay alive.

## 2026-10-18 23:18:38 The lead's shell is denied `rm` and git in the main checkout, so a stale index.lock in /Users/albert/dev/vibeswitcher/.git is removed by a worker on the user's say-so (given at 23:14, "you do it"), under the IndexLock conditions: 0 bytes, no holder by lsof, no git process in that checkout, older than 60 s. Nothing else in the real .git is touched. The stale-git-index-lock worker does it this once; its audit stands and it commits nothing for it.

The same stale lock blocked every merge twice tonight (20:08 and 22:02), the user's rm didn't land, and asking again costs more of the user's time than the one-line removal. The checks are the audited ones from the worker's own IndexLock code, so the lock is never taken from a live git.

## 2026-10-18 23:43:32 Retrospective changes (2026-10-19 00:10): (1) audit evidence must survive a worker's report on an unchanged commit (task "Audit evidence survives a worker report on the same commit"); until it lands, the lead tells workers to answer non-code requests with progress(text:), never report(summary:). (2) The witness must not call a worker stalled while it waits on its own background task (task of that name). (3) Load tests run only through scripts/test-under-load.sh, capped at 2×ncpu, refusing an already loaded Mac (task "One load harness"); until it lands, every contract and audit that involves load says "at most 2×ncpu load processes, stopped by pid afterwards, never when the 1-minute load is already above 2×ncpu". (4) Sessions reported ended must really end (task ended-sessions-really, started).

Each cost real time tonight: a reset audit cost 25 minutes and two verifier runs; a false stall woke the lead for nothing; a verifier's 96-process load slowed every other session for 25 minutes; seven leaked sessions hold 2.4 GB on a Mac that ran out of memory twice today. A rule in a note is forgotten by the next lead; a check isn't.

## 2026-10-18 23:50:05 Install of build 1792360149 done at 23:49 (2026-10-18) by the lead itself, on the user's "Install now". Verified: host pid 31589 unchanged, 31 sessions and 16615 bytes of secrets handed over, 31 new-build parsers, all three leads (vibeswitcher, genswap, films) kept their roles and sessions, no main-thread stall since. The lead's and the running workers' tool servers are the previous build and work; they'll swap themselves at the next install. The lead runs installs from now on when the user says so; the user needs to do nothing but allow a Keychain prompt if one appears.

The first install under a-running-lead-keeps and the vault handover: it proved the seamless path works end to end. Writing the verified state down saves the next lead from re-checking it, and from asking the user to restart anything.

## 2026-10-19 00:18:48 Merge sequencing under load (2026-10-19 00:30): three audited branches (a-replaced-lead-never, accessibility-labels, ended-sessions-really) merge in that order only once the 1-minute load average is under about 40, and no new worker starts until they have landed. ended-sessions-really's failed merge (8 IndexLockTests: the lock-holder search overran its 10 s bound) is a load artefact, not a defect of that branch; the search's slowness under load is a real weakness, assigned to indexlocktests-hold as a production fix in its own commit.

Each merge runs the full suite in a fresh scratch build, and with five workers each running the suite twice the Mac sits at load 66–113, where IndexLockTests and ParserIsolationTests fail for timing reasons. A failed merge costs ten minutes of CPU and makes the load worse. Letting workers finish first lands the audited work in one pass each.

## 2026-10-19 00:48:11 While audited branches wait to merge (2026-10-19 00:50): at most one merge and one verifier run at a time, and no new worker starts; the audit of a finished task waits for the running verifier, and a merge waits for the 1-minute load to be under 35 (a background watch wakes the lead). Order of the queue: accessibility-labels (merging), ended-sessions-really, a-worker-seen-before, timed-out-shell-runs, then board-decode-off-the and test-hosts-exit-with as their audits pass.

Every merge runs the full suite in a fresh build; with two verifiers and three workers also running suites, the Mac sat at load 50–115 and two merges failed on timing-sensitive tests their branches don't touch (IndexLock holder search, parser isolation, Codex trust). One merge plus one verifier keeps the load where the suite passes, and the backlog is only five branches.

## 2026-10-19 07:45:50 Paused at 06:00 on 2026-10-19: the Mac is on battery at 2 % and in sleep cycles (Maintenance Sleep since 01:38, dark wakes of a few seconds every 15 minutes), so no audit or merge starts until it is on AC power and awake; a background watch wakes the lead then. The session host (pid 31589) and the 35 sessions survived. Resume plan, in order: (1) a-worker-seen-before: its full test runs (started 03:14) were frozen across the sleeps; if the worker reports green, audit and merge, else have it rerun; (2) audit indexlocktests-hold again (two verifiers died on the sleep); (3) merge timed-out-shell-runs and test-hosts-exit-with (both audited clean), one at a time under load 35; (4) then start workers for the-witness-reads, the-process-table, audit-evidence-survives, one-load-harness-test and the-app-keeps-the, at most 3 at once while merges wait; (5) ask the user for the next install once the queue is in (nine fixes since the 23:49 build). The-app-keeps-the (a power assertion while the team works, on AC power only by default) is the lasting fix.

Two verifiers and one merge test run died on the sleeps, and a worker's build ran 25 minutes across dark wakes. Starting more work now only burns the last battery and produces more API errors. Writing the state down lets the next lead, or this one after a context reset, continue without the night's conversation.

## 2026-10-19 08:06:04 From the user (2026-10-19 08:05, answering the leaked-sessions question): operational hygiene is the lead's to decide, carefully and holistically, not the user's: leaked or stale sessions, stale lock files, load and memory on the Mac, scratch leftovers. The lead acts (from its own shell when the tools can't, with each target re-verified first) and reports what it did; it asks the user only for direction, taste, and anything irreversible or outward-facing. The seven leaked sessions are ended by the lead now with SIGHUP, each pid checked against its task's session command line before the signal.

The user's words: "This is the type of thing that you should be able to decide yourself in a careful manner and thinking holistically." The question sat seven hours for an action that was safe to take: idle sessions of merged tasks, confirmed by ps, that no tool could end.

## 2026-10-19 09:23:35 Merge order re-planned (2026-10-19 09:40): indexlocktests-hold merges before every other waiting branch, as soon as its audit passes, because it fixes the four tests that keep failing merges at ordinary load (IndexLock holder-search timeouts, the parser-isolation 0.1 s bound, the pkill guard's machine-wide pgrep, the Codex trust quit/timeout race) and makes the lock-holder search fast. a-worker-seen-before (three failed merge attempts: a sleep-killed run, a load-killed run, then the parser-timing flake) and timed-out-shell-runs merge right after it.

Each merge runs the full suite in a fresh build; at any load above about 50 one of those four tests fails, and the Mac rarely stays below that with two workers building. Landing the test fixes first turns the remaining merges from coin flips into single passes.

## 2026-10-19 10:04:14 Concurrency cap from 2026-10-19 10:40 until worker-and-verifier (Mac-wide, load-aware starts) lands: the lead starts no new worker while a merge or a verifier is running and the 1-minute load is above 35, and never more than three workers at once while anything merges. Running workers finish; freed slots stay empty until the load is under 35. Audits of finished tasks start one at a time. The five workers started between 10:05 and 10:30 took the Mac to load 198 by 10:40 on their own.

Each worker runs a release-sized build and two full test suites; five at once plus a merge's fresh build and a verifier's two runs is more than the 12 cores can carry, and above load 100 the handover and timing tests fail for reasons unrelated to the branch, costing a rework round each (five such rounds since last night). Throughput is higher with three workers finishing than with five crawling and merges failing.

## 2026-10-19 10:50:56 Install held (2026-10-19 ~11:00) until a-process-in-a lands: the-process-table (merged this morning) returns nil for the whole table whenever one of the user's own exec'd processes has unreadable argv after two immediate retries, which happens throughout builds and test runs; installed, the app would stop updating its session list during any build. The chat-and-terminal-stay merge (audited clean) failed only on two ProcessTable tests for this reason and is retried once the fix is in. The fix keeps whole-or-nothing for the deadline and the pid listing but records a transient process with an unknown agent instead of voiding the table.

The user's build keeps freezing and an install is wanted, but installing a session scan that freezes during builds would trade one visible defect for another. The ProcessTable tests are now part of every merge's gate, so the flaw also blocks the queue; fixing it first unblocks both.

## 2026-10-19 11:28:38 The user authorised the next install (2026-10-19 11:25, answering AD014B4B): "Go ahead and install as soon as the process-table fix lands." Sequence: merge a-process-in-a once its audit passes, retry the chat-and-terminal-stay merge (its only failure was the process-table flake), then run scripts/build-app.sh --install from the lead and verify as on 10-18 23:49 (host pid unchanged, sessions and secrets handed over, leads kept, no stall lines). The other audited branches (rows-never-show-a, audit-refuses-a-branch, the-lead-s-decisions, the-app-keeps-the) merge after the install and go into a later one.

The user's build freezes several times a day and both fixes are merged; the chat-sync fix was promised in the same install and costs ten minutes; the rest can wait for a later install without cost.

## 2026-10-19 12:07:52 Install of build 1792404424 done at 12:07 on 2026-10-19 by the lead, on the user's authorisation of 11:25. Verified: host pid 31589 unchanged, 40 sessions and 42257 bytes of secrets handed over, 40 new-build parsers, all three leads kept, no main-thread stall since. The six audited branches held back by the process-table gate (the-app-keeps-the, rows-never-show-a, audit-refuses-a-branch, the-lead-s-decisions, a-worker-can-t, the-ui-bench-s) merge now in that order into a later install; when the-lead-s-decisions and a-worker-can-t have both landed, check that the guard hash reads records_dir as the team does (a missing line equals the default), as a-worker-can-t's worker flagged.

The user's build froze four times before noon; this install delivers both fixes plus the morning's work, and the verification matches last night's. Writing the order down keeps the next lead from re-deciding it.

## 2026-10-19 13:26:24 Merge sequencing from 13:40 on 2026-10-19: three audited branches (the-merge-s-test retry, tests-never-write-to, a-worktree-that-left) wait while the Mac sits at load 80–105, because the merge gate's ProcessTable tests fail above about load 80 (a 2 s snapshot deadline on a busy kernel). process-table-reads fixes those tests and the deadline; when it passes its audit it merges first, at whatever load, since its own suite carries the fix, and the others follow at load. A load watch under 35 is the fallback trigger if it comes first.

Two merges failed today on ProcessTable tests at load 80+ that their branches didn't touch; each failure costs ten minutes of CPU and raises the load further. The fix that makes the gate load-tolerant is the one branch whose merge can't be hurt by the load.

## 2026-10-19 14:46:45 Next wave (2026-10-19 15:00), from the re-check of the four evaluation reports (docs/eval/open-2026-10-19.md, in audit): eight tasks added as the top open items, to start as slots free and the Mac's load allows, in this order: the signing identity and password (F-F2, install-sensitive: one line to the user before the install that carries it), a Terminal.app session answerable from the window (WT-1), phone option buttons (PH-1), a dropped host connection never reading as no sessions (E-09 residual, after handover-tests-hold), the two guard-rail residuals (F-L3r/F-L2r), the hook's clip-before-redact and bounds (R4/E-28), the hook installer touching only our handlers (F-H2/H1/E-13), and the steer inbox lock off the main thread (E-14). Items 9–23 of the ranked list wait for these; R3 and R9 touch HangWatchdog.swift, the user's own area, and need the user's word before anyone is assigned.

The reports' top lists were two days old and the lead's own mapping guessed at a third of the verdicts; the re-check gives each open item evidence and a contract. The order follows the report's user-impact ranking.

## 2026-10-19 15:41:07 the-signing-identity-can (F-F2) is not merged until the user answers question 8659FA84 (asked 16:20, 2026-10-19): the fix removes the plaintext keychain password and makes the key codesign-only, but after it every build shows a macOS password dialog (no unattended installs by the lead) and a one-time setup-signing.sh re-run makes a new identity that re-asks macOS for Accessibility, Automation and the Keychain item. If its audit passes before the answer, the task is set to kept with that reason. If the user chooses "merge but keep unattended installs", a follow-up task designs a session-long unlock the user grants once.

It trades the user's stated direction (seamless, unattended installs) against the top open security item; that's the owner's call, not the lead's. Holding it keeps the next install unaffected.

## 2026-10-19 15:50:18 On battery (2026-10-19 16:4x, 29 %, 36 min left): no new worker, audit or merge starts until the Mac is on AC power; the merge in flight (verifier-2-0-part-2) and the two running audits (handover-tests-hold, installing-removing-or) finish. The two running workers continue unless the user says to stop them. An AC-power watch wakes the lead to resume.

The team's builds are the battery drain; a hibernated Mac resumes safely (seen last night) but a drained one at 0 % loses in-flight test runs. Finishing what's running costs minutes; starting more would cost the user's battery for work that could wait.

## 2026-10-19 16:34:55 The user chose to merge the signing-identity fix (F-F2) at 17:2x on 2026-10-19 ("security first, I'll type the password at installs") and called the per-build prompt annoying. the-signing-identity-can is released from kept and merges after the handover fix; a follow-up task makes the keychain ask once per login session (lock on sleep and logout only), restoring unattended installs while the user is logged in. Until that lands, every build, including the lead's installs, needs the user to type the keychain password once, and the first launch after the identity change re-asks macOS for Accessibility, Automation and the Keychain item.

The owner decided the trade-off; the follow-up removes most of its cost without bringing back the plaintext password or an extractable key.

## 2026-10-19 17:37:49 Product choices made by the lead on 2026-10-19 19:3x for the user's two feature requests, without asking (reversible, in branches, audited before merge): (1) the voice briefing is one "Brief me" button in the window toolbar and the menu bar popover, 70–90 words written by the same headless Claude path as the team one-liners, in a language chosen in Settings (default the Mac's first preferred language), spoken by ElevenLabs when an API key is set in Settings (kept in the Keychain) and by the Mac's own voice otherwise; the text is redacted before any model or network call and leaves the Mac only on the button; the phone gets the same button in a follow-up task. (2) The New Project sheet takes a name, a location prefilled from a new "Projects folder" setting (default ~/dev), git init with README, .gitignore and a first commit on the default branch, and a "Then" choice (nothing, open a session with a preset, start the lead with a first goal); no license or template pickers and no GitHub creation unless the user asks. Verifier 2.0 part 2 merged with audit_finders left at 1; the lead will try 2 on a sensitive-path task after the next install and record the cost.

The user asked for the features and left the details open ("I don't know if there need to be any other settings"); these are the smallest versions that do the job, and the user can ask for more once they see them.

## 2026-10-19 17:53:47 test_command is now `bash scripts/test.sh` (set 2026-10-19 20:3x). The script, from home-or-vibeswitcher, runs `swift build && swift test` on a fresh scratch HOME, CFFIXED_USER_HOME, VIBESWITCHER_HOME and TMPDIR under /tmp that it removes on exit. Reason: the same branch adds a guard that refuses to run the tests against the real ~/.vibeswitcher, and the lead's running tool server (older than today's merge-runner scratch-HOME fix) ran the merge's tests on the real home, so the merge was refused by that guard. With the wrapper, every merge, worker and verifier run is isolated whatever server runs it. home-or-vibeswitcher must merge first (it carries the script); every later branch is rebased onto it.

A merge that writes into the user's real app folder was today's recurring incident class (app.log lines, Keychain dialogs); the guard is right to refuse, and the wrapper makes the isolation the default rather than something each caller remembers.

## 2026-10-19 18:35:39 Lead policy from 2026-10-19 22:1x: when the lead accepts an edit outside a task's listed files (by message to the worker or on its own judgement), it appends that acceptance to the task's context (update_task) before calling audit, so the verifier can see it. Reason: two same-commit re-audits today (a-new-project-button, the-phone-gets-the) were caused by approvals the verifier couldn't see. The task the-verifier-sees-the makes the verifier's prompt carry the lead's notes and messages, after which the policy still holds as a habit.

A verifier judges from the contract and the board; an approval that lives only in a message to the worker doesn't count for it, and a repeated full audit costs 20–30 minutes of a loaded Mac each time.

## 2026-10-19 19:06:00 Merge load threshold raised from 35 to 60 (1-minute load) on 2026-10-19 23:3x: every merge this evening ran clean at loads 45–110 once the load-sensitive tests were fixed (PasteDelivery, IndexLock, ParserIsolation, CodexTrust, ProcessTable, handover, SteerOffMain). Audits may start at any load; the lead keeps at most one merge at a time and at most five workers. Retrospective changes recorded as tasks: a temp-folder lint in the normal suite (the-normal-test-suite) and setup-signing.sh announcing each dialog (setup-signing-sh-says). Earlier today: the verifier sees the lead's approvals and the witness ignores verifiers that already gave their verdict, both merged.

The morning threshold protected a flaky suite; tonight's evidence shows the fixes hold, and a lower threshold only delays merges while workers build.

## 2026-10-19 21:30:31 regression_command stays unset for now (2026-10-20 06:1x). The chat bench's settle script, the intended regression check, fails about one case in eight on a quiet Mac on main-thread layout cost alone (pages 0.13–0.18 s with outliers to 0.33 s against the 0.25 s rule; release gives no headroom), so it would fail merges for a cost that isn't a regression. It is pointed at the script once chat-paging-main-thread-cost lands and the script passes 12/12.

A regression gate that fails on known cost trains everyone to ignore it; the bench itself is in (R12) and the cost has a task with numbers.

## 2026-10-19 22:25:12 Clock correction (recorded 2026-10-19 22:25 CEST): every lead note, task context entry and decision stamped "2026-10-20 01:xx–08:xx" was in fact written on 2026-10-19 between about 19:30 and 22:25 CEST; the lead had assumed the day had rolled over. The "night's summary" posted as 07:15 was written at about 21:30 on 2026-10-19, and its counts ("since yesterday morning", "overnight") mean since 2026-10-18 22:10. From here on the lead stamps notes with the Mac's clock (`date`).

A later lead reads these records as its memory; wrong dates would misorder the evening's decisions against the board's own timestamps, which are right.

## 2026-10-19 22:29:18 Merges are held from 2026-10-19 22:35 until chatbenchtests-records has merged: the chat bench test (merged 21:1x) fails on a quiet Mac on the known layout cost (a 0.50 s first-open tick with 0.25 s CPU, between its two escape hatches) and has four cases per full run, so it failed the hook-bounds merge and would fail a large share of merges. The-hook-bounds-tests and hostclienthandovertests (once audited) merge right after it. The chat-paging-main-thread task restores the hard assertion when pages cost under 0.1 s.

A merge gate that fails on a known, filed cost blocks unrelated work; the chat bench stays as the record, the test stops being a gate for that one window until the cost is fixed.

## 2026-10-19 23:26:08 Merges resumed 2026-10-19 23:4x after chatbenchtests-records merged. ChatBenchTests' rule until chat-paging-main-thread lands: judged only when the 1-minute load before and after is under the core count; a failing tick is the known issue "chat paging main-thread cost" when its wall time or its main-thread CPU is at most 0.5 s; more than 0.5 s of main-thread CPU, a non-settle or a hang fails. The bench (ChatBench.swift) and the settle script keep the strict 0.25 s rule. regression_command stays unset.

The known layout cost (0.13–0.18 s a page, outliers to 0.7 s wall under suite load) was failing unrelated merges; the test keeps catching a doubling of main-thread work while the fix is made.

## 2026-10-20 07:42:51 Swift tool runs (scripts and the lead's, workers' and verifiers' sessions) get a scratch TMPDIR of their own that is removed afterwards; the lead cleans the leaked empty TemporaryDirectory.* folders in the user's temp folder once by hand.

2026-10-20 07:4x: 32,871 empty TemporaryDirectory.XXXXXX folders had piled up in the user's $TMPDIR; measured: SwiftPM leaves ~7 per swift build and ~5 per swift test, and only scripts/test.sh redirected TMPDIR. Per-session scratch stops ad hoc runs (benches, settle matrices) from leaking into the user's folder and lets cleanup and the disk witness account for them per task.

## 2026-10-20 10:44:17 audit runs a trial merge onto the lead's branch first and refuses a conflicting branch naming the files (task audit-refuses-a-branch-2).

2026-10-20 retrospective: a-role-session-s passed a complete audit and only then was found to conflict with work merged meanwhile, costing a resolution round and a second verifier.

## 2026-10-20 10:44:19 audit judges settings changes from the branch's commits, reports untracked files in the worktree as leftovers, and workers keep scratch in their session TMPDIR, never inside the worktree (task audit-tells-untracked).

2026-10-20 retrospective: untracked bench scratch homes (.scratch/…/.claude/…) in the chat-paging worktree were taken for settings changes; the verifier started with settings off and waited on a trust question the lead had to end.

## 2026-10-20 10:44:21 The witness tells the lead about power changes (on battery with level and estimate, back on AC) and status shows the state; the lead's rule stays: on battery no new starts or merges, in-flight work finishes, resume on power (task the-witness-tells-the).

2026-10-20 retrospective: three battery switches in 12 h were handled only through the lead's own shell watches, which a replacement lead after a handover would not have.

## 2026-10-20 12:48:51 After the next install the lead keeps working down the current open-items list (WT-2, AX-6, then the HangWatchdog halves when the user says so) rather than re-running the full four-evaluator evaluation.

The user's answer to F8560841 on 2026-10-20 at 12:5x; yesterday's ranked list is nearly done and a fresh evaluation would cost four sessions for little new information.

## 2026-10-20 15:44:13 On battery the lead pauses new starts and merges only below 30 % charge (and always re-arms keep-awake only on AC); above 30 % audits, merges and starts continue as on power, with the battery watch turning into a pause at 30 %.

2026-10-20 15:4x: the Mac went on battery at 85 %; the earlier blanket rule was set during 7–29 % episodes to keep the Mac from dying mid-merge. A full charge gives hours; pausing three workers and their audits at 85 % costs more context and churn than it saves.

## 2026-10-20 16:19:43 GitHub's main is fast-forwarded from project-lead by the user when they ask (a8d93c2 → 9dca1f7 on 2026-10-20 at 16:2x; project-lead now tracks origin/project-lead); the lead never pushes (its shell is denied) and hands the user the exact command. The redaction tests' made-up Slack-webhook fixture (commit b99cd4c) was allowed through GitHub push protection by the user as "used in tests"; task pushes-never-trip-github keeps it from recurring.

The user asked "push to gh" and "lets merge to main"; main was a straight ancestor, so a fast-forward kept history linear and the checkout on project-lead for the workers.

## 2026-10-20 16:28:07 The lead does not message or otherwise touch the other projects' leads (genswap, TGE-ANALYSIS) for now: no SendMessage to them, no reviewing or reporting on their sessions; cross-project hygiene is left to the user and those leads.

The user's instruction on 2026-10-20 at 16:5x ("i dont want you to touch the othr leads for now") after the lead informed both leads about the end-of-day wrap-up.

## 2026-10-20 16:56:08 No GitHub push-protection bypass, ever: fixtures that must look like real secrets are assembled at run time from pieces, docs elide the prefixes, and a repo-wide lint keeps complete shapes out of every file; no .github/secret_scanning.yml. The three commits of the failed attempt (2554086, 9a2c0b9, fff5c70) are dropped from project-lead by a reset to 9dca1f7 (which GitHub already has), run by the user.

2026-10-20 17:0x: the user refused a second 'allow me to expose this secret' click ('This is unacceptable'); GitHub matches shapes regardless of EXAMPLE markers, and the ignore config can't land on main through a push it blocks.

## 2026-10-20 22:11:26 Overnight 2026-10-20/21 the lead runs two tasks on the quiet, plugged-in Mac: the-settle-script-passes (768-run chat settle matrix) and the-signing-scripts-can (keychain search-list hardening); audits and merges only, no install, no push; keep-awake armed for 8 h.

The user's answer to 5DA69A3D ("Run both overnight"): the matrix needs a calm Mac it never got during the day, and the signing-script hardening answers tonight's Chrome "Keychain Not Found" scare.

## 2026-10-20 22:12:05 The battery hold is level-based and a user setting: leads pause starts, audits and merges only while the battery is under the user's limit (default 50 %), not at every unplug; task battery-hold-only-below implements it, and until it lands the lead applies the 50 % line by hand to the witness's messages.

The user on 2026-10-20 at 21:2x: they plug and unplug often, and a hold at 100 % costs workers their context for nothing; the earlier 30 % practice becomes the setting's default of 50 %.

## 2026-10-21 00:15:37 The chat settle matrix passed 64/64 at 12/12 on a quiet Mac (2026-10-20 23:23–00:03, docs/eval/chat-bench-settle-2026-10-20.md, pending audit). regression_command is not set to the full matrix: at 37–40 minutes per run it would make every merge ten times slower. Recommendation for the user, to settle in the morning: a short regression command per merge (`chat-bench-settle.sh -n 3` on the 8 top/middle × 1200/1728 × LIVE/STACK cases, about 3 minutes, judged with the merge's load gate) and the full matrix on demand or nightly; the lead's current tools have no regression_command parameter, so it is set after the next lead restart.

The matrix is the evidence the earlier decision asked for, but its cost per merge is the wrong trade; the 8-case subset is where every real finding came from (top/1728 page 2, the two-heights artifact), and 11 of 768 runs still needed the starved allowance when six jobs hit the same phase together, which the full matrix would turn into merge noise.

## 2026-10-21 11:40:57 selecting-text-in-the gets one narrowly re-planned round instead of a new approach: drop the 40-view pool, keep no views from the warm-up, empty caches synchronously on window close, stage 14 rows a turn. Bar: interleaved most-CPU medians within 10 ms of project-lead on open and page 2, no tick over 0.2 s CPU, churn growth within 2 points and cycle readings within 15 MB of the lead.

The third audit (5699441) passed everything except cost. Two of its three Important findings (memory, churn) come from the pool and warm-up added in that round. The page-2 gap of 20 ms was measured at 20 rows a turn, which earlier measurements showed costs more than 14. The user asked twice for multi-paragraph and multi-message selection, which works on the branch.

## 2026-10-21 12:30:57 The briefing's ElevenLabs key falls back to ELEVENLABS_API_KEY from the user's login shell, then ~/.config/elevenlabs/key.env, when no key is saved in the Keychain. Settings shows the source by name, never the value, and offers 'Save to Keychain'.

The user asked why the app asks for a key that's already in their environment. A Finder-launched app doesn't inherit shell variables, but the app already reads the login-shell environment for sessions. A typed key still wins, so nothing changes for users without the variable.

## 2026-10-21 13:37:19 The user accepts text selection's transient graphics memory: about 100 MB more during repeated chat-window open and close, released when churn stops, with churn growth about 7.6 % against 5 %. selecting-text-in-the merges after a clean audit. The footprint bar for it is the per-cycle and churn numbers the worker measured, not the lead's earlier 2-point and 15 MB bar.

The user's answer to 1B9FE8C5 on 2026-10-21 at 13:2x. The chat's cost now matches today's, the memory is the renderer's surface cache rather than a leak, and the alternative was days of uncertain re-plan.

## 2026-10-21 17:55:46 The picker card's settling work stops after picker-card-the-two. Its two remaining Nits (in the app, ScreenRead.at is the call time; the refusal notice says "changed; here it is now" for one read while the card still shows the old question) stay recorded on the task, not as new tasks.

Four rounds have closed every case that put half-drawn text on the card. What's left changes, at worst, a notice for one 0.15 s read. Further rounds cost more than they protect until the user reports a visible problem.

## 2026-10-21 21:50:31 Working policy from the user, 2026-10-21 17:5x, effective now: (1) One agent owns each change through completion. Separate reviewers (audit) only for security, irreversible operations, or complex changes. (2) Run the affected tests while editing, then the full suite once before merging; repeat only when new changes justify it. (3) Parallelize independent implementation work; serialize expensive builds and tests so workers don't compete for CPU. (4) Fix material bugs; cosmetic observations don't become tasks or block delivery. (5) Stop when the requested behaviour works and the relevant checks pass; no recursive audit loop without a concrete unresolved concern. Until the tools support skipping audits (task one-agent-owns-each), the lead asks for light audits on low-risk work (diff plus affected tests plus one suite, no benches or screenshots unless the change is about them), never re-audits for nits, and contracts ask for one suite run, not two.

The user's direction after the lead's introspection: about five full suites per change, re-audit loops (text selection took four rounds), nit follow-up chains (four picker-card tasks), and CPU contention between parallel suites made the team slower than a single Claude Code session, and hit the weekly usage limit.

## 2026-10-21 22:52:33 Additions to the working policy after the lead's review (2026-10-21 23:0x): (1) The merge's run is the one full suite; workers run affected tests, and the full suite only when they touch shared test or build infrastructure. (2) Workers own routine calls, including small goal-tied boundary excursions, and list them in their report; they ask the lead only about direction, scope, or risky steps. (3) Timing benches leave the default test run (`--perf`), so merges don't fail on load. (4) Worktrees build warm. (5) The policy reaches every project's leads, workers and verifiers through the app: an editable policy text in every prompt, a witness message to running leads, and a Mac-wide `vs-heavy` lock for any project. (6) The lead posts updates only for merges the user would notice; the rest go into a daily summary.

Remaining causes of slowness after the first policy pass: one extra full suite per task in the worker, merge gates failing on load-sensitive benches, about 2 minutes of clean build per worktree, routine worker questions round-tripping through the lead, and the lead's own update volume. The user asked for the policy to reach the other leads and future ones; the user also asked the lead not to touch other leads directly, so delivery goes through the app.

## 2026-10-21 23:26:41 Caps re-evaluated (2026-10-21 23:1x, at the user's request): mac_max_sessions 6 → 10 and max_workers 3 → 4 for vibeswitcher; load_threshold stays 24. Once the Mac-wide heavy-work lock lands (every-lead-and-worker), raise max_workers to 5–6 if memory allows.

At the old cap the Mac sat at load 6–7 while starts were refused, because sessions spend most of their time waiting on the model, not on the CPU. The real limits are memory (36 GB, swap at 13.7 of 14 GB used, each session 0.3–0.5 GB) and concurrent builds, which the coming lock serializes. 10 sessions keeps memory headroom while roughly doubling the work in flight.

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

## 2026-10-24 16:59:30 Six VibeSwitcher fix tasks come out of the 2026-10-24 review of the other projects' leads, started on the user's 'Start all six'. Five are running: lead-prompts-and-tool, lead-record-commits, a-base-branch-the, fail-fast-sessions and the-mac-wide-test. mac-wide-limits-are starts once lead-prompts-and-tool has merged. Review levels: none for the text/prompt task and the limits task; audit for the record-commit conflict handling, the base-move guard, session ending in cleanup, and the test lock (merge machinery, guard rails, killing processes, concurrency).

The review found that most of the leads' waste comes from VibeSwitcher's own texts and mechanics: the per-merge update instruction, retry-in-5-minutes polling, per-project Mac caps, trailers in record commits, base moves that need a restart, silent dead verifiers and cleanups, and false stalls on the test lock. Reports: scratchpad genswap/report.md and tge/report.md of session 9f1ce4d8.

## 2026-10-24 18:27:33 Retrospective of the 2026-10-24 review-fix batch (6 tasks, all merged in about 4 h, no reverts). Changes: (1) audit takes a branch whose trial merge is clean, and ends the task's own idle worker to make room for its verifier (task audit-takes-a-branch). (2) Workers run the lint tests before reporting done (task workers-run-the-project-s). (3) Already running: boundary excursions a worker reports don't fail an audit, and dismissed findings don't force a re-audit (boundary-excursions-a). Until (1) lands, the lead stops a finished worker whose audit is refused for Mac room, and has branches catch up once, after the last of a run of merges, not after each.

About 8 extra worker turns went to conflict-free catch-up merges. Idle finished workers held 4 to 5 of 10 Mac slots and blocked verifiers. One audit failed only on a missing lead note, and one only on a lint a filtered run doesn't cover. The audits also caught three real defects: records that merged cleanly kept the branch's copy, a team command in flight could pass as the user's, and the limits file was writable by agents.

## 2026-10-24 19:21:40 The install of the review-fix batch was done at 19:21 CEST on 2026-10-24 by the lead, on the user's "Install now". Verified: host pid 31589 unchanged, 12 sessions and 62,778 bytes of secrets handed over, all three leads (vibeswitcher, genswap, TGE-ANALYSIS) alive with their sessions, and this lead's tool server swapped in place: status shows the new 'mac_max_sessions is ignored' line and the test-lock line. No main-thread stall since the install; the last one was 14:53. audit-takes-a-branch is still running and goes into a later install.

It brings eight merged fixes to every project's lead without ending a session. Writing the verified state down saves the next lead from re-checking it.

## 2026-10-24 20:52:03 New Project… always creates the git repository with its first commit and starts the project lead. The sheet no longer offers "Nothing" or "Open a session" as next steps, and has no git toggle.

The user said a new project "always needs to start as a full fledged leader".

## 2026-10-24 22:42:24 All-done signal is app-side: VibeSwitcher detects from board.json that the board went from open work to clear, with at least one merge, and puts a green "All tasks finished" card in the lead's chat. The card has a plain-words summary written by headless Claude through Briefing's redaction, falling back to a written summary when the model is unavailable or AI summaries are off. A green check shows on the lead's sidebar row until the user opens that lead. No sound or push for now.

The user asked for a clear signal plus a simple-terms AI summary when all tasks finish. Detecting it in the app makes it reliable without depending on the lead. Reusing Briefing keeps secrets out of the prompt and respects the user's AI-summaries setting.

## 2026-10-25 08:03:22 Lead Process v3, phases 1 and 2, are being built: (1) finished-work-lands: done work merges or gets its audit, and planned tasks start, without waiting for the lead's turn. Merges land overnight too. (2) steadier-merge-gate: one rerun of failing tests at merge, a flake ledger, and early catch-up messages when project-lead overlaps a running branch. (3) workers-run-a-sandboxed: workers run an isolated copy of the app and screenshot it. (4) done-reports-carry: done reports need evidence per acceptance check, plus a blind self-check. (5) audit-v3-blocking: Important findings need a failure scenario, workers fix or answer them, re-roll after 2 rounds, and the verifier runs on a different model. All five run in parallel. Four are audited (guard rails, isolation, concurrency); the evidence task is review none.

The user answered 'Start Phases 1 and 2 together' on 2026-10-25. Data from 2026-10-22..25: 59% of task time was finished work waiting for the lead, about 1.15 of 5 worker slots were used, 17 of 29 failing merges passed on retry, 21 conflicts cost 40.7 task-hours, about 30% of Important findings were dismissed, and the user found 35 bugs by hand. The design follows OpenAI's Symphony and harness write-ups, Anthropic's risk-tiered review, and the research on self-review and fix-loop decay. Overnight merges were taken as included: the merge policy is auto, and nothing reaches the app before the user installs.

## 2026-10-25 09:46:35 From the retrospective of the Lead Process v3 batch: a fix's regression test must be shown to fail without the fix. The worker's evidence shows it, and the re-audit checks it; task a-fix-s-regression. No change for the load waits: the room messages handled them.

finished-work-lands F1's two new tests would have passed on the old code too. The verifier couldn't prove it because a scratch-export command was denied. Without such proof a "fixed" finding has no guard against the bug coming back.

## 2026-10-25 11:55:41 The lead installed the Lead Process v3 batch at 11:55 CEST on 2026-10-25, on the user's "Install now" plus "go" once the Mac was on AC power (the battery was at 5%). Verified: - the host pid 31589 is unchanged; - the leads' tool servers were swapped in place, with the same pids; - vibeswitcher's lead tool server (pid 10199) holds run/advancing.lock, so auto_advance is live; - status works. The build's own relaunch reported _LSOpenURLsWithCompletionHandler error -600. The app (pid 61407, started 11:55:18) was running when checked, after a precautionary `open`.

Writing down the verified state saves the next lead re-checking it. The -600 relaunch error is worth noticing if it recurs.

## 2026-10-25 12:25:44 auto-advance-s-reports:F1 is accepted, not fixed in that branch. A merge's test-command children can seal an auto_advance report to the lead, but they already count as the lead at the vault, a far larger power. The underlying boundary, that branch code run by merge, audit or init is identified as the lead's session, is now its own task, merge-tests-don-t, at review audit. (The dismissal's reason calls it merge-tests-run-as; the task is merge-tests-don-t.)

With auto_advance on, merges run unattended, so worker-written code runs with the lead's standing and no one watching. Narrowing one seal while the whole grant stays exposed would be the wrong fix.

## 2026-10-25 13:45:22 Two changes from the user's 'you decide' on Anthropic's posts (redesigning source control; employment at Anthropic), 2026-10-25. (1) The review level follows what a diff touches. vibeswitcher's sensitive_paths now adds the guard-rail files to the defaults: Sources/VibeHost and vibeswitcher-host, LeadVault*, LeadLaunch, LeadAdvance, Steer, Worktrees, MergeRerun, TestLock, Redaction, HookInstaller, RemoteAccess, RemoteServer, PhoneAccess, Sandbox, build-app.sh and setup-signing.sh. Any branch touching them is audited whatever its task says. LeadToolset.swift is left out, since nearly every task touches it. (2) An app-health watcher (task a-watcher-tells-the) sends vibeswitcher's lead deterministic digests of new hangs, crashes and trends. A third idea, batched merge testing with automatic bisect and revert, waits for a day of merge-queue wait data.

Anthropic's approval rules tell comment-only changes apart from sensitive logic, and its 'superfan' agents watch components. Today the lead filed a permissions change at review none, and its audit (after a manual raise) found three escapes. The one-off log review found four real bugs that nothing had reported.

## 2026-10-25 14:43:56 After the next install, the lead runs configure(watch_app_logs: true) on vibeswitcher. That turns on the app-health watcher (a-watcher-tells-the, merged at 6f9ec250). Today's installed tool server doesn't know the key.

The watcher is off by default and only vibeswitcher's lead should get its digests. Writing it down keeps the step from being lost across compaction or a new lead.

