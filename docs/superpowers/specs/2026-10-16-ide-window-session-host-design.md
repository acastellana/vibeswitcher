# IDE window, part 1: session host and main window

Status: approved direction (2026-10-16), first of four sub-projects.

## Why

You run many Claude Code and Codex sessions, each in its own Terminal window or tab. VibeSwitcher
already tracks them and jumps between them, but the sessions still live in Terminal.app: dozens of
windows, spread across desktops, reached through AppleScript and focus tricks that have stranded
windows before. The goal is one VibeSwitcher window that **runs** the sessions itself, so Terminal.app
is no longer needed for agent work.

## What you said (decisions)

- Shape: a **session cockpit plus code views** — sessions run inside the app; files, diffs, git and
  previews sit around them. Writing code stays in your editor.
- **Sessions must survive** the app quitting, crashing or updating.
- **Same app, new window.** Menu bar dots, notifications and phone access keep working, for sessions
  in the window and for any still in Terminal.app.
- Layout: **three panes** (sessions by project | terminal | inspector) by default; a **terminal grid**
  is a switch away (but the single focused session matters most).
- Settings you'll reach for: **launch per project**, **terminal look & feel**, **attention & alerts**.
- Architecture **A**: native Swift app + our own small session host + SwiftTerm.
- Carry the work through without per-step check-ins.

## The four sub-projects

1. **Session host + main window** (this spec).
2. Session inspector: Changes / Git / Files; Session tab (transcript, plan, tasks and subagents,
   memory) read from each agent's own storage; Stats (tokens, cost, turn times, tools, files, context).
3. Outputs: a Preview tab with what the session opened (localhost servers, Artifacts, URLs, the Chrome
   tabs it drove, generated images and files).
4. Grid mode + attention & alerts settings.

Parts 2–4 get their own specs. This one leaves room for them (the inspector pane exists, empty of
their content) but does not build them.

## Done when

- ⊕ New Session starts Claude or Codex **in the window** by default, using a per-project launch preset.
- The window lists every session grouped by project (window-hosted and Terminal.app ones), shows the
  selected one's live terminal, and you can type in it like in Terminal.
- Quitting VibeSwitcher, `build-app.sh --install`, or a crash of the app leaves window sessions
  running; reopening the window reattaches them with their screen intact.
- Menu bar dots, notifications, the popover, `--open`, and the phone (screen, scrollback, replies)
  work for window sessions.
- A plain shell can be opened in any project, so git/npm don't need Terminal either.
- Terminal look & feel and launch presets are editable in a Settings window.

## Architecture

```
 VibeSwitcher.app (menu bar + main window)            vibeswitcher-host (background, per user)
 ┌──────────────────────────────────────┐   unix    ┌──────────────────────────────────────────┐
 │ HostClient ── attaches, sends input ─┼─ socket ──┤ HostServer                               │
 │   │                                  │  framed   │   └ HostedSession × N                    │
 │   ├ MainWindow (SwiftTerm views)     │  messages │       ├ PTY master  ⇄  shell → claude    │
 │   ├ SessionStore (merges hosted ttys)│           │       ├ output ring buffer (replay)      │
 │   ├ PhoneAccess (screen/history/input)│          │       └ headless SwiftTerm Terminal       │
 │   └ Launcher (window or Terminal)    │           │         (title, screen text, scrollback) │
 └──────────────────────────────────────┘           └──────────────────────────────────────────┘
```

### Session host (`vibeswitcher-host`)

A small separate executable in the app bundle. It owns every window session's pseudo-terminal, so
sessions outlive the app.

- **Lifetime.** At launch the app connects if the socket answers (reattaching whatever is running);
  otherwise it starts the host only when the first window session is requested. It starts it with
  `posix_spawn` + `POSIX_SPAWN_SETSID`, detached from the app. It is not a launchd job: no background-item approval, and `pkill -x VibeSwitcher` (used by
  `build-app.sh`) doesn't match it. It exits on its own 10 minutes after its last session ends and no
  client is connected. One host per user: it takes an exclusive `flock` on `~/.vibeswitcher/host.lock`
  before binding the socket; a second copy exits.
- **Updates.** A running host keeps running the binary it started from, even after the bundle is
  replaced. The app compares `protocolVersion` on hello. Equal: normal. Host older and **no live
  sessions**: the app asks it to exit and starts the new one. Host older **with live sessions**: the
  app keeps using it if the protocol is compatible (same major), else shows a banner "Session host is
  out of date — Restart Host (ends N sessions)". The app never silently kills sessions.
- **Socket.** `~/.vibeswitcher/host.sock`, mode 0600, in the 0700 `~/.vibeswitcher` directory.
  Every connection is checked with `getpeereid`: other users are refused. Only VibeSwitcher.app
  connects; the phone goes through the app as today.
- **Spawning a session.** `forkpty` with the requested size, then in the child: `cd` to the project,
  set the environment, `exec $SHELL -l -i -c '<command>'` (interactive login shell, so PATH set up in
  `.zprofile` *and* `.zshrc` — nvm, Homebrew, etc. — matches Terminal). Environment adds `TERM=xterm-256color`, `COLORTERM=truecolor`,
  `TERM_PROGRAM=VibeSwitcher`, `VIBESWITCHER_SESSION=<id>`, plus the preset's variables. If the
  preset says "keep a shell after the agent exits", the command becomes `<command>; exec $SHELL -l`.
  A plain shell session is `exec $SHELL -l`.
- **Output.** A reader per session drains the PTY continuously into (a) a raw byte ring buffer
  (default 8 MB), (b) a headless SwiftTerm `Terminal` (the engine, no view), and (c) each attached
  client's bounded queue. **The PTY is never blocked by a slow client**: if a client's queue overflows,
  it is dropped from live output and sent a `resync` (see Attach).
- **Headless terminal.** Gives the host, per session: the window title (OSC 0/2), the current screen
  as text, and scrollback as text (last 5,000 lines). These replace AppleScript tab titles, screen
  reads and history for window sessions.
- **One answer per terminal query.** Programs ask the terminal things (cursor position, colors,
  capabilities) and wait for a reply. Both the headless engine and a window's terminal view would
  answer, doubling replies. Rule: while any client is attached, the host discards the headless
  engine's replies and forwards input only from the **primary** client (the one that most recently
  attached or sent keyboard input); input frames from other clients are still delivered, but their
  automatic query replies are dropped by the app before sending (the app marks replies vs. typed
  input). With no client attached, the headless engine's replies go to the PTY, so a session started
  or running while the window is closed never hangs on a query.
- **Attach / replay.** On attach the host sends the ring buffer from the latest **reset point** (a
  full-screen clear, alternate-screen switch or terminal reset recorded while reading; if none is in
  the buffer, from the oldest newline after the buffer start), then live output. After replay it
  nudges the program to redraw: resize the PTY to the client's size (a `TIOCSWINSZ` that changes rows
  by one and back sends SIGWINCH). Claude Code and Codex repaint fully on resize, so the visible screen
  is exact even when the replay start was approximate.
- **Exit.** When the child exits, the host records the exit status and keeps the session record and
  its last screen until the app removes it (or 24 h pass), so the window can show how it ended.
- **Ending a session.** `kill` sends SIGHUP to the session's process group (what closing a Terminal
  tab does), then SIGKILL after 5 s if it is still there.

### Protocol (shared, in VibeCore)

Length-prefixed frames: 4-byte big-endian length, 1-byte kind (`0` JSON control, `1` output bytes
for a session), payload. Max frame 1 MB; larger output is split. Control messages (`HostMessage`,
Codable):

| From app | Reply / effect |
|---|---|
| `hello {protocolVersion, app}` | `welcome {protocolVersion, hostVersion, sessions}` |
| `spawn {cwd, command?, env, cols, rows, keepShell, label}` | `spawned {session}` |
| `attach {id, cols, rows}` / `detach {id}` | replay output frames, then live; `attached {id}` marks the end of replay |
| `input {id, base64 bytes, reply}` | written to the PTY (`reply`: an automatic answer to a terminal query, see "One answer per terminal query") |
| `resize {id, cols, rows}` | `TIOCSWINSZ` |
| `screen {id}` / `history {id, lines}` | `screenText {id, text}` / `historyText {id, lines}` |
| `kill {id}` / `remove {id}` | ends / forgets an ended session |
| `shutdown` | only honoured with no live sessions |

Host → app events: `sessionChanged {session}` (title, size, exit), `resync {id}` (client should
re-attach), `bell {id}`. A `HostSession` record: `id` (UUID), `tty`, `childPID`, `cwd`, `command`,
`label`, `title`, `startedAt`, `cols`, `rows`, `exited?{status, at}`.

### App side

- **`HostClient`** (VibeSwitcher): one connection; starts the host if the socket is missing;
  reconnects with backoff (0.2 s → 5 s); publishes `[HostSession]`; routes output frames to the
  terminal view attached to that session. While disconnected, terminal views show a "Reconnecting…"
  veil and keep their content; on reconnect they re-attach (replay + redraw).
- **`SessionStore`**: window sessions still appear through the existing scan (their agent process runs
  on the host's tty, and the hooks report that tty). The store gets the hosted ttys from `HostClient`
  and, for those, uses the host's title instead of a Terminal tab's, and the host's screen text for
  Claude's footer (background work). `Session` gains `hostID: UUID?` (set for window sessions; `inTerminalApp` keeps
  its meaning) and `agentSessionID` (the agent's own session id, for Resume). "Viewing" for a window session = main window is
  key and that session is selected. The window's list is `store.sessions` plus the hosted sessions
  the scan hasn't matched to an agent: plain shells, sessions whose agent has exited (kept shell or
  ended), and sessions started a moment ago whose agent the 2 s scan hasn't seen yet (shown as
  "Starting…" with the preset's agent). Those extra rows are window-only: not in the menu bar dots,
  notifications or phone.
- **Opening a session** (popover row, menu bar dot, notification, `--open`, phone): `.window` → show
  the main window and select it; `.terminalApp` → today's Terminal path, unchanged.
- **Phone access**: screen and scrollback for window sessions come from the host (`screen`/`history`),
  masked the same way (`Redaction`). Replies: identity check unchanged (the agent process still runs on
  that tty, same pid and start time, pairing and replies switch still allowed), then the sanitized text
  is written to the PTY, then Enter as a separate write 60 ms later (so the TUI doesn't treat it as part
  of a paste). No Accessibility permission, no focus changes, no typing into whatever is in front.
- **Pause**: window sessions are greyed and silenced as today; there is no window to minimize.

### Main window

An `NSWindow` with an `NSSplitViewController` of three panes; SwiftUI for the lists and chrome,
SwiftTerm's AppKit `TerminalView` for the terminal.

- **Left: sessions by project.** Each project (repo root or folder) is a section, ordered by the
  existing session order preference. Rows: status dot, name (custom name or task), activity and time
  ("⚙ Run unit tests · 3m"), agent badge, and a small "Terminal" tag for Terminal.app sessions. Ended
  window sessions stay greyed with "ended 3m ago · exit 0". Section header ⊕ starts a session or shell
  in that project. Right-click: Rename, Pause…, End Session, Resume (ended Claude/Codex sessions with a
  known session id: `claude --resume <id>` / `codex resume <id>`), Remove, Reveal in Finder.
- **Middle: the selected session.** A header bar (name, project path, status, agent, uptime; End and
  Resume buttons) over the live terminal. Selecting a Terminal.app session shows its last screen
  (from the existing AppleScript read) and an "Open in Terminal" button instead. No tab strip: the list
  is the switcher, and ⌘1–⌘9 pick the first nine sessions in list order.
- **Right: inspector.** Collapsible (⌥⌘0). In this part it shows session facts (folder, agent, model if
  known, started, pid, tty, command) and is the home for parts 2–3.
- **Window behaviour.** While the window is open the app switches to a regular app (Dock icon, ⌘-Tab);
  closing it goes back to menu-bar only. Frame, pane widths, inspector state and selection persist.
  The window is opened from: a new "Open Window" button in the popover, ⌘-click on the menu bar icon,
  `VibeSwitcher --window`, and any "open session" of a window session.
- **Keyboard.** ⌘N new session (current project, default preset), ⌥⌘N new shell, ⌘W end session
  (confirms if the agent is working or needs input), ⌘1–9 select, ⌘⌥↑/↓ previous/next session,
  ⌘J next session that needs you, ⌘+ / ⌘− / ⌘0 font size, ⌘F find in the terminal, ⌘K clear
  scrollback. Standard copy/paste and selection from SwiftTerm.

### Launch presets (replaces "Launch Commands…")

A preset: name, agent (`claude`, `codex`, or `shell`), command line, environment variables, "keep a
shell after it exits", and where it runs (window or Terminal.app). Built-ins: "Claude" (`claude`),
"Codex" (`codex`), "Shell". Each project can pick its default preset and add its own; global presets
apply to every project. Stored as JSON in `~/.vibeswitcher/presets.json` (project-specific ones keyed
by project root). The current `claudeCommand` / `codexCommand` preferences migrate into the built-ins.
⊕ shows: recent projects → presets for that project (default first). Starting in Terminal.app keeps
today's `Launcher.launch` path.

### Settings window

Standard macOS Settings (SwiftUI `Settings` scene equivalent in an AppKit app: an `NSWindow` with a
`TabView`): **General** (open window at login, new sessions run in window/Terminal, when an agent
exits: close / keep shell, ended sessions kept for 24 h), **Launch** (presets editor: list, add,
duplicate, delete, per-project defaults), **Terminal** (font family and size, theme — System,
Light, Dark, Solarized Light/Dark, plus custom colors for foreground, background, cursor, selection
and the 16 ANSI colors — cursor style and blink, scrollback lines, option as Meta, bell: none / visual
/ sound). Attention & alerts get their own tab in part 4. Settings apply live to open terminals.

## Errors and edge cases

- Host can't start (binary missing, socket in use by a stale file, spawn fails): the window shows a
  banner with the reason and a Retry button, and ⊕ falls back to Terminal.app for that launch. Stale
  socket files are removed when the lock is free.
- Socket drops: reconnect with backoff; views keep content under a veil; reattach replays.
- Bad project folder or command: the shell prints the error in the session (it runs through the
  login shell), the session ends, and its last screen stays visible.
- Very fast output (e.g. `cat` of a huge file): the host never blocks on clients; slow clients get a
  resync instead of an ever-growing queue.
- The Mac sleeps: nothing special; PTYs and processes continue as they do in Terminal.
- Two clients at once (rare: the single-instance guard keeps one menu bar copy, but a test build can
  connect too): both get output; query replies follow the primary-client rule above.
- Privacy prompts (Desktop, Documents…) for tools run inside window sessions will name VibeSwitcher
  instead of Terminal, since VibeSwitcher started them. Expected; noted in the README.
- Never tested on real sessions: automated and manual tests use scratch programs and throwaway
  sessions only (see the project's memory about a test that broke a real session).

## Testing

- **VibeCore unit tests:** frame encoding/decoding (split and joined frames, oversize rejection,
  truncated input), `HostMessage` round-trips, the ring buffer and reset-point replay start, preset
  resolution (project default → global → built-in; command line and env quoting into the shell
  command), the preset JSON migration from the old two preferences.
- **Host tests (`VibeHostTests`, real PTYs, scratch programs only):** spawn `/bin/sh -c` scripts in a
  host started on a temporary socket; read output; send input (`read x; echo got:$x`); resize delivers
  SIGWINCH (`trap 'echo winch' WINCH`); detach + reattach replays earlier output; a slow client gets
  `resync` while the PTY keeps draining; kill ends the process group; exit status recorded; a second
  host refuses to start while the lock is held; a connection from another uid is refused (unit-tested
  through the peer-check function).
- **App:** `SessionStore` merging hosted ttys (title, viewing, location) as pure functions in
  VibeCore where possible; manual checks in the real app with throwaway sessions: start, type, quit
  the app, relaunch and reattach, `build-app.sh --install` mid-session, phone screen/scrollback/reply
  against a scratch `cat` session.

## Code layout

- `Package.swift`: add SwiftTerm `exact: "1.19.0"` (latest stable; 1.99/2.0 is a week-old preview
  with breaking API changes). New targets: `VibeHost` (library: PTY, sessions, ring buffer, server),
  `vibeswitcher-host` (executable, tiny `main`), `VibeHostTests`.
- `VibeCore`: `HostProtocol.swift` (frames + messages), `RingBuffer.swift`, `LaunchPresets.swift`.
- `VibeSwitcher`: `HostClient.swift`, `MainWindow/` (`MainWindowController.swift`,
  `SessionListView.swift`, `TerminalPane.swift`, `SessionHeaderView.swift`, `InspectorView.swift`),
  `SettingsWindow.swift`, plus changes in `SessionStore`, `AppDelegate` (open, window, CLI),
  `PhoneAccess`, `RemoteInput` (hosted branch), `Launcher`, `Preferences`, `PopoverView`.
- `scripts/build-app.sh`: copy and sign `vibeswitcher-host` like the hook binary.

## Not in this part

Grid mode, alerts settings, inspector content (diffs, git, files, transcript, plan, tasks, memory,
stats), previews and outputs, moving an already-running Terminal.app session into the window (a
running process can't change terminals; such sessions stay listed and jump to Terminal as today).
