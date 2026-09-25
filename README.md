# VibeSwitcher

A macOS menu bar app that tracks every Claude Code and Codex session running in your terminals, shows
what each one is doing, and jumps to its Terminal tab in one keystroke.

| Dot | Status | Meaning |
| --- | --- | --- |
| 🔴 | Needs input | Blocked on you: permission prompt, question, plan approval |
| 🟠 | Working | Thinking or running tools |
| 🔵 | Background | Turn ended, but background shells/tasks are still running; it will resume on its own |
| 🟢 | Done | Finished a turn you haven't looked at yet |
| ⚪️ | Idle | Finished and already seen |
| ◯ | Unknown | No hooks and no readable title yet |

The menu bar shows one dot per session, in the order of your desktops: sessions on Desktop 1 first, then
Desktop 2, and so on (as Mission Control and ⌃← / ⌃→ order them); windows sharing a desktop go in reading
order, tabs in tab order. Each row says which desktop it's on. Prefer oldest-first? Switch it in ⚙︎.
While a session runs a tool, its row shows what and for how long ("⚙ Run unit tests · 3m", orange after 10 min).

- **Click a dot** to jump straight to that session's Terminal tab. Hover a dot to see which session it is.
- The session whose Terminal tab you're looking at has a **ring** around its dot (and a "Viewing" tag in the list).
- **Right-click** (or **⌃⌥V**) opens the list; there, click a row or press **1–9** / **↑↓ ⏎**.
- **Right-click a row › Rename…** to give a session your own name (kept while it runs, and across
  `--resume` when the session id is kept).
- **⊕ in the list header** starts a new session: pick a recent project (from your running sessions, Claude
  Code's project list and Codex's trusted projects) and Claude Code or Codex, and a new Terminal window
  opens there. The commands it runs are editable (e.g. add `--model`), under ⊕ › Launch Commands….
- The icon stays narrow: up to 4 sessions in one row, then two rows of small dots (12 max, then counts).

**Crowded menu bar?** On notched MacBooks, macOS silently hides status icons that don't fit right of the
notch. VibeSwitcher starts next to the clock, where overflow never reaches (⌘-drag it elsewhere if you
like). If its icon does get hidden, a floating pill with the same numbered dots appears automatically;
drag it anywhere. Set it to Always / Never in the ⚙︎ menu.

## Install

```sh
./scripts/build-app.sh --install        # builds, copies to /Applications, launches
/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher --install-hooks
```

Or click **Install hooks** in the popover. That installs the hook binary, adds hooks to both agents'
configs, and marks the Codex hooks as trusted (the same `hooks/list` + `config/batchWrite` calls that
Codex's own `/hooks` screen makes through `codex app-server`). Then macOS asks twice:

- **Control Terminal**: allow it. That's how tab titles are read and tabs are selected.
- **Notifications**: allow it to get a banner when a session needs you (with sound) or finishes. Clicking
  the banner jumps to that tab. Without permission you still get a sound when a session needs input.

Running Claude Code sessions pick the hooks up immediately; Codex sessions started before the install
need a restart. VibeSwitcher registers itself as a login item on first launch (toggle it in the ⚙︎ menu).

Uninstall the hooks with `--uninstall-hooks`. The first install keeps copies of your original configs as
`~/.claude/settings.json.vibeswitcher-backup` and `~/.codex/hooks.json.vibeswitcher-backup`. The Codex trust
entries (`hooks.state` in `~/.codex/config.toml`) stay behind after uninstalling; they are inert without the
hooks and can be deleted by hand.

## Privacy

Everything stays on your Mac. The hook writes a few facts per terminal (last event, your last prompt, the
agent's last message, both truncated) to `~/.vibeswitcher/state/`, and the app reads them plus Terminal's
tab titles. Nothing is sent anywhere. Delete `~/.vibeswitcher` to remove all of it.

## How status is detected

Three sources, most precise first:

1. **Hooks.** Claude Code (`~/.claude/settings.json`) and Codex (`~/.codex/hooks.json`) run
   `~/.vibeswitcher/bin/vibeswitcher-hook` on `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
   `PermissionRequest`, `Notification`, `Stop`, `Interrupt` (Codex), `PreCompact` and `SessionEnd`. The hook
   writes that terminal's latest facts to `~/.vibeswitcher/state/<tty>.json`. It prints nothing and always
   exits 0, so it can never block an agent.
2. **Terminal tab titles.** Claude Code titles its tab `✳ <task>` when idle and uses a spinner glyph while
   working. That covers sessions without hooks, plus the transitions hooks miss (Esc interrupts fire no
   `Stop`). For finished Claude sessions the footer is read too: `1 shell` / `2 background tasks` there
   means it's waiting on background work (🔵).
3. **The process table** (`sysctl`, no `ps`). Finds every `claude` / `codex` process attached to a TTY, so
   every session is listed even before it sends a hook event.

Desktop numbers come from macOS's private SkyLight window-server calls (the same ones yabai and Hammerspoon
use), looked up at runtime; if they're ever unavailable, ordering falls back to window position.

Sessions are keyed by TTY, which also identifies the Terminal tab to focus. Sessions in other terminal apps
are listed too; clicking them activates the hosting app.

## Command line

```sh
VibeSwitcher --dump            # detected sessions + raw hook state
VibeSwitcher --toggle          # open/close the popover of the running app (bind it in Raycast etc.)
VibeSwitcher --open ttys012    # ask the running app to open a session (same path as clicking its row)
VibeSwitcher --focus ttys012   # select a Terminal tab directly (no activation handling)
VibeSwitcher --snapshot /tmp   # render popover + menu bar icon PNGs from live data
VibeSwitcher --new claude ~/dev/app   # new Terminal window running the configured command there
VibeSwitcher --install-hooks | --uninstall-hooks
cat ~/.vibeswitcher/app-status.json   # debug aid: what the running app currently sees
```

(`VibeSwitcher` = `/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher`.)

## Development

Requires macOS 14+ and a Swift 6 toolchain (Xcode or just the Command Line Tools).

```sh
swift build && swift test      # Swift Testing; works with Command Line Tools only
./scripts/build-app.sh --install
```

Run the app through `build-app.sh` rather than `swift run`: notifications, the login item and the
Automation permission all need a real `.app` bundle.

`Sources/VibeCore` holds the testable logic (status rules, hook reducer, process table, installer),
`Sources/VibeSwitcher` the AppKit/SwiftUI app, and `Sources/vibeswitcher-hook` the hook binary.
