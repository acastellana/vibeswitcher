# Decisions

Archived decisions: 112 entries (superseded, obsolete or now enforced by a check) are in decisions-archive.md, moved there unchanged (last on 2026-11-02).

## 2026-10-17 17:45 The lead's decisions.md and progress.md move into the repository (docs/lead/ by default) and are committed to the base branch automatically by the tool server, touching only those files. board.json, workflow.md and run/ stay local and git-ignored.

User's call. The project's reasoning should survive a lost .vibeswitcher folder, another machine or a new lead, and be visible to teammates. The board holds transient state (sessions, PIDs, questions) and stays local.

## 2026-10-17 21:27 The pipeline-lane design is replaced by a calm one-line-per-task Team view with AI plain-language summaries (headless `claude -p`, small model, cached and throttled, can be switched off) and a fading feed of the lead's decisions. Questions get proposals with a 10-minute default timer, where silence means the lead goes ahead. Risky or blocking questions never get a timer.

The user found the lanes noisy and space-hungry and wants a glanceable high-level view in which past things fade out. The timer keeps work moving without the user having to answer, and the risky-question exclusion keeps irreversible calls with the user.

## 2026-10-18 17:55:49 Accepted the crash-isolation cost: one parser process per session, adding about 3.5 MB of footprint per session (about 130 MB at 37 sessions) and no idle CPU. The parser keeps the 5,000-line scrollback.

Measured on release builds, the host plus parsers use 42 MB of footprint at 10 idle sessions, against 9 MB before. In exchange, one session's parser trap or stall no longer takes down every session. The phone's transcript view asks for 5,000 lines, and the raw replay can't stand in for the scrollback, so it isn't cut to 1,000.

## 2026-10-18 18:50:08 Merge policy for vibeswitcher, set by the user: the lead merges audited work by itself, including guard-rail, security and hook-installer changes, and doesn't ask per merge. It then posts an update saying what changed, how it was checked, the risk and how to revert. This replaces the 2026-10-17 17:23 hand-applied risk tiers. The user is asked only about direction, taste, and anything irreversible or outward-facing (pushing, publishing, deleting work). The lead also checks in with the user proactively and runs a short retrospective now and then.

The user said asking them about every merge is annoying and mostly pointless. Merge behaviour is something the lead should agree with the project owner once, and then the lead should be proactive: ask how they want things done, check how things are going, and run retrospectives.

## 2026-10-19 08:06:04 From the user (2026-10-19 08:05, answering the leaked-sessions question): operational hygiene is the lead's to decide, carefully and holistically, not the user's: leaked or stale sessions, stale lock files, load and memory on the Mac, scratch leftovers. The lead acts (from its own shell when the tools can't, with each target re-verified first) and reports what it did; it asks the user only for direction, taste, and anything irreversible or outward-facing. The seven leaked sessions are ended by the lead now with SIGHUP, each pid checked against its task's session command line before the signal.

The user's words: "This is the type of thing that you should be able to decide yourself in a careful manner and thinking holistically." The question sat seven hours for an action that was safe to take: idle sessions of merged tasks, confirmed by ps, that no tool could end.

## 2026-10-19 18:35:39 Lead policy from 2026-10-19 22:1x: when the lead accepts an edit outside a task's listed files (by message to the worker or on its own judgement), it appends that acceptance to the task's context (update_task) before calling audit, so the verifier can see it. Reason: two same-commit re-audits today (a-new-project-button, the-phone-gets-the) were caused by approvals the verifier couldn't see. The task the-verifier-sees-the makes the verifier's prompt carry the lead's notes and messages, after which the policy still holds as a habit.

A verifier judges from the contract and the board; an approval that lives only in a message to the worker doesn't count for it, and a repeated full audit costs 20–30 minutes of a loaded Mac each time.

## 2026-10-20 16:56:08 No GitHub push-protection bypass, ever: fixtures that must look like real secrets are assembled at run time from pieces, docs elide the prefixes, and a repo-wide lint keeps complete shapes out of every file; no .github/secret_scanning.yml. The three commits of the failed attempt (2554086, 9a2c0b9, fff5c70) are dropped from project-lead by a reset to 9dca1f7 (which GitHub already has), run by the user.

2026-10-20 17:0x: the user refused a second 'allow me to expose this secret' click ('This is unacceptable'); GitHub matches shapes regardless of EXAMPLE markers, and the ignore config can't land on main through a push it blocks.

## 2026-10-21 12:30:57 The briefing's ElevenLabs key falls back to ELEVENLABS_API_KEY from the user's login shell, then ~/.config/elevenlabs/key.env, when no key is saved in the Keychain. Settings shows the source by name, never the value, and offers 'Save to Keychain'.

The user asked why the app asks for a key that's already in their environment. A Finder-launched app doesn't inherit shell variables, but the app already reads the login-shell environment for sessions. A typed key still wins, so nothing changes for users without the variable.

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


## 2026-10-31 00:40:21 2026-10-31: after the user pulls outside work into main (e.g. from GitHub), the lead has the full suite run on main (a small review-none task, or the next merge's gate watched closely) before stacking tasks behind it. Failures on main get their own fix task first.

On 2026-10-30, a ~130-commit pull left main failing 2 tests on this Mac (Spanish locale, Swift 6.4 per-target bundles). It surfaced only at the first merge and held 3 tasks back.

## 2026-10-31 14:54:51 Vault requests: VibeSwitcher only initiates transactions. It writes a strict, secret-free request (vault-request v1, specified in docs/protocol/vault-request.md), sends it through the `passage` CLI to the paired vault Mac, and shows the vault's result and delivers it back to the session that asked. A wallet app on the vault Mac checks each request and proposes it, and the user signs there with a hardware wallet. VibeSwitcher never signs, holds keys or judges whether a transaction is correct. Two tasks carry it: vault-requests-the, then vault-requests-in-the. Both are audited (security).

User's direction, 2026-10-31: the keys stay on one isolated Mac behind a hardware wallet, and agents can only ask. The repo names Passage because the code calls its CLI. The wallet app and wallet profiles stay generic in the repo, under the 2026-10-28 naming rule.

## 2026-10-31 15:15:54 The wallet app's baseline is developed on this Mac as its own project (code and made-up data only), and the vault Mac pulls it from a private repository and runs it. The app holds no keys or data: it reads a versioned per-workspace folder structure on the encrypted volume, with hardware, hot and Safe wallets in every workspace. Hot-wallet keys are the only keys stored, encrypted in the volume. Transactions cross between the Macs only through Passage. VibeSwitcher on the vault Mac is for availability and never carries requests, keys or approvals. VibeSwitcher's request format (docs/protocol/vault-request.md and its vectors) is the contract both projects test against.

User's direction, 2026-10-31: keep the vault domain as safe as possible but VibeSwitcher always available. Keeping one narrow channel and a single shared format lets us verify the integration here without real keys ever being on this Mac.

## 2026-10-31 17:16:40 The payment-request feature is renamed to "wallet requests". The new names are WalletRequest… code, the `vs-wallet` CLI, Settings › Wallet, the "Send to Wallet Manager" button, and a wire format of vibeswitcher.wallet-request/-result in docs/protocol/wallet-request.md, still version 1. In VibeSwitcher, "vault" means only the lead's vault (LeadVault/VaultStorage). Stored state is carried over once. The Wallet Manager's lead was told and updates its side when the rename merges (task rename-the-vault-request, after agents-know-they-can).

User's call, 2026-10-31. Two unrelated things were both called "vault" in VibeSwitcher, the lead's team and key store and the payment requests, which invites mix-ups for the user and for agents. It's renamed now, while the format is new and nothing real uses it yet.

## 2026-10-31 18:19:28 Wallet requests are tested end to end on this Mac first: VibeSwitcher's sandbox, a loop `passage` stand-in and a locally run Wallet Manager on a synthetic vault (task local-end-to-end). The real two-Mac trial over Passage, with the older MacBook already paired as the vault Mac, and moving the Wallet Manager there through a private GitHub repository come at the end, once everything is tested, at the user's go.

User, 2026-10-31: the vault Mac isn't at hand, so test everything locally; the GitHub transfer is later, at the end. Passage can't pair a Mac with itself, and the rules forbid touching real pairings, so the loop stands in for the transport.

## 2026-10-31 23:30:46 From the 2026-10-31 wallet batch retrospective. (1) Before building a feature that integrates with another app or a second Mac, the lead first checks the real environment on this Mac: the other app's CLI on the PATH or in /Applications and how it's invoked, the names VibeSwitcher already uses, and what happens with nothing set up. The plan covers each case (task contexts name it). Today three follow-up tasks came from skipping that: the vault/wallet name clash, Passage.app not on the PATH, and no fallback without a Wallet Manager. (2) Verifiers stop running a full suite of their own, and the merge's run is the one full suite (task verifiers-don-t-run-a, with verifier-eval). (3) Cross-project work runs through the other project's lead by cross-session message, with the shared contract (docs/protocol and vectors) and an on-demand end-to-end script both sides can run.

The batch landed (13 tasks, no reverts, 2 incidents turned into checks). But three tasks were rework from environment facts that one look would have shown, and doubled full-suite runs added to a load the user complained about.

## 2026-11-01 01:12:23 The user approved real GenLayer testnet transactions for the end-to-end harness (2026-11-01, F9C2A658): one proving run now, and on demand later, only with an explicit --real-testnet. Each run is a self-transfer of at most 1000 wei from the Wallet Manager project's throwaway testnet wallet (0x4c50…ab99), never mainnet or any other wallet, never in normal tests, merges or audits.

Production readiness: the Wallet Manager's lead and an independent review both asked for one real payment through the whole chain before more features. It broadcasts publicly, which is why it was the user's call.

## 2026-11-01 01:15:26 Wallet production-readiness pass (2026-11-01, user: "make sure this is production ready"). VibeSwitcher's wallet path gets four audited hardening tasks, run in this order because they share files: wallet-card-truth-the, wallet-card-can-t, wallet-outcomes-always, wallet-path-robustness. Alongside: spec-an-unparseable, strict-paths-an, the-app-s-host and wallet-e2e-real-testnet (one real testnet payment, user-approved). The Wallet Manager's lead is fixing its review's five concerns (approvals, audit holds, logs, the real path, local writers). Done means: all of it merged, the real-testnet run passing, and then the two-Mac run when the older MacBook is back.

Independent read-only reviews of both projects found no way to sign or send without the user, but several states that could mislead the user into paying again, a token-approval drain risk on the browser path and the Wallet Manager's signing page, and missing production logs.

## 2026-11-01 07:55:22 Audits run on Opus (configure verifier_model: opus) from 2026-11-01 06:4x until the Fable limit resets on 2026-11-05 at 12:00. The lead then switches back with configure(verifier_model: "") (the default: Fable while workers run Opus).

User's answer to 19AF8BCD. The account hit its Fable usage limit, and the wallet production-readiness pass's audited tasks would otherwise wait three days. The verifier-eval baseline was measured with Fable, so Opus verdicts in this window get the same scrutiny, and nothing about the audit rules changes.

## 2026-11-01 08:20:57 Reading freeze reports: "N% of its sample inside the stall" is how much of the sample was taken during the stall, not the share of time in the frames listed. Before planning a freeze task, count the main thread's samples in the .txt that pass through the suspected code (the 2026-10-31 00:48 rule), and plan only if they're a real share.

2026-11-01: the lead planned terminal-drawing-froze from a report saying '100% of its sample inside the stall' under SwiftTerm.buildAttributedString. 0 of 2092 main-thread samples were actually in terminal drawing. The worker checked before building and the task was abandoned, but it cost a worker start. Third-party code (SwiftTerm, a pinned dependency) was also assumed to be vendored.

## 2026-11-01 08:50:10 The boost release (2026-11-01), approved by the user in full, ships as 7 tasks in waves. Wave 1, in parallel: the load recorder, heavy jobs outside vs-heavy reported to their lead, and the usage-limit watch. Wave 2: release idle workers during audits, then batched merges (merge_batching off|boost|always, default off). Wave 3: Boost mode (Off/On/Automatic), with load_threshold 36, mac_max_sessions 18, max_workers 7 and heavy_slots 3; Automatic only when away AND on AC power, never on battery; fairness to the most recently active project, and a usage-watch veto. Then a release check tuned on the recorder's data. Always-on regardless of boost: the recorder, the heavy-job reports, releasing idle workers and the usage watch.

The user wants more throughput when away. A 4-day load study found freezes and suite time bend at 24, throughput peaks around 36–48 and falls past 48, the worst spikes come from heavy jobs outside the lock, and two account limits stopped work on 2026-10-31/11-01. The user chose AC-only for automatic boost.

## 2026-11-01 08:54:47 From 2026-11-01, every feature or process change the lead plans gets an entry in docs/process/impact.md, written when it's planned: hypothesis, metric, baseline, check date and window. Each retrospective reviews the entries that are due with scripts/impact-metrics.sh, records the result and a verdict (keep/tune/revert/inconclusive) with the why, and each verdict becomes a task or a recorded decision. It starts manual; a lead tool replaces it only once the routine has proved useful.

The user wants to track which features help and why, to self-improve recursively. Today's changes (one suite per task, strict paths, the boost release) were all made on reasoned guesses; the ledger turns them into checked results.

## 2026-11-01 18:08:55 Correction to "heavy slots go from 3 to 2": there was no Settings value for heavy slots. The count came from VIBESWITCHER_HEAVY_SLOTS or cores ÷ 4 (3 here). boost-release-6-7 adds it to Settings › Project lead and mac-limits.json, default cores ÷ 6 (2 here), with the lead's lock and vs-heavy reading one count.

The lead asked the user to change a setting that didn't exist, so the load stayed at three heavy jobs. The worker found this while fixing F6. Lesson: verify a setting exists before asking the user to change it.

## 2026-11-02 08:18:57 Usage-aware routing (2026-11-02): when Claude's quota runs ahead of pace, implementation work moves to Codex. Task usage-aware-worker adds agent: auto (Codex when Claude is tight and Codex has room), reads Codex's quota from its rollouts, shows both accounts' pace in status, and lets auto tasks go to Codex instead of waiting at Claude's 80% hold. Until it lands, the lead marks bounded implementation tasks agent: codex by hand whenever Claude's weekly usage is ahead of the week's elapsed share. Leads, planning and audits stay on Claude, and design-heavy or security tasks stay pinned to claude. Once it lands, the lead sets agent_default: auto for this project.

The user, 2026-11-02: "if there's not a lot of quota I should be leveraging Codex much more". Codex workers have worked since 8f44a65, but nothing chose them: the usage watch only stopped work at 80%. A Codex worker spends roughly a tenth of a task's Claude cost (the audit), going by boost-release-3b-codex's receipt: verifier $1.86 against worker $14.79.

## 2026-11-02 08:45:52 Boost can run on battery when the user turns on a new Settings option, "Also on battery" (off by default; task boost-on-battery-a). With it on, On and Automatic behave as on AC down to 30% charge, and boost stays off below that or when the charge is unknown. This supersedes "never on battery, whatever the mode" from the 2026-11-01 boost release decision for users who opt in.

The user asked for it on 2026-11-02. The 30% floor is the lead's choice, so an unattended boosted Mac doesn't drain its battery flat. The usage veto and the battery pause hold still apply.

## 2026-11-02 12:57:30 agent_default is auto from now on: codex-workers-can-run merged at 24716a2, so Codex workers can run the focused tests and lints.

Decision 3 (2026-11-02) held auto back until Codex workers could run the checks. The audit and the full suite now show they can, except for socket tests and the full suite, which the merge's run covers.

