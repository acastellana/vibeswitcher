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
order, tabs in tab order. Each row says which desktop it's on. Prefer oldest-first? Switch it in ⚙︎.
While a session runs a tool, its row shows what and for how long ("⚙ Run unit tests · 3m", orange after 10 min).

- **Click a dot** to jump straight to that session's Terminal tab. Hover a dot to see which session it is.
- The session whose Terminal tab you're looking at has a **ring** around its dot (and a "Viewing" tag in the list).
- **Right-click** (or **⌃⌥V**) opens the list; there, click a row or press **1–9** / **↑↓ ⏎**.
- **Right-click a row › Pause** (until you resume it, for 1 hour, until tomorrow morning, or for a week), or select it
  and press **P**, to park a session you're waiting on or don't want to deal with now. It stays in its place
  but greyed out (dot, row, floating panel, phone), sends no notifications or reminders, and its waiting
  doesn't count in Today. Pausing also minimizes the session's window to the Dock when it's the only tab there
  (⚙︎ to turn off); Resume brings it back. Pauses survive restarts; timed ones end by themselves (the window
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

**Today** (at the bottom of the list): how long agents were working today (in a turn; background jobs are
listed per project, since a leftover dev server isn't work), and how long sessions were waiting on you:
a question or permission prompt, or a finished turn you hadn't looked at (its first 30 minutes; after that
you've set it aside). Waiting only counts while you're at the Mac (screen unlocked, input in the last
5 minutes). Expand it for a per-project split.

**Crowded menu bar?** On notched MacBooks, macOS silently hides status icons that don't fit right of the
notch. VibeSwitcher starts next to the clock, where overflow never reaches (⌘-drag it elsewhere if you
like). If its icon does get hidden, a floating pill with the same numbered dots appears automatically;
drag it anywhere. Set it to Always / Never in the ⚙︎ menu.

## Phone Access (over Tailscale)

See your sessions on your phone: the list with live status, each session's screen, the Today summary,
and notifications when a session needs you or finishes. Optionally reply and press keys (Esc, 1–3, ↑↓, ⏎, ⌃C).

1. ⚙︎ › **Phone Access…** › turn it on. It needs Tailscale on this Mac with HTTPS certificates enabled
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
   - Only pages open in Chrome right now can be opened; your other local servers can't be reached.
   - Each page gets its own HTTPS port on your tailnet (8444–8447) through a proxy in VibeSwitcher. Every
     request must come from your own Tailscale account and carry a cookie that only the paired phone can
     get, from a link that works once, for a minute.
   - At most 4 pages at once. A fifth takes over the least recently used page's port: a phone tab still open
     on the old page then shows the new one (its storage is cleared). Reopen the old one from the list. Links hard-coded to
     `http://localhost:…` inside the app won't work on the phone, dev servers that only serve HTTPS aren't
     supported, and cookies a dev app sets are shared between its previews (browsers scope cookies by
     host, not port).

How it's kept safe:

- **Tailnet only.** The server listens on `127.0.0.1`; `tailscale serve` (never Funnel) is the only way in,
  over HTTPS. Requests must come from this Mac's own Tailscale account, which Tailscale vouches for.
- **Paired devices only.** Every request needs a device token, handed out once per pairing with a
  one-time code shown on the Mac (10 minutes, one use, 5 attempts). Only a hash of each token is kept.
  Remove a device on the Mac or unpair it from the phone; its token stops working immediately.
- **Replies are remote control.** Your sessions can run commands, so typing is a separate switch. The tab is
  brought to the front and verified before anything is typed, keys go to Terminal only, and nothing is
  typed while the Mac is locked. Every pairing and input is written to `~/.vibeswitcher/remote/audit.log`
  and announced on the Mac.
- **Minimal data.** Credentials are masked in everything sent to the phone. Notifications are end-to-end
  encrypted (Web Push, RFC 8291): Google's push service relays them but can't read them. By default the
  phone is notified only while you're away from the Mac. No page content is cached on the phone.

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
  The banner says what's being asked: the question, the exact command waiting for approval
  ("Run: npm publish"), or the plan's title; a finished session shows the start of its last message.
  One reminder follows if a session has waited on you for 10 minutes (looking at its tab restarts the
  clock), or if a working session has shown no progress for 15 minutes, which usually means it's stuck.
  Reminders wait while you're away from the Mac. Turn them off in ⚙︎. Credentials in commands and
  messages (tokens, passwords, API keys, `Authorization` headers, `user:pass@` URLs) are masked before
  they are stored or shown.

Running Claude Code sessions pick the hooks up immediately; Codex sessions started before the install
need a restart. VibeSwitcher registers itself as a login item on first launch (toggle it in the ⚙︎ menu).

Uninstall the hooks with `--uninstall-hooks`. The first install keeps copies of your original configs as
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

Run `./scripts/setup-signing.sh` once: it creates a self-signed signing identity in its own keychain
file (`~/.vibeswitcher/signing`, your login keychain is untouched) so every rebuild keeps the same code
identity, and trusts that certificate for code signing (your user only; macOS asks for your password).
macOS only keeps a permission across rebuilds for a trusted signature: otherwise, ad-hoc or not, it pins
the Accessibility and Automation permissions to the exact build and silently drops them on the next one,
while System Settings still shows them as on.

Run the app through `build-app.sh` rather than `swift run`: notifications, the login item and the
Automation permission all need a real `.app` bundle.

`Sources/VibeCore` holds the testable logic (status rules, hook reducer, process table, installer),
`Sources/VibeSwitcher` the AppKit/SwiftUI app, and `Sources/vibeswitcher-hook` the hook binary.
