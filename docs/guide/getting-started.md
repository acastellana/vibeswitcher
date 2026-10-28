# Getting started

How to build and install VibeSwitcher, what the first launch asks, and what to do when something doesn't start.

## Requirements

- macOS 14 or later (`Package.swift`, `Resources/Info.plist`).
- A Swift 6 toolchain: Xcode, or only the Command Line Tools.
- `claude` (Claude Code) and/or `codex` on your login shell's PATH. Sessions start as `$SHELL -l -i`, so a command
  your Terminal finds is found here too (`Sources/VibeCore/LoginShell.swift`). The project lead runs Claude Code only.
- git. VibeSwitcher calls `/usr/bin/git`, which needs the Command Line Tools.
- Optional: Tailscale, for [phone access](phone-access.md); Node.js, only for the web tests.

## Build and install

```sh
./scripts/setup-signing.sh          # once, in Terminal
./scripts/build-app.sh              # build only: build/VibeSwitcher.app
./scripts/build-app.sh --install    # build, then replace /Applications/VibeSwitcher.app and open it
```

`build-app.sh` runs `swift build -c release` and puts the app together in `build/VibeSwitcher.app`: the app, the
session host (`vibeswitcher-host`), the hook (`vibeswitcher-hook`), the tool server (`vibeswitcher-mcp`), the phone's
web app and `vs-heavy`. `--install` is its only option. It quits the running VibeSwitcher (waiting up to 10 seconds),
replaces `/Applications/VibeSwitcher.app` and opens the new one. Sessions in the window keep running: the session host
hands itself over to the new build ([Architecture](architecture.md#handover-updating-without-ending-sessions)).

Run the app from the `.app` bundle, not with `swift run`: notifications, the login item and the Automation permission
need a real bundle.

### Signing

`scripts/setup-signing.sh` makes a self-signed identity, "VibeSwitcher Local Signing", in a keychain of its own
(`~/.vibeswitcher/signing`; your login keychain is untouched). Every build is signed with it, so macOS keeps the app's
Accessibility and Automation permissions across rebuilds. Without it, `build-app.sh` signs ad hoc, and macOS drops
those permissions at every rebuild while System Settings still shows them as on.

The script tells you which password it wants before each step:

- the certificate-trust dialog wants your Mac login password (Cancel is safe; the certificate stays untrusted);
- the signing keychain wants a new password of your choice, typed twice.

If you cancel or press Ctrl-C, it lists what it did; running it again continues from there.

The signing keychain is locked until you unlock it. The first build after you log in or wake the Mac asks for its
password in a dialog. It then stays unlocked, so later builds don't ask, until the Mac sleeps or you log out. A dialog
for it when you didn't start a build is something else trying to sign as VibeSwitcher: cancel it. To lock it yourself:

```sh
security lock-keychain ~/.vibeswitcher/signing/vibeswitcher.keychain-db
```

The key can't be exported and only `/usr/bin/codesign` may use it. `build-app.sh` refuses an identity made by an older
`setup-signing.sh` (one that saved its password in `~/.vibeswitcher/signing/password`); run the script again to
replace it. `scripts/test-signing.sh` checks the scripts.

Every binary is signed with the Hardened Runtime (`--options runtime`). The app carries one entitlement,
`com.apple.security.automation.apple-events`, so it can control Terminal (`Resources/VibeSwitcher.entitlements`).

### The keychain dialog after each install

The app keeps a key in your login keychain (service `dev.vibeswitcher.app-proof`) and uses it to prove to the session
host that it's the app ([Architecture](architecture.md#who-may-do-what)). A newly installed build asks macOS for that
key at launch, and macOS shows a dialog. Click **Always Allow**.

If you click Deny, the app has no key to prove itself with. The session host then doesn't treat it as the app: the
window's header says "The session host doesn't recognise this app" in red, no sessions are shown and new ones can't
start. Quit and open VibeSwitcher again to get the dialog back.

## First run

When nothing is set up yet, a welcome window opens. Each step says why it's needed, shows its live state and can be
skipped. Settings (⌘,) › General › **Show Welcome…** opens it again.

1. **Live status: the hooks.** It installs the hook binary in `~/.vibeswitcher/bin` and adds VibeSwitcher's entries
   to `~/.claude/settings.json` and `~/.codex/hooks.json`, beside your own hooks. It also marks the Codex hooks as
   trusted in `~/.codex/config.toml`. The first install keeps a copy of each file as `…vibeswitcher-backup`. Without
   hooks, sessions are still listed, from their titles and the process table, but less precisely.
2. **Terminal.** macOS asks whether VibeSwitcher may control Terminal: that's how it reads tab titles and brings a
   tab to the front. Sessions in VibeSwitcher's own window don't need it.
3. **Notifications.** A banner when a session needs you or finishes. Without permission you still hear a sound when a
   session needs input.
4. **Open at login.** On by default; nothing is registered until you click Done.

Running Claude Code sessions pick up the hooks at once; Codex sessions started before the install need a restart.

Accessibility isn't a welcome step. The menu bar list asks for it when several Terminal tabs share a window, so it can
list them in tab order; phone replies need it too.

Settings (⌘,) has five tabs: General, Agents (hooks, Codex trust, Terminal and Accessibility permissions), Phone,
Launch (presets: command, flags, environment, window or Terminal) and Terminal (font, colours, cursor, scrollback,
bell).

### Uninstalling the hooks

Settings › Agents, or `VibeSwitcher --uninstall-hooks`. The Codex trust entries (`hooks.state` in
`~/.codex/config.toml`) stay behind; they do nothing without the hooks and can be deleted by hand. Delete
`~/.vibeswitcher` to remove everything VibeSwitcher keeps.

## Troubleshooting

### "The session host doesn't recognise this app"

The app couldn't prove itself to the session host. Usually the keychain dialog was denied: quit and reopen
VibeSwitcher, then click **Always Allow**. If the app has a key but the host holds a different one, an alert offers
**Teach It This App's Key**; the host accepts a new key only while no session is running.

### The session host doesn't start

The app says "Couldn't start the session host: …" or "The session host didn't start. See ~/.vibeswitcher/host.log."
That file holds the host's own output. The window's **Restart Session Host** (VibeSwitcher menu) replaces it.

### A lead won't start on a new Mac

VibeSwitcher doesn't check for these itself, so check them by hand in Terminal:

- **`claude` isn't found.** Run `claude --version` in a new Terminal window. If it fails, install Claude Code and make
  sure your login shell's PATH has it (`~/.zprofile` or `~/.zshrc`); VibeSwitcher starts sessions through that shell.
- **git or the Command Line Tools are missing.** Run `/usr/bin/git --version`. On a Mac without the Command Line
  Tools it asks you to install them; run `xcode-select --install`, then start the lead again. You need them to build
  VibeSwitcher anyway.
- **The folder isn't a git repository.** Picking it offers "Make it a git repository and start the lead", "Start a
  plain Claude session" or "Cancel". A repository with no commits offers "Make a first commit and start the lead".
  Nothing is pushed.

### A session's VibeSwitcher tools are gone (/mcp)

Every lead, worker and verifier gets its tools from `vibeswitcher-mcp`, run under a keeper that restarts it and
reconnects Claude Code by itself (`Sources/VibeCore/MCPKeeper.swift`). The keeper gives up after 5 restarts in 60
seconds. A session started by a build from before the keeper (2026-10-28) doesn't have it. In either case, type
`/mcp` in that session and reconnect `vibeswitcher`, or start the lead again.

## Where the logs are

Everything VibeSwitcher keeps is in `~/.vibeswitcher` (folders `0700`, files `0600`). The logs:

| File | What's in it |
| --- | --- |
| `debug/app.log` | What the app did lately; rotated at about 1 MB. |
| `debug/host.log` | The session host's events: sessions started, ended or ended by whom, handovers, parser restarts, terminal resizes. |
| `debug/hang-*.log`, `debug/hang-*.txt` | A freeze report each time the app's main thread was stuck for more than 2 seconds: the app's state, the stacks and recent events (`.log`), and a 3-second sample (`.txt`). Kept 7 days, at most 500 MB. |
| `debug/mcp-<role>-<pid>.log` | One per tool server and keeper (role: lead, worker or verifier): names and numbers only. Rotated at 256 KB, deleted after 7 days. |
| `host.log` | The session host's own output, for when it doesn't start. |
| `remote/audit.log` | Every phone pairing and every input from a phone. |
| `app-status.json` | What the running app sees right now: each session's status, title, desktop and tab. |

Crash reports are in `~/Library/Logs/DiagnosticReports` (VibeSwitcher, vibeswitcher-host, vibeswitcher-mcp).
`VibeSwitcher --dump` prints the detected sessions and the raw hook state.
