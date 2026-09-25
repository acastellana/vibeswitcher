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

Or click **Install hooks** in the popover. Then:

- **Terminal.app** asks once whether VibeSwitcher may control Terminal. Allow it: that's how tab titles are
  read and tabs are selected.
- **Codex** asks you to trust new hooks once: run `/hooks` in a Codex session and trust the
  `vibeswitcher-hook` entries.

Uninstall the hooks with `--uninstall-hooks`. The first install keeps a copy of your original config as
`~/.claude/settings.json.vibeswitcher-backup`.

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

## Development

```sh
swift build && swift test                          # Swift Testing; works with Command Line Tools only
.build/debug/VibeSwitcher --dump                   # print detected sessions + hook state
.build/debug/VibeSwitcher --snapshot /tmp          # render popover + icon PNGs from live data
```

`Sources/VibeCore` holds the testable logic (status rules, hook reducer, process table, installer),
`Sources/VibeSwitcher` the AppKit/SwiftUI app, and `Sources/vibeswitcher-hook` the hook binary.
