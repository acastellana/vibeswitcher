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

The menu bar shows one dot per session (counts once there are more than 10). Click it or press
**⌃⌥V**, then click a row or press **1–9** / **↑↓ ⏎** to focus that session's Terminal tab.

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
`~/.claude/settings.json.vibeswitcher-backup` (and `~/.codex/config.toml.vibeswitcher-backup` if you made one).

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
cat ~/.vibeswitcher/app-status.json   # what the running app currently sees
```

(`VibeSwitcher` = `/Applications/VibeSwitcher.app/Contents/MacOS/VibeSwitcher`.)

## Development

```sh
swift build && swift test      # Swift Testing; works with Command Line Tools only
./scripts/build-app.sh --install
```

`Sources/VibeCore` holds the testable logic (status rules, hook reducer, process table, installer),
`Sources/VibeSwitcher` the AppKit/SwiftUI app, and `Sources/vibeswitcher-hook` the hook binary.
