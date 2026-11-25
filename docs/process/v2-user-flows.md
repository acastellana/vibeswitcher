# V1 and V2: the user flows

What the user does day to day, step by step in V1 (the Mac app) and in V2 (the node: its web page, its command line or
both), with a verdict for each. The feature by feature table is [V1 and V2: what each one does](v2-parity.md); this
page uses its words (**under trust**, the Mac's steps). Checked 2026-11-25 against `v2-web-fixes` at `932aeb99`.

How each V2 side was checked:

- **Driven**: the page's mock (`WebApp/serve.sh` on port 8796, `?mock`) in headless Chrome on a profile of its own,
  through `scripts/e2e/chrome-cdp.cjs`: routes visited, buttons clicked, text and screenshots read. The mock acts for
  you (its hello gives the page the `act` right), as a real node's page does only under trust, and it takes fewer kinds
  than a node (not `session.new`, `session.end`, `session.reply`, `lead`), so for those it shows the line to run. A
  driven step proves the page, not the node.
- **Read**: the node's side (the command line, `Sources/VibeNode`) by reading the code and its tests; nothing was run.

**On the Mac**: V2's node is refused on this Mac today (`NodeSystem.macUnbuilt`), so every V2 flow below waits for the
Mac node before the user can live it here. Each flow says whether that is all it waits on (**waits for the Mac node**,
with the step when one matters) or whether something is **missing in V2 everywhere**, Linux included.

## The flows at a glance

| # | Flow | Verdict | On the Mac | Checked |
| --- | --- | --- | --- | --- |
| 1 | First install and first project | works differently, worse | waits for steps 4, 5, 7 | read; New project driven |
| 2 | Start a project and its lead and give it work | works differently, about the same | waits for step 4 | read; forms driven |
| 3 | See what needs me and answer a lead's question | works the same (under trust) | waits for step 4 | driven |
| 4 | Answer a session's own prompt | works differently, worse | waits for step 4; the page's answer missing everywhere | driven |
| 5 | Start, find, rename, pause, end and resume my own session | works differently, worse | waits for step 4; keys missing everywhere | driven in part |
| 6 | Type to a working session and steer it | works differently, about the same | waits for step 4 | driven |
| 7 | Read a session (chat, terminal, scroll back, copy, search) | works differently, worse | terminal find and typing missing everywhere | driven (chat) |
| 8 | Attach an image or a file | works the same | waits for the Mac node | driven in part |
| 9 | Dictate | works differently, worse | V1's ways missing everywhere | driven in part |
| 10 | Approve a push and a merge policy | works the same (under trust) | waits for step 4 | driven (push) |
| 11 | Review what a lead did | works differently, better | waits for the Mac node | driven |
| 12 | Get notified when the page or app is closed | can't be done | missing everywhere | read; toggles driven |
| 13 | Use it from the phone | works differently, worse | acting from a phone missing everywhere | driven (layout) |
| 14 | Change a setting for the node and for a project | works the same (under trust) | waits for step 4 | driven |
| 15 | Update to a new version and roll back | works differently, better | waits for steps 5, 7 | read; This node driven |
| 16 | Restart the Mac and get my sessions back | works differently, worse | waits for step 5 | read |
| 17 | A wallet request end to end | can't be done (Wallet Manager) | missing everywhere | read |
| 18 | Open a shell for a command an agent asks for (vs-shell) | works the same (under trust) | waits for step 4 | read |
| 19 | See the Mac's load, usage limits and Boost | works differently, about the same | keep-awake and Boost's Automatic owed on a Mac | driven |
| 20 | Several projects' leads at once, and messages between leads | works differently, worse | waits for the Mac node | driven in part |
| 21 | Get briefed | works the same, plainer voice | waits for the Mac node | driven |
| 22 | Accept a held config change or a moved base | works the same (under trust) | waits for steps 4, 8 | read; the notice driven |
| 23 | Tidy finished shells and replaced leads | works differently, about the same | waits for step 4 | read |

Under trust needs three things from a terminal first: `vibeswitcher web`, the pairing phrase confirmed with the code,
and `vibeswitcher set web_acts trust`. The pairing lasts 12 hours and a reload loses it. Without trust, every V2 step
marked "(acts under trust)" is instead a line the page shows, to copy and run in a terminal with a typed code.

## 1. First install and first project

**V1**: 1. Build and install the app (`scripts/build-app.sh --install`). 2. First-run setup (Settings › General)
checks Claude Code, the hooks, Terminal control and notifications, and installs what's missing with a click. 3. The
start page's New Project…: name it; the app makes the folder, the repository and a first commit. 4. The project's lead
starts in the window.

**V2**: 1. In a terminal: `scripts/install-node.sh COMMIT` (Linux; the Mac's `scripts/install-node-mac.sh` writes the
LaunchAgent but `start` is still refused), then `vibeswitcher start [--at-login]`. 2. `vibeswitcher doctor` lists what
the node needs, each with the command to run yourself (nothing is installed for you); `vibeswitcher hooks install`.
3. `vibeswitcher web`: open the address it prints, confirm the pairing phrase in the terminal; optionally
`vibeswitcher set web_acts trust`. 4. The page's New project (`#/new`, driven): name and place, and it shows the
`vibeswitcher new-project NAME --goal …` line; run it in the terminal (the page can't make a project even under trust).
5. The lead starts; the page shows it under Projects.

**Verdict**: works differently, worse: five terminal steps and a typed code before the first lead, no one-click
installs, and the pairing to redo every 12 hours or reload. **On the Mac**: waits for the Mac node (steps 4 voice, 5
LaunchAgent, 7 install); `doctor`'s checks are Linux's (a Mac piece owed). **Checked**: read; New project driven.

## 2. Start a project and its lead and give it work

**V1**: 1. ⌘K › Start Project Lead in … (or New Project…). 2. A folder with no repository or no commit is offered one.
3. The lead opens; type the goal in its composer, ↩. 4. Later work: type to the lead again.

**V2**: 1. The page's New project › Start a project lead (driven): a folder and a goal; Start lead (acts under trust),
or the `vibeswitcher lead FOLDER --goal …` line. A folder with no commit needs `lead FOLDER --init` from a terminal.
2. The project's page opens: the lead's conversation, the dial, the team strip. 3. Later work: the message box at the
foot, "To the lead of PROJECT", sends at its next step, now, or after this turn (acts under trust; driven: the Send
menu's ways), and says when the lead has read it; `vibeswitcher tell FOLDER TEXT` from a terminal.

**Verdict**: works differently, about the same under trust; worse without it (each step a terminal line). V2 adds
goals and a roadmap the lead keeps. **On the Mac**: waits for step 4. **Checked**: read; the forms and the message box
driven.

## 3. See what needs me and answer a lead's question

**V1**: 1. The sidebar groups by attention; the menu bar dots and a banner say something needs you. 2. ⌘J jumps to the
next. 3. The question card shows its options and a proposed answer on a timer. 4. Click an option, ⌘1–9, or your own
words; Hold stops the timer.

**V2**: 1. The left column says "N need you" per project and in all; the tab's title counts; the browser notifies while
a page is open. 2. ⌘J / ⌥J: the next project with a card waiting. 3. The project page's "Waiting on me" shows the
question with its options and timer. 4. Click an option (acts under trust; driven: "Thursday" gave "Sending “Thursday”…
· Undo", a Blocking card's five seconds) or type your own words; Hold is a button. Without trust the card shows
`vibeswitcher answer CARD` to run.

**Verdict**: works the same under trust, with Undo as a bonus; worse without it. ⌘J skips your own sessions, and
nothing outside a browser tab says something needs you. **On the Mac**: waits for step 4 (the Mac's own H1 too).
**Checked**: driven.

## 4. Answer a session's own prompt

**V1**: 1. A session shows a permission prompt or a question; its row turns "needs you". 2. Open it: the chat shows
the prompt as a card. 3. Click an option, ⌘1–9, or ↑/↓ and ↩.

**V2**: 1. The session shows "Needs you" under Your own sessions (driven). 2. Open it: "Claude is asking", the prompt
and its numbered options (driven). 3. A click picks an option and shows the `vibeswitcher reply SESSION CHOICE` line;
run it in a terminal (it answers only while that question is still on the screen). Even under trust the page doesn't
answer (no page sends `session.reply`, though the node would take it). A multi-select: in its terminal only, which a
page can't type into.

**Verdict**: works differently, worse: a terminal step for every prompt. **On the Mac**: waits for step 4; the page's
one-click answer is missing everywhere (S). **Checked**: driven.

## 5. Start, find, rename, pause, end and resume my own session

**V1**: 1. ⌘N, ⌥⌘N, or ⌘K › New PRESET in FOLDER. 2. Find it in the sidebar (⌥⌘F, ⌘1–9, ⌘K). 3. Right-click › Rename…,
Pause ›, Resume Notifications. 4. End Session… (asks first). 5. The start page's Ended lately, or the row's Resume.

**V2**: 1. Your own sessions (`#/sessions`, driven): Start a session with Claude, Codex, Shell or a preset (acts under
trust), or `vibeswitcher new FOLDER [--agent] [--preset]`; the palette's New PRESET in FOLDER. 2. Find it: Your own
sessions lists yours; team sessions only under their project; ⌘K searches. 3. The session's Actions… (driven: it
opened): Rename, the four pauses, Resume Notifications, each "Do it" under trust, or `vibeswitcher rename`/`pause`.
4. Actions › End: one click, no confirmation; or `vibeswitcher end SESSION`. 5. Ended lately (driven) with Resume and
its `vibeswitcher resume ID` line.

**Verdict**: works differently, worse: no ⌘N, ⌘1–9, next/previous or filter (the redesign removed them), End without a
confirmation. **On the Mac**: waits for step 4; the keys and the filter are missing everywhere. **Checked**: driven in
part (the mock has no `session.new` or `session.end`, so those showed their lines).

## 6. Type to a working session and steer it

**V1**: 1. Open the session; type in the composer. 2. ↩ while it works: taken after its current step, or held behind
an open question. 3. ⌘. stops it. 4. Or type straight into its terminal.

**V2**: 1. Type in the session's box; ↩ leaves it as a draft over the box (driven: "Your message for Claude", Edit,
Discard). 2. The draft's Send (acts under trust) or its menu (driven): At its next step, Now, Interrupt then send; or
`vibeswitcher send SESSION TEXT [--when …]`. A message sent while a question is open waits and goes in once it
closes (driven: "A message waits to go in"). 3. No bare stop: "Interrupt, then send" needs a message. 4. No typing into
the terminal.

**Verdict**: works differently, about the same for steering (two steps where V1 has one, and more ways); worse for a
bare stop and the terminal. **On the Mac**: waits for step 4; typing into a terminal is missing everywhere (H1 and the
user's decisions). **Checked**: driven.

## 7. Read a session (chat, terminal, scroll back, copy, search)

**V1**: 1. ⌥⌘2 chat, ⌥⌘1 terminal. 2. The chat opens at "New since you looked". 3. Select across messages and copy;
Copy as Markdown; Export Chat. 4. ⌘F in the chat or the terminal's scrollback. 5. ⌘+ ⌘− ⌘0.

**V2**: 1. The session's Chat and Terminal tabs (driven). 2. The chat opens where you left it in this page, else at
"New since you looked". 3. Copy, Copy as Markdown, Export Chat (a `.md` download); select what's drawn. 4. ⌘F / Ctrl+F
finds in the chat. The terminal is watch only, and only on a loopback page confirmed in a terminal; no find in it, no
clear, no full window; the mock has no terminal. 5. The browser zooms the chat; the terminal's size is in Settings ›
Terminal.

**Verdict**: works differently, worse for the terminal (watch only, no find), the same for the chat. **On the Mac**:
waits for the Mac node; the terminal's find and input are missing everywhere. **Checked**: driven (chat), read
(terminal).

## 8. Attach an image or a file

**V1**: 1. Paste or drop an image into the composer, or drag a file. 2. `@` completes a project's file. 3. Send.

**V2**: 1. Paste, drop, or the box's + (driven: the + is there at phone width) for an image from this device; one on
the node by its path goes as `vibeswitcher send SESSION … --image PATH`. 2. `@` completes from the node. 3. Send
(under trust) or the send line.

**Verdict**: works the same. **On the Mac**: waits for the Mac node. **Checked**: driven in part (the +), read.

## 9. Dictate

**V1**: 1. Settings › Dictation & Briefing: an OpenAI key in the Keychain, or Claude Code's own /voice. 2. Hold Space
(or the mic) and speak; the Mac can go silent meanwhile. 3. The words, helped by the project's names, land in the box;
you send. From the phone, its recording is transcribed on the Mac.

**V2**: 1. This node › Dictation: turn on "Hold the mic beside a message or an answer" (driven). 2. Hold the mic beside
the session's box or a card's answer (driven: two mics on the session page); the browser's own speech service hears
you (Chrome's goes to Google), only on a secure page (the loopback one, not the tailnet's). 3. The words fill the box.

**Verdict**: works differently, worse: no OpenAI or Claude /voice, no project words, no Hold Space, nothing from the
phone's plain-HTTP page, no mic on the lead's message box. **On the Mac**: V1's ways are missing everywhere.
**Checked**: driven in part (the toggle and the mics), read.

## 10. Approve a push and a merge policy

**V1**: 1. The lead asks to push: a card with what goes where. 2. Push or Decline. 3. A sensitive merge waits for an
approval card, per the merge policy and the floor (Settings › Project lead › Review rules floor). 4. Approve; recorded
in the vault.

**V2**: 1. The project page: "The lead asks you to push", from git and the vault: the branch at its commit, the
remote, the commits (driven). 2. Push or Decline (acts under trust; driven: Push clicked), or `vibeswitcher push
FOLDER` / `decline-push`. 3. An approval card the same way (`answer CARD`, or its button under trust). 4. The floor:
`vibeswitcher set FOLDER floor_merge_policy …` from a terminal only (a page never sets a floor, by rule); Settings
shows it (driven: "Merge policy, at least").

**Verdict**: works the same under trust; the floor is a terminal's, on purpose. **On the Mac**: waits for step 4.
**Checked**: driven (push, settings), read (approval).

## 11. Review what a lead did (board, tasks, decisions, results with screenshots, scorecard, stats)

**V1**: 1. Open the lead; ⌥⌘0 for the Team tab. 2. Tasks, decisions, answered questions, results with screenshots, the
scorecard, between leads. 3. The all-done card. 4. Window › Statistics….

**V2**: 1. The project page (driven): the lead's conversation of questions, results and decisions under the dial
(Waiting on me, Decisions and results, Everything); the team strip. 2. Team, Stats (estimates and the scorecard,
driven), Files (where the lead's files are, driven) on the right; a task opens in place (driven: blocked, waits on,
goal, attempt). 3. The roadmap: goals with estimated landings (driven). 4. Result screenshots and a task's whole
details in a team session's inspector. 5. Statistics (`#/stats`, driven: load, usage, merges, quality, cost, by agent,
8 weeks). 6. The all-done card shows in the lead's chat, but nothing marks it seen any more.

**Verdict**: works differently, better (goals, landing dates, the dial), with two losses: the all-done mark never
clears, and a task's full details are only in a team session's inspector. **On the Mac**: waits for the Mac node.
**Checked**: driven.

## 12. Get notified when the page or app is closed

**V1**: 1. The app keeps running in the menu bar with its window closed: banners and a sound keep coming. 2. Away from
the Mac, a paired phone gets push notifications (optionally only while away). 3. Quit the app and nothing notifies.

**V2**: 1. With a page open: the browser's notifications and a chime, each kind's choice on This node (driven).
2. With no page open: nothing. No push (four decisions open, [the push decision note](v2-push-decision.md)), no
notifier on the node. 3. A terminal can wait: `vibeswitcher questions --wait`.

**Verdict**: can't be done: step 1 breaks once the tab closes. **On the Mac**: missing everywhere (push M; a Mac node's
own banner would be a Mac piece). **Checked**: read; the toggles driven.

## 13. Use it from the phone

**V1**: 1. Settings › Phone: access over Tailscale, pair the phone, allow replies and key presses. 2. On the phone:
sessions, leads' questions and pages; answer, type, dictate, Brief me, open dev pages through Chrome. 3. Push while
away.

**V2**: 1. `vibeswitcher web --tailnet` in a terminal; open its MagicDNS address on the phone; pair with the code it
prints. 2. The phone's layout (driven at 390 px: the lead page and a session with its prompt): read everything, draft
answers and messages, each to be run from a terminal. 3. The tailnet page never acts, by rule; no terminal there, no
dictation (not a secure page), no dev pages, no push.

**Verdict**: works differently, worse: from the phone you read and draft only. **On the Mac**: acting from the phone,
push and dev pages are missing everywhere. **Checked**: driven (layout), read.

## 14. Change a setting for the node and for a project

**V1**: 1. ⌘, opens Settings; search or pick a tab. 2. Change a value; running leads are told where it matters.

**V2**: 1. Settings (`#/settings`, driven): This node and each project; every setting with its value, default, where it
lives and its range. 2. Change… sets it (acts under trust), or drafts `vibeswitcher set [FOLDER] KEY VALUE`. The policy,
the floors, `lead_mail`, `verifier_model`, `security_audit_model` and `max_workers` are a terminal's only (the page shows
a Set button for the last four, which the node refuses). 3. Search: `vibeswitcher settings --find WORDS` or the page's
box.

**Verdict**: works the same under trust, with some settings a terminal's on purpose. **On the Mac**: waits for step 4.
**Checked**: driven.

## 15. Update to a new version and roll back

**V1**: 1. The update card lists the new commits (GitHub's with who pushed them). 2. Install & Restart opens a shell
that asks for the signing keychain's password, builds, installs and relaunches; sessions keep running. 3. No rollback:
build an older commit by hand.

**V2**: 1. `status` and This node's Updates say a newer build both CI runs passed, how many commits ahead, with its line
(read; This node's Build driven: running, installed, "Rollback goes to"). 2. `vibeswitcher update [COMMIT]` in a
terminal: install, switch and accept with one code; sessions survive the handover. 3. `vibeswitcher rollback` goes back
to the previous build.

**Verdict**: works differently, better (rollback), without V1's changelog. **On the Mac**: waits for steps 5 and 7.
**Checked**: read; This node driven.

## 16. Restart the Mac and get my sessions back

**V1**: 1. Restart. 2. The app opens at login and its restart card offers the sessions that were open; leads `--resume`
in their conversations. 3. Click Reopen.

**V2**: 1. Restart. 2. The node starts at login (`start --at-login`). 3. `vibeswitcher status` offers `vibeswitcher
reopen` (your own sessions) and `lead FOLDER --resume` (each lead); run them in a terminal. The page has Resume lead /
Fresh lead (under trust) but no reopen for your own sessions. 4. Pair the page again.

**Verdict**: works differently, worse: terminal steps where V1 has one card. **On the Mac**: waits for step 5.
**Checked**: read.

## 17. A wallet request end to end

**V1**: 1. An agent asks for a transaction (`vs-wallet`): a wallet card and a strip along the terminal. 2. Send to
Wallet Manager (Passage carries it to the vault Mac, the Trezor signs) or sign in a browser wallet. 3. The hash or the
rejection settles the card; Send all N… sends several.

**V2**: 1. `vibeswitcher plugin add FOLDER` and `plugin on wallet` for the external `vibeswitcher-wallet` plugin (not in
this repository: unverified), `set wallet_chains …`. 2. An agent's `vs-wallet` request becomes a card; `vibeswitcher
answer CARD sign` serves the signing page once on its own origin, its address printed in the terminal. 3. The page
reports the hash or the rejection.

**Verdict**: can't be done for Wallet Manager and Passage (step 2's first way); browser signing works differently and
is unverified here. **On the Mac**: missing everywhere. **Checked**: read (the plugin frame only).

## 18. Open a shell for a command an agent asks for (vs-shell)

**V1**: 1. An agent runs `vs-shell run -- CMD`: a card with the folder and the command. 2. Run or Decline; a shell
session opens there and runs it; the agent is told. 3. Optionally "Let agents open shells without asking".

**V2**: 1. The same `vs-shell run` files a card (the shell plugin, on by default). 2. Run or Decline (acts under trust)
or `vibeswitcher answer CARD run`; the shell session runs it, the agent is told, the shell ends by itself once done.
3. No "without asking", on purpose.

**Verdict**: works the same under trust. **On the Mac**: waits for step 4. **Checked**: read.

## 19. See the Mac's load, usage limits and Boost

**V1**: 1. The Team tab's foot: the Mac's load, the usage limits, keep awake. 2. The Boost mark; Settings ›
Performance. 3. Statistics for the history.

**V2**: 1. This node (driven): account usage (each limit, "holds work back"), Boost (state, mode, raised limits), Health.
2. The bolt beside This node in the left column; Settings' Boost and limits (driven). 3. Statistics (driven: load,
freezes, Boost hours, usage pace). Not shown on the project page: the load now.

**Verdict**: works differently, about the same. **On the Mac**: keep-awake, the battery hold and Boost's Automatic are
owed on a Mac node (Mac pieces). **Checked**: driven.

## 20. Several projects' leads at once, and messages between leads

**V1**: 1. A lead in each project; the sidebar groups them. 2. ⌘J walks what needs you across all of them. 3. Leads
message each other (`tell_lead`); the Team tab's Between leads; Settings turns it off.

**V2**: 1. A lead in each project; the left column lists them, each with its ring and "N need you" (the mock has one
project). 2. ⌘J goes project to project. 3. Between leads (`#/mail`, driven: each project's messages, which way, kind,
what became of it); `vibeswitcher mail`; `set lead_mail off`.

**Verdict**: works differently, worse only in ⌘J skipping your own sessions. **On the Mac**: waits for the Mac node.
**Checked**: driven in part (one project), read.

## 21. Get briefed

**V1**: 1. ⇧⌘B (or one project's). 2. A popover with what happened and what's asked of you, spoken in an ElevenLabs
voice in the chosen language.

**V2**: 1. Brief me under the left column (driven), or `vibeswitcher brief [FOLDER]`. 2. "What happened, and what's
asked of you" (driven), Speak reads it with the browser's voice; English only.

**Verdict**: works the same, with a plainer voice. **On the Mac**: waits for the Mac node. **Checked**: driven.

## 22. Accept a held config change or a moved base

**V1**: 1. A change to the agents' config is held: an Accept card says what changed. 2. Accept. 3. A base moved
outside the lead: a card, Accept or Keep.

**V2**: 1. A notice on This node and the project (driven: "landing-base moved outside the lead's merges; its next merge
is refused until you accept the move"). 2. Accept, Accept move or Keep base (acts under trust), or This node's Approve
all; from a terminal `vibeswitcher config accept`, `base accept`, or `approve` for all of them with one code. A move your
own `!` git line made is a card too.

**Verdict**: works the same under trust; V2's `approve` is quicker for several. **On the Mac**: waits for steps 4 and
8. **Checked**: read; the notice driven.

## 23. Tidy finished shells and replaced leads

**V1**: 1. The sidebar's foot: Close Finished (N)…. 2. One confirmation lists them; OK ends them.

**V2**: 1. Replaced leads end by themselves once the new lead is up; a Run card's shell ends by itself once finished.
2. Other shells: `vibeswitcher close-shells [FOLDER]` in a terminal; the page has no button or count for it.

**Verdict**: works differently, about the same (more is automatic). **On the Mac**: waits for step 4. **Checked**:
read.
