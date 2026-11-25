# Decisions

Archived decisions: 170 entries (superseded, obsolete or now enforced by a check) are in decisions-archive.md, moved there unchanged (last on 2026-11-24).

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

## 2026-10-21 12:30:57 The briefing's ElevenLabs key falls back to ELEVENLABS_API_KEY from the user's login shell, then ~/.config/elevenlabs/key.env, when no key is saved in the Keychain. Settings shows the source by name, never the value, and offers 'Save to Keychain'.

The user asked why the app asks for a key that's already in their environment. A Finder-launched app doesn't inherit shell variables, but the app already reads the login-shell environment for sessions. A typed key still wins, so nothing changes for users without the variable.

## 2026-10-21 22:52:33 Additions to the working policy after the lead's review (2026-10-21 23:0x): (1) The merge's run is the one full suite; workers run affected tests, and the full suite only when they touch shared test or build infrastructure. (2) Workers own routine calls, including small goal-tied boundary excursions, and list them in their report; they ask the lead only about direction, scope, or risky steps. (3) Timing benches leave the default test run (`--perf`), so merges don't fail on load. (4) Worktrees build warm. (5) The policy reaches every project's leads, workers and verifiers through the app: an editable policy text in every prompt, a witness message to running leads, and a Mac-wide `vs-heavy` lock for any project. (6) The lead posts updates only for merges the user would notice; the rest go into a daily summary.

Remaining causes of slowness after the first policy pass: one extra full suite per task in the worker, merge gates failing on load-sensitive benches, about 2 minutes of clean build per worktree, routine worker questions round-tripping through the lead, and the lead's own update volume. The user asked for the policy to reach the other leads and future ones; the user also asked the lead not to touch other leads directly, so delivery goes through the app.

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

## 2026-11-01 08:20:57 Reading freeze reports: "N% of its sample inside the stall" is how much of the sample was taken during the stall, not the share of time in the frames listed. Before planning a freeze task, count the main thread's samples in the .txt that pass through the suspected code (the 2026-10-31 00:48 rule), and plan only if they're a real share.

2026-11-01: the lead planned terminal-drawing-froze from a report saying '100% of its sample inside the stall' under SwiftTerm.buildAttributedString. 0 of 2092 main-thread samples were actually in terminal drawing. The worker checked before building and the task was abandoned, but it cost a worker start. Third-party code (SwiftTerm, a pinned dependency) was also assumed to be vendored.

## 2026-11-02 08:18:57 Usage-aware routing (2026-11-02): when Claude's quota runs ahead of pace, implementation work moves to Codex. Task usage-aware-worker adds agent: auto (Codex when Claude is tight and Codex has room), reads Codex's quota from its rollouts, shows both accounts' pace in status, and lets auto tasks go to Codex instead of waiting at Claude's 80% hold. Until it lands, the lead marks bounded implementation tasks agent: codex by hand whenever Claude's weekly usage is ahead of the week's elapsed share. Leads, planning and audits stay on Claude, and design-heavy or security tasks stay pinned to claude. Once it lands, the lead sets agent_default: auto for this project.

The user, 2026-11-02: "if there's not a lot of quota I should be leveraging Codex much more". Codex workers have worked since 8f44a65, but nothing chose them: the usage watch only stopped work at 80%. A Codex worker spends roughly a tenth of a task's Claude cost (the audit), going by boost-release-3b-codex's receipt: verifier $1.86 against worker $14.79.

## 2026-11-02 08:45:52 Boost can run on battery when the user turns on a new Settings option, "Also on battery" (off by default; task boost-on-battery-a). With it on, On and Automatic behave as on AC down to 30% charge, and boost stays off below that or when the charge is unknown. This supersedes "never on battery, whatever the mode" from the 2026-11-01 boost release decision for users who opt in.

The user asked for it on 2026-11-02. The 30% floor is the lead's choice, so an unattended boosted Mac doesn't drain its battery flat. The usage veto and the battery pause hold still apply.

## 2026-11-02 10:26:32 Xcode's Metal Toolchain is a build prerequisite for VibeSwitcher on this Mac (SwiftTerm 1.19.0 compiles Shaders.metal in every configuration). Installed by the user on 2026-11-02. If a build fails with "missing Metal Toolchain", the user runs `xcodebuild -downloadComponent MetalToolchain`. Don't patch around it.

Xcode 27.2 stopped bundling it. Every build, install and test run failed until the 840 MB component was downloaded. The user chose the download over changing the dependency.

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

## 2026-11-06 22:35:21 Ideas from Anthropic, OpenAI and METR posts (2026-11-06) stay parked as triggered ideas, not tasks: (2) VibeSwitcher mechanically checks that a branch's new tests fail without its non-test changes and pass with them. Build it when a merged test turns out not to exercise its change, or a merge is reverted for a defect its tests should have caught. (3) A per-contract path-glob field, a PreToolUse reminder on edits outside it, and a deterministic diff-vs-globs check at done. Build it when a worker touches something out of scope that nobody catches. Also parked: - (1)/(6) measure verifier recall with planted bugs, and randomly audit 5–10% of review-none merges; - (4) rerun verifier-eval when verifier_model changes; - (7) mid-task mechanical checks about every 30 min; - (8) a chaos corpus for the orchestrator as regression_command; - an audit of how agent text is rendered in the chat.

The user agreed (2026-11-06). This week's evidence shows no failure these would have caught: workers always ran the reverse-apply check, a verifier reproduced it once, there were no reverts, and every out-of-boundary edit was declared and accepted. They cost usage and heavy slots while usage is ahead of pace and load spikes are the live problem. The policy is incident first, then the check.

## 2026-11-07 18:33:18 A code block's Run is one behaviour in every session kind that can take a command: Claude sessions, the lead's chat, Codex (via its own shell escape) and plain shells (typed without `!`). It uses the same detection, the same confirmation rule and the same can't-run message everywhere, through a single typing seam per session kind. It's audited, because it types into sessions.

On 2026-11-07 the user reported that Run is unreliable and sometimes missing, with no confirmation popup. Today it appears only in Claude window sessions and fails with a bare beep. Asked whether Run should reach other session kinds, the user answered "yes lets unify stuff. make sure tis clean".

## 2026-11-07 19:48:57 For a UI task whose worker will need sandbox probe commands, the lead says in the contract from the start that adding sandbox commands to Sources/VibeSwitcher/Sandbox.swift is accepted. Those commands only drive the sandbox's own windows and pasteboard, and run no commands and write no files. The note goes in before any audit, never after one has started.

The same setback happened twice on 2026-11-07. terminal-panes-text-can and chat-view-copying-text each came back "suspect" with 0 Important findings, only because a sensitive-path edit (Sandbox.swift probes) wasn't covered by a lead note. In the second case the lead's note arrived after auto_advance had already started the verifier. Each cost a second audit round.

## 2026-11-07 20:08:53 Review rules get a user-owned floor, set in Settings › Project lead. It covers sensitive_paths, strict_paths, audit_finders, merge_policy, risk_lines, risk_model and the verifier-model relation (the verifier's model is never the workers' unless the user says otherwise). The lead's configure can raise protection above the floor (add paths, more finders, a stricter policy) but can't lower it. A lowering is refused with a Settings hint, and the user sets it in the app.

The user chose it on 2026-11-07 (F0181AFD). The 2026-11-07 harness review found governance capture: the lead proposes changes and also sets the evaluation policy that judges them, with only a progress line as record. The macKeys refusal pattern (LeadWorkflow.swift ~380) is the precedent.

## 2026-11-07 21:09:09 Nothing on the board stays blocked waiting on the user. When an idea gets a lukewarm answer ("meh"), the lead abandons it, or moves it into docs/process/backlog.md, rather than holding it as blocked. A task is blocked only on a concrete external condition (data, a reset, another task), and its reason names that condition.

On 2026-11-07 the app showed items waiting on the user. They were two chat tasks the lead had blocked after the user said "meh". The user: "It's saying that some things are waiting for me. You shouldn't wait for me, right?"

## 2026-11-08 06:33:00 Plugin updates always need the user's Accept, like any other code change, whoever made them and whether or not team sessions ran. config-seal-covers merges as built, and plugin-updates-always (after it, audited) removes its silent sealing of updates. The plugin seal ships in an install only once both have merged.

Question CEDA0180, 2026-11-08: the user didn't answer in 15 min, so the lead's proposal applied. A plugin's hooks run as code in every Claude session, and a forged update (a new version folder in the cache with the install record repointed) can't be told apart on disk from Claude Code's own update. That matches the standing rule that code that runs always needs Accept.

## 2026-11-08 07:28:52 From the 2026-11-08 batch retrospective, two planning rules. (1) Tasks whose boundaries name the same source file never run side by side: the later one gets `after` on the earlier. (2) A task whose contract needs its worker to run a full suite (it changes scripts/test.sh or the test harness) gets budget_min 120, not 60. Full suites took 600–1,100 s that night, and two tasks ran over their budgets just waiting on them.

(1) config-seal-covers and config-seal-a-merge both changed LeadVault.swift's seal code and started together, because the lead gave both `after: branch-code-can-t` instead of chaining them. The lead had to send a warning message mid-task, and a merge conflict was likely. (2) swift-testing-s-parallel ran over 60 then 100 min, and branch-code-can-t over 180 then 225 min. Each extension cost a round trip and a stopped turn.

## 2026-11-08 11:20:21 The app icon stays as it is (the user, 2026-11-08, after two rounds of options: "meh lets leave the current logo"). brand-new-app-icon is abandoned, and no tagline or About text changes in the app. The README rewrite goes ahead with a plain opening description. This supersedes the 2026-11-08 brand decision (1A1D1711).

Ten icons and eight taglines didn't win over the current look. Per the 2026-11-07 rule, a lukewarm answer means dropping the idea rather than holding it open.

## 2026-11-08 17:52:40 Narrows the 2026-11-08 07:28 rule (1): tasks that name the same source file may run side by side when they change different functions of it and the Mac has room. Two tasks that change the same function, or the same whole file (LeadRecords.swift), still chain with `after`. Applied now: every-text-that-crosses runs after a-branch-that-moves, alongside the-vault-s-no, and the-board-and-records runs after the-vault-s-no (they share LeadRecords.swift).

The user asked "why not start more?" on 2026-11-08 while the Mac sat at load 7 with one session of this project. The three review tasks were chained only because their boundaries all name LeadToolset.swift, in unrelated places (checkBaseMoves and the merge's recording, saveMergeLog, the scratch sweep), and git merges separate hunks cleanly. The rule came from two seal tasks that edited the same seal code. A strict chain of three audited tasks costs hours.

## 2026-11-08 20:08:48 When the user needs to run something that wants a real terminal (a password prompt, an install, anything interactive), the lead and workers file `vs-shell run` so the user gets a one-click Run card. They don't tell the user to open Terminal.app, paste a command or type `! <command>`, and never take a password in chat. This replaces Claude Code's generic "suggest `!`" advice inside VibeSwitcher sessions. Task anything-needing-a-real puts it in the prompts and makes build-app.sh's locked-keychain failure say what to do.

On 2026-11-08 an install failed on a locked signing keychain. The lead said to use Terminal.app, the user ran it through `!` twice, which has no terminal for the password, and only `vs-shell run` worked. The user: "you should have asked to do a shell like you did now".

## 2026-11-08 23:16:41 From the 2026-11-08 batch retrospective: (1) Before calling a long merge or test run hung, check `pmset -g log` for sleep and the load recorder, and don't tell the user "it hung" until that's done. (2) A task's contract change no longer assumes a running worker has it: task incident-tasks-wait makes record_incident's task wait for the lead's contract and delivers a changed contract to a running worker. (3) The test-width timer is closed with no change: this evening's merge-sized full runs took 423-660 s, around the 600 s line, and the width was never shown to be the cause.

(1) The lead told the user a merge "really did hang" from a log that can't show sleep; the Mac had slept 41 times. (2) The 2026-11-05 decision said to make a product task if an incident task auto-started again on its generic brief. turn-this-incident-into-16 did, and its worker reported that v2 never reached it, which cost a round trip.
## 2026-11-10 18:41:18 Wallet cards get "Send all N to Wallet Manager…" for one session's waiting requests (task wallet-cards-send-all, audited): one action opens a list of exactly those requests, and confirming sends that snapshot one at a time through the existing single-card send, each with its own outcome, stopping at the first failure. No pre-authorisation of future requests by pattern, timer or setting: VibeSwitcher sends only what the user was shown in the list they confirmed. Never for Sign in browser wallet. The wallet-request format stays version 1, unchanged.

The user said yes on 2026-11-10 after another project's lead asked for fewer clicks: its rollout files 36 near-identical requests, each needing its own Send. The lead advised against pattern pre-authorisation because VibeSwitcher never judges a transaction and the Send click exists to check the agent that files the requests; exact matching belongs with the Wallet Manager's checks.
## 2026-11-09 09:50:05 3D representations of a session (67js seed head, river, railway yard) were built on 2026-11-09, the user looked and said "meh - remove them"; all three are deleted. Don't propose 3D session views again unless the user brings it up.

It was a look at what's possible, not a direction, and the user didn't like the result. This supersedes the earlier decision to hold those three prototypes as kept.

## 2026-11-09 11:14:36 Not building the fresh-reader contract check or the tests-got-weaker check (2026-11-09). Reopen the first only with a reader that separates good contracts from bad; reopen the second on an incident where a weakened test let a bug through.

Backtests in docs/process/reviews/: the cheap reader flagged 97% of both failed and clean contracts (AUC 0.57), so it gives no signal; the tests check would have raised 4 of the last 100 merges, 1 of them new, and that one was a correct refactor.

## 2026-11-09 14:20:42 From the user's review of where work goes wrong (2026-11-09). (1) Four tasks: the merge checks the commit it's about to land across every route, audit exceptions become a structured record before the audit, stall reports name their cause with evidence, and start_worker warns on overlapping write boundaries (warning only). (2) The impact ledger is paused: no new entries, and the routine in the 2026-11-01 08:54 decision is suspended. The history stays. Reopen it if an entry shows a measurement changed or reversed a decision. (3) Pilot, by hand and only on high-risk contracts (a security boundary, or what moves main): the lead writes one concrete way the acceptance checks could pass while the guarantee fails, and makes it a test. No tool is built for this, and the 2026-11-09 11:14 decision against a fresh-reader check stands. (4) From the next batch, each retrospective counts merged tasks that needed a corrective follow-up and where the defect first became detectable, from the receipts. (5) Kept: your click on outward actions, the adversarial audit of permission changes, and the default finder count. Correction: the second GitHub merge flattening (2026-11-07) came from a stale installed gate, not the batch path.

The incidents point to handoffs the system controls, not to too few reviewers. The verifier passed a correct branch and the merge step changed the result; two 2026-11-07 send-backs were the lead failing to pass on an acceptance; and a five-hour misdiagnosis came from a report that couldn't show Mac sleep. The 15 oldest impact entries are all still pending. The hand pilot is narrower than the backtested contract reader, which gave no signal across all contracts. 14 user-found and 14 system-found bugs count discoveries, not escapes, so the follow-up measure is needed.

## 2026-11-09 17:30:54 Updates to Claude's own synced skills keep needing the user's Accept (their answer to A200C514, 2026-11-09). The card gets clearer instead (task the-config-seal-s): which skill and files, the text difference, when, and the likely source and how sure that is.

A skill runs in every Claude session, and a forged sync update can't be told from a real one on disk, the same reasoning as the 2026-11-08 06:33 plugin decision. The user's complaint was not knowing what changed or why, and real skill-content changes are rare.

## 2026-11-11 23:36:52 UI tasks that need sandbox screenshots go to a Claude worker (agent: claude), permanently, not auto or Codex. Text-only UI changes on Codex may waive screenshots when tests pin the text. This supersedes the 2026-11-11 "until the-sandbox-app-builds merges" decision.

the-sandbox-app-builds showed that Codex's sandbox denies com.apple.hiservices-xpcservice, so the sandbox app can't start there even once it builds. The task was abandoned rather than merging Codex-only build paths that don't yield screenshots.

## 2026-11-12 09:21:45 The periodic prompt audit is a reminder card for the user, not something leads run on their own (task remind-the-user-to). Each project's lead chat gets a card when 14 days have passed since that project's last `/doctor prompt-audit` or when its sessions' model has changed. The card offers Run now (on the user's click only), Remind me in a week, and Not for this project, with an on/off toggle and the interval in Settings › Project lead. The audit's 2026-11-12 findings for AGENTS.md (the stale lint list, and --load 24 being refused on 8 cores) go to task agents-md-run-every. The leftover worktree .claude/worktrees/fix-worker-tools, which holds an older AGENTS.md, stays until the user decides, because it may hold unmerged work.

The user asked for the reminder (via wallet-manager's lead) and left the design to the lead ("do what you consider"). /doctor is a user command, and its proposed diff needs the user's eye, so the user starts each run. A model change is the second trigger because what counts as outdated depends on the model.
## 2026-11-12 09:23:09 Contracts for tasks that run on Fable state the outcome and its acceptance checks, give a larger scope than an Opus task would get, and leave the steps and routine test reminders out. Hard tasks get effort xhigh once per-task effort exists (each-role-gets-the). The user's global ~/.claude effort and advisor settings are left alone.

Anthropic's Claude Code guidance for Fable: describe the outcome rather than the steps, skip routine test or check reminders, and give it larger tasks you'd normally split up. xhigh is the recommended effort for agentic coding on these models. A global advisorModel would change every Claude session on the Mac.

## 2026-11-12 09:35:22 Briefs for tasks that use a third-party CLI scaffold (e.g. `npx hyperframes init`) say whether it writes outside the worktree. Where it does, as HyperFrames' init installs skills into ~/.claude/skills, ~/.agents, ~/.cursor, ~/.gemini and opencode, the brief forbids it and names the alternative, or the lead gets the user's OK first.

2026-11-12: the an-animated-explainer worker ran `npx hyperframes init` as the skill said, and it installed two new skills into ~/.claude/skills plus symlinks into other agents' folders. The config seal caught it, but every new worker, audit and merge was held until the user ruled. My brief allowed "project-local npx" without checking what init writes.

## 2026-11-12 10:33:35 Supersedes the earlier 2026-11-12 "tasks get bigger" decision: keep tasks under about 30 min of work where the change allows, and batch only parts that share files and would otherwise conflict or wait. Also: when gate or lead commits on main wait uninstalled and nothing is in flight, the lead files one install card saying how many commits and what they fix, instead of waiting for the user to ask.

Fable's check of the speed review (2026-11-12) measured the opposite of the talk's advice for this project: tasks with over an hour of work needed a second audit round 59% of the time, against 18% for tasks under 30 min, and extra rounds are the largest in-flight cost (about 95 task-hours in 7 days, an upper bound). Merged work also waits a median of up to 4.5 h for an install, and most merges change the lead's own machinery, which runs from the installed app.

## 2026-11-12 10:41:54 Small tasks merge without an audit: a task whose worker worked under 30 minutes, touching no sensitive or strict path, not flagged by the risk check, not Codex's work, and not marked security or irreversible, merges on its done report, the pre-done check and the merge's full suite, plus the existing 10% audit sample. The lead files such tasks review none, and VibeSwitcher applies the rule at done for tasks filed audit only for size or caution (task small-tasks-merge).

The user's answer to A4977A3E (2026-11-12). Fable's check of the speed review: tasks under 30 minutes of work took 42% of the week's verifier spend ($220 of $526), and 5 of 49 had an Important finding. The pre-done check and the full suite now catch much of what audits caught on small changes.

## 2026-11-12 11:32:16 Nothing the lead records (dismiss reasons, decisions, contracts, updates, progress) names the user's other projects. Say "another project".

2026-11-12 10:57: a dismiss reason named one, it went into docs/lead/progress.md, and PrivateNamesLint, which scans every tracked file including docs/lead/, then fails every merge's full suite until the line is fixed.

## 2026-11-12 15:28:58 After a block clears with many tasks ready, the lead merges them itself in batches of up to 8 (merge with tasks), lowest-risk first, with the batch carrying test fixes (flaky-test fixes, test infrastructure) going first. auto_advance stays off for the few minutes that takes, so it doesn't fall back to one merge at a time.

The user, 2026-11-12: "you need to be extremely proactive and try to make sure that everything gets to the finish line as quickly as possible." After the block, auto_advance went to merging the 14 ready tasks one at a time, about 15 min each, 3–4 h in all, where two batches take about 30–40 min.

## 2026-11-12 16:27:53 Before batching, order tasks so that those touching the same hot files (LeadToolset.swift, LeadAdvance.swift, LeadWorkflow.swift, the merge path) go in separate batches or in a known order, and the rest go together. When planning, avoid running more than two tasks at once that change the same hot file.

2026-11-12: a batch of 6 lost 2 tasks (a-calm-mac-merge, small-non-sensitive) to conflicts with others in the same stack, all touching LeadToolset and the merge path, which costs another round of catching up and testing.

## 2026-11-13 19:24:12 No shared notes board between workers for now. Revisit when a second incident appears where several workers each track down the same shared trap, or when a rerun of scripts/worker-rediscovery.py puts tip-preventable repeats plus concurrent clashes over 5% of worker time.

The user asked whether to adopt a board like Antigravity's /swarm and chose to measure first. Over 150 worker sessions in 7 days, repeats a tip would have prevented plus concurrent clashes cost 3.0% of worker time (docs/process/reviews/worker-rediscovery-2026-11.md, audited), and all of the tip-preventable part was one incident: main red on 2026-11-12. Cheaper fixes cover it: agents-md-and-the and every-worker-is-told.

## 2026-11-13 22:49:20 A task's boundaries name the function or behaviour it must change wherever it lives, and always allow the minimal edits the compiler forces elsewhere (exhaustive switches), to be listed in the done report. When a worker's done report names an edit outside its boundaries that the lead accepts, and the audit has already started, settle a 'suspect' verdict with update_task(exception, accept_verdict) instead of a new audit round; findings from a suspect verdict are sent to the worker by the lead at once, since auto_advance doesn't send them.

Twice on 2026-11-13 (teammate-sender-a-frame, member-worktrees-a-sub) the lead's boundaries were narrower than the goal, the worker rightly edited outside them, and the lead's exception was recorded after auto_advance had started the audit. The first cost a suspect verdict and 8 minutes with the task sitting failed, which the user noticed.

## 2026-11-14 10:34:24 From observing another tool's multi-agent run on another project (2026-11-14, first 75 minutes, 22 agents): adopt (1) a structured handoff on part_done: what changed, caveats, how to verify (added to take-part-the-integrator's contract); (2) in the team experiment, one member of the team arm is a test track that writes the acceptance tests from the integrator's committed interface while the others implement. Not adopted: a shared workspace with ownership by instruction only, liveness judged from agents' self-written progress files, relay-only sub-orchestrators, and five verifiers per milestone (audit_finders already gives 2 or 3 focused finders when a task warrants it). Look again when that run ends and compare time, agents used and outcome before deciding anything further.

In that run a stale progress file got a healthy worker declared hung and its finished work re-dispatched, the coordinator twice told the user work was verified before any verifier existed, and the test track drifted from the interface because it had no committed contract to import. Its heavier mode used no shared board at all: hierarchy, written contracts and independent verification carried the coordination. One run in progress is thin evidence, so only the two cheap changes are taken now.

## 2026-11-16 07:21:59 Team experiment instance 1 result, by the bar set beforehand: DROP. Team mode stays in the code, but I don't choose team tasks by default, instance 2 isn't run, and the team-only follow-ups (an integrator waiting on members counting as stalled, a fuller UI) aren't built. Numbers: normal arm 209 min to merge-ready (20:33 to 00:02), 100 worker-min, 41M worker tokens (est. $21.8), 0 Important findings, 3 merge conflicts. Team arm about 174 min raw (audit pass 23:09 plus a typical 18-min merge test), about 153 min with the excluded catch-up and the start wait only it hit (17–27% sooner), 128 worker-min, 82M worker tokens (2.0×, est. $32.7, 1.5×), 1 Important finding (masking applied to every sandbox shot, fixed in one round), 0 conflicts inside the team.

The pre-registered rule (team-on-one-task-design.md §5) drops on more Important findings in either instance; the team arm also misses the ≤1.5× token bar (2.0×) and is only borderline on speed. Its real gains were quality ones the bar doesn't count: no hot-file conflicts, stable back-to-back journeys, and it found the inspector root cause that left the normal arm's select-copy flaky. It also cost about 8 extra lead turns (member starts, false stall alarms). Revisit if a task has 3+ parts that must share one hot file and conflicts cost more than the token overhead.

## 2026-11-16 09:31:56 After a Mac restart, VibeSwitcher offers one card at launch that lists the sessions live at shutdown, with "Reopen all" and "Choose". Nothing reopens without the user's click. Leads reopen first and are told to restart their workers; workers and verifiers aren't listed.

The user's answer to 9B2720A6 (2026-11-16). Reopening everything automatically would spend tokens and load the Mac without the user choosing to.

## 2026-11-17 09:46:02 The config seal accepts a finished round of Claude Code's skill sync inside ~/.claude/skills/synced/ by itself (strict shape: manifest and round marker rewritten together, only under bucket folders with matching .bucket- markers, no symlinks). Every other change to the sealed config is still held for the user. Built as accept-claude-code-s, a security audit.

The user chose it on 2026-11-17 (question 1EA6E8D7). The sync stalled every worker, audit and merge three times in a day, each time waiting on the user's click, and the changes were Claude Code's own bookkeeping.

## 2026-11-17 11:44:39 The app checks for a newer VibeSwitcher (GitHub's origin/main, or this Mac's main) about 2 minutes after launch and every 6 hours after that, and has a menu item. It shows a card with a plain-language changelog and Install & Restart. The button opens a shell card asking for the signing keychain's password each time; the password is never stored. Built as update-check-a-card (audit).

The user asked for it on 2026-11-17, to replace the lead's hand-filed install cards, and chose click plus password over a stored password (question 6867BF0F).

## 2026-11-17 19:55:55 The lead speaks to the user only when (1) the user must act (a card to run, a password, a question), (2) something the user asked for is finished (one message at the end, not one per step), (3) a real problem, risk or security finding needs their attention, or (4) the daily summary is due. Routine wakes get no message at all: a worker started, an audit started or passed, findings sent back automatically, a merge running long, a cleanup, an alert caused by our own test or probe.

On 2026-11-17 the user said "we have too much noise... I don't even read 80%". On that afternoon's run (flaky tests, the Code Mode trial, the git guard), about 14 lead messages went out, and only about 4 needed the user: the install password, the trial's plugin finding, the security gap, and the final results.

## 2026-11-18 09:57:28 Swift Testing's parallel width in the merge's suite may go above the heavy slot's core count: 2× VS_HEAVY_CORES, done in faster-test-suite with an override variable. This revises the 2026-11-08 05:42:44 cap of width = VS_HEAVY_CORES. CPU-bound suites (benches, load tests) keep their own limits, and the change merges only if 3 full runs at the new width show no new flake.

The 2026-11-08 decision said to measure the cap's cost on later merges, and the measurement is in. On main the test phase took 680 s at 6 cores and 1009 s at 4: the same slot-seconds either way, while the test process ran at only 1–35% CPU. So tests hold width while they wait on subprocesses, sockets and timers, and the cap costs time without protecting the CPU.

## 2026-11-18 11:22:44 From the book review (docs/process/reviews/books-patterns.md), the user approved six proposals on 2026-11-18. They are built as four tasks: - lead-brief-merge-error (items 1, 2 and 8): the merge error budget (at most 5% of merges passing only on a rerun, and a calm-Mac median of 10 minutes or less; while missed, test and flake fixes go ahead of features), tidy-first as its own task, and a recurrence check in retrospectives. - scorecard-merge (items 1 and 7): the merge objectives and the count of lead messages in the weekly scorecard. - git-guard-fails-closed (item 3). - memory-benches-run-by (item 5). Not built now: item 4 (splitting Sandbox.swift, which needs the user's review-floor click), item 6 (time to restore) and item 9 (a status transition table).

Each answers a measured problem: 18% of the week's merges passed only on a rerun, with a 17-minute median; tasks over an hour of work need a second audit round 59% of the time; the git guard needed two rounds of bypass fixes in one evening; memory growth has taken 9 tasks, each found a day late; and the noise rule had to be written twice.

## 2026-11-18 12:17:32 Workers and routine audits run on Opus. Fable is for the lead, for security and sensitive audits, and as advisor on hard tasks (the user's answer to 99E29A76, 2026-11-18). The lead sets model: opus on every task it adds, because a worker otherwise takes the Claude command's default, which follows the user's own /model choice.

On 2026-11-18 the user's /model switch to Fable 5.2 saved itself as the default for new sessions, and new workers then started on Fable at about twice Opus's price, on a day the account had already hit its weekly limit. workflow.md has no project-wide worker model setting, so until one exists the pin is per task.

## 2026-11-18 13:56:12 No cache heartbeat (keep-warm) for the lead. Only the handover after a long idle with a large context is built (task lead-context-cost-hand).

Measured on the week to 2026-11-18, with the handover in place: a heartbeat sent only while work is in flight avoids 2 of the 27 cold lead wakes, saving about $2.34 a week for $0.17 spent. But it reads 3 to 4 times more tokens than it saves, on a plan whose limits count tokens, and each heartbeat is a turn typed into the lead's chat. The user asked for this check on 2026-11-18 (answer to 001841F9). Revisit if usage is billed in dollars, or if cold wakes with work in flight become common.

## 2026-11-18 18:53:12 The targeted hunt for the SIGPIPE writer is closed without a catch (find-the-test-that, 2026-11-18), so the merge's test width stays at 1 a core. Instead the probe goes into every test run (task sigpipe-probe-always-on), so the next merge that takes a SIGPIPE names the writer; the fix and the switch to two tests a core follow from that catch. A second flake the hunt reproduced 9 times gets its own task (flaky-status-line-test).

About 160 probed runs caught the signal once, before the sharper probe existed (roughly 1% of early-suite runs), while merges' full runs under load hit it far more often: 12 of the week's 37 flakes and 3 of today's merges. More hunting costs heavy slots for little chance; an always-on probe costs nothing per run and catches it where it actually happens.

## 2026-11-18 19:57:48 Tasks whose checks run VibeSwitcher's host or terminal tests (they bind Unix sockets and open ptys: VibeHostTests, the terminal and input suites) go to a Claude worker (agent: claude), never auto or Codex. Codex's sandbox refuses `bind` (Operation not permitted), so it can't show a host test red or green, nor run its load proof.

2026-11-18: flaky-host-tests-turn went to Codex by agent auto while Claude's weekly overage limit was reached; its baseline load run failed 36 issues a run on `bind: Operation not permitted` before reaching the code under test. Same shape as the 2026-11-11 rule for sandbox-screenshot UI tasks.

## 2026-11-18 21:51:10 From the 2026-11-18 retrospective: (1) Disk stalls get a product fix (task new-work-waits-when): new workers wait while free disk is under the load floor plus headroom, so work in flight can finish its load run. Until it lands, the lead starts no new worker by hand while free disk is under 20 GB. (2) A worker's done gate run inside Codex's sandbox can fail on sandbox-only limits (sockets, /dev/stdout); the lead then runs the same check outside the sandbox and, on a pass, sets that task's done_check off with the result in its context. (3) Silent workers are handled by the merged auto-nudge (a-worker-that-stops); the merge reruns by sigpipe-probe-always-on and the flake tasks. No change for the status size bound (once) or the /model switch (the per-task opus pin held).

Today five finished workers waited 1–3 h on the 15 GB load-run floor while new ones kept starting, and six of the lead's turns answered the same disk question; two Codex rounds failed their checks only because of the sandbox. The silent-worker and rerun setbacks already have merged or planned fixes.

## 2026-11-18 22:48:03 From the 2026-11-18 speed review (start to merge, 94 tasks, 294 task-hours): three merge-path fixes, chained because they share the merge code: merge-reruns-only-what (a failure reruns only what failed, not the whole suite), then the-config-seal-is (seal checked before a merge's tests; a passing run survives a seal hold), then the-lead-s-records (records committed before every merge). Not changed now: merge width stays at 4 cores until sigpipe-probe-always-on names the pipe writer; Mac sleep (54 h) and rework rounds (~15 h) get no task.

Whole-suite reruns cost about 35 h in the week (24 of 91 first runs failed; every rerun re-ran everything, a median 39 min against 16 for a clean pass). Seal checks after the tests threw away three passing runs, and the lead's records failed 9 merges. Sleep is mostly the lid closed overnight; rework is spread thin with no single cause.

## 2026-11-19 08:20:29 Codex reviews when Claude has no quota (the user, 2026-11-19: "Make sure that the reviews are happening through Codex especially when there's no quota"). When the verifier's Claude model is held back at a usage limit, audits run on Codex instead of waiting, sensitive ones included. The verdict is marked as Codex's, and each sensitive-path merge made on a Codex verdict gets a follow-up Claude audit after the reset. Task audits-run-on-codex (after sensitive-audits-fall). This supersedes "Codex never reviews", but only as a fallback: when Claude has quota, Claude reviews.

Eight finished tasks sat 7–11 h waiting on Fable's limit (resets Nov 24) while Codex had 86% of its week left. The follow-up Claude audit keeps a second-model check on the guard rails without blocking delivery.

## 2026-11-19 11:02:14 the-config-seal-is: a passing merge test run that survives a config-seal hold is kept in the tool server's memory only. It is bound to the exact base and branch heads it tested, and it is lost on restart (option b, of the worker's three). No durable pass receipt.

A durable pass sealed with the lead's seal could be forged from the lead's shell to skip a merge's test run, a new way past the gate. Keeping it in memory meets the contract (it survives a seal hold) without adding anything forgeable, and a restart only costs a rerun.

## 2026-11-19 13:02:39 audits-run-on-codex: the lead may close a pending post-merge Claude re-audit that can't be audited (branch gone, verifier keeps ending) only through cleanup(task, force: true, reason:). The reason must cite something checkable, it is screened by the record lints, and the close is recorded as "closed by the lead", never as passed. Not vetoed.

Without it, an unauditable obligation would block cleanup forever. The change it tracks is already merged, so closing it removes no gate, and the waiver is explicit, has a reason and is visible on the record, like dismiss_finding.

## 2026-11-19 15:09:00 From the 2026-11-19 retrospective: (1) Root-cause and debugging tasks go to Claude (agent: claude, advisor fable), never auto or Codex. (2) Never delete the build output of a task waiting for review to free disk. new-work-waits-when now holds new starts instead; free disk elsewhere first. (3) The lead files vs-shell commands with the whole command line as one quoted argument, never through `zsh -c` with separate words.

(1) merge-reruns-only-what's Codex round failed 3 Important findings on root cause, and the Claude round fixed them. (2) Deleting 16 GB of build output made 8 reviews rebuild from scratch at load 60–110. (3) The first install card ran `zsh -c security` with no arguments and failed.

## 2026-11-21 15:56:14 Memory growth (2026-11-21): no fix task. The lead read the footprint-relief lines in app.log for Nov 19–21: it isn't a leak. Malloc in use stays level at about 120–170 MB with 27 sessions, and the footprint moves between about 250 and 420 MB with activity and comes back down; what stays is 150–200 MB of freed malloc-small memory that macOS keeps for reuse after busy peaks. File a root-cause task (agent claude, advisor fable) only if malloc in use keeps climbing across a day, or the footprint settles above about 500 MB, or the Mac's memory pressure leaves normal with the app among the top users.

Two leads promised the user to read the memory log and file "the real fix". The log shows the "+5 MB an hour" trend is the allocator holding freed pages after peaks, not memory in use growing: in use was 120 MB at 27 h and 120–125 MB a day later. Nine memory tasks have already been spent, memory pressure is normal, and the working policy rules out another round without a concrete concern.

## 2026-11-22 09:10:26 A lead handover looks like one continuous lead to the user (2026-11-22). The handover itself stays (a fresh session at 50 idle minutes with over 150k tokens of context, and the daily/context rotation): it is kept for cost. What changes is how it shows: the old lead session ends by itself once the new lead holds the role and has finished its first turn and the old one is between turns (task a-lead-handover-keeps, audited: it ends sessions), the new lead takes its row and the selection, and the lead's chat shows the earlier sessions' conversation above one divider line, "Started a fresh lead session at HH:mm (reason)" (task the-lead-s-chat, after it). In-place compaction of the old session is not used instead.

The user dislikes seeing one lead finished and replaced by another, and asked for a single continuous session with a signal that a new lead started. Keeping the handover: a fresh lead starts near 80k tokens against 166k–411k carried by the three leads replaced on Nov 19–21, and every later turn re-reads the whole context; compaction would re-send the old context to write a lossy summary, while a fresh lead continues from the board and decisions, which are durable. The old session's terminal scrollback is lost when it ends; its transcript stays on disk and feeds the chat.

## 2026-11-23 12:31:43 From the verification article (claude.dev, Nov 2026), agreed with the user 2026-11-23: (1) a test that flakes once in a merge gets a fix task at once, and fix tasks fix the root cause or delete the test with a reason, never sleep/retry/skip (a-test-that-flakes); a merge that passes only on its rerun still merges. (2) The "naming no test" flakes are investigated as a likely double count first (a-merge-whose-tests), and this week's repeat flakers get fix tasks (fix-the-dictation-tests, fix). (3) After those: REVIEW.md rules get triggers, sources and per-rule counts for pruning (review-rules-carry-a), and the scorecard counts bugs that got past review (the-weekly-scorecard-counts). Not adopted: stacking reviewers (we keep one primary verifier by default), a commit gate (merge already requires a review and stamps VS-Review).

Merge health misses its objectives (12% passing only on rerun); the article names retrying flaky tests and unscoped, unpruned review rules as the failure modes we have, and an escape count is the missing measure of our review.

## 2026-11-23 13:25:47 Ledger-planned flaky-test fix tasks are review audit, and one that deletes a test can't drop to review none through small_task_min (built in a-test-that-flakes).

Fix tasks may now delete a test whose root cause isn't found; without a review, one load-induced timeout could end in a deleted test merged unchecked. An audit checks that the cause is real or that the deletion's reason is written down. Cost: one audit per flake fix (about 4–8 a week).

## 2026-11-23 14:02:00 Fix tasks for tests that were red on main too (red-on-base) are audited like flaky-test fixes. a-test-that-flakes:F1, which flags that they now get an audit and the small_task_min hold, is intended, not a defect.

A red-on-base fix changes a failing test just as a flake fix does and can weaken or delete it; the same review keeps that honest. They are rare (0 in the last 7 days), so the cost is negligible.

## 2026-11-23 18:07:09 From the 2026-11-23 retrospective (verification plan): (1) Before filing a flaky-test fix task by hand, the lead checks `git log --since=<flake time> main -- <the test's file and the code it exercises>` for a fix that landed after the flake; if one did, no task (task fix found 5743c865 had already fixed it, after a worker's 0.3 h). (2) To settle an Important finding as intended, the lead dismisses it and leaves the worker running for auto_advance to merge, never stop_worker first: stopping it set the task blocked, so auto_advance didn't merge it and the lead had to merge by hand. (3) At the next decisions archive (after Fable's reset, Nov 25), the lead also reads status's review-rules line: R13's trigger matched every eval case and drew 3 false alarms, R2 matched none; narrow or prune from the 30-day counts, not from one eval run.

Each is a setback from today's batch: a fix task with nothing to fix, a manual merge after a self-inflicted block, and review rules whose triggers don't yet discriminate.

## 2026-11-23 23:37:08 Tests never use UserDefaults.standard: each test keeps its settings in a Scratch.defaults suite, and a lint enforces it (task tests-keep-their, after fix-the-flaky-test-25).

fix-the-flaky-test-25 showed that an unbundled test binary's UserDefaults.standard lives in the real ~/Library/Preferences through cfprefsd, whatever the scratch HOME says, so every test process on the Mac shares it (6 of 10 EndedFoldTests runs failed under load). 19 more test files still use it, a latent cross-process flake source while merges miss their rerun objective.

## 2026-11-24 02:27:23 Memory bench churn growth: the Nov 23–24 rise was the bench's off-screen window keeping an open/close animation per cycle while the display slept (fixed in find-why-the-memory: animationBehavior .none on presentOffscreen only). The ~1.8 MB malloc rise left over 40 cycles (AppKit KVO dependency tables, SwiftUI glass display links) is not a task now.

With the fix the bench passes at 5.6–6.5 % with the display asleep, and the absolute growth left (3.2–3.7 MB) matches the daytime passes since before Nov 22, so it isn't new. File a root-cause task (agent claude, advisor fable) only if churn-growth-percent passes 8 % again on a run with the display awake, or the live app's malloc in use keeps climbing across a day (the 2026-11-21 memory decision's conditions).

## 2026-11-24 14:05:16 Commits from GitHub show the GitHub handle that pushed them: on the update card and in fetch_remote and merge_remote reports (task github-commits-name-the, audited as security). The handle comes from GitHub's record of the push, read-only through the user's gh. When the handle can't be found, the commit shows as before. Merges made on this Mac aren't in scope.

The user asked on 2026-11-24 to see who triggered an update's merge, and chose this scope (DEC96FEA). There are no PRs (direct pushes from two Macs), and git author names aren't handles.

## 2026-11-24 21:15:47 Fable's reset, 2026-11-24 21:15: verifier_model stays opus, set explicitly. It is not cleared as the 2026-11-18 22:19 entry and the handover said. Routine audits run on Opus, and sensitive and security audits on Fable (VibeSwitcher routes those to Fable whatever verifier_model says, while Fable is available). Workers stay pinned to model: opus per task (2026-11-18 12:17).

The user's answer to 99E29A76 (2026-11-18 12:17) is the standing rule: workers and routine audits on Opus, Fable only for the lead, security and sensitive audits, and hard-task advice. The later "back to Fable" answer (BD489D1B) was about the sensitive reviews only. Cleared, the setting picks the audit model from the Claude command's default (Fable), which per-task Opus pins could flip.

## 2026-11-24 22:22:58 disk_headroom_gb goes from 6 to 2, so new workers start at about 18.1 GB free instead of 22.1 GB (the user's answer to C08E0405, 2026-11-24).

22 GB was more than a single worker needs (about 3 GB for a clone and build), and it held the v2 test with nothing else of this project in flight. If finished workers start waiting on disk for their load runs again, as on Nov 18, raise it back.

## 2026-11-25 07:56:15 v2's test failures on this Mac are fixed here, in a scratch clone of GitHub's v2, as commits on a local branch plus a patch series. Nothing merges into main, and nothing is pushed without the user's say on how the commits reach v2. This lifts, for these fixes only, the earlier "don't fix v2 here" note; merging v2 into main still needs planning with the user.

The user, 2026-11-25: "fix whatever u see in v2". Most of the 13 failures are Mac-only and can only be reproduced on a Mac, which the Linux machine where v2 is developed can't do. Workers can't push, and pushing is outward-facing, so delivery stays the user's choice.

## 2026-11-25 13:41:28 The user tries v2's Mac app through a side-by-side build (their answer to 648E8D12, 2026-11-25): "VibeSwitcher v2.app" with its own name, bundle id, state root, host and Keychain names, built in a scratch clone of v2-mac-fixes (task a-side-by-side-v2). Whatever would write into a folder the installed app uses and can't be pointed elsewhere (hooks in ~/.claude) is switched off in it. Nothing merges into main and nothing is pushed. v2's real app is never launched or installed over the installed one on this Mac without the user's explicit say. The earlier task launch-v2-s-mac is kept (its worktree holds the first clone and the screenshots) until the user is finished with v2 here.

launch-v2-s-mac found that v2's real app shares the installed app's bundle id, would take over or replace its running session host, rewrites ~/.vibeswitcher/bin/vibeswitcher-hook at launch, and that the two builds drop each other's fields in board.json and vault.sealed. The sandbox is invisible by design, so it can't be used by hand.

## 2026-11-25 15:42:12 v2 on this Mac means the user's own node running here as on Linux, one version (the user, 2026-11-25): the design's milestone 5. The lead's team does the real-Mac steps of docs/superpowers/specs/2026-11-19-v2-node-on-macos.md in order, in scratch clones of v2, delivered as branches for v2 (nothing merges into main, pushes at the user's click), starting with step 4's measurements. Nothing switches on a refusal the design keeps off (approvalMeasured, isCheckedMacNode) without its measurement and an audit. The side-by-side Mac app (a-side-by-side) and the mock page are not the goal; the "scratch node" the lead offered doesn't run on a Mac (its harness is Linux-only) and is dropped.

The user said v2 should be as close as possible to Linux, one single version, run in full and operated normally. v2's design says the same (one node; the Mac last; each Mac step needs a real Mac) and its Mac node is partly built, off behind deliberate refusals, and never run on a real Mac. The refusals guard a security property (a session must not be able to approve as the user), so they are lifted by doing the design's steps, not by bypassing them.

## 2026-11-25 16:27:18 The remaining Mac parts of v2 are built on this Mac by this lead's team (the user's answer to 650522CE, 2026-11-25): each piece built and proven in a scratch clone of v2, on its own local branch from v2-mac-fixes, delivered as a GitHub branch for v2 at the user's push; nothing merges into main. The measurement branch v2-mac-step4 is pushed first so the Linux lead sees the findings. Because VibeSwitcher's audit can't see commits inside a clone, each piece that touches a security path gets a separate report-only review task by a fresh worker (advisor fable) before its branch is offered for v2, and no refusal constant (approvalMeasured, isCheckedMacNode, macUnbuilt) is switched on by a build task. Order: docs/process/v2-mac-measurements.md's table on v2-mac-step4.

v2's design puts building on Linux and checking on the Mac, but every remaining piece needs a real Mac to prove, and the user chose building here over slower round trips. Pushing the record first keeps the two leads from building the same security code. The design itself requires an independent review of each security path.

## 2026-11-25 16:27:52 Two choices of the user for v2 on the Mac (2026-11-25). (1) BCECD1F3: the command line's check that it talks to the real server (item 10) is anchored in a root-owned record: the install writes the real programs' code fingerprints where only an administrator can change them, one password prompt per install or update, nothing day to day. (2) 541E258F: approvals go through one Touch ID that allows the 'page acts for you' mode, opens the page and confirms it, after which the page acts with no prompt for up to 12 hours on loopback; a design change with a security review. This supersedes, for the page mode, the 2026-11-20 choice of Touch ID for each state change, which still holds for the command line outside it.

The anchor gates the checked start, the service wiring and two smaller checks; a root-owned record needs no paid identity and no Keychain rewriting. The user asked to authorize once rather than per command, and accepted the stated cost: during the 12 hours anything that can read the open page's secrets, a team's session included, could act as them.

## 2026-11-25 21:19:58 v2 page input (the user's answer to B4C0D428, 2026-11-25): a page may send input into every session, the user's own unconfined Claude and shell sessions included, as v1 does, on condition that each device holds its own key made at pairing (Touch ID / passkey) and every input message is checked against it. This answers the H1 plan's decision 1 (amending the design's "reply rights type only into confined sessions") and, by the lead's call, its decision 2 (device keys, as stage 4 plans, not a bearer token with a third right). The signing key for phone push lives in the host's vault (the lead's call). These are node pieces built on the Linux side: the lead writes the answers into v2's decision documents on a branch for v2.

The v1-against-v2 list (2026-11-25) ranks 'can't type into a terminal from the page' and 'the phone never acts' among the gaps that stop daily use of v2 in place of v1; the user wants v2 to do all v1 does and said to ask what's needed and go ahead. Device keys are the stronger of the two rights v2's own plan offers and match the user's choice of one Touch ID for the acting page.

## 2026-11-25 21:20:04 v2's phone page moves to HTTPS through `tailscale serve` (the user's answer to 223BB776, 2026-11-25): way B of the remote access note's decision 1, and the H1 plan's decision 4 and the push note's decision 1. The user accepted that turning on HTTPS certificates puts the machine's and the tailnet's names in public certificate logs. Built on the Linux side; written into v2's decision documents with the other answers.

Without a secure context the phone can have neither push with the page closed nor device keys, so it could never answer or type: gaps 2 and 3 of the v1-against-v2 list.

## 2026-11-25 21:20:29 v2 gets phone push with the page closed (the user's answer to 7E3F8A88, 2026-11-25): the node may post encrypted pushes to the browser vendors' push services (the app's allow-list), and the lock screen shows the first line of the card or prompt, as the open page's notification does. The user chose this over the kind-only text the lead recommended, accepting that whoever holds the phone reads that line. With B4C0D428 and 223BB776 this answers every decision the push note and the H1 plan left to the user.

Nothing telling the user anything once the page is closed is gap 2 of the v1-against-v2 list; v1 already pushes through the same vendors with content.

## 2026-11-25 21:56:27 v2 direction from the user (2026-11-25): having to go to a terminal is bad UX. In v2 nothing the user does day to day needs a terminal: every action the page shows as a `vibeswitcher …` line to paste becomes a button on the page, on the desktop and on the phone, authorised by the device's key (Touch ID on the Mac, a passkey elsewhere), not by a typed code in a shell. The command line stays as a second way in, never the only one. The terminal may be needed at most once, for the install and the first pairing, and the lead looks for a way to drop that too. The lead inventories every terminal-only step (task v2-every-step) and turns it into tasks: page-only ones built by this Mac's team, node-side ones written up for the Linux side.

The user's words: "in general i think having to go to the terminal is a shit UX". The v1-against-v2 list ranks 'the page acts only after terminal steps, and the phone never acts' among the gaps that stop daily use; v1 needs no terminal for any of it. This extends the same day's answers (page input into every session with a device key, HTTPS for the phone, push).

## 2026-11-25 22:01:01 v2's quality bar and the remaining remote-access choices, decided by the lead at the user's word (2026-11-25: "think carefully about the UX and the security of the system - this needs to feel like a good/apple app"). The bar: v2's page must feel like a well-made native app: no terminal day to day, biometrics instead of typed codes, no commands, hashes or internal names where a person reads, safe defaults that need no setup, and every action says what happened. The choices: (1) A device is paired once, with its own key (passkey; Touch ID on the Mac), and stays paired until the user removes it from a Devices list on the page; opening the page after a while asks for Face ID / Touch ID and that unlock lasts 12 hours, on the phone as on the Mac. This replaces the 8-hour token that needs a new pairing from a terminal (the remote note's decision 2). (2) Credentials (tokens, keys, passwords) are masked on every remote page, as v1's phone does, before any phone is left paired (decision 3). (3) A second, invisible check: a remote peer's Tailscale login must be the machine's own (decision 4). (4) A phone is added by scanning a QR code shown on the already-unlocked page (This node › Devices › Add a phone), not drawn in a terminal (decision 5). (5) The phone may watch and type into a session's terminal once device keys and HTTPS are built, not before (decision 6). (6) The port stays 47830 (decision 7). (7) The page on the same machine keeps acting as today until device keys are built, then requires the device's key; on the Mac that is the single Touch ID. The lock screen's text follows the user's earlier answer (the first line), and the phone's own 'hide previews when locked' setting still applies on top.

The user said they didn't know the seven proposals and left them to the lead with that bar. Each choice is the one a person never has to think about and that tightens rather than loosens: a per-device key with biometrics is both stronger than a bearer token and less work than re-pairing; masking and the login check cost the user nothing; a QR on the page removes a terminal step, in line with the same day's 'no terminal' direction. Reversible: none is built yet, and each is a line in v2's decision documents.

## 2026-11-25 22:09:24 This Mac's team builds most of v2's remaining pieces, not only the Mac-specific ones (the user, 2026-11-25: "i think you can build most from here"): the page, and the node pieces the day's decisions need (device keys at pairing and the per-message check, the Devices list and QR pairing, page input into sessions, HTTPS for the phone, push, masking on remote pages, a new-project request, the node's texts as keys the page translates), each in a scratch clone of v2 on its own branch, delivered as a GitHub branch for v2 at the user's push, nothing merged into main. Security pieces keep a separate report-only review before they are offered, and no refusal constant is switched on by a build task (2026-11-25 16:27). Linux can't be built or run on this Mac: every node branch says which parts were proven here (shared code and the Mac's arm, by tests) and which Linux paths were only read, and the decision documents are pushed first so the Linux lead doesn't build the same things. This widens the 2026-11-25 16:27 decision (the Mac parts) and replaces the lead's earlier plan to only write node pieces up for the Linux side.

The user wants v2 to do everything v1 does and more, without a terminal and at the quality of a well-made native app, and prefers building here over round trips. The cost is that Linux behaviour is unverified from this Mac, so each branch states it and the Linux side's CI stays the check.

## 2026-11-25 22:19:31 v2 without a terminal: the lead's calls on the inventory's open decisions (docs/process/v2-no-terminal.md on branch v2-no-terminal, 2026-11-25), under the user's bar of the same day (careful about UX and security; feels like a good Apple app). N1: guarded changes (update and rollback, hooks, a first config accept and changed rails, policy, review floors and models, adding a plugin) can be approved on a page that holds a device key, with Touch ID / Face ID on each one and the change shown before the prompt; on the desktop and on the phone; never by the 12-hour unlock alone. N2: on Linux the first browser is confirmed in the install line's own terminal, so there is no second trip. N3: the node starts at login by default. N5: the node sets `tailscale serve` itself, on the user's click on 'Turn on phone access', showing what it changes and undoing it on 'Turn off'. N6: the journal is acknowledged from a device-key page, recorded as the user's. N7: the desktop's loopback page may hold a passkey (answering on `localhost` as well as 127.0.0.1), subject to the security review of the Host and Origin checks that go with it; if that review says no, Linux's desktop keeps the terminal pairing and the Mac uses Touch ID. N8: Claude Code's self-update switch follows N1. N4 (a distributed, signed build: a Mac app or installer and a one-line Linux install) is asked of the user: it costs a paid Apple developer identity and distributes binaries. Build order as the document gives it: the 11 page-only items, then the node's kinds and values, then the device-key track, each security piece with its own independent review.

The inventory found 42 terminal steps in v2 against none in v1, and that 'nothing day to day' is reachable only if guarded changes can be approved with biometrics on the page. A per-change biometric with the change shown is the pattern a person already knows from their phone and is stronger than a typed code a session could read; keeping these out of the 12-hour unlock keeps the day's one accepted exposure from reaching the root of trust. N1 is the choice that most deserves the user's eye; it was reported to them as such.

## 2026-11-25 22:20:45 v2 is not shipped as a signed app for now (the user's answer to ADE896BB, 2026-11-25): it keeps being built from source on each machine; setup keeps a few terminal lines, and day-to-day use has none. No Apple Developer ID, no published binaries. This answers the no-terminal inventory's N4; revisit when day-to-day use is terminal-free and setup is what's left.

The user chose 'Later'. Setup happens once per machine; the day-to-day steps are where the cost is.

