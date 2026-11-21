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

Of 101 features: **56 has it**, **13 partly**, **16 missing** (two of them on purpose: Codex workers, and Codex's trust of the hooks), **9 not needed on
Linux**, **6 Linux-only new**, **1 unverified** (counted again from the table on 2026-11-20, `v2-stability`, after the
settings, composer, push and rotation lanes' merges and that lane's rows: reopening your own sessions after a restart, the prompt-audit reminder,
reminders about waiting or stuck sessions, New Project…, the sound, the "New since you looked" line, Between leads, the
all-done mark, rename and pause, ended sessions resumed, and Close Finished Shells; launch presets edited on the node since the page-actions lane; and on 2026-11-21, `v2-small-rows`: Check for Updates, the developer tools notice, the projects folder, and shell requests; Codex's trust of the hooks left out on purpose).

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
11. **No phone or remote access** (planned for stage 7). The web page is reachable on `127.0.0.1` only.

## The table

States: **has it**, **partly**, **missing**, **not needed** (on Linux), **Linux-only** (V2 has it and V1 doesn't).
Sizes to close: S is about a day, M a few days, L a week or more.

### Sessions and terminals

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| A session host that keeps sessions running, and hands them to a new build | `Sources/VibeHost`, `Sources/VibeSwitcher/HostClient.swift` | has it | `Sources/VibeNode/Host/HostLink.swift`; the host runs under the node (`vibeswitcher start`) | | V2 always hands over and never replaces the host |
| Start a new Claude, Codex or shell session (⌘N, ⌥⌘N, `--new`) | `MainWindow/MainWindowController.swift`, `Launcher.swift` | partly | `vibeswitcher new FOLDER [--agent claude\|shell] [--model M]` (`session.new`, the user's voice, `Server/SessionRequests.swift`), labelled as the app's built-in Claude and Shell presets, or `--preset NAME` (the row below); the start page shows the line. No Codex | | closed for Claude and a shell 2026-11-20 |
| Launch presets (per folder, environment, keep a shell open) | `SettingsWindow.swift`, `Sources/VibeCore/LaunchPresets.swift` | has it | read from the node's `presets.json` as the app writes it (`Server/SessionPresets.swift`, `session.presets`): `vibeswitcher presets [FOLDER]`, `vibeswitcher new FOLDER --preset NAME` (shown, then bound to what was shown by its digest); the page's New session lists them, the folder's default first. A Claude preset's command must be `claude` and plain words (EN-D13); Codex refused. Edited on the node with `vibeswitcher preset add\|edit\|remove NAME [--folder FOLDER] …` (2026-11-20, `presets.edit`, `Server/PresetEditRequest.swift`; the user's voice): the node's rules kept (the reviewed variables only, no built-in's name), the rest of the file kept as it was, an edit bound to the preset shown by its digest, and taken only from the file as you accepted it (a change of anyone else's is never carried in); the seal then holds the file until `config accept`, whose card says what changed in presets (names, commands, variables by name; `config held --diff ~/.vibeswitcher/presets.json` with values, secret-looking ones masked). The page's Edit presets… drafts each line | S | closed 2026-11-20 |
| End a session (End Session…, Close Finished Shells) | `MainWindow/SessionListView.swift` | has it | `vibeswitcher end SESSION` (`session.end`), refused for a lead and its team; the session's Actions… shows the line (End), and its folder's `close-shells` line (Close shells). `vibeswitcher close-shells [FOLDER]` (2026-11-20, `Server/ShellRequests.swift`; the user's voice) lists the node's shells and ends those back at their prompt (`ShellTidy`), leaving one still running something | | it closes the node's own Shell sessions, Run cards' included (`ShellCards.swift`, 2026-11-21); nothing ends a Run card's shell by itself yet, as the app's `ShellTidier` does |
| Pause, rename, reset a session's name | `MainWindow/SessionListView.swift`, `Sources/VibeCore/Pausing.swift` | has it | `vibeswitcher rename SESSION [NAME]` and `vibeswitcher pause SESSION [--hours N \| --tomorrow \| --off]` (2026-11-20, `Stores/SessionMarks.swift`, `Server/SessionMarkRequests.swift`; the user's voice): kept by the session's keys (`SessionKeys`, so across `--resume`), shown in `status` and on the page (`name`, `pausedUntil`: greyed out, never reminded or notified of). The session's Actions… (and the palette's Rename Session…, Pause Session…, Resume Notifications) drafts each line, the Mac's four pauses (2026-11-20, `WebApp/js/actions.js`) | | |
| Live terminal: type, select, find, scrollback, text size | `MainWindow/TerminalPane.swift` | partly | watching: your node shows a session's terminal live in the page at the session's own size (`TerminalRelay` in its watch mode, on the host's `watch`, 2026-11-20); a page doesn't type into it, and says to use `vibeswitcher send`. Typing from the page waits for H1 (the host binds the web port) and is only on a scratch server (`--test-web-terminal`); select, find and text size are xterm.js's own | L | typing from a page: after H1 |
| Terminal look: theme, font, cursor, ANSI colours, Option as Meta, bell | `SettingsWindow.swift` (Appearance), `Sources/VibeCore/TerminalAppearance.swift` | missing | needs the terminal first | M | the page follows the system's light or dark (`?theme=`) |
| Sessions in other terminals: listed and readable | `SessionStore.swift`, `Sources/VibeCore/SessionScanner.swift` | has it | `Stores/NodeSessions.swift`: listed with `hosted: false`, and never typed into | | |
| Terminal.app control: Open in Terminal, `--focus`, Move to Window | `TerminalBridge.swift`, `TabOrder.swift`, `Sources/VibeCore/MoveToWindow.swift` | not needed | there's no Terminal.app on Linux (design non-goal) | | |
| Ended sessions: resume, copy the resume command or session id | `MainWindow/StartPage.swift`, `SessionListView.swift` | has it | `vibeswitcher resume [SESSION]` (2026-11-20, `Engine/SessionReopen.swift`'s ended list, `session.resume`, the user's voice): your sessions that ended lately listed with their conversation ids and the command that resumes each by hand; one started again in its conversation, checked as `reopen` checks one. The start page lists them, each with its resume line and its id to copy, and an ended session's own view shows its resume line (2026-11-20); a session's `agentSession` is on the wire | | |
| Reopen sessions after the machine restarts (the restart card, a lead `--resume`d) | `RestartCard.swift`, `Sources/VibeCore/RestartReopen.swift` | has it | the lead: `vibeswitcher lead FOLDER --resume` (`Engine/RestartResume.swift`); your own Claude sessions: `vibeswitcher reopen [all\|SESSION…\|--forget]` (`Engine/SessionReopen.swift`, `Server/ReopenRequest.swift`, 2026-11-20), each `claude --resume <id>` in its folder, the record checked as a hint; `status` offers both after a host restart | | no launch presets, no Codex sessions (a node starts none) |
| Status detection: hooks, OSC 7501, titles, the process table | `SessionStore.swift`, `Sources/VibeCore/StatusRules.swift` | has it | `Stores/NodeSessions.swift`, `Sources/VibeHost/V2/ParserReplies.swift` (automatic) | | titles only for sessions the host runs |
| Background shells shown on a session | `SessionStore.swift` | has it | `Stores/NodeSessions.swift` | | |

### The switcher, sidebar and attention

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| The session list with its states (needs you, working, background, done, idle) | `MainWindow/SessionListView.swift`, `Sources/VibeCore/Attention.swift` | has it | `vibeswitcher status`; the web sidebar (`WebApp/js/views/sidebar.js`), live | | |
| Group by attention or by project, filter | `MainWindow/MainMenu.swift` | has it | the web page (`WebApp/js/ui.js`), ⌥F | | |
| Next needing you (⌘J), sessions 1–9, next and previous | `MainWindow/MainMenu.swift` | has it | the web page's keys (`WebApp/README.md`, Keys) | | ⌥ in place of ⌘ where the browser keeps ⌘ |
| Command palette (⌘K) | `MainWindow/CommandPalette.swift` | has it | `WebApp/js/views/palette.js`: jumps to sessions and view commands; the session's Rename, Pause, End and Close Finished Shells; "New PRESET in FOLDER" for the recent folders and each one's presets (2026-11-20: the start page's form with them, and its line); "Start Project Lead in FOLDER" for the shown session's folder and the recent ones, the Mac's (2026-11-20: the start page's lead form with that folder, a goal to write, and its `vibeswitcher lead FOLDER --goal …` line) | S | closed 2026-11-20 |
| Start page: recent projects, ended sessions, Choose Folder | `MainWindow/StartPage.swift` | partly | `WebApp/js/views/start.js`: what needs you, and the keys. Nothing can be started from it | M | |
| Inspector: Overview, Activity, Team | `MainWindow/InspectorView.swift` | partly | `WebApp/js/views/inspector.js`. Missing: branch, pid, command, size, exit status, tokens and cost, the Team tab's tasks | M | the fields are listed in `WebApp/README.md` |
| A finished session counts as seen once you look at it | `SessionStore.swift` | has it | `Stores/NodeSessions.swift` `acknowledge` and the app's rule (a turn that ended before the node started, or before your last look, reads `idle`); the page sends `seen` after 1.5 s on a finished session (`WebApp/js/views/session.js`), a `read` kind (`Requests.seen`) | | closed 2026-11-19; no command-line way, as the app has none but looking |
| Menu bar dots and popover | `PopoverView.swift`, `Sources/VibeCore/MenuBarDots.swift` | not needed | design non-goal | | |
| Sidebar mode, auto-hide, Spaces, global hot key, `--toggle`, minimize on pause | `Sidebar.swift`, `Spaces.swift`, `HotKey.swift` | not needed | design non-goal (macOS only) | | |
| Statistics window | `Statistics/` | missing | "later" in the design's parity table | L | the model is in VibeCore |

### Chat and composer

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Read a conversation: prompts, replies, folded tool calls, diffs, to-dos, paged history | `MainWindow/Chat/ChatView.swift`, `ToolViews.swift` | has it | `Sources/VibeNode/Live/ChatStore.swift`; `WebApp/js/views/chat.js`, live, with `chat.page` | | |
| Team messages between the lead and its workers | `MainWindow/Chat/TeamMessageCard.swift` | has it | chat items of type `team` (`Live/ChatValue.swift`, `chat.js`) | | |
| Images in the chat | `MainWindow/Chat/ToolViews.swift` (image viewer) | partly | only the type and size are shown, because the node serves no image bytes (`chat.js`) | S | |
| Composer: send, steer while working, queue, `/` commands, `@` files, pasted images | `MainWindow/Chat/ComposerView.swift`, `ComposerOutbox.swift` | has it | `vibeswitcher send SESSION [TEXT] [--image PATH]...` (`send`, the user's voice) types as the composer does, a working agent taking it after its turn; a message sent while a question, picker or menu is open is held and typed once it closes (`Server/SessionSend.swift`, the session's `queued`), and a `/` command's picker is said; images go as quoted paths, the Enter waiting for Claude to take them. The page's composer completes `/` and `@` (`session.complete`), takes pasted and dropped images (`session.attach`, kept in `<root>/attachments`), leaves a `session.draft` naming them and shows `vibeswitcher send SESSION`. Steering closed 2026-11-20: `send ... --now` steers a working Claude agent mid-turn through its hook as the user's (`Engine/SessionSteer.swift`), typed when idle, and the page leaves a send-now draft while its agent works (⌥↩ one for after). Held messages kept across a server restart or a `switch` since 2026-11-20 (`Server/HeldSendStore.swift`: `<root>/v2/held-sends.json`, each restored only when the vault vouches for its action, the digest of what it types and its session; spent once typed; `HeldSendRestartTests`), as the app's outbox is on disk. The question's free-text answer from the box since 2026-11-20: with a question open that takes typed words (its "Type something." row; not a multi-select), `send SESSION TEXT` types the words as that answer, as the app's composer does (`answerFreeText`, gated as `reply` is), and the page's draft says it answers the question | S | closed 2026-11-20 |
| Answer a session's own permission prompt or question (⌘1–9 card) | `MainWindow/Chat/ChatView.swift` | has it | `NodeSessions.prompts` reads it off the screen (`SessionPrompt`); `vibeswitcher reply SESSION CHOICE [TEXT]` (`session.reply`) types the app's keys while the same question shows; the page's card shows the line. A multi-select is answered in its terminal | | closed 2026-11-20 |
| Find in the chat, Export Chat, Copy as Markdown, Edit in Composer, Send Again | `MainWindow/Chat/ChatView.swift` | missing | not in `chat.js` | M | the browser's own find works on the rows drawn |
| "New since you looked" marker and summary | `MainWindow/Chat/ChatView.swift` | has it | `WebApp/js/views/chat.js`, `chatops.js` `newSince`/`sinceSummary` (2026-11-20): a line before the first item after the last one this browser saw at the chat's end, with what came since ("Ran 1 command · 1 reply"); worked out when the chat opens. What was seen is per browser (the Mac's per app) | | the chat opens at the end, not at the marker |
| Run a code block (type it into the session after you confirm) | `MainWindow/Chat/ChatRunner.swift` | missing | needs the composer | M | |
| The all-done card (a batch's summary and receipts) | `MainWindow/Lead/AllDoneWatch.swift`, `Chat/AllDoneCard.swift` | partly | `Engine/AllDoneLook.swift` (2026-11-20): a board that clears is marked under its lock with the written summary (`BatchSummary`, no model asked), and `status` says it for a day. No card in the page's lead chat yet, no receipts shown, no seen mark | S | |
| Push-to-talk dictation | `Dictation/` | missing | "later" in the design | L | |
| Chat text size (⌘+ ⌘− ⌘0) | `MainWindow/Chat/MarkdownView.swift` | not needed | the browser zooms | | |

### The project lead

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Start a lead in a folder, with a goal | `MainWindow/Lead/LeadController.swift`, `--lead` | has it | `vibeswitcher lead FOLDER [--goal] [--take-head] [--replace]`; `Engine/LeadStart.swift` | | refuses a folder that isn't a repository or has no commit, where V1 offers to make one |
| New Project… (make a repository, start its lead) | `MainWindow/NewProject/NewProjectSheet.swift`, `Sources/VibeCore/ProjectCreation.swift` | has it | `vibeswitcher new-project NAME [--in LOCATION] [--folder NAME] [--goal TEXT] [--no-lead]` (2026-11-20, `vibeswitcher-cli/NewProject.swift`): `ProjectCreation`'s folder, repository and first commit (nothing left on a failure), then `vibeswitcher lead FOLDER --goal`, its own typed code. Default location the node's projects folder (`vibeswitcher set projects_folder PATH`, else `~/dev`); on the user's node a new folder also needs its line in `~/.vibeswitcher/v2/projects` (the host's allow-list says so) | | not on the page |
| Message a running lead, or send it a goal | `LeadController.swift`, `--lead --goal` | has it | `vibeswitcher tell FOLDER TEXT`, `lead FOLDER --goal`; `Engine/Delivery.swift`, `Engine/Tell.swift` | | |
| Questions to you, proposed answers on a timer, Hold | `LeadController.swift`, `MainWindow/Lead/LeadViews.swift` | has it | `vibeswitcher questions`, `answer CARD`, `hold CARD`; `Engine/Answers.swift`, `Stores/CardStore.swift`; the web page shows the cards | | |
| Answer a card with one click | `MainWindow/Lead/LeadViews.swift` | partly | the web page leaves a draft and shows the `vibeswitcher answer CARD` line to confirm it in a terminal | | on purpose: a web page is never the user's voice (LW-D6) |
| Approve a merge (the approval is recorded in the vault) | `LeadController.swift` | has it | approval cards in `Engine/Answers.swift` | | |
| The board: tasks, decisions, scorecard, answered questions, files | `MainWindow/Lead/TeamViews.swift`, `TeamRows.swift` | missing | no command shows it. The web Team tab says "the board's tasks come in a later build" (`inspector.js`), and the node streams no `boards` collection (`Server/NodeLive.swift`) | M | |
| Workers, verifiers, audits, the merge gate, the risk check, revert, provenance, auto_advance | `Sources/VibeCore/LeadToolset.swift` (shared) | has it | the lead's tool server `vibeswitcher-mcp` runs on the node (`Sources/VibeCore/V2/RoleProgram.swift`); proved by the full scratch team run (`docs/process/v2-linux-inventory.md`, S10) | | |
| Codex workers, `agent: auto` routing to Codex | `LeadToolset.swift`, `docs/guide/project-lead.md` | missing | turned off with `VIBESWITCHER_CODEX_WORKERS=0` (`Engine/LeadStart.swift`) | | on purpose: security decision 15 |
| The lead's own model (`lead_model`, `lead_advisor`) | `LeadController.swift` `leadRun` | has it | `Engine/LeadStart.swift` `leadRun` (`LeadLaunch.leadRun`, the app's rule), for a start and the idle handover; Fable held back by the account usage kept under the node's root | | closed 2026-11-19 |
| The witness: stalls, the room watch, the role sweep, declining stuck prompts, the disk watch | `LeadController.swift`, `RoleSweep.swift`, `PromptDecline.swift` | has it | `Engine/Witness.swift`, `RoomWatch.swift`, `RoleSweep.swift`, `PromptDecline.swift` (automatic) | | |
| Rotation: a fresh lead when the context is large | `LeadController.swift`, `Sources/VibeCore/LeadRotation.swift` | has it | `Engine/IdleHandover.swift`: daily, at 60% context or idle with a large context, a warm lead asked for its own note, a cold one's written by VibeSwitcher; workflow.md's `lead_rotation:` (`daily`, `context`, `never`) stands in for the setting. The user's typing into the lead isn't seen (the two-minute quiet counts from the engine's start) | | closed 2026-11-20 |
| A server or host restart: the lead rebound, held messages kept | `LeadController.swift` | has it | `Engine/Restarts.swift`; `status` says how the host ended | | |
| The config seal and Accept cards | `MainWindow/Lead/ConfigHolds.swift` | has it | `vibeswitcher config held [--diff]`, `config accept CARD`; `Stores/ConfigHoldStore.swift` | | |
| Base moves (a base moved outside the lead) | `MainWindow/Lead/BaseMoves.swift` | has it | `vibeswitcher base show/accept/keep`; `Stores/BaseMoveStore.swift` | | V1's typed `!` lines wait for a composer |
| Push to the remote (`push_remote`, then your Push click) | `MainWindow/Lead/PushRequests.swift` | has it | `vibeswitcher push FOLDER` / `decline-push FOLDER` (the user's voice: typed code, recorded in the vault and journal), settling exactly the request shown through the vault and `LeadPush.settle` in the server; the lead told the outcome; the page shows the request in the lead's chat and drafts both lines, never pushes (`Engine/PushAsks.swift`, `Server/PushRequest.swift`) | | closed 2026-11-20. The tool's own reply still says "click Push … in VibeSwitcher" (`LeadPush.swift`, shared with main) |
| Fetch from and merge the remote (`fetch_remote`, `merge_remote`) | `LeadToolset.swift` (shared) | unverified | shared tool, so it should work, but no node run has used it | | |
| Leads messaging each other (`tell_lead`), and the "Between leads" view | `LeadToolset.swift`, `MainWindow/Lead/LeadMailViews.swift` | partly | the messages work (shared tool, delivered by `Engine/Delivery.swift`); `vibeswitcher mail [FOLDER] [--all]` shows each project's record of them, newest first, which way each went and what became of it (2026-11-20, `Server/MailRequest.swift`; the user's voice, no code: a private record). `vibeswitcher set lead_mail off` turns them off (the settings lane, 2026-11-20). No page view | S | |
| The prompt-audit reminder | `MainWindow/Lead/PromptAuditDesk.swift` | has it | `Engine/PromptAuditWatch.swift` (2026-11-20): each running lead's project's transcripts looked at every 30 min (`PromptAudit`, shared); a project due one gets a `status` notice saying why and to type `/doctor prompt-audit` in its lead's session; `vibeswitcher prompt-audit FOLDER snooze\|off\|on` (the user's voice) is the card's Remind me in a week and Not for this project. Nothing types the command (the app's Run now is a click; here the user types it); on, every 14 days (the app's settings aren't the node's) | | |
| `small_task_min` drops a review for tiny work | `LeadController.swift` `noteWorking` | has it | `Engine/Witness.swift` `witnessed`: the vault is told the sessions seen at work (`LeadVault.noteWorking`), on change or every 30 s, as the app's | | closed 2026-11-19 |
| Fable held back: halted workers restarted on Opus | `LeadController.swift` `WitnessWork` | has it | `Engine/WitnessWork.swift` | | |
| AI summaries of what each agent is doing | `MainWindow/Lead/TeamSummaryModel.swift`, `Sources/VibeCore/TeamSummaries.swift` | missing | no caller | M | |
| Records: progress, decisions, incidents, redaction, the board's archive | `LeadToolset.swift` (shared) | has it | the lead's tool server | | |
| Your working policy, and leads told when it changes | `WorkingPolicySettings.swift`, `Sources/VibeCore/WorkingPolicy.swift` | has it | `vibeswitcher set policy TEXT` (`- ` reads it from standard input, `default` puts the five rules back; `Settings/NodeSettings.swift`), the page drafts it; the running leads told once when it changes, again after a compaction (`Engine/SettingsWatch.swift`, `LeadWitness.PolicyWatch`) | | closed 2026-11-20 |
| The review rules floor | `ReviewFloorSettings.swift`, `Sources/VibeCore/LeadReviewFloor.swift` | has it | recorded at `config accept` as workflow.md proposes it (`Stores/ConfigHoldStore.swift`); each rule set with `vibeswitcher set FOLDER floor_… VALUE` into the host's vault (`Settings/NodeSettingsSet.swift`), the project's lead told; the floor holds `set verifier_model` too | | closed 2026-11-20; the floor is the user's voice with a typed code |

### Accounts, usage limits and performance

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| The account's usage, read from the roles' status line | `Sources/VibeCore/AccountUsage.swift` | has it | the status line reaches the roles through the door (`Sources/VibeCore/V2/Door/Porter.swift`) | | |
| Workers and audits held back at 80 % of a limit | `LeadToolset.swift` (shared) | has it | the lead's tool server | | |
| Usage shown to you (review rows waiting on a limit) | `MainWindow/Lead/TeamRows.swift` | missing | the engine reads no usage (the account watch is owed) | M | |
| Ignore usage limits | `MacLimitsSettings.swift` | has it | `vibeswitcher set ignore_usage_limits on` (`mac-limits.json`, as the app writes it); the page drafts it | | closed 2026-11-20 |
| Machine-wide limits: team sessions, load, test and build slots, memory | `MacLimitsSettings.swift`, `Sources/VibeCore/MacLoad.swift` | has it | enforced (`Engine/RoomWatch.swift`, the tool server); shown and set with `vibeswitcher settings` and `set mac_max_sessions`, `load_threshold`, `mac_heavy_slots` (2026-11-20), the room looked at again at once. The memory holds stay the file's, as in the app (no control) | | memory pressure and swap are read on Linux (`VibePlatform/Host+Linux.swift`) |
| Boost | `BoostWatch.swift`, `MainWindow/BoostMark.swift` | partly | `vibeswitcher set boost on` and the boost limits (`settings.plist`); the engine writes `boost.json` (`Engine/SettingsWatch.swift` `lookAtBoost`): On unless the usage holds it off, Automatic as Off. No mark on the page, no Also on battery | S | the design says Automatic acts as Off on WSL |
| Heavy-job slots (`vs-heavy`) | `Sources/VibeCore/TestLock.swift`, `HeavyJobs.swift` | has it | the command folder is on the sessions' PATH (`Sources/VibeHost/V2/HostImages.swift`) | | |
| Battery hold, keep the machine awake, the sleep's cost | `KeepAwake.swift`, `PowerReading.swift`, `Sources/VibeCore/PowerSource.swift` | not needed | the battery hold: a node runs on a server or WSL on mains (no `/sys/class/power_supply` battery there), and has no battery limit setting; nothing writes `power.json` under its root, so the hold never applies, said in `Engine/Refresh.swift` (2026-11-19). Keep-awake is owed | M | WSL has nothing to keep awake; a Linux laptop node would need the reading, the limit and the watch's telling together (M) |
| Memory benches, malloc relief, hang watchdog, UI benches | `MallocMode.swift`, `HangWatchdog.swift`, `UIBench.swift` | not needed | they measure the app's own process | | |

### Hooks, status line, config seal and git guards

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Install and remove the hooks for Claude and Codex | `AppDelegate.swift` `HookSetup`, Settings › Agents | has it | `vibeswitcher hooks install|remove [--agent]`; `Server/HooksRequest.swift`, sealed after a typed code | | each config is checked first (`Sources/VibeCore/V2/HookInstallCheck.swift`) |
| Trust VibeSwitcher's hooks in Codex automatically | `CodexTrust.swift` | missing | on purpose (2026-11-21): you trust them in Codex's `/hooks`, as `vibeswitcher hooks install` says. The app's way runs `codex app-server` inside the vault's sealed write of `~/.codex/config.toml`, so whatever that process (or a planted `codex`, or a login shell's startup files) writes there would be sealed as VibeSwitcher's: a seal bypass on a node, where every file of the user is a worker's to change | S | on purpose |
| The status line for the lead, workers and verifiers | `Sources/VibeCore/LeadLaunch.swift`, `vibeswitcher-mcp --status-line` | has it | through the door (`Porter.swift`) | | |
| Git guards: refused git options, deny rules, the read-only command hook | `Sources/VibeCore/RefusedGit.swift`, `ReadOnlyCommand.swift`, `LeadLaunch.swift` | has it | the node launches through the shared `LeadLaunch.prepare` | | |

### Notifications and sounds

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Banners when a session needs input or finishes | `AppDelegate.swift`, Settings › Notifications | partly | `WebApp/js/notify.js` (2026-11-20): the browser's notification while the page is open, when a card opens, a session's prompt waits (not a worker's or verifier's) or a lead stops; first line only; asked once, a toggle on This node; the title counts what needs you. `vibeswitcher questions --wait` for a terminal. Missing: a finished worker's banner (the Mac's is off for workers too), per-kind choices | M | planned "through the browser" |
| A sound when a session needs input | Settings › Notifications | has it | `WebApp/js/notify.js` (2026-11-20): a short chime made on the page when a card opens or a session's prompt waits (not a lead stopping, nor the session you're looking at), its own toggle on This node, off until turned on; while the page is open | | |
| Reminders about waiting or stuck sessions | Settings › Notifications, `Sources/VibeCore/AlertRules.swift` | has it | `NodeSessions.reminderNotices` (2026-11-20): the app's `Nudges` and `AlertRules.nudge` as `status` notices while each stands: waiting on you 10 min (a look from the page, `seen`, restarts it), working with no hook event for 15; a team's silent, a lead's only while it waits on you. A notice, not a banner: the page's notifications don't show them yet; no setting turns them off (the settings lane's) | | |
| Phone push notifications | `Sources/VibeCore/WebPush.swift`, `Web/sw.js` | missing | stage 7 | M | |

### Updates and install

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Check for Updates, the update card | `UpdateChecks.swift`, `UpdateCard.swift`, `Sources/VibeCore/AppUpdateWatch.swift` | has it | `Facts/UpdateWatch.swift` (2026-11-21): the user's node asks GitHub (`gh`, the install script's repository and token handling) 2 minutes after its start and every 6 hours for v2's newest commit both CI workflows passed, compares it with the running build, and while one is newer `status` and the page's notices name it with its install line (`scripts/install-node.sh COMMIT`, then `vibeswitcher switch COMMIT`); `status` also says up to date or why it couldn't look. Read-only, kept in `update-check.json`. No Check now button, nothing installed for you | | releases are stage 8; the install script checks the commit again before it builds |
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
| The developer tools notice | `Sources/VibeCore/ToolchainWatch.swift` | has it | `Facts/NodeToolchain.swift`, `Engine/ToolchainLook.swift` (2026-11-21): every 10 minutes each running lead's project's tools, as its files name them (`Package.swift` and `.swift-version`: swift; `package.json` and `.nvmrc` or `.node-version`: node), are asked their versions in its folder on the server's PATH; one missing or not the named version is a `status` notice (and the page's) while it stands, a change is told to its lead once as the witness and noted for a day. Kept in `toolchain.json`. Queries only | | the app's watches Xcode and the Command Line Tools, which Linux hasn't |
| What plain mode doesn't promise, said once | — | Linux-only | `Facts/NotPromised.swift`, shown by `start` and `status` | | |

### Plugins and everything else

| Feature | V1 (where) | V2 state | Where in V2 / what's missing | Size | Note |
| --- | --- | --- | --- | --- | --- |
| Shell requests (an agent asks for a shell: Run or Decline) | `Shell/`, `Sources/VibeCore/ShellAsk.swift` | has it | `Engine/ShellCards.swift` (2026-11-21): an agent's `vs-shell run` (on the sessions' PATH from the install's `Resources/bin`) files a request the host stamps; each one the host vouches for, from a session it runs, is a `shell` card (`vibeswitcher questions`) showing the asking session, the exact folder and every line of the command, and a `status` notice (the page's notices). `vibeswitcher answer CARD run` (the user's voice, the card's code, recorded in the vault) starts a shell session there with the command given at launch; `decline` declines; unanswered it expires in 30 minutes; the asker is told each outcome and how the command ended. No "open shells without asking" on a node | | the page lists no shell card yet, only its notice; a commit the command makes on a lead's base is a base-move card (the app takes it as yours) |
| Wallet requests (Wallet Manager, Passage, browser signing) | `Wallet/`, `Sources/VibeCore/Wallet*.swift` | missing | no caller | L | the design keeps only browser signing for Linux |
| Brief Me (spoken briefing) | `Briefing/` | missing | "later" in the design | L | |
| Settings (the window, its search, every tab) | `SettingsWindow.swift`, `SettingsCatalog.swift` | partly | `vibeswitcher settings [FOLDER]` and `set [FOLDER] KEY VALUE` (2026-11-20): the limits, usage limits, Boost, leads messaging each other, the policy, and a project's models, max_workers and review floor; the page's Settings (`#/settings`) drafts each change as the line to run. No search; the window's and devices' tabs left out and said so (`NodeSettings.leftOut`) | M | |
| Projects folder | Settings › General | has it | `vibeswitcher set projects_folder PATH` (2026-11-21, `NodeSettings`): kept in the node's `settings.plist` under the app's key (`projectsFolder`), a full path or one under `~`; `vibeswitcher new-project` makes a project there when `--in` names no other place (default `~/dev`, as the app's). Listed by `vibeswitcher settings` and drafted by the page's Settings | | V1 uses it only for New Project…, and so does the node |
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
