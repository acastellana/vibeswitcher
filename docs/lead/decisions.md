# Decisions

Archived decisions: 128 entries (superseded, obsolete or now enforced by a check) are in decisions-archive.md, moved there unchanged (last on 2026-11-08).

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

## 2026-11-01 08:20:57 Reading freeze reports: "N% of its sample inside the stall" is how much of the sample was taken during the stall, not the share of time in the frames listed. Before planning a freeze task, count the main thread's samples in the .txt that pass through the suspected code (the 2026-10-31 00:48 rule), and plan only if they're a real share.

2026-11-01: the lead planned terminal-drawing-froze from a report saying '100% of its sample inside the stall' under SwiftTerm.buildAttributedString. 0 of 2092 main-thread samples were actually in terminal drawing. The worker checked before building and the task was abandoned, but it cost a worker start. Third-party code (SwiftTerm, a pinned dependency) was also assumed to be vendored.

## 2026-11-01 08:50:10 The boost release (2026-11-01), approved by the user in full, ships as 7 tasks in waves. Wave 1, in parallel: the load recorder, heavy jobs outside vs-heavy reported to their lead, and the usage-limit watch. Wave 2: release idle workers during audits, then batched merges (merge_batching off|boost|always, default off). Wave 3: Boost mode (Off/On/Automatic), with load_threshold 36, mac_max_sessions 18, max_workers 7 and heavy_slots 3; Automatic only when away AND on AC power, never on battery; fairness to the most recently active project, and a usage-watch veto. Then a release check tuned on the recorder's data. Always-on regardless of boost: the recorder, the heavy-job reports, releasing idle workers and the usage watch.

The user wants more throughput when away. A 4-day load study found freezes and suite time bend at 24, throughput peaks around 36–48 and falls past 48, the worst spikes come from heavy jobs outside the lock, and two account limits stopped work on 2026-10-31/11-01. The user chose AC-only for automatic boost.

## 2026-11-01 08:54:47 From 2026-11-01, every feature or process change the lead plans gets an entry in docs/process/impact.md, written when it's planned: hypothesis, metric, baseline, check date and window. Each retrospective reviews the entries that are due with scripts/impact-metrics.sh, records the result and a verdict (keep/tune/revert/inconclusive) with the why, and each verdict becomes a task or a recorded decision. It starts manual; a lead tool replaces it only once the routine has proved useful.

The user wants to track which features help and why, to self-improve recursively. Today's changes (one suite per task, strict paths, the boost release) were all made on reasoned guesses; the ledger turns them into checked results.

## 2026-11-02 08:18:57 Usage-aware routing (2026-11-02): when Claude's quota runs ahead of pace, implementation work moves to Codex. Task usage-aware-worker adds agent: auto (Codex when Claude is tight and Codex has room), reads Codex's quota from its rollouts, shows both accounts' pace in status, and lets auto tasks go to Codex instead of waiting at Claude's 80% hold. Until it lands, the lead marks bounded implementation tasks agent: codex by hand whenever Claude's weekly usage is ahead of the week's elapsed share. Leads, planning and audits stay on Claude, and design-heavy or security tasks stay pinned to claude. Once it lands, the lead sets agent_default: auto for this project.

The user, 2026-11-02: "if there's not a lot of quota I should be leveraging Codex much more". Codex workers have worked since 8f44a65, but nothing chose them: the usage watch only stopped work at 80%. A Codex worker spends roughly a tenth of a task's Claude cost (the audit), going by boost-release-3b-codex's receipt: verifier $1.86 against worker $14.79.

## 2026-11-02 08:45:52 Boost can run on battery when the user turns on a new Settings option, "Also on battery" (off by default; task boost-on-battery-a). With it on, On and Automatic behave as on AC down to 30% charge, and boost stays off below that or when the charge is unknown. This supersedes "never on battery, whatever the mode" from the 2026-11-01 boost release decision for users who opt in.

The user asked for it on 2026-11-02. The 30% floor is the lead's choice, so an unattended boosted Mac doesn't drain its battery flat. The usage veto and the battery pause hold still apply.

## 2026-11-02 12:57:30 agent_default is auto from now on: codex-workers-can-run merged at 24716a2, so Codex workers can run the focused tests and lints.

Decision 3 (2026-11-02) held auto back until Codex workers could run the checks. The audit and the full suite now show they can, except for socket tests and the full suite, which the merge's run covers.

## 2026-11-02 10:26:32 Xcode's Metal Toolchain is a build prerequisite for VibeSwitcher on this Mac (SwiftTerm 1.19.0 compiles Shaders.metal in every configuration). Installed by the user on 2026-11-02. If a build fails with "missing Metal Toolchain", the user runs `xcodebuild -downloadComponent MetalToolchain`. Don't patch around it.

Xcode 27.2 stopped bundling it. Every build, install and test run failed until the 840 MB component was downloaded. The user chose the download over changing the dependency.

## 2026-11-02 22:59:59 Statistics grows from activity counts to "how well is it working", in three parts. (1) statistics-3-quality, from data already kept: first-audit pass rate, rounds, what happened to findings, merge first-try rate, escapes, autonomy (questions, user minutes, share of tasks that needed nobody), where time goes, cost split into implementation, verification and reruns. Each broken down by Claude vs Codex and by model, with an 8-week trend. (2) statistics-record-what records what's missing: lead tokens, Codex tokens, boost hours, waits by cause. (3) The comparison with working solo in Claude Code or Codex: a measured replay of past tasks if the user approves the spend (question AA210BD8), else an estimate labelled as one.

The user (2026-11-02, about 21:30) asked for more information and for how well this setup does compared with working directly in Claude Code or Codex. Only a measured replay answers the counterfactual honestly. Everything else comes from the receipts and the board.

## 2026-11-02 23:00:53 No replays to compare VibeSwitcher with working solo (the user's answer to AA210BD8, 2026-11-02). Statistics 4 shows an estimate, labelled as one: process cost beyond the implementing worker, what reviews and reruns caught before merge next to what escaped after, parallel hours of work per hour, and hands-off work per minute of the user's time.

The user chose estimate only over a $60–100 pilot.

## 2026-11-05 14:37:03 Wallet-request v1 gains a reason marker, at the Wallet Manager lead's request (2026-11-05): a request whose `reason` has the exact first line `LOCAL FORK ONLY` is refused by the Wallet Manager unless it runs against a loopback RPC for that network. VibeSwitcher's part (task wallet-requests-marked, audited): the spec gets a dated note, still version 1 with no format or vector change, and a marked request is never offered Sign in browser wallet, whatever its `from`. VibeSwitcher reads no other meaning into `reason`.

Another project runs a local-fork rehearsal that files real-looking requests; the marker keeps them off real networks. The browser wallet signs without the Wallet Manager's checks, so a marked request from an 0x address would bypass that guard. Accepted without a new field because the marker can only refuse, so the rule that a reason is never followed as an instruction holds in effect, and the spec's sentence is amended to say so.

## 2026-11-05 22:32:42 Wallet requests get a same-Mac transport (the user's answer to 67D93641, 2026-11-05): when the Wallet Manager runs on the same Mac as VibeSwitcher, requests and results travel through an owner-only folder pair instead of Passage, chosen in Settings › Wallet as "Wallet Manager on this Mac". The format, the card, the user's Send and every Wallet Manager check stay as they are. Task wallet-requests-reach, audited. This supersedes, for a Wallet Manager on this Mac, the 2026-10-31 15:15 rule that transactions cross only through Passage; the two-Mac Passage link stays as it is. Which networks the Wallet Manager accepts over the local transport is the Wallet Manager's gate, which its lead is confirming with the user.

Another project's local-fork rehearsal files its requests on the Mac where the Wallet Manager runs, and VibeSwitcher had no way to deliver them there: Passage has no peer that is the Mac itself. The user chose building the path over moving the sessions to the other Mac or rehearsing with made-up data. A folder pair adds no listening endpoint, and gives a same-user process nothing it couldn't already do with the Passage command line or Passage's inbox folder.

## 2026-11-06 10:07:50 Agents can ask for a New Shell session running a command (`vs-shell run`, task an-agent-can-open, audited). It starts on the user's one click on a card that shows the exact command and folder; a Settings option, off by default, lets it start without the click. The command is passed to the shell at launch, never typed as keystrokes.

The user asked on 2026-11-06 why they had to open New Shell and paste a command another project's lead gave them, "or do it yourself". Agents' own shells have no terminal, so interactive long-running programs (local-fork runs that file wallet requests) need a hosted shell session. The click is the default because the command runs as the user in a session with a real terminal; the no-click option is the user's to turn on.

## 2026-11-07 12:49:02 Settings › Project lead gets "Ignore usage limits", off by default and Mac-wide in mac-limits.json (task a-settings-option-to, audited, started with override_usage). When it's on: no 80% hold on starts, audits or auto_advance; no Boost usage veto; agent: auto stays on Claude unless Claude is refusing at a reached limit. Usage stays visible, marked "(limits ignored)". This supersedes, for users who turn it on, the 80% hold and the Codex routing in the 2026-11-02 08:18 decision.

The user asked for it on 2026-11-07 ("a setting to disable worrying about quota"). The lead judged that "worrying" covers all three ways usage changes behaviour, not only the 80% start hold. Load and battery holds stay as they are.
## 2026-11-04 22:18:21 Lead-to-lead messaging goes through a VibeSwitcher channel, tell_lead. - VibeSwitcher fills in the sender from the vault's role binding, never from server arguments. - Delivery is immediate. - Secret-shaped text is refused, and messages are capped in size and rate. - Each message is logged privately in .vibeswitcher/; the app shows them and the user can turn the channel off. - Raw Claude Code SendMessage and ListAgents are denied to every role VibeSwitcher starts. - Raw cross-session messages are unverified information, never approval. - docs/lead/ never holds message content or another project's name.

The user wants lead-to-lead messaging kept and made truly safe, and chose immediate delivery with full visibility and an off switch (4D5835E0). Raw cross-session messages can be spoofed (any session can take a --name), workers can use them, the user can't see them, and nothing guards secrets. Repo records are pushed to GitHub, so message content stays out of them.

## 2026-11-04 22:42:35 The lead syncs with GitHub through fixed-shape VibeSwitcher tools, not raw git: - fetch_remote and merge_remote: a true merge, tested before main moves, with lead records merged by union. - push_remote: each push needs the user's one click in the app, which pushes exactly the approved sha as a fast-forward, never forced. LeadLaunch's deny rules on raw git fetch and push stay.

The user wants the lead to handle the GitHub sync and chose "ask me each time: one click in the app" for pushes (F6BE148C). Raw fetch and push can move main or reach any URL, so the shape is fixed in audited code. Pushing is outward-facing, so only the user's click in the app approves it.

## 2026-11-05 00:30:32 Security contracts list every path to the protected property (every writer of the data, every channel, every trust on first use), not only the new feature's own path, and each path gets an acceptance check.

Lead mail's first contract made tell_lead unforgeable but missed direct inbox seals under another name, honest-name seals into another team, and the remote URL's trust on first use. That cost 3 follow-up tasks and audits (retrospective, 2026-11-05).

## 2026-11-05 00:30:33 After record_incident, in the same turn, set auto_advance: false on the planned task, sharpen its contract, then set auto_advance back to true.

turn-this-incident-into-9 auto-started on the generic brief before the sharpened contract landed (2026-11-03). If it happens again despite this, make a product task so incident tasks wait for the lead's contract.

## 2026-11-06 22:35:21 Ideas from Anthropic, OpenAI and METR posts (2026-11-06) stay parked as triggered ideas, not tasks: (2) VibeSwitcher mechanically checks that a branch's new tests fail without its non-test changes and pass with them. Build it when a merged test turns out not to exercise its change, or a merge is reverted for a defect its tests should have caught. (3) A per-contract path-glob field, a PreToolUse reminder on edits outside it, and a deterministic diff-vs-globs check at done. Build it when a worker touches something out of scope that nobody catches. Also parked: - (1)/(6) measure verifier recall with planted bugs, and randomly audit 5–10% of review-none merges; - (4) rerun verifier-eval when verifier_model changes; - (7) mid-task mechanical checks about every 30 min; - (8) a chaos corpus for the orchestrator as regression_command; - an audit of how agent text is rendered in the chat.

The user agreed (2026-11-06). This week's evidence shows no failure these would have caught: workers always ran the reverse-apply check, a verifier reproduced it once, there were no reverts, and every out-of-boundary edit was declared and accepted. They cost usage and heavy slots while usage is ahead of pace and load spikes are the live problem. The policy is incident first, then the check.

## 2026-11-07 09:57:10 Past 80% of Claude's weekly limit, keep starting workers and audits (override_usage) until the limit itself, through the Nov 11 18:00 reset.

The user's answer to FFC4FEF0 (2026-11-07): "Keep everything going past 80%, up to the limit", and "lets continue with all".

## 2026-11-07 18:33:18 A code block's Run is one behaviour in every session kind that can take a command: Claude sessions, the lead's chat, Codex (via its own shell escape) and plain shells (typed without `!`). It uses the same detection, the same confirmation rule and the same can't-run message everywhere, through a single typing seam per session kind. It's audited, because it types into sessions.

On 2026-11-07 the user reported that Run is unreliable and sometimes missing, with no confirmation popup. Today it appears only in Claude window sessions and fails with a bare beep. Asked whether Run should reach other session kinds, the user answered "yes lets unify stuff. make sure tis clean".

## 2026-11-07 19:48:57 For a UI task whose worker will need sandbox probe commands, the lead says in the contract from the start that adding sandbox commands to Sources/VibeSwitcher/Sandbox.swift is accepted. Those commands only drive the sandbox's own windows and pasteboard, and run no commands and write no files. The note goes in before any audit, never after one has started.

The same setback happened twice on 2026-11-07. terminal-panes-text-can and chat-view-copying-text each came back "suspect" with 0 Important findings, only because a sensitive-path edit (Sandbox.swift probes) wasn't covered by a lead note. In the second case the lead's note arrived after auto_advance had already started the verifier. Each cost a second audit round.

## 2026-11-07 20:06:54 Two changes. (1) Reviews go back to Fable now: verifier_model is cleared, so audits run on another model than the workers'. This replaces the "back to Fable on Nov 11 18:00" timer. (2) The harness's own gate files are now sensitive paths, so any change to them is audited: LeadToolset, LeadWorkflow (the verifier prompt), LeadBoard (the flake ledger), LeadAuditVote, LeadWitness, ReadOnlyCommand, MCPServer, Sources/vibeswitcher-mcp/ and scripts/verifier-eval*. In two weeks (2026-11-21), the lead checks what share of tasks this sends to audit, and narrows the list if it's most of them. Moving the gate checks out of LeadToolset into a small file of their own is the structural fix.

(1) The user chose it on 2026-11-07 (2F4161CC), after logging into a new account where Fable runs. Since Nov 1, 32% of audits had been Opus reviewing Opus. (2) A red-team review on 2026-11-07 found that the file deciding what counts as sensitive (LeadToolset.swift) wasn't sensitive itself. A small, pattern-free review-none edit to it could merge unaudited. The literature backs the risk: Auditing Harness Tampering found tampering in 63–85% of iterations of self-improving systems, and VS's own data shows 4 of ~9 gaming cases aimed at its guard rails.

## 2026-11-07 20:08:53 Review rules get a user-owned floor, set in Settings › Project lead. It covers sensitive_paths, strict_paths, audit_finders, merge_policy, risk_lines, risk_model and the verifier-model relation (the verifier's model is never the workers' unless the user says otherwise). The lead's configure can raise protection above the floor (add paths, more finders, a stricter policy) but can't lower it. A lowering is refused with a Settings hint, and the user sets it in the app.

The user chose it on 2026-11-07 (F0181AFD). The 2026-11-07 harness review found governance capture: the lead proposes changes and also sets the evaluation policy that judges them, with only a progress line as record. The macKeys refusal pattern (LeadWorkflow.swift ~380) is the precedent.

## 2026-11-07 21:09:09 Nothing on the board stays blocked waiting on the user. When an idea gets a lukewarm answer ("meh"), the lead abandons it, or moves it into docs/process/backlog.md, rather than holding it as blocked. A task is blocked only on a concrete external condition (data, a reset, another task), and its reason names that condition.

On 2026-11-07 the app showed items waiting on the user. They were two chat tasks the lead had blocked after the user said "meh". The user: "It's saying that some things are waiting for me. You shouldn't wait for me, right?"

## 2026-11-08 00:08:13 First backlog batch, chosen by the user on 2026-11-08, after the lead reviewed each tier-A idea. In parallel: the log watcher (A3), freeze reduction plus a freeze metric (B3), and the product inventory plus a check-before-proposing rule in the lead's prompt (A5 + the cheap A4). In sequence, because they share the merge, board and receipt code: git provenance trailers (A2) → versioned contracts (A6) → the small scorecard (A1: exact data, no model classifier yet). A8 moves to tier B. The model-based question filter (full A4) and the message classifier wait until the scorecard shows they're needed.

The user's goal: exactly what they want, without issues, safely, cheaply, fast, with only necessary questions. The lead's review judged A1–A6 and A9 worth doing (A1 and A4 in cheaper forms) and A8 lukewarm. B3 was added because 75–94 freezes a day hit the user directly. The user answered "yes".

## 2026-11-08 05:42:44 swift-testing-s-parallel merges as built: under a heavy slot, Swift Testing's parallel width is capped to VS_HEAVY_CORES. Its cost gets measured on the merges that follow, not tuned in the task: the next 5 merge test runs' swift-test times against the earlier 290–400 s, and the app's freezes per hour (IM-18) against 3.43/h. If merge runs stay above about 1.5x (around 600 s) on a calm Mac, the width goes to 2× the slot's share.

On 2026-11-08 from 03:40 to 05:35, the load reached 100–225 on 12 cores whenever full suites overlapped, and the app froze dozens of times. Each suite ran 12 tests at once whatever its slot. The worker's two timings (1003–1093 s) came while the Mac was loaded at 57 to 225, so they can't separate the width's cost from the load.

## 2026-11-08 06:33:00 Plugin updates always need the user's Accept, like any other code change, whoever made them and whether or not team sessions ran. config-seal-covers merges as built, and plugin-updates-always (after it, audited) removes its silent sealing of updates. The plugin seal ships in an install only once both have merged.

Question CEDA0180, 2026-11-08: the user didn't answer in 15 min, so the lead's proposal applied. A plugin's hooks run as code in every Claude session, and a forged update (a new version folder in the cache with the install record repointed) can't be told apart on disk from Claude Code's own update. That matches the standing rule that code that runs always needs Accept.

## 2026-11-08 07:28:52 From the 2026-11-08 batch retrospective, two planning rules. (1) Tasks whose boundaries name the same source file never run side by side: the later one gets `after` on the earlier. (2) A task whose contract needs its worker to run a full suite (it changes scripts/test.sh or the test harness) gets budget_min 120, not 60. Full suites took 600–1,100 s that night, and two tasks ran over their budgets just waiting on them.

(1) config-seal-covers and config-seal-a-merge both changed LeadVault.swift's seal code and started together, because the lead gave both `after: branch-code-can-t` instead of chaining them. The lead had to send a warning message mid-task, and a merge conflict was likely. (2) swift-testing-s-parallel ran over 60 then 100 min, and branch-code-can-t over 180 then 225 min. Each extension cost a round trip and a stopped turn.

## 2026-11-08 07:28:55 Starts and audits also wait when the Mac is short of memory (task starts-and-audits-wait, audited). Until it lands, the lead watches status for a load above 100 and starts nothing by hand while it lasts.

On 2026-11-08 from 03:40 to 06:00, load was 100–225 with idle CPU, 504 MB of RAM free and swap at 85%. The overload came from parallel full suites, 12 tests wide each, the old-host rebuild in every merge and audit, and up to 7 boosted sessions. The width cap and the old-host cache address the suites; nothing yet holds new sessions while the Mac pages.

## 2026-11-08 11:20:21 The app icon stays as it is (the user, 2026-11-08, after two rounds of options: "meh lets leave the current logo"). brand-new-app-icon is abandoned, and no tagline or About text changes in the app. The README rewrite goes ahead with a plain opening description. This supersedes the 2026-11-08 brand decision (1A1D1711).

Ten icons and eight taglines didn't win over the current look. Per the 2026-11-07 rule, a lukewarm answer means dropping the idea rather than holding it open.

## 2026-11-08 14:15:49 The 2026-11-08 project review's material findings became 8 tasks (a-branch-that-moves, the-vault-s-no, host-reply-timers-belong, wallet-cards-trust-only, every-text-that-crosses, product-fixes-from-the, the-board-and-records, correctness-tests-stop). Tasks that share LeadToolset.swift are chained with `after`. The minor findings are left alone. The security review's phone, host-authentication and tool-boundary parts didn't run: Fable's safety filter stopped it, and whether to run them another way is the user's call.

The user asked for a pass to find issues; their working policy is to fix material bugs and not to turn cosmetic observations into tasks. A filter stop isn't something for the lead to route around.

## 2026-11-08 17:52:40 Narrows the 2026-11-08 07:28 rule (1): tasks that name the same source file may run side by side when they change different functions of it and the Mac has room. Two tasks that change the same function, or the same whole file (LeadRecords.swift), still chain with `after`. Applied now: every-text-that-crosses runs after a-branch-that-moves, alongside the-vault-s-no, and the-board-and-records runs after the-vault-s-no (they share LeadRecords.swift).

The user asked "why not start more?" on 2026-11-08 while the Mac sat at load 7 with one session of this project. The three review tasks were chained only because their boundaries all name LeadToolset.swift, in unrelated places (checkBaseMoves and the merge's recording, saveMergeLog, the scratch sweep), and git merges separate hunks cleanly. The rule came from two seal tasks that edited the same seal code. A strict chain of three audited tasks costs hours.

## 2026-11-08 20:08:48 When the user needs to run something that wants a real terminal (a password prompt, an install, anything interactive), the lead and workers file `vs-shell run` so the user gets a one-click Run card. They don't tell the user to open Terminal.app, paste a command or type `! <command>`, and never take a password in chat. This replaces Claude Code's generic "suggest `!`" advice inside VibeSwitcher sessions. Task anything-needing-a-real puts it in the prompts and makes build-app.sh's locked-keychain failure say what to do.

On 2026-11-08 an install failed on a locked signing keychain. The lead said to use Terminal.app, the user ran it through `!` twice, which has no terminal for the password, and only `vs-shell run` worked. The user: "you should have asked to do a shell like you did now".

## 2026-11-08 20:36:08 Correction to the incident recorded 2026-11-08 about hung merge tests: the merge test of 2aa1e894 wasn't a hang. The Mac was asleep (51.8 min on the wall clock, 4.9 min awake; `pmset -g log` shows 41 sleeps between 15:00 and 20:00 on battery). The fix is that a merge's timeout counts awake time (turn-this-incident-into-16, contract v3). The stall limit isn't lowered.

The lead told the user "at least one merge really did hang" from the hung log, which can't show sleep. The worker checked the power log and the lead confirmed it. The afternoon's slow runs and the "tests stopped at 16:08" reading also fit the Mac sleeping, so neither test width nor battery load was the cause.

## 2026-11-08 23:16:41 From the 2026-11-08 batch retrospective: (1) Before calling a long merge or test run hung, check `pmset -g log` for sleep and the load recorder, and don't tell the user "it hung" until that's done. (2) A task's contract change no longer assumes a running worker has it: task incident-tasks-wait makes record_incident's task wait for the lead's contract and delivers a changed contract to a running worker. (3) The test-width timer is closed with no change: this evening's merge-sized full runs took 423-660 s, around the 600 s line, and the width was never shown to be the cause.

(1) The lead told the user a merge "really did hang" from a log that can't show sleep; the Mac had slept 41 times. (2) The 2026-11-05 decision said to make a product task if an incident task auto-started again on its generic brief. turn-this-incident-into-16 did, and its worker reported that v2 never reached it, which cost a round trip.
## 2026-11-08 16:53:35 2026-11-08: GitHub's main (3b271e17, 226 commits from the other Mac) is merged into this Mac's main by a worker (task merge-github-s-main, auto_advance off) as a true merge with the two test conflicts resolved and the full suite passing. The user then fast-forwards main (`git merge --ff-only agent/merge-github-s-main`) and pushes, and the lead installs. merge(task) isn't used for it because the installed tool server rebases a branch onto main.

The user asked to fetch the latest and install. The trial merge conflicts in WalletRobustnessTests and TerminalBridgeTests, which this Mac's handover-tests-stop and the other Mac's 204a442f both changed, so a hand merge by the user would need conflict resolution and testing. A rebase would rewrite 226 published commits.

## 2026-11-09 09:14:34 The three 67js prototypes (prototypes/session-object, session-journey, session-team) are throwaways for the user to look at: never merge them. Each task has auto_advance false and goes to status kept once done; delete or keep is the user's call.

The user asked to see what's possible and said they'll probably delete them. Local npm install with --ignore-scripts in the prototype or scratch folder only, by the user's request to use this library; its MCP server and Claude plugin stay out because they'd write agent config and trip the seal.

## 2026-11-10 18:41:18 Wallet cards get "Send all N to Wallet Manager…" for one session's waiting requests (task wallet-cards-send-all, audited): one action opens a list of exactly those requests, and confirming sends that snapshot one at a time through the existing single-card send, each with its own outcome, stopping at the first failure. No pre-authorisation of future requests by pattern, timer or setting: VibeSwitcher sends only what the user was shown in the list they confirmed. Never for Sign in browser wallet. The wallet-request format stays version 1, unchanged.

The user said yes on 2026-11-10 after another project's lead asked for fewer clicks: its rollout files 36 near-identical requests, each needing its own Send. The lead advised against pattern pre-authorisation because VibeSwitcher never judges a transaction and the Send click exists to check the agent that files the requests; exact matching belongs with the Wallet Manager's checks.
## 2026-11-09 09:50:05 3D representations of a session (67js seed head, river, railway yard) were built on 2026-11-09, the user looked and said "meh - remove them"; all three are deleted. Don't propose 3D session views again unless the user brings it up.

It was a look at what's possible, not a direction, and the user didn't like the result. This supersedes the earlier decision to hold those three prototypes as kept.

## 2026-11-09 10:29:38 Which ideas from the four repository reviews should the team build? 1–6 are cheap fixes: don't score failed eval runs, give the eval REVIEW.md, make dismissing an Important finding cite evidence, start bug tasks by reproducing the symptom, record the Claude Code version on merges, and cap prompt size. 7–9 change the audit prompt and share one eval run of about $50: settle doubts instead of filing them as Nits, check crashed and in-flight states, and flag what a diff added that nobody asked for. 10–11 get tested on past data first. → Build 1–9, and test 10–11 on past data

The lead proposed it with a 15 min timer and the user didn't answer in time, so it went ahead (question AC8DD1C8). Why it was asked: All four reviews are merged, and nothing starts until this is chosen.

## 2026-11-09 10:39:43 From the four repository reviews, build ideas 1-9 and backtest 10-11 before building them (the lead's proposal, taken by timer on 2026-11-09 after the user asked "what about the ideas?"). The audit-prompt change waits for the fixed eval's baseline, and has auto_advance off so the lead compares its eval summary before its audit and merge.

The reviews found the eval scores errored runs and runs without REVIEW.md, so verifier prompt changes can't be measured until that's fixed. Real audit quality gains (4 of 8 found bugs were Nit-only; 5 of 6 misses were unwalked states) depend on that measurement. Items resting on hypotheses get backtested first, in line with incident-first (2026-11-06 22:35).

## 2026-11-09 11:14:36 Not building the fresh-reader contract check or the tests-got-weaker check (2026-11-09). Reopen the first only with a reader that separates good contracts from bad; reopen the second on an incident where a weakened test let a bug through.

Backtests in docs/process/reviews/: the cheap reader flagged 97% of both failed and clean contracts (AUC 0.57), so it gives no signal; the tests check would have raised 4 of the last 100 merges, 1 of them new, and that one was a correct refactor.

## 2026-11-09 13:43:32 The phone and Tailscale review and fix (the user's request, 2026-11-09) runs as three audited Claude tasks side by side: setup and pairing, day-to-day views and recovery, and input. They share PhoneAccess.swift in different functions, and only the input task changes the input path. Each fixes material bugs, and lists missing features rather than building them. No worker touches real Tailscale settings, a real phone or a real session. The dedicated security review of the phone stays out of these tasks, pending the user's answer on how to run it after Fable's filter stopped it on 2026-11-08.

The three areas are independent enough to parallelize under the 2026-11-08 17:52 rule and the 2026-10-23 input-path rule. Tailscale serve and pairing are the user's real setup, so workers test through a fake CLI and the sandbox, and a real-phone pass stays with the user. The 2026-11-08 decision left routing around the filter to the user.

## 2026-11-09 13:45:12 The security review of the phone, host authentication and tool boundaries, stopped by Fable's filter on 2026-11-08, runs on Opus after the three phone tasks (the user's answer to 0C15FEF1, 2026-11-09). Findings left unfixed stay out of the public repository, in the done report only.

The 2026-11-08 decision left how to run it to the user, and they chose Opus. The repository is public, so committing an open weakness would publish it before the fix.

## 2026-11-09 14:20:42 From the user's review of where work goes wrong (2026-11-09). (1) Four tasks: the merge checks the commit it's about to land across every route, audit exceptions become a structured record before the audit, stall reports name their cause with evidence, and start_worker warns on overlapping write boundaries (warning only). (2) The impact ledger is paused: no new entries, and the routine in the 2026-11-01 08:54 decision is suspended. The history stays. Reopen it if an entry shows a measurement changed or reversed a decision. (3) Pilot, by hand and only on high-risk contracts (a security boundary, or what moves main): the lead writes one concrete way the acceptance checks could pass while the guarantee fails, and makes it a test. No tool is built for this, and the 2026-11-09 11:14 decision against a fresh-reader check stands. (4) From the next batch, each retrospective counts merged tasks that needed a corrective follow-up and where the defect first became detectable, from the receipts. (5) Kept: your click on outward actions, the adversarial audit of permission changes, and the default finder count. Correction: the second GitHub merge flattening (2026-11-07) came from a stale installed gate, not the batch path.

The incidents point to handoffs the system controls, not to too few reviewers. The verifier passed a correct branch and the merge step changed the result; two 2026-11-07 send-backs were the lead failing to pass on an acceptance; and a five-hour misdiagnosis came from a report that couldn't show Mac sleep. The 15 oldest impact entries are all still pending. The hand pilot is narrower than the backtested contract reader, which gave no signal across all contracts. 14 user-found and 14 system-found bugs count discoveries, not escapes, so the follow-up measure is needed.

## 2026-11-09 17:30:54 Updates to Claude's own synced skills keep needing the user's Accept (their answer to A200C514, 2026-11-09). The card gets clearer instead (task the-config-seal-s): which skill and files, the text difference, when, and the likely source and how sure that is.

A skill runs in every Claude session, and a forged sync update can't be told from a real one on disk, the same reasoning as the 2026-11-08 06:33 plugin decision. The user's complaint was not knowing what changed or why, and real skill-content changes are rare.

## 2026-11-09 20:24:31 This account has hit its Fable limit until Nov 12, 12:00, and Fable runs the audits. Three tasks still need one: the merge failure message, the test run's false blame, and the audit prompt changes. None of them is urgent, and all the phone and security work is already merged. What should I do with those audits? → Wait for the reset on Nov 12

The lead proposed it with a 30 min timer and the user didn't answer in time, so it went ahead (question E8B48BFD). Why it was asked: An audit has already stopped at the limit, and two more tasks are about to need one.

## 2026-11-09 20:25:00 From the 2026-11-09 retrospective. (1) Audits and paid evals wait for the Fable limit's reset on Nov 12, 12:00 (the proposal on E8B48BFD, by timer); audit prompt changes then finish six unscored cases only. (2) Before a paid eval, the lead checks in status that the Fable limit has headroom for its full run and that the Mac is on AC or has enough battery; otherwise it waits. (3) What the lead tells the user about a cause carries its evidence, or says it's a guess: on 2026-11-09 three such statements needed correcting.

Two paid evals were lost in part on 2026-11-09: about $12 when a session ended mid-run on battery, and six of twelve cases when the Fable limit ran out, with about $29 of that still usable. The lead also told the user the second merge flattening came from batching, that the size cap could run early, and that the user's app caused a merge failure, each without checking; the records said otherwise or couldn't confirm it.

## 2026-11-09 21:46:02 Audits run on Opus until the Fable limit resets on Nov 12, 12:00 (the user's late answer to E8B48BFD, and they lowered the review floor in Settings to allow it). This replaces the wait for those audits. After the reset, the lead clears verifier_model so audits run on Fable again, and tells the user they can restore the floor. The audit prompt eval still waits for Fable, so it stays comparable with the baseline.

The user preferred same-model audits to waiting. Two infrastructure audits can go ahead now, and the eval must keep the baseline's model to mean anything.

## 2026-11-11 23:29:31 Until the-sandbox-app-builds merges, UI tasks with real layout changes go to a Claude worker (agent: claude), not auto. Text-only UI changes on Codex may waive screenshots when tests pin the text.

Codex workers can't run scripts/sandbox-app.sh: the manifest compile writes ~/.cache/clang/ModuleCache, outside their sandbox. Screenshots were waived twice on 2026-11-11 (boost-release-7-7, a-blocked-task-s). The second time was a repeat, so it became a task instead of a third waiver.

## 2026-11-11 23:36:52 UI tasks that need sandbox screenshots go to a Claude worker (agent: claude), permanently, not auto or Codex. Text-only UI changes on Codex may waive screenshots when tests pin the text. This supersedes the 2026-11-11 "until the-sandbox-app-builds merges" decision.

the-sandbox-app-builds showed that Codex's sandbox denies com.apple.hiservices-xpcservice, so the sandbox app can't start there even once it builds. The task was abandoned rather than merging Codex-only build paths that don't yield screenshots.

