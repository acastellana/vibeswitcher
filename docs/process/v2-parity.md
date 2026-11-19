# V1 and V2: what each one does

V1 is the Mac app on `main` (`Sources/VibeSwitcher`, with the shared engine in `Sources/VibeCore` and
`Sources/VibeHost`). V2 is the Linux node on `v2` (`Sources/VibeNode`, the `vibeswitcher` command line in
`Sources/vibeswitcher-cli`, the web page in `WebApp/`, the Linux parts in `Sources/VibePlatform` and the `V2` folders).
This table compares them feature by feature, so gaps get found on purpose and not by accident.

Checked against `origin/v2` at `5b6eccd9` (2026-11-19), by reading the node's code, not only its plans. Work still on
other branches (the web terminal, chat sending and answering lanes, the sandbox's launcher) isn't counted. A feature
that works through shared code counts only if the node actually calls it. Anything not checked end to end says
**unverified**.

## Summary

Of 101 features: **30 has it**, **15 partly**, **41 missing** (one of them, Codex workers, on purpose), **8 not needed on
Linux**, **6 Linux-only new**, **1 unverified**.

The gaps that matter most for daily use, worst first:

1. **You can't type to a session.** The web page has no working composer (the node doesn't accept `send`), so you can't
   message or steer a session. The only way to talk to an agent is `vibeswitcher tell FOLDER TEXT`, and only to a lead.
2. **No live terminal** on your node. The web terminal exists only on a scratch test server.
3. **You can't start or end an ordinary session.** There's no new session, new shell or launch preset, and no
   End Session. The node runs only leads and their teams. `stop` ends everything.
4. **No board view.** A lead's tasks, decisions, scorecard and messages between leads aren't shown anywhere (no
   command and no web tab). You'd have to read `board.json` yourself.
5. **No notifications.** No banner, sound or reminder when a session needs you or finishes.
6. **You can't answer a session's own prompt.** Permission prompts and Claude's own questions can't be answered. Only
   the lead's cards can.
7. **The lead ignores `lead_model` and `lead_advisor`**, so it runs on Claude's default model (owed since the
   2026-11-17 merge).
8. **`push_remote` does nothing on a node.** The request is recorded, but no Push button or command acts on it.
9. **No settings.** Limits, Ignore usage limits, the working policy, Boost and leads messaging each other can only be
   changed by editing files by hand. Running leads aren't told when the policy changes.
10. **Restarts lose work.** Nothing records the open sessions or reopens a lead with `--resume` after the machine
    restarts. Rotation is only the cold idle handover.
11. **No phone or remote access** (planned for stage 7). The web page is reachable on `127.0.0.1` only.

## The table

States: **has it**, **partly**, **missing**, **not needed** (on Linux), **Linux-only** (V2 has it and V1 doesn't).
Sizes to close: S is about a day, M a few days, L a week or more.

### Sessions and terminals

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| A session host that keeps sessions running, and hands them to a new build | `Sources/VibeHost`, `Sources/VibeSwitcher/HostClient.swift` | has it | `Sources/VibeNode/Host/HostLink.swift`; the host runs under the node (`vibeswitcher start`) | | V2 always hands over and never replaces the host |
| Start a new Claude, Codex or shell session (⌘N, ⌥⌘N, `--new`) | `MainWindow/MainWindowController.swift`, `Launcher.swift` | missing | no request type, command or page starts a session that isn't a lead | L | the host can do it; needs a request, a voice rule and a client |
| Launch presets (per folder, environment, keep a shell open) | `SettingsWindow.swift`, `Sources/VibeCore/LaunchPresets.swift` | missing | no caller on the node | M | the shared code builds on Linux |
| End a session (End Session…, Close Finished Shells) | `MainWindow/SessionListView.swift` | missing | only `stop` (ends every session) and the role sweep (ends finished team members) | S | |
| Pause, rename, reset a session's name | `MainWindow/SessionListView.swift`, `Sources/VibeCore/Pausing.swift` | missing | names are automatic only (`SessionNaming` in `Stores/NodeSessions.swift`) | S | |
| Live terminal: type, select, find, scrollback, text size | `MainWindow/TerminalPane.swift` | partly | `Sources/VibeNode/Live/TerminalRelay.swift` exists, but only a scratch server enables it (`--test-web-terminal`). Your node answers `term.open` with `unknown-kind`, and the page says "comes in a later build" | L | another lane is building it |
| Terminal look: theme, font, cursor, ANSI colours, Option as Meta, bell | `SettingsWindow.swift` (Appearance), `Sources/VibeCore/TerminalAppearance.swift` | missing | needs the terminal first | M | the page follows the system's light or dark (`?theme=`) |
| Sessions in other terminals: listed and readable | `SessionStore.swift`, `Sources/VibeCore/SessionScanner.swift` | has it | `Stores/NodeSessions.swift`: listed with `hosted: false`, and never typed into | | |
| Terminal.app control: Open in Terminal, `--focus`, Move to Window | `TerminalBridge.swift`, `TabOrder.swift`, `Sources/VibeCore/MoveToWindow.swift` | not needed | there's no Terminal.app on Linux (design non-goal) | | |
| Ended sessions: resume, copy the resume command or session id | `MainWindow/StartPage.swift`, `SessionListView.swift` | missing | the agent's session id isn't on the wire yet (`WebApp/README.md`, "Asked of the node") | S | |
| Reopen sessions after the machine restarts (the restart card, a lead `--resume`d) | `RestartCard.swift`, `Sources/VibeCore/RestartReopen.swift` | missing | owed in the port map: "nothing offers them back" | M | |
| Status detection: hooks, OSC 7501, titles, the process table | `SessionStore.swift`, `Sources/VibeCore/StatusRules.swift` | has it | `Stores/NodeSessions.swift`, `Sources/VibeHost/V2/ParserReplies.swift` (automatic) | | titles only for sessions the host runs |
| Background shells shown on a session | `SessionStore.swift` | has it | `Stores/NodeSessions.swift` | | |

### The switcher, sidebar and attention

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| The session list with its states (needs you, working, background, done, idle) | `MainWindow/SessionListView.swift`, `Sources/VibeCore/Attention.swift` | has it | `vibeswitcher status`; the web sidebar (`WebApp/js/views/sidebar.js`), live | | |
| Group by attention or by project, filter | `MainWindow/MainMenu.swift` | has it | the web page (`WebApp/js/ui.js`), ⌥F | | |
| Next needing you (⌘J), sessions 1–9, next and previous | `MainWindow/MainMenu.swift` | has it | the web page's keys (`WebApp/README.md`, Keys) | | ⌥ in place of ⌘ where the browser keeps ⌘ |
| Command palette (⌘K) | `MainWindow/CommandPalette.swift` | partly | `WebApp/js/views/palette.js`: jumps to sessions and view commands. There's no "New … in …" or "Start Project Lead in …" | S | needs starting sessions first |
| Start page: recent projects, ended sessions, Choose Folder | `MainWindow/StartPage.swift` | partly | `WebApp/js/views/start.js`: what needs you, and the keys. Nothing can be started from it | M | |
| Inspector: Overview, Activity, Team | `MainWindow/InspectorView.swift` | partly | `WebApp/js/views/inspector.js`. Missing: branch, pid, command, size, exit status, tokens and cost, the Team tab's tasks | M | the fields are listed in `WebApp/README.md` |
| A finished session counts as seen once you look at it | `SessionStore.swift` | missing | `Stores/NodeSessions.swift`: "nothing acknowledges a finished turn", so it stays `done` | S | made sense when nobody looked at a node; the web page does now |
| Menu bar dots and popover | `PopoverView.swift`, `Sources/VibeCore/MenuBarDots.swift` | not needed | design non-goal | | |
| Sidebar mode, auto-hide, Spaces, global hot key, `--toggle`, minimize on pause | `Sidebar.swift`, `Spaces.swift`, `HotKey.swift` | not needed | design non-goal (macOS only) | | |
| Statistics window | `Statistics/` | missing | "later" in the design's parity table | L | the model is in VibeCore |

### Chat and composer

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Read a conversation: prompts, replies, folded tool calls, diffs, to-dos, paged history | `MainWindow/Chat/ChatView.swift`, `ToolViews.swift` | has it | `Sources/VibeNode/Live/ChatStore.swift`; `WebApp/js/views/chat.js`, live, with `chat.page` | | |
| Team messages between the lead and its workers | `MainWindow/Chat/TeamMessageCard.swift` | has it | chat items of type `team` (`Live/ChatValue.swift`, `chat.js`) | | |
| Images in the chat | `MainWindow/Chat/ToolViews.swift` (image viewer) | partly | only the type and size are shown, because the node serves no image bytes (`chat.js`) | S | |
| Composer: send, steer while working, queue, `/` commands, `@` files, pasted images | `MainWindow/Chat/ComposerView.swift`, `ComposerOutbox.swift` | missing | the page's composer is built but hidden. The node doesn't accept `send` (`Server/NodeWire.swift`'s `taken`) | L | another lane is building it |
| Answer a session's own permission prompt or question (⌘1–9 card) | `MainWindow/Chat/ChatView.swift` | missing | `ask.answer` isn't accepted. Only the lead's cards can be answered | M | |
| Find in the chat, Export Chat, Copy as Markdown, Edit in Composer, Send Again | `MainWindow/Chat/ChatView.swift` | missing | not in `chat.js` | M | the browser's own find works on the rows drawn |
| "New since you looked" marker and summary | `MainWindow/Chat/ChatView.swift` | missing | not in `chat.js` | S | |
| Run a code block (type it into the session after you confirm) | `MainWindow/Chat/ChatRunner.swift` | missing | needs the composer | M | |
| The all-done card (a batch's summary and receipts) | `MainWindow/Lead/AllDoneWatch.swift`, `Chat/AllDoneCard.swift` | missing | owed in the port map | S | |
| Push-to-talk dictation | `Dictation/` | missing | "later" in the design | L | |
| Chat text size (⌘+ ⌘− ⌘0) | `MainWindow/Chat/MarkdownView.swift` | not needed | the browser zooms | | |

### The project lead

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Start a lead in a folder, with a goal | `MainWindow/Lead/LeadController.swift`, `--lead` | has it | `vibeswitcher lead FOLDER [--goal] [--take-head] [--replace]`; `Engine/LeadStart.swift` | | refuses a folder that isn't a repository or has no commit, where V1 offers to make one |
| New Project… (make a repository, start its lead) | `MainWindow/NewProject/NewProjectSheet.swift`, `Sources/VibeCore/ProjectCreation.swift` | missing | no caller | S | |
| Message a running lead, or send it a goal | `LeadController.swift`, `--lead --goal` | has it | `vibeswitcher tell FOLDER TEXT`, `lead FOLDER --goal`; `Engine/Delivery.swift`, `Engine/Tell.swift` | | |
| Questions to you, proposed answers on a timer, Hold | `LeadController.swift`, `MainWindow/Lead/LeadViews.swift` | has it | `vibeswitcher questions`, `answer CARD`, `hold CARD`; `Engine/Answers.swift`, `Stores/CardStore.swift`; the web page shows the cards | | |
| Answer a card with one click | `MainWindow/Lead/LeadViews.swift` | partly | the web page leaves a draft and shows the `vibeswitcher answer CARD` line to confirm it in a terminal | | on purpose: a web page is never the user's voice (LW-D6) |
| Approve a merge (the approval is recorded in the vault) | `LeadController.swift` | has it | approval cards in `Engine/Answers.swift` | | |
| The board: tasks, decisions, scorecard, answered questions, files | `MainWindow/Lead/TeamViews.swift`, `TeamRows.swift` | missing | no command shows it. The web Team tab says "the board's tasks come in a later build" (`inspector.js`), and the node streams no `boards` collection (`Server/NodeLive.swift`) | M | |
| Workers, verifiers, audits, the merge gate, the risk check, revert, provenance, auto_advance | `Sources/VibeCore/LeadToolset.swift` (shared) | has it | the lead's tool server `vibeswitcher-mcp` runs on the node (`Sources/VibeCore/V2/RoleProgram.swift`); proved by the full scratch team run (`docs/process/v2-linux-inventory.md`, S10) | | |
| Codex workers, `agent: auto` routing to Codex | `LeadToolset.swift`, `docs/guide/project-lead.md` | missing | turned off with `VIBESWITCHER_CODEX_WORKERS=0` (`Engine/LeadStart.swift`) | | on purpose: security decision 15 |
| The lead's own model (`lead_model`, `lead_advisor`) | `LeadController.swift` `leadRun` | missing | `LeadLaunch.prepare` is called with no model (`Engine/LeadStart.swift`) | S | owed in the port map since 2026-11-17 |
| The witness: stalls, the room watch, the role sweep, declining stuck prompts, the disk watch | `LeadController.swift`, `RoleSweep.swift`, `PromptDecline.swift` | has it | `Engine/Witness.swift`, `RoomWatch.swift`, `RoleSweep.swift`, `PromptDecline.swift` (automatic) | | |
| Rotation: a fresh lead when the context is large | `LeadController.swift`, `Sources/VibeCore/LeadRotation.swift` | partly | only the cold idle handover (`Engine/IdleHandover.swift`). Missing: asking a warm lead for its own note, and the "Start a fresh lead session" setting | M | |
| A server or host restart: the lead rebound, held messages kept | `LeadController.swift` | has it | `Engine/Restarts.swift`; `status` says how the host ended | | |
| The config seal and Accept cards | `MainWindow/Lead/ConfigHolds.swift` | has it | `vibeswitcher config held [--diff]`, `config accept CARD`; `Stores/ConfigHoldStore.swift` | | |
| Base moves (a base moved outside the lead) | `MainWindow/Lead/BaseMoves.swift` | has it | `vibeswitcher base show/accept/keep`; `Stores/BaseMoveStore.swift` | | V1's typed `!` lines wait for a composer |
| Push to the remote (`push_remote`, then your Push click) | `MainWindow/Lead/PushRequests.swift` | missing | the tool records the request, but nothing on the node offers or does the push | M | owed in the port map |
| Fetch from and merge the remote (`fetch_remote`, `merge_remote`) | `LeadToolset.swift` (shared) | unverified | shared tool, so it should work, but no node run has used it | | |
| Leads messaging each other (`tell_lead`), and the "Between leads" view | `LeadToolset.swift`, `MainWindow/Lead/LeadMailViews.swift` | partly | the messages work (shared tool, delivered by `Engine/Delivery.swift`). There's no view, and no control to turn it off | S | |
| The prompt-audit reminder | `MainWindow/Lead/PromptAuditDesk.swift` | missing | owed in the port map | S | |
| `small_task_min` drops a review for tiny work | `LeadController.swift` `noteWorking` | partly | the engine never tells the vault which sessions it saw working, so no review is ever dropped | S | the safe side; owed |
| Fable held back: halted workers restarted on Opus | `LeadController.swift` `WitnessWork` | has it | `Engine/WitnessWork.swift` | | |
| AI summaries of what each agent is doing | `MainWindow/Lead/TeamSummaryModel.swift`, `Sources/VibeCore/TeamSummaries.swift` | missing | no caller | M | |
| Records: progress, decisions, incidents, redaction, the board's archive | `LeadToolset.swift` (shared) | has it | the lead's tool server | | |
| Your working policy, and leads told when it changes | `WorkingPolicySettings.swift`, `Sources/VibeCore/WorkingPolicy.swift` | partly | read from `~/.vibeswitcher/policy.md` when a lead starts (`Engine/LeadStart.swift`). No editor, and running leads aren't told of a change (the policy watch is owed) | S | |
| The review rules floor | `ReviewFloorSettings.swift`, `Sources/VibeCore/LeadReviewFloor.swift` | partly | the floor that workflow.md proposes is recorded by `config accept` (`Stores/ConfigHoldStore.swift`). There's no per-project floor editor | M | on purpose in part: the floor is accepted with a typed code |

### Accounts, usage limits and performance

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| The account's usage, read from the roles' status line | `Sources/VibeCore/AccountUsage.swift` | has it | the status line reaches the roles through the door (`Sources/VibeCore/V2/Door/Porter.swift`) | | |
| Workers and audits held back at 80 % of a limit | `LeadToolset.swift` (shared) | has it | the lead's tool server | | |
| Usage shown to you (review rows waiting on a limit) | `MainWindow/Lead/TeamRows.swift` | missing | the engine reads no usage (the account watch is owed) | M | |
| Ignore usage limits | `MacLimitsSettings.swift` | partly | honoured if `ignoreUsageLimits` is set in `~/.vibeswitcher/mac-limits.json` by hand | S | |
| Machine-wide limits: team sessions, load, test and build slots, memory | `MacLimitsSettings.swift`, `Sources/VibeCore/MacLoad.swift` | partly | enforced (`Engine/RoomWatch.swift`, the tool server), on defaults unless the JSON is edited | S | memory pressure and swap are read on Linux (`VibePlatform/Host+Linux.swift`) |
| Boost | `BoostWatch.swift`, `MainWindow/BoostMark.swift` | missing | nothing writes `boost.json` on a node | M | the design says Automatic acts as Off on WSL |
| Heavy-job slots (`vs-heavy`) | `Sources/VibeCore/TestLock.swift`, `HeavyJobs.swift` | has it | the command folder is on the sessions' PATH (`Sources/VibeHost/V2/HostImages.swift`) | | |
| Battery hold, keep the machine awake, the sleep's cost | `KeepAwake.swift`, `PowerReading.swift`, `Sources/VibeCore/PowerSource.swift` | missing | nothing on the node writes the power state, so the battery hold never applies; keep-awake is owed | M | WSL has nothing to keep awake |
| Memory benches, malloc relief, hang watchdog, UI benches | `MallocMode.swift`, `HangWatchdog.swift`, `UIBench.swift` | not needed | they measure the app's own process | | |

### Hooks, status line, config seal and git guards

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Install and remove the hooks for Claude and Codex | `AppDelegate.swift` `HookSetup`, Settings › Agents | has it | `vibeswitcher hooks install|remove [--agent]`; `Server/HooksRequest.swift`, sealed after a typed code | | each config is checked first (`Sources/VibeCore/V2/HookInstallCheck.swift`) |
| Trust VibeSwitcher's hooks in Codex automatically | `CodexTrust.swift` | missing | the command line tells you to trust them in Codex's `/hooks` | S | |
| The status line for the lead, workers and verifiers | `Sources/VibeCore/LeadLaunch.swift`, `vibeswitcher-mcp --status-line` | has it | through the door (`Porter.swift`) | | |
| Git guards: refused git options, deny rules, the read-only command hook | `Sources/VibeCore/RefusedGit.swift`, `ReadOnlyCommand.swift`, `LeadLaunch.swift` | has it | the node launches through the shared `LeadLaunch.prepare` | | |

### Notifications and sounds

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Banners when a session needs input or finishes | `AppDelegate.swift`, Settings › Notifications | missing | there's no browser Notification code in `WebApp/` | M | planned "through the browser" |
| A sound when a session needs input | Settings › Notifications | missing | | S | |
| Reminders about waiting or stuck sessions | Settings › Notifications, `Sources/VibeCore/AlertRules.swift` | missing | `AlertRules.baseMoved` is the only alert, shown as a `status` notice | S | |
| Phone push notifications | `Sources/VibeCore/WebPush.swift`, `Web/sw.js` | missing | stage 7 | M | |

### Updates and install

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Check for Updates, the update card | `UpdateChecks.swift`, `UpdateCard.swift`, `Sources/VibeCore/AppUpdateWatch.swift` | missing | you build and install by hand (`scripts/install-node.sh`), then `vibeswitcher switch` | S | releases are stage 8 |
| Install | `scripts/build-app.sh --install` | Linux-only | `scripts/install-node.sh`, `install-record`; `vibeswitcher start` (a systemd user unit, `Start/NodeUnit.swift`) | | |
| Switch between builds and roll back, keeping the sessions | — | Linux-only | `vibeswitcher switch COMMIT`, `rollback`; `Server/SwitchRequest.swift`, `Start/SwitchPlan.swift` | | |
| Open at login | Settings › General (ServiceManagement) | has it | `vibeswitcher start --at-login` | | |
| First-run setup, installing Claude Code and tools | `Onboarding.swift`, `ToolInstaller.swift` | partly | `start` and `lead` refuse and name what's missing (`Start/StartPreflight.swift`, `Engine/NodePreflight.swift`). Nothing is installed | | agents install nothing |
| Restart Session Host | `HostRestart.swift` | has it | `vibeswitcher stop`, `start`; `switch` hands over | | `stop` asks for a typed code and says how many sessions end |

### Remote and web

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Phone access over Tailscale: pairing, replies, key presses, answers, Chrome access | `PhoneAccess.swift`, `RemoteServer.swift`, `Tailscale.swift`, `Web/` | missing | stage 7. `Web/` isn't ported | L | |
| Dev pages, previews | `DevPreviews.swift`, `Sources/VibeCore/DevPages.swift` | missing | "later" in the design | M | |
| A web page for the desktop, paired with a one-time code | — | Linux-only | `vibeswitcher web [--revoke]`; `Sources/VibeNode/Web/`, `WebApp/` on `127.0.0.1` | | the page reads and drafts, never answers |

### Diagnostics and health

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Sessions and the raw hook state (`--dump`) | `AppDelegate.swift` | has it | `vibeswitcher status [--json]`, `status --probe` | | |
| Logs | `app.log`, `Sources/VibeCore/DebugLog.swift` | has it | the node's journal (`Facts/NodeJournal.swift`) and the server log (the host's stderr, the unit's journal) | | |
| The app health digest, freeze reports | `AppHealthWatcher.swift`, `Sources/VibeCore/AppHealth.swift` | missing | "later" in the design | M | |
| The developer tools notice | `Sources/VibeCore/ToolchainWatch.swift` | missing | owed ("what waits") | S | |
| What plain mode doesn't promise, said once | — | Linux-only | `Facts/NotPromised.swift`, shown by `start` and `status` | | |

### Plugins and everything else

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Shell requests (an agent asks for a shell: Run or Decline) | `Shell/`, `Sources/VibeCore/ShellAsk.swift` | missing | no caller | M | |
| Wallet requests (Wallet Manager, Passage, browser signing) | `Wallet/`, `Sources/VibeCore/Wallet*.swift` | missing | no caller | L | the design keeps only browser signing for Linux |
| Brief Me (spoken briefing) | `Briefing/` | missing | "later" in the design | L | |
| Settings (the window, its search, every tab) | `SettingsWindow.swift`, `SettingsCatalog.swift` | missing | no settings command or page. `VibePlatform/Settings+Linux.swift` keeps a settings file, but nothing lets you change it | L | |
| Projects folder | Settings › General | missing | | S | |
| Mac permissions (Automation, Accessibility) | Settings › Advanced | not needed | macOS only | | |
| App Nap, focus log, presence | `TeamActivity.swift`, `FocusLog.swift`, `UserPresence.swift` | not needed | macOS only | | |
| Wallet and passage end-to-end test | `scripts/e2e/wallet-e2e.sh` | not needed | there's no wallet on the node yet | | |

### Linux-only new

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| The user's voice: a typed code before each change | — | Linux-only | the command line's typed word (`Sources/vibeswitcher-cli/TypedWord.swift`), `Server/Voice.swift`, `NodeWire.kinds` | | every change is recorded in the vault and the journal |
| The session sandbox: shim, planner, door, egress proxy | — | partly | built (`Sources/VibeCore/V2/Sandbox/`, `V2/Door/`, `Sources/VibeHost/V2/EgressProxy.swift`, `VibePlatform/Sandbox+Linux.swift`), but nothing launches a session in a box yet: `SandboxPlanner` has no caller (SB3 is still to come) | L | |
| The host's project allow-list and hardening (parser, seccomp) | — | Linux-only | `Sources/VibeHost/V2/ProjectAllowList.swift`, `HostHardening.swift` | | |

Counts: 101 rows, counted from the third column. The sandbox row is new on Linux but counted as partly, since it
doesn't yet confine anything.

## Different on purpose and different by accident

**On purpose** (security or platform decisions; keep them):

- A web page is never the user's voice. It drafts, and a typed code in a terminal confirms (LW-D6, EN-D5).
- Every change from the command line needs a typed code, and is recorded in the vault and journal. V1 takes
  `--lead --goal` from any process and marks it "not vouched for".
- Codex workers are off on the node (security decision 15), so `agent: auto` stays on Claude.
- A lead's question card comes only from the lead's tool server's sealed post, never from `board.json` (S3). V1's
  alerts also read the board.
- The node delivers to the board's lead only when the vault binds that session to the role and the host lists it live.
  V1 trusts whatever the board names: a Mac fix owed in `docs/process/v2-mac-tasks.md`.
- `lead` refuses a folder with no repository or no commit, and installs nothing. V1 offers to make one.
- The web page listens on `127.0.0.1` only, with a pairing code good for 120 s. Phone access waits for stage 7.
- The host always hands over to a new build. V1 can also replace an outdated host and end its sessions.
- The review floor comes from workflow.md and is accepted with `config accept`, not set in a settings window.

**By accident** (candidates for bugs or owed work):

- The lead starts on Claude's default model, ignoring `lead_model` and `lead_advisor`.
- A finished session stays `done` forever, because nothing marks it seen. The web page now shows it.
- `small_task_min` never drops a review. The safe side, but not what workflow.md says.
- The limits run on defaults (10 team sessions, test and build slots at a sixth of the cores) with no way to change
  them except by hand, and the defaults aren't shown.
- The battery hold never applies on the node, because no one writes the power state.
- Running leads aren't told when `policy.md` changes.
- `push_remote` tells the lead it recorded a request that only you can push, but no client offers the push.
- The node's restart ends every session, and nothing records or reopens them.

## Keeping it current

Add this line to "How it is kept" in `docs/process/v2-port-map.md`:

- **At every merge from main and every node feature merged into `v2`**, update the rows it changes in
  [the parity table](v2-parity.md) (state, where, size), and add a row for each new user-visible V1 feature.
