# Window UI 2: the cockpit

Builds on the IDE window (spec `2026-10-16-ide-window-session-host-design.md`). Comes before parts 2–4
(inspector depth, previews, grid); part 2 extends the Activity tab added here.

## Product

You run many agents at once. The window exists to answer, in order:

1. **Who needs me?** Sessions waiting on you are on top, with how long they've waited.
2. **How do I get there?** One keystroke: ⌘J (next needing you), ⌘1–9, ⌘K (palette).
3. **What has it been doing?** Without scrolling the terminal: status, current tool, recent activity.
4. **Answer and move on.** The terminal (or Terminal.app for sessions running there) is one click away.

What the user said that drives this: "so I don't need to be having a hundred different terminals open",
"extremely full-fledged", the focus view matters more than the grid, statistics and session files must be
visible (parts 2–3). "Level up the UI a lot more — you decide, think about the product."

## Sidebar: attention first

- **Two groupings**, switched with a segmented control at the top of the sidebar and remembered:
  - **Attention** (default): *Needs you* (needs input; longest waiting first), *Working* (working and
    background; earliest started first), *Ready* (done, not yet seen; most recent first), *Idle* (idle,
    unknown, paused, Terminal sessions with unknown state, ended window sessions, shells; project order).
    Empty groups are hidden. Paused sessions always go to Idle.
  - **Projects**: today's sections, with the ⊕ menu shown on the header.
- Group headers show a count.
- **Row** (two lines):
  - agent mark: a 20 pt rounded square in the agent's color (Claude coral, Codex grey-blue, shell grey)
    with a glyph, and a status dot on its corner (red needs input, orange working, blue background,
    green ready, grey otherwise; hollow for unknown);
  - line 1: title (custom name › task › host title › project), semibold, one line;
  - line 2: in Attention grouping `project · state`, in Projects grouping just `state`, where state is
    the current tool and its time ("Run tests · 3m"), "waiting 12m", "done 5m ago", "ended · exit 1",
    "Shell", or the hook detail;
  - trailing: time in state (monospaced digits), a small "Terminal" icon when it runs in Terminal.app.
- Ended and paused rows are dimmed. Times refresh every 30 s.
- **Footer**: a filter field (⌥⌘F focuses it) that keeps rows whose title, project or task contain the
  text (case-insensitive), and a one-line summary: "2 need you · 3 working".
- Keyboard order (⌘1–9, ⌥⌘↓/↑, ⌘J) follows the rows as shown.

## Header: the session bar

One 52 pt bar above the terminal:
- agent mark, title (double-click renames agent sessions), status pill (colored capsule: "Needs input ·
  4m"), and on a second line: `~/path` · ⎇ branch · current tool.
- Right side, icon buttons with tooltips: *Open in Terminal* (Terminal sessions), *Resume* / *Remove*
  (ended window sessions), *End* (live window sessions), then a ••• menu: Rename…, Pause ▸, Copy Session
  ID, Copy Resume Command, Reveal in Finder.
- The window title is the selected session's title (shows in ⌘`, Mission Control, Window menu).
- Host problems (connecting / failed / outdated) stay in the bar as today.

Branch: read from `.git/HEAD` of the project root (`ref: refs/heads/x` → `x`; a detached HEAD → first 7
characters of the hash; a `.git` *file* with `gitdir:` is followed). No git process is run.

## Middle pane

- **Window sessions**: the terminal gets a 10 pt inset; the margin uses the terminal's background color.
  When the session has ended, a bar along the bottom says "Ended · exit N · <time>" with Resume (when
  possible) and Remove.
- **Terminal.app sessions**: a mirror. A banner ("Runs in Terminal" + Open in Terminal, ⌘O) over the tab's
  screen, drawn unwrapped (horizontal scroll) in the terminal font, scrolled to the bottom, re-read every
  2 s while shown.
- **Nothing selected / no sessions**: a start page. "Start a session" with up to 8 recent projects, each
  with its presets as buttons (default preset first), "Choose Folder…", and the keyboard hints
  (⌘K, ⌘N, ⌘J, ⌘1–9).

## Inspector: Overview and Activity

A segmented control at the top: **Overview** | **Activity** (remembered).
- **Overview**, grouped cards:
  - Status: state, since when, current tool.
  - Place: folder (Reveal), branch, runs in (Window / Terminal).
  - Time: started, running for.
  - Agent: agent, session id (copy button), process (pid on tty), command (window sessions), exit.
- **Activity**: the last ~60 entries of the agent's transcript (`TranscriptWindow` tail, 256 KB), newest
  at the bottom, as compact rows: your prompts (bold, 3 lines), replies (2 lines), tool calls (tool name,
  one-line description, duration, ✕ when failed). Re-read when the session's hook event time changes
  (and at most every 2 s). "No transcript for this session" otherwise.

## Command palette (⌘K)

A floating panel over the window: a search field and results.
- Items: every session row ("project-c — Borderless work", subtitle state); "New <preset> in <project>" for
  recent projects × their presets; window commands (New Session…, New Shell, Group by Attention/Projects,
  Toggle Inspector, Settings…, Next Needing You).
- Fuzzy match: the query's characters must appear in order (case-insensitive). Score favors matches at
  the start of words and runs of consecutive characters, then shorter candidates. Empty query: sessions
  needing you first, then other sessions, then commands.
- ↑/↓ move, Return runs, Escape or clicking outside closes. At most 50 results shown.

## Small things

- Dock badge: number of sessions needing you while the window is open (cleared at 0).
- Menu additions: View › Group by Attention (⌘⌃1) / Projects (⌘⌃2), View › Filter Sessions (⌥⌘F),
  Session › Command Palette (⌘K), Session › Open in Terminal (⌘O). Clear Scrollback moves to ⇧⌘K.

## Testing

Pure logic lives in VibeCore with unit tests: attention grouping and ordering, row filtering, fuzzy
matching and ranking, the branch reader, row state text, activity rows from transcript entries. The
views are checked with `--capture-window` captures against scratch sessions only (never real sessions:
no input sent to them).

## Out of scope

Grid mode, previews, statistics, files/plan/memory (parts 2–4); replying to Terminal.app sessions from
the window; light-mode-specific tuning beyond using system colors.
