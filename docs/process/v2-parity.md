# V1 and V2: what each one does

V1 is the Mac app on `main` (`Sources/VibeSwitcher`, with the shared engine in `Sources/VibeCore` and
`Sources/VibeHost`). V2 is the Linux node on `v2` (`Sources/VibeNode`, the `vibeswitcher` command line in
`Sources/vibeswitcher-cli`, the web page in `WebApp/`, the Linux parts in `Sources/VibePlatform` and the `V2` folders).
This table compares them feature by feature, so gaps get found on purpose and not by accident.

Checked again against `v2-web-fixes` at `932aeb99` (2026-11-25), which sits on v2's merge `8bc36606` of 2026-11-24,
by reading the node's code, the command line, `WebApp/` and their tests, not their plans; first checked at `5b6eccd9`
(2026-11-19). V1 is `main` as of 2026-11-25: v2 last merged main on 2026-11-19 (`cd6c4ae9`), so none of main's 48
commits since are in v2. Work on other branches isn't counted. A feature that works through shared code counts only if
the node actually calls it. Anything not checked end to end says **unverified**.

## Summary

Of 101 features: **75 has it**, **8 partly**, **3 missing** (two of them on purpose: Codex workers, and Codex's trust of the hooks), **9 not needed on
Linux**, **6 Linux-only new**, **0 unverified** (counted again from the table on 2026-11-20, `v2-stability`, after the
settings, composer, push and rotation lanes' merges and that lane's rows: reopening your own sessions after a restart, the prompt-audit reminder,
reminders about waiting or stuck sessions, New Project…, the sound, the "New since you looked" line, Between leads, the
all-done mark, rename and pause, ended sessions resumed, and Close Finished Shells; launch presets edited on the node since the page-actions lane; and on 2026-11-21, `v2-small-rows`: Check for Updates, the developer tools notice, the projects folder, and shell requests; Codex's trust of the hooks left out on purpose; the inspector, chat images and the chat's copy, export and find since `v2-web-detail`; usage shown and AI summaries since `v2-usage-summaries`; and the small rows' second round: a code block's Run, the health digest, phone access rechecked, and dev servers; and 2026-11-22's feature review of the lead, usage, hooks and diagnostics (`docs/process/v2-review-lead.md`): fetch and merge from the remote verified (A40), `lead --init`, the page's New project, `send` as the lead's input (its `!` git lines still a card, on purpose), the push reply's words, `logs`, and how the server last ended).

The gaps that matter most for daily use, worst first:

1. ~~**You can't type to a session.**~~ Closed 2026-11-20: `vibeswitcher send SESSION [TEXT]` types into a session the
   node's host started, as the composer does; the page's composer leaves the message as a draft beside the session and
   shows the line that sends it. Since the composer's lane (2026-11-20): a message sent while a question is open is
   held and typed once it closes, `/` and `@` complete on the page, and images go by path (`--image`) or pasted on
   the page. Steering a working agent through its hook since 2026-11-20 (`send --now`), and held messages kept across a
   server restart or a switch (`Server/HeldSendStore.swift`, vault-vouched).
2. **No live terminal** on your node. The web terminal exists only on a scratch test server.
3. ~~**You can't start or end an ordinary session.**~~ Closed 2026-11-20: `vibeswitcher new FOLDER [--agent claude|shell]
   [--model M]` and `vibeswitcher end SESSION`; the page shows each as a line to run. Launch presets since the
   composer's lane (2026-11-20): `vibeswitcher presets FOLDER`, `new FOLDER --preset NAME`, and the page's form lists them.
4. **No board view.** A lead's tasks, decisions, scorecard and messages between leads aren't shown anywhere (no
   command and no web tab). You'd have to read `board.json` yourself.
5. **Notifications only while the page is open** (2026-11-20). The page notifies through the browser when a card opens, a
   session's prompt waits or a lead stops, and counts what needs you in its title; `vibeswitcher questions --wait`
   blocks until a card needs you. No sound, no reminders, nothing with the page closed (stage 7's push).
6. ~~**You can't answer a session's own prompt.**~~ Closed 2026-11-20: the node reads the question on a session's
   screen into its `prompt`, `vibeswitcher reply SESSION CHOICE [TEXT]` answers it, and the page shows it as a card
   with the line that answers it. A multi-select is still answered in the session's terminal.
7. ~~**The lead ignores `lead_model` and `lead_advisor`**~~: closed 2026-11-19, the node starts its lead as the app does.
8. ~~**`push_remote` does nothing on a node.**~~ Closed 2026-11-20: `vibeswitcher push FOLDER` and
   `vibeswitcher decline-push FOLDER` settle the request; the page shows it in the lead's chat with both lines to run.
9. ~~**No settings.**~~ Closed 2026-11-20: `vibeswitcher settings [FOLDER]` shows the node's settings and a project's,
   each with its value, default, where it lives and whether it is a guard rail; `vibeswitcher set [FOLDER] KEY VALUE`
   changes one in the user's voice (typed code, recorded in the vault); the page's Settings drafts the line. Running
   leads are told when the policy changes, and a project's lead when its settings do.
10. ~~**Restarts lose work.**~~ Closed 2026-11-20: after a host restart `vibeswitcher lead FOLDER --resume` reopens a
    project's lead in its conversation, and `vibeswitcher reopen` the user's own Claude sessions in theirs. A lead's
    workers are its to start again (told which). Rotation is on the node since 2026-11-20 (workflow.md's `lead_rotation:`).
11. **Remote access reads and drafts only.** `vibeswitcher web --tailnet` (2026-11-20) opens the page on the tailnet for
    a phone, read and draft as on loopback; replies and key presses from the phone wait for H1 (what H1 needs and the
    decisions page input waits on: `docs/process/v2-h1-plan.md`, 2026-11-21).

## The table

States: **has it**, **partly**, **missing**, **not needed**, **v2-only** (V2 has it and V1 doesn't), **unverified**
(couldn't be checked end to end). Sizes to close: S is about a day, M a few days, L a week or more.

**On the Mac** says what the row waits on for someone on this Mac, where V2's own node is refused today
(`NodeSystem.macUnbuilt`): **node start** (it works on a Linux node now and needs only the node to start on the Mac:
steps 2 to 5 of [the node on macOS](../superpowers/specs/2026-11-19-v2-node-on-macos.md#the-order-of-work)), **step N**
(the step it depends on specifically: 3 the server child, 4 the voice by Touch ID, which every change waits on, 5 the
LaunchAgent, 6 the unified log, 7 the install script, 8 the seal list, 9 living beside the app), **missing everywhere**
(not in V2 on any system), **Mac piece owed** (not needed on Linux, needed on a Mac node, and in none of those steps),
**n/a**.

"Under trust" means a page on this machine's loopback, paired and its pairing confirmed in a terminal, with
`vibeswitcher set web_acts trust` (off by default, raised only from a terminal): such a page acts as you
(`Sources/VibeNode/Web/ActingPages.swift`). Every other page reads and drafts the line to run.

### Sessions and terminals

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| A session host that keeps sessions running, and hands them to a new build | `Sources/VibeHost`, `Sources/VibeSwitcher/HostClient.swift` | has it | `Sources/VibeNode/Host/HostLink.swift`; the host runs under the node (`vibeswitcher start`), a handover carries sealed copies (`VibeHost/V2/HandoverMemory.swift`) | | step 3 (server child) | V2 always hands over and never replaces the host |
| Start a new Claude, Codex or shell session (⌘N, ⌥⌘N, `--new`) | `MainWindow/MainWindowController.swift`, `Launcher.swift` | has it | `vibeswitcher new FOLDER [--agent claude\|codex\|shell] [--preset] [--model]` (`session.new`, `Server/SessionRequests.swift`); the page's Your own sessions › Start acts under `web_acts trust` (`views/drive.js` `newSessionForm`); palette "New PRESET in FOLDER". No ⌘N key on the page; the page's Start click has no test | | step 4 (voice) | was "the start page shows the line": the page starts it itself under trust |
| Launch presets (per folder, environment, keep a shell open) | `SettingsWindow.swift`, `Sources/VibeCore/LaunchPresets.swift` | has it | `vibeswitcher presets`, `new --preset`, `preset add\|edit\|remove` (`presets.edit`, `Server/PresetEditRequest.swift`); the page's New session lists them. Edit presets… on the page only drafts the lines (no page sends `presets.edit`) | S | step 4 (voice) | |
| End a session (End Session…, Close Finished Shells) | `MainWindow/SessionListView.swift` | has it | `vibeswitcher end SESSION` (refused for a lead and its team), `close-shells [FOLDER]` (`Server/ShellRequests.swift`); Run-card shells end by themselves (`Engine/ShellTidying.swift`); the page's Actions › End "Do it" acts under trust (`drive.js` `actionsStrip`), in one click with no confirmation (V1 asks); Close shells on the page is still a line | S | step 4 (voice) | was "Actions… shows the line" |
| Pause, rename, reset a session's name | `MainWindow/SessionListView.swift`, `Sources/VibeCore/Pausing.swift` | has it | `vibeswitcher rename`, `pause [--hours N\|--tomorrow\|--off]` (`Stores/SessionMarks.swift`, `Server/SessionMarkRequests.swift`); the page's Actions › Rename / the four pauses / Resume Notifications act under trust (`drive.js`), palette opens them | | step 4 (voice) | was "drafts each line" |
| Live terminal: type, select, find, scrollback, text size | `MainWindow/TerminalPane.swift` | partly | watch only: the page shows a hosted session's terminal live (`Live/TerminalRelay.swift` watch mode, `views/terminal.js`), now only on a loopback page whose pairing was confirmed in a terminal (`Web/ActingPages.swift` `watches`). **Missing**: typing into it from a page (input refused, `TerminalRelay`; waits on H1 and the user's decisions, `docs/process/v2-h1-plan.md`), find in the scrollback (no xterm search add-on in `WebApp/vendor`), ⌘+ ⌘− ⌘0 (size only in Settings › Terminal), any terminal on the tailnet page; no `vibeswitcher attach` | L | step 4 (voice), then H1 | the old row's "find is xterm.js's own" was wrong |
| Terminal look: theme, font, cursor, ANSI colours, Option as Meta, bell | `SettingsWindow.swift` (Appearance), `Sources/VibeCore/TerminalAppearance.swift` | has it | the page's own, per browser: Settings › Terminal · this browser (`js/termlook.js`, `views/termlook.js`), palette Terminal Look; `termlook.test.mjs` | | node start | each viewer picks their own |
| Sessions in other terminals: listed and readable | `SessionStore.swift`, `Sources/VibeCore/SessionScanner.swift` | has it | `Stores/NodeSessions.swift`, `hosted: false`, never typed into; the page says "in another terminal" | | node start | |
| Terminal.app control: Open in Terminal, `--focus`, Move to Window | `TerminalBridge.swift`, `TabOrder.swift`, `Sources/VibeCore/MoveToWindow.swift` | missing | nothing takes you to the Terminal.app tab of a session it lists, and nothing attaches a real terminal to a hosted one | M | Mac piece owed | was "not needed" (no Terminal.app on Linux); a Mac user leaving the app loses it; not in the Mac node's steps |
| Ended sessions: resume, copy the resume command or session id | `MainWindow/StartPage.swift`, `SessionListView.swift` | has it | `vibeswitcher resume [SESSION]` (`session.resume`, `Engine/SessionReopen.swift`), Claude and Codex; the page's Your own sessions › Ended lately has Resume (acts under trust) and the line to copy (`views/own.js`), a session's Actions › Resume its id | | step 4 (voice) | was the start page (`start.js`, gone) |
| Reopen sessions after the machine restarts (the restart card, a lead `--resume`d) | `RestartCard.swift`, `Sources/VibeCore/RestartReopen.swift` | has it | `vibeswitcher reopen [all\|SESSION…\|--forget]` (`Server/ReopenRequest.swift`), `lead FOLDER --resume` (`Engine/RestartResume.swift`); the page's project has Resume lead / Fresh lead (`project.js`, kind `lead`). The page has no reopen control for your own sessions (`session.reopen` unused in `WebApp/js`) | S | step 5 (LaunchAgent) | a preset's session reopens without its preset's variables |
| Status detection: hooks, OSC 7501, titles, the process table | `SessionStore.swift`, `Sources/VibeCore/StatusRules.swift` | has it | `Stores/NodeSessions.swift`, `Sources/VibeHost/V2/ParserReplies.swift` | | step 9 (hooks shared with the app) | titles only for sessions the host runs |
| Background shells shown on a session | `SessionStore.swift` | has it | `Stores/NodeSessions.swift` (`BackgroundWork.summary`) | | node start | |

### The switcher, sidebar and attention

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| The session list with its states (needs you, working, background, done, idle) | `MainWindow/SessionListView.swift`, `Sources/VibeCore/Attention.swift` | has it | `vibeswitcher status`; the page's left column (projects, each with its ring and line: `views/left.js`), Your own sessions (`views/own.js`), each project's team strip (`project.js`), a replaced lead marked (`ui.js` `leadMarks`). No single list of every session: team members show only under their project | | node start | |
| Group by attention or by project, filter | `MainWindow/MainMenu.swift` | partly | the left column is by project; the palette's search narrows sessions. **Missing**: grouping by attention and the filter (⌥F), removed by the redesign (`3ff1455b`, 2026-11-23: "Gone: … the list's grouping, filter and keys") | S | missing everywhere | was has it: a regression of the redesign |
| Next needing you (⌘J), sessions 1–9, next and previous | `MainWindow/MainMenu.swift` | partly | ⌘J / ⌥J goes to the next *project* with a card waiting (`app.js` `nextNeedingYou`); ⌥⌘1/2 panes, ⌥⌘0 inspector, ⌥⌘3 Team. **Missing**: ⌘J doesn't reach your own sessions that need you; sessions 1–9 and next/previous were removed by `3ff1455b` | S | missing everywhere | was has it: a regression of the redesign |
| Command palette (⌘K) | `MainWindow/CommandPalette.swift` | has it | `views/palette.js`, `app.js` `commands()`: sessions, next project needing you, panes and inspector, each project's Lead and Roadmap, the shown session's Rename/Pause/End, Find/Copy/Export chat, the places, Terminal Look, Statistics, Between leads, notifications, Start Project Lead in …, New PRESET in …. Not in it: Brief Me, Focus Terminal, Open in Terminal | S | node start | |
| Start page: recent projects, ended sessions, Choose Folder | `MainWindow/StartPage.swift` | has it | split by the redesign: `#/sessions` (new session form with Start, Ended lately with Resume) and `#/new` (New project, Start a project lead with Start lead, recent folders from `recent`, `Server/RecentRequest.swift`) in `views/own.js`. Recent folders are lines to copy, no button; Choose Folder is a text field, no picker | S | node start | was `start.js` (gone) |
| Inspector: Overview, Activity, Team | `MainWindow/InspectorView.swift` | has it | `WebApp/js/views/inspector.js` (id, pid, branch, command, size, usage; the Team tab), ⌥⌘0 | | node start | |
| A finished session counts as seen once you look at it | `SessionStore.swift` | has it | `Stores/NodeSessions.swift` `acknowledge`; the page sends `seen` after 1.5 s (`views/session.js`) | | node start | |
| Menu bar dots and popover | `PopoverView.swift`, `Sources/VibeCore/MenuBarDots.swift` | missing | nothing outside a browser tab: the tab title counts what needs you and the browser notifies while the page is open (`js/notify.js`) | M | Mac piece owed | was "not needed" (a design non-goal on Linux); a Mac user loses the always-visible status and its switch/pause/rename |
| Sidebar mode, auto-hide, Spaces, global hot key, `--toggle`, minimize on pause | `Sidebar.swift`, `Spaces.swift`, `HotKey.swift` | missing | the left column is fixed. **Missing**: a global hot key or `--toggle` to bring the switcher up. Docking, auto-hide, Spaces and minimize-on-pause stay not needed: the page is a browser tab and hosted sessions have no Terminal windows | S | Mac piece owed | was "not needed" |
| Statistics window | `Statistics/` | has it | `vibeswitcher stats [today\|week\|month] [--json]` (`Stats/StatisticsText.swift`), the page's Statistics (`views/stats.js`, `#/stats`) | | node start | |
### Chat and composer

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| Read a conversation: prompts, replies, folded tool calls, diffs, to-dos, paged history | `MainWindow/Chat/ChatView.swift`, `ToolViews.swift` | has it | `Live/ChatStore.swift`, `ChatValue.swift`, `chat.page`; `WebApp/js/views/chat.js` (folds, diffs, to-dos inside their tool call, Earlier messages paged in) | | node start | |
| Team messages between the lead and its workers | `MainWindow/Chat/TeamMessageCard.swift` | has it | chat items of type `team` (`Live/ChatValue.swift`, `chat.js`) | | node start | |
| Images in the chat | `MainWindow/Chat/ToolViews.swift` (image viewer) | has it | `chat.image` (`Live/ChatReads.swift`), `js/images.js`, opens wide on a tap | | node start | |
| Composer: send, steer while working, queue, `/` commands, `@` files, pasted images | `MainWindow/Chat/ComposerView.swift`, `ComposerOutbox.swift` | has it | `vibeswitcher send SESSION [TEXT] [--image PATH] [--when step\|now\|after\|interrupt]` (`Server/SessionSend.swift`, `SendWhen.swift`): held behind an open question and kept across a restart (`Server/HeldSendStore.swift`), steered mid-turn. On the page ↩ leaves a draft (`/` and `@` complete, images pasted, dropped or picked with +); under `web_acts trust` the draft's Send menu sends it (`drive.js` `sessionSender`), two steps where V1 has one; that Send has no test (the acting check drives the lead's box) | S | step 4 (voice) | the send ways are new since 2026-11-24 |
| Answer a session's own permission prompt or question (⌘1–9 card) | `MainWindow/Chat/ChatView.swift` | partly | `vibeswitcher reply SESSION CHOICE [TEXT]` (`session.reply`) answers it; the page shows it as a card under the chat (`drive.js` `promptCard`). **Missing**: the page can't answer it even under trust (no page sends `session.reply`, though the node allows it), no 1–9 or ↩ keys; a multi-select only in its terminal | S | step 4 (voice) | was has it: re-judged now that the page acts elsewhere |
| Find in the chat, Export Chat, Copy as Markdown, Edit in Composer, Send Again | `MainWindow/Chat/ChatView.swift` | has it | `chat.js` (⌘F / Ctrl+F, ↩ ⇧↩; Export Chat; Copy as Markdown; a prompt's Copy, Edit in Composer, Send Again as a draft), `chatops.js`, palette. Over what the page has paged in | | node start | |
| "New since you looked" marker and summary | `MainWindow/Chat/ChatView.swift` | has it | `chat.js` `newSince`/`sinceSummary`, `openingPlace`, the Latest button with its unseen count | | node start | what was seen is per browser |
| Run a code block (type it into the session after you confirm) | `MainWindow/Chat/ChatRunner.swift` | has it | `WebApp/js/runnable.js` (the app's `RunnableCommand` rules): Run leaves `! command` as the draft; `vibeswitcher send` types it, or the draft's Send under trust | | step 4 (voice) | a block whose lines only mean something together gets no Run |
| The all-done card (a batch's summary and receipts) | `MainWindow/Lead/AllDoneWatch.swift`, `Chat/AllDoneCard.swift` | partly | `Engine/AllDoneLook.swift`; `vibeswitcher status` and `board` show it; the page shows it in the lead's chat (`views/alldone.js`) and "All done" in the left column. **Missing**: nothing marks it seen any more (the redesign removed the board card and its `seen {project}`; no caller on the page or the command line), so "All done" stays | S | missing everywhere | was has it: a regression of `3ff1455b` |
| Push-to-talk dictation | `Dictation/` | partly | `WebApp/js/dictate.js`: hold the mic beside the session's composer and the lead cards' answer boxes; the browser's own speech service (Chrome: Google's), only on a secure page, off until turned on on This node. **Missing**: V1's OpenAI transcription with the project's words, Claude Code's own /voice, Hold Space, silencing the Mac (new rows below); no mic on the lead's message box | M | node start | was has it: re-judged against V1's whole dictation |
| Chat text size (⌘+ ⌘− ⌘0) | `MainWindow/Chat/MarkdownView.swift` | not needed | the browser zooms | | n/a | |

### Accounts, usage limits and performance

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| The account's usage, read from the roles' status line | `Sources/VibeCore/AccountUsage.swift` | has it | `Sources/VibeCore/V2/Door/Porter.swift` (the status line for lead, workers and verifiers), kept in `account-usage.json` | | node start | |
| Workers and audits held back at 80 % of a limit | `LeadToolset.swift` (shared) | has it | the lead's tool server (`LeadToolset.usageHold`) | | node start | |
| Usage shown to you (review rows waiting on a limit) | `MainWindow/Lead/TeamRows.swift` | has it | `Engine/NodeUsage.swift`, `UsageWaits.swift`; `vibeswitcher status`, `settings`; the page's This node and Settings, a waiting review's line in the Team tab | | node start | |
| Ignore usage limits | `MacLimitsSettings.swift` | has it | `vibeswitcher set ignore_usage_limits on`; the page's Settings sets it under trust | | step 4 (voice) | |
| Machine-wide limits: team sessions, load, test and build slots, memory | `MacLimitsSettings.swift`, `Sources/VibeCore/MacLoad.swift` | has it | enforced (`Engine/RoomWatch.swift`, the tool server); `set node_max_sessions`, `load_threshold`, `node_heavy_slots`; the page's Settings; memory pressure read on both systems (`VibePlatform/Host+Darwin.swift`, `Host+Linux.swift`) | | node start | **unverified**: whether a Mac node and the app, both running, count each other's sessions |
| Boost | `BoostWatch.swift`, `MainWindow/BoostMark.swift` | partly | `vibeswitcher set boost on` and its limits; `Engine/SettingsWatch.swift` `lookAtBoost`; the mark in `status` and the page's left column, a Boost group on This node. **Missing**: Automatic (on mains while you're away) acts as Off, and Also on battery is left out (`NodeSettings.leftOut`) | M | Mac piece owed | was has it: re-judged for a Mac |
| Heavy-job slots (`vs-heavy`) | `Sources/VibeCore/TestLock.swift`, `HeavyJobs.swift` | has it | the command folder is on the sessions' PATH (`Sources/VibeHost/V2/HostImages.swift`) | | node start | **unverified**: whether a Mac node's slots and the app's are one set |
| Battery hold, keep the machine awake, the sleep's cost | `KeepAwake.swift`, `PowerReading.swift`, `Sources/VibeCore/PowerSource.swift` | missing | nothing writes `power.json` under the node's root (`Engine/Refresh.swift`), no keep-awake anywhere in the node. A Mac node on a laptop needs the power reading, "on battery, pause lead work below" and "keep the Mac awake while the team works", or a sleeping Mac stops the team | M | Mac piece owed | was "not needed" (servers and WSL run on mains); not in the Mac node's steps |
| Memory benches, malloc relief, hang watchdog, UI benches | `MallocMode.swift`, `HangWatchdog.swift`, `UIBench.swift` | not needed | they measure the app's own process; the node has its own watchdog (the host restarts a stuck server) and benches | | n/a | |
### The project lead

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| Start a lead in a folder, with a goal | `MainWindow/Lead/LeadController.swift`, `--lead` | has it | `vibeswitcher lead FOLDER [--goal TEXT\|--resume] [--take-head] [--replace] [--init]` (`Engine/LeadStart.swift`, `Start/LeadInit.swift`); under `web_acts trust` the page's Start lead, Resume lead and Fresh lead buttons (`drive.js` `newLeadForm`, `project.js`). `--init` (a first commit) from a terminal only | | step 4 (voice); `--init` is refused under the Mac's approval rule; a project the app leads: step 9 | the page now starts a lead itself under trust |
| New Project… (make a repository, start its lead) | `MainWindow/NewProject/NewProjectSheet.swift`, `Sources/VibeCore/ProjectCreation.swift` | has it | `vibeswitcher new-project NAME [--in] [--folder] [--goal] [--no-lead]` (`vibeswitcher-cli/NewProject.swift`); the page's New project (`#/new`, `views/own.js`) drafts the line. The page can't make the project even under trust (there's no `new-project` kind), only start a lead in an existing folder | S | step 4 (voice) | |
| Message a running lead, or send it a goal | `LeadController.swift`, `--lead --goal` | has it | `vibeswitcher tell FOLDER TEXT`, `lead FOLDER --goal`; the project page's message box sends `tell` (at its next step) or `send` (now, after this turn) under trust, says when it was read and takes back an unread one (`project.js`, `Engine/Tell.swift`, `Delivery.swift`) | | step 4 (voice) | was a draft on the page |
| Questions to you, proposed answers on a timer, Hold | `LeadController.swift`, `MainWindow/Lead/LeadViews.swift` | has it | `vibeswitcher questions [--wait]`, `answer CARD`, `hold CARD` (`Engine/Answers.swift`, `Stores/CardStore.swift`); the page's question cards with their timer, and Hold as a button under trust (`cards.js`) | | step 4 (voice) | |
| Answer a card with one click | `MainWindow/Lead/LeadViews.swift` | has it | under `web_acts trust` an option's click (or its digit) answers (`cards.js` `choose`; a Blocking card waits 5 s with Undo); the node takes it as yours (`Web/ActingPages.swift`). Only on a loopback page paired and confirmed in a terminal (12 h, lost on reload); `web_acts` is off by default and raised from a terminal; a tailnet or phone page still drafts | | step 4 (voice), and the Mac's own H1 | was partly: pages act since 2026-11-24 |
| Approve a merge (the approval is recorded in the vault) | `LeadController.swift` | has it | approval cards (`Engine/Answers.swift` `recordApproval`), answered with `vibeswitcher answer CARD` or the card's button under trust | | step 4 (voice) | |
| The board: tasks, decisions, scorecard, answered questions, files | `MainWindow/Lead/TeamViews.swift`, `TeamRows.swift` | has it | `vibeswitcher board`, the `boards` stream (`Live/LiveBoards.swift`, `BoardRecords.swift`, `BoardDetails.swift`). Since the redesign: the project page (the lead's conversation of questions, results and decisions under the dial; Team, Stats and Files on the right; the roadmap) and a team session's inspector Team tab (records, results with screenshots, a task's details, between leads). A task opened on the project page shows less than the inspector does; the team wall and the Mac-wide foot (load, limits, keep awake) aren't shown | S | node start | |
| Workers, verifiers, audits, the merge gate, the risk check, revert, provenance, auto_advance | `Sources/VibeCore/LeadToolset.swift` (shared) | has it | the tool server `vibeswitcher-mcp` on the node (`Sources/VibeCore/V2/RoleProgram.swift`): all 34 of V1's tools are there. V2's copy of `LeadToolset.swift` has drifted: V1's newer arguments are missing (new rows below) | M | node start | |
| Codex workers, `agent: auto` routing to Codex | `LeadToolset.swift`, `docs/guide/project-lead.md` | missing | off (`VIBESWITCHER_CODEX_WORKERS=0`, `Engine/LeadStart.swift`); also V1's `configure codex_verifier` (Codex audits while Claude is at its limit) isn't in V2's tools | | missing everywhere | on purpose: security decision 15 |
| The lead's own model (`lead_model`, `lead_advisor`) | `LeadController.swift` `leadRun` | has it | `Engine/LeadStart.swift` `leadRun`, at a start and at the idle handover | | node start | |
| The witness: stalls, the room watch, the role sweep, declining stuck prompts, the disk watch | `LeadController.swift`, `RoleSweep.swift`, `PromptDecline.swift` | has it | `Engine/Witness.swift`, `RoomWatch.swift`, `RoleSweep.swift`, `PromptDecline.swift`; V1's disk headroom gate on new workers is a new row below | | node start | |
| Rotation: a fresh lead when the context is large | `LeadController.swift`, `Sources/VibeCore/LeadRotation.swift` | has it | `Engine/IdleHandover.swift` (daily, at 60 % context, or idle with a large one; workflow.md's `lead_rotation:`); a `send` into the lead counts as its input; the replaced lead ends by itself (`Engine/ReplacedLeads.swift`) | | node start | |
| A server or host restart: the lead rebound, held messages kept | `LeadController.swift` | has it | `Engine/Restarts.swift`, `RestartResume.swift`, `Server/HeldSendStore.swift`; `status` says how the host ended | | step 5 (LaunchAgent) | |
| The config seal and Accept cards | `MainWindow/Lead/ConfigHolds.swift` | has it | `vibeswitcher config held [--diff]`, `config accept CARD`, `vibeswitcher approve` (a batch); `Stores/ConfigHoldStore.swift`; the page's Accept and This node's Approve all under trust (`project.js`, `node.js`). Claude Code's own updates stay held (the card says what it likely is) | | step 8 (seal list) | |
| Base moves (a base moved outside the lead) | `MainWindow/Lead/BaseMoves.swift` | partly | `vibeswitcher base show/accept/keep`, `approve`; `Stores/BaseMoveStore.swift`; the page's Accept move / Keep base under trust. A move your own `!` git line made is a card too (V1 takes it without asking) | | step 4 (voice) | on purpose: a card, one click or `approve` away |
| Push to the remote (`push_remote`, then your Push click) | `MainWindow/Lead/PushRequests.swift` | has it | `vibeswitcher push FOLDER` / `decline-push FOLDER` (`Engine/PushAsks.swift`, `Server/PushRequest.swift`); the push card's Push and Decline act under trust (`cards.js`) | | step 4 (voice) | was "never pushes" on the page |
| Fetch from and merge the remote (`fetch_remote`, `merge_remote`) | `LeadToolset.swift` (shared) | has it | shared tools; a scratch node's lead fetches and fast-forwards (acceptance A40). V1 now names who pushed each GitHub commit (a new row below) | | node start | |
| Leads messaging each other (`tell_lead`), and the "Between leads" view | `LeadToolset.swift`, `MainWindow/Lead/LeadMailViews.swift` | has it | `tell_lead` (shared, `Engine/Delivery.swift`); `vibeswitcher mail [FOLDER] [--all]`; the page's `#/mail` (from the palette and This node) and a project's in the inspector's Team tab; `set lead_mail off` | | node start | |
| The prompt-audit reminder | `MainWindow/Lead/PromptAuditDesk.swift` | has it | `Engine/PromptAuditWatch.swift`: a `status` notice to type `/doctor prompt-audit` in the lead's session; `vibeswitcher prompt-audit FOLDER snooze\|off\|on`. No page control (no view sends `prompt-audit`); nothing types the command for you (V1's Run now) | S | node start | |
| `small_task_min` drops a review for tiny work | `LeadController.swift` `noteWorking` | has it | `Engine/Witness.swift` `witnessed` tells the vault what it sees at work | | node start | |
| Fable held back: halted workers restarted on Opus | `LeadController.swift` `WitnessWork` | has it | `Engine/WitnessWork.swift` | | node start | file and tests seen, not read in depth |
| AI summaries of what each agent is doing | `MainWindow/Lead/TeamSummaryModel.swift`, `Sources/VibeCore/TeamSummaries.swift` | has it | `Engine/TeamSummaryWatch.swift` (Haiku, `set ai_summaries off`): a task's line, "Decided: …", a long message's "TL;DR" | | node start | file and tests seen, not read in depth |
| Records: progress, decisions, incidents, redaction, the board's archive | `LeadToolset.swift` (shared) | has it | the lead's tool server (`progress`, `record_decision`, `record_incident`, `redact_record`, `archive_decisions`) | | node start | |
| Your working policy, and leads told when it changes | `WorkingPolicySettings.swift`, `Sources/VibeCore/WorkingPolicy.swift` | has it | `vibeswitcher set policy TEXT` (`Settings/NodeSettings.swift`); running leads told (`Engine/SettingsWatch.swift`); the page shows the line, never sets it (a guard rail) | | step 4 (voice) | |
| The review rules floor | `ReviewFloorSettings.swift`, `Sources/VibeCore/LeadReviewFloor.swift` | has it | recorded at `config accept`; `vibeswitcher set FOLDER floor_… VALUE` (`Settings/NodeSettingsSet.swift`); a page never sets a floor | | step 4 (voice) | V1's review rules with ids are a new row below |
### Hooks, status line, config seal and git guards

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| Install and remove the hooks for Claude and Codex | `AppDelegate.swift` `HookSetup`, Settings › Agents | has it | `vibeswitcher hooks install\|remove [--agent]` (`Server/HooksRequest.swift`, sealed, each config checked first); install only from a terminal | | step 9 (hooks shared with the app) | |
| Trust VibeSwitcher's hooks in Codex automatically | `CodexTrust.swift` | has it | `Server/NodeCodexTrust.swift` (2026-11-24, `5fd5e055`, reviewed): `hooks install` asks the linked Codex's `app-server` for the hooks' hashes, writes only VibeSwitcher's entries to `config.toml` and seals them only when they are alone, else holds the file | | step 9 (hooks shared with the app) | was missing on purpose: the seal bypass is answered |
| The status line for the lead, workers and verifiers | `Sources/VibeCore/LeadLaunch.swift`, `vibeswitcher-mcp --status-line` | has it | through the door (`Sources/VibeCore/V2/Door/Porter.swift`) | | node start | the door is Linux's; on a Mac the roles read it as the app's do |
| Git guards: refused git options, deny rules, the read-only command hook | `Sources/VibeCore/RefusedGit.swift`, `ReadOnlyCommand.swift`, `LeadLaunch.swift` | has it | the shared `LeadLaunch.prepare`, called by `Engine/LeadStart.swift` and `IdleHandover.swift` | | node start | |

### Notifications and sounds

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| Banners when a session needs input or finishes | `AppDelegate.swift`, Settings › Notifications | partly | `WebApp/js/notify.js`: the browser's notification when a card opens, a prompt waits, a lead stops, your session finishes, a freeze is kept; each kind's choice on This node; the tab title counts; `vibeswitcher questions --wait` for a terminal. **Missing**: anything with no page open (no notifier on the node, no push) | M | Mac piece owed | was has it: re-judged; V1's banners come whenever the app runs, the page's only while a tab is open |
| A sound when a session needs input | Settings › Notifications | partly | `notify.js`'s chime, its own toggle on This node, off by default. **Missing**: as above, only while a page is open | S | Mac piece owed | was has it: same limit |
| Reminders about waiting or stuck sessions | Settings › Notifications, `Sources/VibeCore/AlertRules.swift` | has it | `Stores/NodeSessions.swift` `reminderNotices` (in `status`) and `node.reminders` (the page's banner, "Remind me about waiting or stuck sessions") | | node start | a banner only while a page is open |
| Phone push notifications | `Sources/VibeCore/WebPush.swift`, `Web/sw.js` | missing | no service worker or push anywhere in `WebApp`; four decisions still open ([the push decision note](v2-push-decision.md)): HTTPS by `tailscale serve`, posting to the browser vendors, the VAPID key's home, what a lock screen shows | M | missing everywhere | `WebApp/js/push.js` is the lead's push request, not this |

### Updates and install

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| Check for Updates, the update card | `UpdateChecks.swift`, `UpdateCard.swift`, `Sources/VibeCore/AppUpdateWatch.swift` | partly | `Facts/UpdateWatch.swift` (`gh`, every 6 hours, the newest v2 commit both CI runs passed); `status --check-updates`; This node's Updates; `vibeswitcher update [COMMIT]` (2026-11-24, `vibeswitcher-cli/Update.swift`: install, switch and accept with one code). **Missing**: V1's changelog (V2 says only how many commits ahead) and Later; installing is a terminal command (a page never switches builds) | S | step 7 (install script) | was has it: re-judged against V1's card |
| Install | `scripts/build-app.sh --install` | has it | Linux: `scripts/install-node.sh`, `vibeswitcher start` (a systemd user unit). Mac: `scripts/install-node-mac.sh` writes the LaunchAgent through `vibeswitcher agent-plist` and prints the `launchctl` lines; untried on a real Mac, and `start` there still refuses | | step 7 (install script) | was Linux-only: V1 installs too, and the Mac arm exists now |
| Switch between builds and roll back, keeping the sessions | — | v2-only | `vibeswitcher switch COMMIT`, `rollback`, `update` (`Server/SwitchRequest.swift`, `Start/SwitchPlan.swift`; an idle worker parked); This node shows the builds and the rollback's target; from a terminal only | | step 5 (LaunchAgent) | |
| Open at login | Settings › General (ServiceManagement) | has it | `vibeswitcher start --at-login`; the Mac's agent property list sets RunAtLoad with it (`Start/NodeAgent.swift`) | | step 5 (LaunchAgent) | |
| First-run setup, installing Claude Code and tools | `Onboarding.swift`, `ToolInstaller.swift` | partly | `vibeswitcher doctor` (`Start/NodeDoctor.swift`): what the node needs, each missing piece with its command. **Missing**: one-click installs (on purpose: agents install nothing); every check is Linux's (swiftly, WSL, systemd), none for a Mac (Xcode or its Command Line Tools, Homebrew's gh, launchd) | S | Mac piece owed | |
| Restart Session Host | `HostRestart.swift` | has it | `vibeswitcher stop`, `start`; `switch` hands over; This node's Stop the node acts under trust (asks again in place); starting again is a terminal's | | step 5 (LaunchAgent) | |

### Remote and web

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| Phone access over Tailscale: pairing, replies, key presses, answers, Chrome access | `PhoneAccess.swift`, `RemoteServer.swift`, `Tailscale.swift`, `Web/` | partly | `vibeswitcher web --tailnet` (`Server/TailnetWeb.swift`, the listener now the host's: H1 is built), its MagicDNS name, 8 h tokens, `web --revoke`; the phone layout; reads everything and drafts; the chat's secrets masked (`Redaction`, `Live/CommandMask.swift`). **Missing**: anything acted from the phone (answers, replies, key presses): the tailnet page never acts, by rule (`Web/WebAccess.swift`: acting is the loopback page's only); no terminal there; Chrome access, push, a QR code, `tailscale whois` | L | node start | input no longer waits on H1, only on the rule; **unverified**: whether cards and the board are masked as the chat is |
| Dev pages, previews | `DevPreviews.swift`, `Sources/VibeCore/DevPages.swift` | partly | `Facts/DevPorts.swift`, `session.ports`: the inspector's Dev servers, each opening `localhost:PORT` on the loopback page. **Missing**: the phone's previews and Chrome access (the remote decisions); the ports are read from `/proc`, which a Mac hasn't | S | Mac piece owed | |
| A web page for the desktop, paired with a one-time code | — | v2-only | `vibeswitcher web [--tailnet\|--revoke]` (`Sources/VibeNode/Web/`), `WebApp/` on `127.0.0.1`, redesigned 2026-11-23, in English and Spanish; acts when `web_acts trust` and its pairing phrase is confirmed in the terminal | | node start | was "reads and drafts, never answers" |

### Diagnostics and health

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| Sessions and the raw hook state (`--dump`) | `AppDelegate.swift` | has it | `vibeswitcher status [--json]`, `status --probe` | | node start | |
| Logs | `app.log`, `Sources/VibeCore/DebugLog.swift` | has it | `vibeswitcher logs [--lines N] [--sessions]` (`vibeswitcher-cli/Logs.swift`): the unit's journal or the host's log file | | step 6 (unified log) | |
| The app health digest, freeze reports | `AppHealthWatcher.swift`, `Sources/VibeCore/AppHealth.swift` | partly | `Facts/NodeHealth.swift`: `status --health` and This node's Health (freezes, slow refreshes, restarts, the last failing lines by cause, how the server last ended); the page notifies a freeze. **Missing**: the freeze's stack sample | S | node start | |
| The developer tools notice | `Sources/VibeCore/ToolchainWatch.swift` | has it | `Facts/NodeToolchain.swift`, `Engine/ToolchainLook.swift`: a project's swift and node pins against the node's tools. On a Mac node V1's Xcode and Command Line Tools watch is owed | S | Mac piece owed | |
| What plain mode doesn't promise, said once | — | v2-only | `Facts/NotPromised.swift`, shown by `start` and `status` | | step 6 (unified log) | |

### Plugins and everything else

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| Shell requests (an agent asks for a shell: Run or Decline) | `Shell/`, `Sources/VibeCore/ShellAsk.swift` | has it | now a feature plugin, on by default (`Sources/VibeNode/Plugins/Shell/ShellPlugin.swift`, `vs-shell` on the sessions' PATH): a card with the folder and the whole command; `vibeswitcher answer CARD run\|decline`, or the card's Run and Decline under trust (`cards.js`, `js/plugincard.js`); its shell ends by itself once finished | | step 4 (voice) | no "open shells without asking", on purpose |
| Wallet requests (Wallet Manager, Passage, browser signing) | `Wallet/`, `Sources/VibeCore/Wallet*.swift` | partly | the node's external plugins (`plugin add\|on\|off\|remove`, `Plugins/ExternalPlugin.swift`, `PluginDesk.swift`, the signing page on its own origin: `PluginPage.swift`), tested; browser signing is the `vibeswitcher-wallet` plugin in a repository of its own (**unverified**: its code isn't in this clone; acceptance A45 is by hand). **Missing**: Wallet Manager and Passage, the Mac's three-app flow | L | missing everywhere | was has it: only the frame can be read here |
| Brief Me (spoken briefing) | `Briefing/` | has it | `vibeswitcher brief [FOLDER]` (`Server/BriefRequest.swift`); the page's Brief me under the left column, read aloud by the browser (`js/brief.js`). **Missing**: V1's ElevenLabs voice and its language setting | | node start | the page's Brief me driven against the mock |
| Settings (the window, its search, every tab) | `SettingsWindow.swift`, `SettingsCatalog.swift` | has it | `vibeswitcher settings [FOLDER] [--find WORDS]`, `set`; the page's Settings sets under trust, else drafts (`views/settings.js`). A page may never set the policy, the floors, `lead_mail`, `verifier_model`, `security_audit_model`, `max_workers`, or raise `web_acts`; the page still shows a Set button for the middle four, which the node refuses | | step 4 (voice) | |
| Projects folder | Settings › General | has it | `vibeswitcher set projects_folder PATH` (and the page under trust), used by `new-project` | | step 4 (voice) | |
| Mac permissions (Automation, Accessibility) | Settings › Advanced | not needed | the node drives its own terminals and no other app; its voice on a Mac is Touch ID, which needs neither | | n/a | owed only with Open in Terminal or a hot key on a Mac |
| App Nap, focus log, presence | `TeamActivity.swift`, `FocusLog.swift`, `UserPresence.swift` | missing | App Nap is answered by the Mac agent's `ProcessType Interactive` (`Start/NodeAgent.swift`); the focus log has nothing to log. **Missing**: presence (V1 uses it for Boost's Automatic, reminders and push only while away) | S | Mac piece owed | was "not needed" |
| Wallet and passage end-to-end test | `scripts/e2e/wallet-e2e.sh` | missing | none for the node; the wallet plugin's case A45 is by hand | S | missing everywhere | was "not needed": a wallet plugin exists now |

### V2-only

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | On the Mac | Note |
| --- | --- | --- | --- | --- | --- | --- |
| The user's voice: a typed code before each change | — | v2-only | the command line's typed word (`vibeswitcher-cli/TypedWord.swift`), `Server/Voice.swift`; every change recorded in the vault and the journal. On a Mac: Touch ID per change, built (`VoiceRule.Mode.approval`) and off until measured (`NodeSystem.approvalMeasured`) | | step 4 (voice) | |
| The session sandbox: shim, planner, door, egress proxy | — | partly | built (`Sources/VibeCore/V2/Sandbox/`, `V2/Door/`, `Sources/VibeHost/V2/SessionSandbox.swift`, `EgressProxy.swift`); branch runs are boxed. **Missing**: workers', leads' and verifiers' sessions (nothing spawns one with a box: SB3, SB11); no box on a Mac | L | Mac piece owed | unchanged since 2026-11-22 |
| The host's project allow-list and hardening (parser, seccomp) | — | v2-only | `Sources/VibeHost/V2/ProjectAllowList.swift`, `HostHardening.swift` | | Mac piece owed | Linux's host only |

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
- The web page listens on `127.0.0.1`, and on the tailnet only after `vibeswitcher web --tailnet`, each with a pairing code good
  for 120 s. A phone reads and drafts; its own input waits for H1.
- The host always hands over to a new build. V1 can also replace an outdated host and end its sessions.
- The review floor comes from workflow.md and is accepted with `config accept`; each rule is changed with
  `vibeswitcher set FOLDER floor_… VALUE`, not in a settings window.

**By accident** (candidates for bugs or owed work):

- ~~The lead starts on Claude's default model, ignoring `lead_model` and `lead_advisor`.~~ Closed 2026-11-19.
- ~~A finished session stays `done` forever, because nothing marks it seen.~~ Closed 2026-11-19: the app's seen rule,
  and the page's `seen`.
- ~~`small_task_min` never drops a review.~~ Closed 2026-11-19: the witness tells the vault what it sees at work.
- ~~The limits run on defaults (10 team sessions, test and build slots at a sixth of the cores) with no way to change
  them except by hand, and the defaults aren't shown.~~ Closed 2026-11-20: `vibeswitcher settings` shows them,
  `vibeswitcher set` changes them.
- ~~The battery hold never applies on the node, because no one writes the power state.~~ Now on purpose (2026-11-19):
  not needed on a server or WSL on mains; recorded in the table and in `Engine/Refresh.swift`.
- ~~Running leads aren't told when `policy.md` changes.~~ Closed 2026-11-20: the policy watch.
- ~~`push_remote` tells the lead it recorded a request that only you can push, but no client offers the push.~~ Closed
  2026-11-20: `vibeswitcher push` and `decline-push`.
- The node's restart ends every session, and nothing records or reopens them.

## Keeping it current

Add this line to "How it is kept" in `docs/process/v2-port-map.md`:

- **At every merge from main and every node feature merged into `v2`**, update the rows it changes in
  [the parity table](v2-parity.md) (state, where, size), and add a row for each new user-visible V1 feature.
