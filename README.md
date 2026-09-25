# VibeSwitcher

A macOS menu bar app that tracks every Claude Code and Codex session running in your terminals, shows
what each one is doing, and jumps to its Terminal tab in one keystroke.

| Dot | Status | Meaning |
| --- | --- | --- |
| 🔴 | Needs input | Blocked on you: permission prompt, question, plan approval |
| 🟠 | Working | Thinking or running tools |
| 🟢 | Done | Finished a turn you haven't looked at yet |
| ⚪️ | Idle | Finished and already seen |
| ◯ | Unknown | No hooks and no readable title yet |

The menu bar shows one dot per session, oldest first, so each dot keeps its position.

- **Click a dot** to jump straight to that session's Terminal tab. Hover a dot to see which session it is.
- **Right-click** (or **⌃⌥V**) opens the list; there, click a row or press **1–9** / **↑↓ ⏎**.
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
   `Stop`).
3. **The process table** (`sysctl`, no `ps`). Finds every `claude` / `codex` process attached to a TTY, so
   every session is listed even before it sends a hook event.

Sessions are keyed by TTY, which also identifies the Terminal tab to focus. Sessions in other terminal apps
are listed too; clicking them activates the hosting app.

## Command line

```sh
VibeSwitcher --dump            # detected sessions + raw hook state
VibeSwitcher --toggle          # open/close the popover of the running app (bind it in Raycast etc.)
VibeSwitcher --open ttys012    # ask the running app to open a session (same path as clicking its row)
VibeSwitcher --focus ttys012   # select a Terminal tab directly (no activation handling)
VibeSwitcher --snapshot /tmp   # render popover + menu bar icon PNGs from live data
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
