# VibeSwitcher

A macOS menu bar app that tracks every Claude Code and Codex session running in your terminals, shows
what each one is doing, and jumps to its Terminal tab in one keystroke.

| Dot | Status | Meaning |
| --- | --- | --- |
| 🔴 | Needs input | Blocked on you: permission prompt, question, plan approval |
| 🟠 | Working | Thinking or running tools |
| 🔵 | Background | Turn ended, but background work is still running (the row shows what and for how long, e.g. `npm run prove · 6h`) |
| 🟢 | Done | Finished a turn you haven't looked at yet |
| ⚪️ | Idle | Finished and already seen |
| ◯ | Unknown | No hooks and no readable title yet |

The menu bar shows one dot per session, in the order of your desktops: sessions on Desktop 1 first, then
Desktop 2, and so on (as Mission Control and ⌃← / ⌃→ order them); windows sharing a desktop go in reading
order, tabs in tab order. Each row says which desktop it's on. Prefer oldest-first? Switch it in Settings › General.
While a session runs a tool, its row shows what and for how long ("⚙ Run unit tests · 3m", orange after 10 min).

- **Click a dot** to jump straight to that session's Terminal tab. Hover a dot to see which session it is.
- The session whose Terminal tab you're looking at has a **ring** around its dot (and a "Viewing" tag in the list).
- **Right-click** (or **⌃⌥V**) opens the list; there, click a row or press **1–9** / **↑↓ ⏎**.
- **Right-click a row › Pause** (until you resume it, for 1 hour, until tomorrow morning, or for a week), or select it
  and press **P**, to park a session you're waiting on or don't want to deal with now. It stays in its place
  but greyed out (dot, row, floating panel, phone), sends no notifications or reminders, and its waiting
  doesn't count in Today. Pausing also minimizes the session's window to the Dock when it's the only tab there
  (Settings › General to turn off); Resume brings it back. Pauses survive restarts; timed ones end by themselves (the window
  stays in the Dock then, instead of popping up). Resume from the same menu (or P).
- **Right-click a row › Rename…** to give a session your own name (kept while it runs, and across
  `--resume` when the session id is kept).
- **⊕ in the list header** starts a new session: pick a recent project (from your running sessions, Claude
  Code's project list and Codex's trusted projects) and Claude Code or Codex, and a new Terminal window
  opens there. The commands it runs are editable (e.g. add `--model`), under ⊕ › Launch Commands….
- The icon stays narrow: up to 4 sessions in one row, then two rows of small dots (12 max, then counts).

**Sidebar mode** (⚙︎ › Sidebar mode): the session list lives on the right edge of the screen, on every
desktop. It hides itself and slides in when the mouse touches the middle of the right edge (not the corners), then slides away when the
mouse leaves (turn off auto-hide to keep it docked). Click a session to go to it, like the menu bar list.
When you switch desktops it slides in for a moment, with the session(s) on the new desktop framed.

**The window** (⌘-click the menu bar icon, the window button in the list, or `VibeSwitcher --window`): a
cockpit for all your sessions. The list on the left puts first what needs you (Needs you, Working, Ready, Idle,
with how long each has been in that state), or groups by project; filter it with ⌥⌘F. The middle shows the
selected session's live terminal, or for a session running in Terminal, a read-only mirror of its screen with
Open in Terminal (⌘O). The right shows its Overview (status, folder and branch, times, session id) or its
Activity: your prompts, the agent's replies and the tools it ran, from its transcript. ⌘K jumps to any session
or command, or starts a preset in a recent project; ⌘J goes to the next session needing you, ⌘1–9 to a session,
⇧⌘H to the start page (recent projects with their presets). The Dock badge counts sessions waiting on you.
⌘W closes the window (or the ⌘K palette) and never ends a session: they keep running. End Session… (⇧⌘⌫, the
header's stop button or the row's menu) always asks first, unless the session has ended already. The Edit menu
is the standard one: Undo, Redo, Cut, Paste and Match Style work in the composer, the filter and Settings.

**Chat** (⌥⌘2; ⌥⌘1 back to the terminal): any Claude or Codex session as a readable conversation, built from
its transcript. Replies are rendered markdown (tables, lists, code with syntax colors and Copy); the tool calls
between two messages fold into one line ("Ran 3 commands · edited 2 files") that opens to each command and its
output, colored diffs of edits, written files, thinking, questions and agents; screenshots the tools took show
inline (click for full size). Paths in replies open the file. It follows the session live, marks what's new since
you last looked, shows the agent's to-do list and plan over the composer, and ⌘F searches it; export it as
markdown. When the agent asks a question (AskUserQuestion, a permission or plan prompt), the chat shows it as a
card you answer with a click. For window sessions the composer types into the session: ↩ sends, ⇧↩ adds a line,
↑ recalls earlier prompts, / completes commands and @ files, pasted or dropped images and files are attached
(thumbnails), and the chips under it show and switch the mode and model and how full the context is. While the
agent works, ↩ **steers** it: the message reaches it at its next step without stopping it (through the hooks);
⌥↩ queues it for when the turn ends instead, and ■ stops the turn. Drafts, attachments and queued messages are
kept per session. A Terminal session can be moved into the window between turns (Move to Window) to reply from
here, in full color.

**Project lead** (a project's ⊕ menu › Project Lead, the start page, ⌘K, or `VibeSwitcher --lead FOLDER [--goal …]`):
one Claude session per repository that you talk to about the project, and that runs a small team for you. You
tell it what you want; it plans the work into tasks, each with a contract (goal, acceptance checks, boundaries),
and starts up to three **workers**, each a Claude session in its own git worktree (`.vibeswitcher/worktrees/<task>`
on `agent/<task>`). When a worker reports, the lead starts a read-only **verifier** that checks the work against
the contract with real commands (and tries to break it); only work the verifier passes is rebased on the lead's branch,
tested (the workflow's `test_command`) and fast-forwarded into it, never with a merge commit or a force. The lead's
branch is the one checked out when it first starts in the repository (`base_branch:` in `workflow.md` changes it);
workers start from it. Then the lead
removes the worktree and branch, and tells you what landed in a few lines. The grunt work stays out of your way:
workers and verifiers fold under their lead in the list, and the lead's chat shows a strip with the team's state.
It only asks you what's really yours to decide; its questions show as cards you answer without stopping it (the
answer reaches it at its next step), and you can message it any time the same way. VibeSwitcher is its witness:
it tells the lead when a worker waits for input, stops without reporting, or dies, and when one has stalled
whatever its screen says: it reads as working but its transcript hasn't grown for 15 minutes with no shell of its
running, it's been between turns for 10 minutes without reporting or asking the lead anything, its transcript ends
at a context-compaction summary with nothing after it for 5 minutes, or a message has waited in its inbox for 5
minutes. Each stall is told once, `status` lists stalled workers first, and their rows read "Stalled 2h". Reports (a
worker done or blocked, a verdict, the witness's news) wake a lead that's between turns, in any project: a few
seconds after they come in (several close together count as one), VibeSwitcher types one short prompt into its
empty box ("2 new reports (verifier x passed; worker y blocked). Call status.") and the reports themselves reach it
with that prompt. Never into your draft (Claude's dim suggestion isn't one), mid-turn or over a dialog, and no second
one until the lead has taken a turn; if it can't for two minutes, the lead's strip shows "N reports waiting". The Team
tab in the inspector
is meant to be glanced at: the lead's open questions first, then its own recent decisions (`record_decision`), each
one short line ("Decided: run overlapping tasks in parallel") that stays in full view for two minutes, fades and blurs
out over the next minute and folds into "Earlier decisions (n)" (with Reduce Motion it just folds); click one for the
whole decision and why. Then each task in one line, a status mark with its own color and shape, the title and its
state with how long it's been there ("Working 12m", "Rework 1 · 22m", "In review 3m", "Needs you", "Queued"), counted
from when that stage began; ordered by what needs you, then work under way, review, the queue in planned order, and
the merged ones folded into "Merged (n)". Under each task at work, one dim line says in plain words what its agent is
doing, written by a small model through headless Claude Code (`claude -p` with haiku and no tools) from the task's
title, its checkpoints (workers note milestones with a `progress` tool) and its agent's last steps, at most every three
minutes per task and only when its transcript changed, while the tab is open; long decisions get a plain one-line
summary the same way. Without it (Settings → General → Project lead turns it off, or Claude isn't there or is slow)
the line is the latest checkpoint or what the agent is doing. Click a task for why it last failed, its checkpoints
with their times, the worker's report, the audit and links to the worker's and the verifier's sessions. Below are
your answers, the results, and the lead's files. All of it lives in the
repository, git-ignored: `.vibeswitcher/board.json` (tasks, questions, updates), `workflow.md` (limits, test and
setup commands, the verifier's model, the lead's branch), `decisions.md` and `progress.md`. The lead sets up
`workflow.md` itself with its `configure` tool, which changes only those settings' lines and keeps your comments
and notes; when there's no test command, `status` says so and suggests one from the repository (SwiftPM,
`package.json`, a Makefile, Cargo, Go), and a merge without one says it ran no tests. Guard rails, not a sandbox
(the whole team runs as you, so a file one of them can read, all of them can): the team's records (who holds which
role, verdicts, where the lead left its branch) and the key that seals your messages are held by the session host
(`vibeswitcher-host`) in its memory, and kept on disk only sealed with a key in your login Keychain that the host
reads without asking you (other programs make macOS ask). The host tells who asks by the process on the other end
of its socket, never by what it says: by its audit token as the host accepted the connection, then the session whose
process tree it's in, or for the app, the code it runs (its cdhash, the one of the app beside the host, not its
path); a connection that anything else then sends on (a child it forked, or the same pid after an exec) counts as
no one. So a worker's Bash,
whether it runs the tool server as the verifier or the lead or writes to the socket itself, is the worker (or,
once it leaves its session's process tree, no one, even when it execs the app's binary), and it
can't give a verdict, take the lead's tools, record the lead's branch, seal a message as yours or type into the
lead's terminal (a session in a team takes keys only from the app, itself or its lead). Only the verifier the
lead last started on a task gives its verdict, from its own session, about the commit it was started on. Not
protected: anything that runs code as the app or the host (a debugger, a library injected into the app's binary,
which isn't built with the hardened runtime, or the app's files rewritten: they're yours to write), or
that changes what the sessions run (the hook binary in `~/.vibeswitcher/bin`, Claude settings, `CLAUDE.md`);
the app's window itself when a worker drives it through Accessibility; ordinary (non-team) sessions, which still
take keys from anyone running as you; and messages labelled as the lead's or VibeSwitcher's, which aren't sealed.
A goal sent with `vibeswitcher --lead` (any process can send one) reaches the lead as not vouched for. With an
ad-hoc signed build (no `scripts/setup-signing.sh`) the rebuilt host can't read its Keychain key, so the vault
starts empty after a host restart. `merge` reads that verdict from there, not from `board.json`; it refuses when the lead's branch was
moved by anything but its own merges since the lead last left it (starting the lead again takes the branch as it
is), rebases exactly the audited commit in a worktree no agent works in (squashing it into one commit when the
worker merged the base in, so the lead's history stays a line), runs the test command there and
fast-forwards to exactly what was tested. Verifiers start without the branch's project settings, hooks and MCP servers, and
VibeSwitcher doesn't answer Claude's trust question for a branch that changes them. Messages reach the lead quoted
under a line naming their sender, so a worker's report can't pass for the user's words, and only the app sends as
the user. They reach the lead's own conversation, never a subagent it started (a subagent's tool calls fire the same
hooks; the message waits for the lead's next step), and count as delivered only once they're in it; `status` also
lists every report that came in since the lead last asked. Claude Code permission rules add a second layer: the lead and verifiers are denied file edits, shell
file writes and git writes; workers are denied pushing, moving refs, checking out, switching to or resetting hard onto
the lead's branch or another `agent/` branch, and rebasing any branch but their own. A worker brings its own branch
up to date by merging: `git merge <base>`, resolve, `git add`, then `git commit` (`git merge --abort` starts over), each
typed on its own with no pipes or `&&`, the one form Claude Code's auto mode doesn't refuse as destructive (it refuses
a rebase and an amend). Its session runs with `GIT_EDITOR=true`, so those bare commands never wait on an editor and
need nothing in front. When `merge` finds a branch conflicting it asks the lead to have that worker merge the base in. Every session reads git (log, diff,
status, show) without asking, after a denied command too.
Their tools come from `vibeswitcher-mcp`, a tool server bundled with the app.

New sessions (⊕, ⌘N) start **in the window** by default: VibeSwitcher runs them itself, in a small background
process (`vibeswitcher-host`) that keeps them going when VibeSwitcher quits, crashes or updates; reopening the
window reattaches them. ⌥⌘N opens a plain shell in the same project. Sessions you still run in Terminal are
listed too and open there. Settings (⌘,) has launch presets (per project: command, flags, environment, window or
Terminal) and the terminal's font, colors, cursor, scrollback and bell. Tools run inside window sessions ask for
privacy permissions (Desktop, Documents…) as VibeSwitcher rather than Terminal.

An app update also updates the session host without ending its sessions (a **handover**). When the app finds an
older host running, it asks that host to become the bundled build: the host first runs the new binary as a probe
that reads the state it would be handed, and only if the probe says it can take over does the host re-execute itself
in place as the new build. It's the same process, so every session's program stays its child (exits are still
reported with their real status), and the PTYs, the lock and the socket stay open across the exec. Each session's
details, what it printed and any input not yet written go in a state file only you can read (beside the host's lock),
which the new build reads and deletes; it rebuilds each screen from what the session printed and nudges full-screen
programs to repaint. Secrets the host keeps in memory go through an inherited socket, never into that file. The app
loses its connection for a moment and reattaches every view. If the new build can't start, the old host carries on
as it was; if it starts but can't restore, it goes back to the old build's own copy, which restores the sessions. A
host from before handovers can't do this: it's still replaced only once its sessions are gone, or from the window's
**Restart Session Host**, which ends them. Once a host that can hand over runs, that button reads "keeps sessions".

**Today** (at the bottom of the list): how long agents were working today (in a turn; background jobs are
listed per project, since a leftover dev server isn't work), and how long sessions were waiting on you:
a question or permission prompt, or a finished turn you hadn't looked at (its first 30 minutes; after that
you've set it aside). Waiting only counts while you're at the Mac (screen unlocked, input in the last
5 minutes). Expand it for a per-project split.

**Crowded menu bar?** On notched MacBooks, macOS silently hides status icons that don't fit right of the
notch. VibeSwitcher starts next to the clock, where overflow never reaches (⌘-drag it elsewhere if you
like). If its icon does get hidden, a floating pill with the same numbered dots appears automatically;
drag it anywhere. Set it to Always / Never in Settings › General.

## Phone Access (over Tailscale)

See your sessions on your phone: the list with live status, each session's screen, the Today summary,
and notifications when a session needs you or finishes. Optionally reply and press keys (Esc, 1–3, ↑↓, ⏎, ⌃C).

1. Settings (⌘,) › **Phone** › turn it on. It needs Tailscale on this Mac with HTTPS certificates enabled
   for your tailnet (admin console › DNS). VibeSwitcher runs `tailscale serve --bg --https=8443` for its
   local server and removes that mapping when you turn Phone Access off or quit.
2. **Pair a Phone…**: scan the QR code with your phone (Tailscale on), or open the address shown and type
   the code. Add the page to your home screen, then tap **Turn on notifications**.
3. To reply from the phone, switch on **Allow replies and key presses** (off by default).
   The session view has quick replies (tap to send; ✎ edits the list, kept on that phone). While a
   session is showing a question or menu, a quick reply goes into the box instead of being sent:
   text doesn't answer a menu (use 1–3 / ↑↓ ⏎), it gets read as "let's discuss the question".
4. A session's view has two tabs. **Terminal** is the live screen; scroll up for the tab's earlier output
   (up to the last 5,000 lines). **Conversation** is the session as a clean timeline, read from Claude
   Code's (or Codex's) own transcript: your prompts, the agent's replies and one row per tool call (tap
   one for its output). It updates as the session moves.
5. **Dev pages**: turn on **Allow opening dev pages** to open, on the phone, the localhost pages that are open
   in Chrome on your Mac (`http://localhost:5173/…`, `127.0.0.1`, `[::1]`, `*.localhost`): live, so taps,
   typing and hot reload work. The first time, macOS asks whether VibeSwitcher may control Google Chrome;
   the line under the toggle shows the answer (with **Open Settings…** if it was no).
   - Only pages open in Chrome right now can be opened; your other local servers can't be reached. Pages
     in incognito windows aren't listed.
   - Each page gets its own HTTPS port on your tailnet (8444–8447) through a proxy in VibeSwitcher. Every
     request must name the Mac's tailnet address, come from your own Tailscale account and carry a cookie
     that the paired phone gets from a link that works once, for a minute. Each phone has its own session
     per page: removing the phone ends its sessions (open live-reload connections included). A page left
     unused for 12 hours, or opened more than 24 hours ago, has to be opened again from the list. Pages in
     one port can't use another port's session (a cookie they plant can't push the real one aside), and a
     dev server can't see or set VibeSwitcher's cookies.
   - If the phone's browser blocks the new tab, an **Open the page** link appears under the list; tap it.
   - At most 4 pages at once. A fifth takes over the least recently used page's port: a phone tab still open
     on the old page stops working (it never sees the new one, whose storage starts empty). Reopen the old
     one from the list. Links hard-coded to
     `http://localhost:…` inside the app won't work on the phone, dev servers that only serve HTTPS aren't
     supported. A dev app's login cookies (HttpOnly) stay on the Mac, kept per opened page and sent only back
     to that app; cookies its own scripts read are shared between the previews (browsers scope cookies by
     host, not port).

How it's kept safe:

- **Tailnet only.** The server listens on `127.0.0.1`; `tailscale serve` (never Funnel) is the only way in,
  over HTTPS. Requests must name this Mac's tailnet address (`<mac>.<tailnet>.ts.net`, which `tailscale
  serve` passes on), so a web page that points its own name at `127.0.0.1` gets nothing, and must come from
  this Mac's own Tailscale account, which Tailscale vouches for.
- **Paired devices only.** Every request needs a device token, handed out once per pairing with a
  one-time code shown on the Mac (10 minutes, one use, 5 attempts). Only a hash of each token is kept.
  Remove a device on the Mac or unpair it from the phone; its token and its dev-page sessions stop working
  immediately. Wrong tokens are throttled per source (20 a minute), and a valid token is never turned away,
  so nobody can lock your phones out.
- **Replies are remote control.** Your sessions can run commands, so typing is a separate switch. The tab is
  brought to the front and verified before anything is typed, keys go to Terminal only (or straight into a
  window session's terminal), and nothing is typed while the Mac is locked: the lock is checked again right
  before every keystroke batch, so a reply that's under way stops when the Mac locks. Every pairing and input is written to `~/.vibeswitcher/remote/audit.log`
  and announced on the Mac.
- **Minimal data.** Credentials are masked in everything sent to the phone: tokens of the common services
  (OpenAI, Anthropic, GitHub, GitLab, Slack, Stripe, AWS, Google, npm, PyPI, Hugging Face, SendGrid, age),
  webhook URLs, private keys, cookies, bearer tokens, passwords in commands and secret-named values, even a
  token the terminal wrapped onto the next row. Notifications are end-to-end
  encrypted (Web Push, RFC 8291): Google's push service relays them but can't read them. By default the
  phone is notified only while you're away from the Mac. No page content is cached on the phone.

## Install

```sh
./scripts/build-app.sh --install        # builds, copies to /Applications, launches
```

On first launch a short welcome window sets VibeSwitcher up. Every step says why it's needed, shows its live
state, and can be skipped; Settings (⌘,) › General › **Show Welcome…** brings the window back.

1. **Live status**: installs the hooks. That installs the hook binary, adds VibeSwitcher's entries to
   `~/.claude/settings.json` and `~/.codex/hooks.json` (beside your own hooks), and marks the Codex hooks as
   trusted (the same `hooks/list` + `config/batchWrite` calls that Codex's own `/hooks` screen makes through
   `codex app-server`). Later: Settings › **Agents**, the popover's **Install hooks** banner, or
   `/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher --install-hooks`.
2. **Terminal**: macOS asks whether VibeSwitcher may control Terminal. Allow it: that's how tab titles are read
   and tabs are selected. Sessions in VibeSwitcher's own window don't need it.
3. **Notifications**: allow them to get a banner when a session needs you (with sound) or finishes. Clicking
   the banner jumps to that tab. Without permission you still get a sound when a session needs input.
   The banner says what's being asked: the question, the exact command waiting for approval
   ("Run: npm publish"), or the plan's title; a finished session shows the start of its last message.
   One reminder follows if a session has waited on you for 10 minutes (looking at its tab restarts the
   clock), or if a working session has shown no progress for 15 minutes, which usually means it's stuck.
   Reminders wait while you're away from the Mac. Choose which you get in Settings › General. Credentials in
   commands and messages (tokens, passwords, API keys, `Authorization`, `Cookie` and bearer headers,
   `user:pass@` URLs, `curl -u`, `mysql -p…`, private keys, webhook URLs) are masked before they are stored
   or shown.
4. **Open at login**: on unless you switch it off; nothing is registered until you click Done. Change it in
   Settings › General.

Running Claude Code sessions pick the hooks up immediately; Codex sessions started before the install
need a restart. Every setting lives in Settings (⌘,): General, Agents (hooks, Codex trust, Terminal and
Accessibility permissions), Phone, Launch and Terminal. The ⚙︎ menu in the list repeats a few toggles.

Uninstall the hooks in Settings › Agents or with `--uninstall-hooks`. The first install keeps copies of your original configs as
`~/.claude/settings.json.vibeswitcher-backup` and `~/.codex/hooks.json.vibeswitcher-backup`. The Codex trust
entries (`hooks.state` in `~/.codex/config.toml`) stay behind after uninstalling; they are inert without the
hooks and can be deleted by hand.

## Privacy

Everything stays on your Mac, readable only by you (`~/.vibeswitcher` is `0700`, its files `0600`). The hook writes a few facts per terminal (last event, your last prompt, the
agent's last message, both truncated) to `~/.vibeswitcher/state/`, and the app reads them plus Terminal's
tab titles. The Today totals are kept per day in `~/.vibeswitcher/stats/` (project names and seconds). Nothing is sent anywhere. Delete `~/.vibeswitcher` to remove all of it.

## How status is detected

Three sources, most precise first:

1. **Hooks.** Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) run
   `~/.vibeswitcher/bin/vibeswitcher-hook` on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
   `PermissionRequest`, `Notification`, `Stop`, `Interrupt` (Codex), `PreCompact` and `SessionEnd`. The hook
   writes that terminal's latest facts to `~/.vibeswitcher/state/<tty>.json`. It prints nothing and always
   exits 0, so it can never block an agent.
2. **Terminal tab titles.** Claude Code titles its tab `✳ <task>` when idle and uses a spinner glyph while
   working. That covers sessions without hooks, plus the transitions hooks miss (Esc interrupts fire no
   `Stop`). For finished Claude sessions, background work is found in the process tree: shells Claude
   started that are still running (with their real command and age), plus Claude's footer for
   background agents/tasks that aren't processes (🔵).
3. **The process table** (`sysctl`, no `ps`). Finds every `claude` / `codex` process attached to a TTY, so
   every session is listed even before it sends a hook event.

Desktop numbers come from macOS's private SkyLight window-server calls (the same ones yabai and Hammerspoon
use), looked up at runtime; if they're ever unavailable, ordering falls back to window position.

Terminal's tabs are native macOS window tabs, which its scripting sees as separate windows. With the
Accessibility permission, VibeSwitcher reads each window's tab bar so tabbed sessions are listed in
the order you see (and follow you when you drag tabs); without it they stay together, oldest first.

Sessions are keyed by TTY, which also identifies the Terminal tab to focus. Sessions in other terminal apps
are listed too; clicking them activates the hosting app.

## Command line

```sh
VibeSwitcher --dump            # detected sessions + raw hook state
VibeSwitcher --toggle          # open/close the popover of the running app (bind it in Raycast etc.)
VibeSwitcher --open ttys012    # ask the running app to open a session (same path as clicking its row)
VibeSwitcher --focus ttys012   # select a Terminal tab directly (no activation handling)
VibeSwitcher --snapshot /tmp   # render popover + menu bar icon PNGs from live data
VibeSwitcher --new claude ~/dev/app   # start a preset (name, or claude/codex/shell) there; --terminal: in Terminal
VibeSwitcher --window [palette|home]  # open the window (with the command palette, or on the start page)
VibeSwitcher --window select:genswap  # … and select the first session matching the text
VibeSwitcher --window move:ttys012    # move that Terminal session into the window (between turns)
VibeSwitcher --settings launch        # open Settings (general, agents, phone, launch or terminal)
VibeSwitcher --lead ~/dev/app --goal "add a login page"  # start (or message) the project lead of that repository
VibeSwitcher --install-hooks | --uninstall-hooks
cat ~/.vibeswitcher/app-status.json   # debug aid: what the running app currently sees
ls ~/.vibeswitcher/debug/             # app.log: what the app did lately; hang-*.txt/.log: a sample of every thread
                                      # and the app's state whenever its main thread was stuck for over 2 s
VibeSwitcher --chat-bench TRANSCRIPT  # debug aid: the chat view offscreen on a transcript, timing its layouts
VibeSwitcher --capture-window /tmp/w.png # debug aid: the running app draws its windows into PNGs (+ view tree .txt; /tmp or ~/.vibeswitcher only)
```

(`VibeSwitcher` = `/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher`.)

## Development

Requires macOS 14+ and a Swift 6 toolchain (Xcode or just the Command Line Tools).

```sh
swift build && swift test      # Swift Testing; works with Command Line Tools only
./scripts/build-app.sh --install
```

Run `./scripts/setup-signing.sh` once: it creates a self-signed signing identity in its own keychain
file (`~/.vibeswitcher/signing`, your login keychain is untouched) so every rebuild keeps the same code
identity, and trusts that certificate for code signing (your user only; macOS asks for your password).
macOS only keeps a permission across rebuilds for a trusted signature: otherwise, ad-hoc or not, it pins
the Accessibility and Automation permissions to the exact build and silently drops them on the next one,
while System Settings still shows them as on.

Run the app through `build-app.sh` rather than `swift run`: notifications, the login item and the
Automation permission all need a real `.app` bundle.

`Sources/VibeCore` holds the testable logic (status rules, hook reducer, process table, installer),
`Sources/VibeSwitcher` the AppKit/SwiftUI app, `Sources/vibeswitcher-hook` the hook binary,
`Sources/vibeswitcher-host` the session host, and `Sources/vibeswitcher-mcp` the project lead's tool server.
