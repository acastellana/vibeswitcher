# Architecture

How VibeSwitcher is put together: its processes, how they talk, and what keeps one session from acting as another.

## The pieces

| Piece | Code | What it does |
| --- | --- | --- |
| The app | `Sources/VibeSwitcher` | The menu bar, the window, the chat, Settings, phone access, the lead's controller and the witness. |
| Shared logic | `Sources/VibeCore` | Status rules, the hook reducer, the process table, the lead's board, tools and workflow, the vault's rules. Most tests are here. |
| The session host | `Sources/VibeHost`, `Sources/vibeswitcher-host` | Runs window sessions on PTYs, keeps them alive when the app quits, holds the vault. |
| The hook | `Sources/vibeswitcher-hook` | Run by Claude Code and Codex on each event; writes that terminal's latest facts. |
| The tool server | `Sources/vibeswitcher-mcp` | The MCP server that gives a lead, its workers and verifiers their tools. |
| `vs-heavy` | `Resources/bin/vs-heavy` | Mac-wide slots for test suites and release builds. |

In the app bundle, the four binaries are in `Contents/MacOS/` and `vs-heavy` in `Contents/Resources/bin/`.

## The session host

`vibeswitcher-host` is one process per user, started by the app and detached from it. It runs every window session:
it owns their PTYs, keeps what each printed, and passes output to every view attached to it over a Unix socket
(`~/.vibeswitcher/host.sock`). It keeps running when the app quits or crashes; reopening the window reattaches. With no
live session and no client for 10 minutes, it exits.

The host runs from a private copy of its binary (`~/.vibeswitcher/host/launcher-<build>`), which also starts the
session programs and the parsers, so an install that replaces the app doesn't pull the binary from under it.

**Parsers.** Each running session's output is parsed in a small process of its own
(`vibeswitcher-host --parse-session`): it holds that session's headless terminal (screen, 200 lines of scrollback,
title, its program status) and no PTY. The host passes output to views without waiting on any parser, so a parser that
crashes or hangs holds up only that session's screen. A watchdog replaces a parser that ended, or one with work waiting
and no progress for 10 seconds, with a new one rebuilt from what the session printed. After more than 5 failures in a
minute the session runs on without a parser: output still reaches views, but its screen stays as last shown. Each event
is a line in `~/.vibeswitcher/debug/host.log`.

### Handover: updating without ending sessions

When the app finds a host of another build, it replaces it if it has no sessions, and otherwise asks it to **hand
over** to the bundled build:

1. The host writes each session's details, its recent output and any unwritten input to a state file only you can
   read (`~/.vibeswitcher/host.lock.handover`).
2. It runs the new binary as a probe that reads that state, for up to 3 minutes. Only if the probe says it can take
   over does the host go on.
3. It re-executes itself in place as the new build: the same process, so every session stays its child, and its lock,
   socket and PTYs stay open.
4. The new build reads and deletes the state file, rebuilds each screen and nudges full-screen programs to repaint.

The vault's secrets never go into that file: they pass through a socket the new build inherits. If anything fails
before the exec, the old host carries on. If the new build can't restore, it goes back to the old build's copy. Only
the app may ask for a handover.

## The hooks

The hook binary is installed in `~/.vibeswitcher/bin/vibeswitcher-hook` and registered in `~/.claude/settings.json` and
`~/.codex/hooks.json` with a 5-second timeout. Claude Code runs it on SessionStart, SessionEnd, UserPromptSubmit,
PreToolUse, PostToolUse, PermissionRequest, Notification, Stop and PreCompact; Codex on most of the same, plus
Interrupt, PostCompact, SubagentStart and SubagentStop. It writes the terminal's latest facts (last event, your last
prompt, the agent's last message, both truncated) to `~/.vibeswitcher/state/<tty>.json`. It prints nothing, always
exits 0 and gives up after 3 seconds, so it never blocks an agent.

The hooks also carry steering: a message you send to a working agent waits until its next hook and reaches it there.

## How status is detected

Four sources, most precise first (`Sources/VibeCore/StatusRules.swift`):

1. **Hooks**, as above.
2. **The program's own status (OSC 7501).** In a window session the host answers the Program Status Protocol's query,
   and a program that speaks it reports working, blocked, done, error or idle. Hooks win when both exist.
3. **Terminal titles.** Claude Code titles its tab `✳ <task>` when idle and uses a spinner glyph while working. That
   covers sessions without hooks, and interrupts that fire no hook. A title overrides a hook only once the hook is more
   than 4 seconds old.
4. **The process table** (`sysctl`, not `ps`) finds every `claude` and `codex` process on a TTY, so every session is
   listed even before its first hook.

Background work is found in the process tree: shells a finished Claude session started that are still running.
Desktop numbers come from macOS's private SkyLight calls, looked up at runtime; without them, ordering falls back to
window position. Terminal's tab order is read through Accessibility.

## The tool server and its keeper

A lead, each worker and each verifier gets its tools from `vibeswitcher-mcp`, configured per role
(`--role lead|worker|verifier --root REPO [--task TASK]`). The lead's tools include `status`, `board`, `add_task`,
`update_task`, `start_worker`, `message`, `audit`, `merge`, `revert`, `cleanup`, `ask_user`, `record_decision` and
`configure`; a worker has `report`, `ask_lead`, `progress` and `answer_findings`; a verifier has `submit_audit`. When the
binary on disk changes (an install), the tool server switches to the new build in place.

Each runs under a **keeper** (`--keeper`, `Sources/VibeCore/MCPKeeper.swift`): the keeper holds Claude Code's
connection and runs the real server as its child. If the child dies, the keeper answers the calls it had in hand with
an error saying to check and call again, starts a new child, replays the handshake and tells Claude Code its tools may
have changed. Claude Code never sees the connection close, so nobody has to run `/mcp`. The keeper gives up after 5
restarts in 60 seconds. Each keeper and server logs names and numbers to
`~/.vibeswitcher/debug/mcp-<role>-<pid>.log`.

`auto_advance` runs inside the lead's tool server: it watches the project's `.vibeswitcher` folder (kevent, no
polling) and moves finished work on through the lead's own tools.

## The vault and roles

The team's records live in the session host's memory, in the **vault**:

- who holds which role (lead, worker, verifier) for which task, in which session;
- each task's review level, its worker's done report and evidence, its verdicts and findings;
- where the lead last left its branch, and approvals you gave for exact commits;
- a hash of each `workflow.md` guard rail as the lead last set it;
- the key that seals your messages to the lead, and the app's key.

On disk the vault is kept only sealed (`~/.vibeswitcher/lead/vault.sealed`, ChaChaPoly), with a key in your login
keychain that the host reads without asking. A sealed file that was changed, or sealed with another key, isn't
trusted: the vault starts empty, and `merge` then says an audit needs running again. With an ad-hoc signed build the
rebuilt host can't read its key, so the vault starts empty after a host replacement (a handover keeps it).

This is why a worker can't lower its own task's review level, give a verdict, or approve its own merge by editing
`board.json`: `merge` reads those from the vault.

## Who may do what

The host decides who is asking by the process on the other end of its socket, never by what it says
(`Sources/VibeHost/HostServer.swift`):

- It takes the connection's **audit token** when it accepts it (same user only), and checks it again on every read: a
  connection that a forked child or an exec'd image then uses counts as no one.
- A process inside a live session's process tree is **that session**.
- The **app** is the app only once it proves it on that connection: the host greets each connection with a fresh
  challenge, and only the app's code (its cdhash matching the app beside the host) answering with an HMAC under the
  app's key counts. That key is in your login keychain, readable without asking only by the app
  ([the keychain dialog](getting-started.md#the-keychain-dialog-after-each-install)), and in the vault. The app hands it
  to a host it starts on its stdin.

Then:

- **A session reaches itself and what it started.** Attaching, typing, resizing, reading the screen or history,
  and ending a session are allowed to the app, the session itself, any session started from it, and the lead of its
  team. The session list (`hello`) shows a caller only the sessions it can reach.
- **A lead reaches its team.** A session that holds a role takes keys only from the app, itself or its lead.
- **Only the app** may shut the host down or ask for a handover.
- **The census.** Any live session may ask how many team sessions are running, per repository and role: counts only,
  no ids or screens (`HostCensus`, `Sources/VibeCore/HostProtocol.swift`). Every lead uses it for the
  [Mac-wide limits](project-lead.md#mac-wide-limits).

So a worker's shell, whatever it sends on the socket, is the worker. It can't give a verdict, use the lead's tools,
seal a message as you or the lead, type into the lead's terminal, end another team's session, or hand the host over.

Messages reach a lead quoted under a line naming their sender, so a worker's report can't pass for your words. Only
the app sends as you; a line appended to an inbox without a seal reaches the agent as from an "unverified sender".

### Signing and the Hardened Runtime

Every binary is signed with the Hardened Runtime, which refuses injected libraries (`DYLD_*`). The app's one
entitlement is Apple Events, so it can control Terminal. With the local signing identity, the app's keychain item
trusts the identity (its designated requirement: identifier and certificate), not one exact build. The signing key
can't be exported and only `/usr/bin/codesign` may use it; see [Signing](getting-started.md#signing).

### What isn't protected

These are guard rails, not a sandbox: every session runs as you.

- Another program you run with your full rights, or one you approve in a keychain dialog meant for VibeSwitcher.
- While the signing keychain is unlocked, a process running as you can sign a binary as VibeSwitcher. Such a binary
  gets the app's permissions and keychain items, but it still isn't the app to the host, which checks the exact code
  beside it.
- Signals: any process running as you can end any other, the host included.
- What the sessions themselves run: the hook binary, Claude's settings, `CLAUDE.md`.
- Ordinary (non-team) sessions take keys from anyone running as you; the host records it, and the next merge asks you
  about commits such a session made.
- The code a merge's tests run from the branch itself. That's why a branch touching `sensitive_paths` is always
  audited.

The full review of the host's security, and the fixes made, are in [docs/security](../security/SECURITY-AUDIT.md).

## Privacy

Everything stays on your Mac, readable only by you (`~/.vibeswitcher` is `0700`, its files `0600`). The hook writes a
few facts per terminal to `~/.vibeswitcher/state/`; the Today totals are kept per day in `~/.vibeswitcher/stats/`
(project names and seconds). Nothing is sent anywhere except what you ask for: the Team tab's one-line summaries and
Brief me go to Claude through your own `claude` command, a briefing's text goes to ElevenLabs when you've saved a key
and press Brief me, and phone notifications pass through the browser's push service, encrypted. Delete
`~/.vibeswitcher` to remove all of it.

## Files in ~/.vibeswitcher

| Path | What |
| --- | --- |
| `state/<tty>.json` | The hook's facts per terminal. |
| `stats/<date>.json` | Today's totals per day. |
| `bin/vibeswitcher-hook` | The installed hook. |
| `host.sock`, `host.lock`, `host.log` | The session host's socket, lock and output. |
| `host/launcher-<build>` | The host's private copy of its binary. |
| `lead/vault.sealed` | The sealed vault. |
| `debug/` | `app.log`, `host.log`, freeze reports, tool server logs ([details](getting-started.md#where-the-logs-are)). |
| `remote/` | Phone access: paired devices, the push key, the audit log. |
| `policy.md` | Your working policy for leads and their teams. |
| `mac-limits.json` | The Mac-wide team limits. |
| `presets.json` | Launch presets. |
| `signing/` | The local signing identity's keychain. |
| `app-status.json`, `app-health.json` | What the app sees now; the health watcher's state. |

`VIBESWITCHER_HOME` (an absolute path) moves the whole folder; otherwise it's `.vibeswitcher` in
`CFFIXED_USER_HOME`, then `HOME`. The tests and the sandbox use that to keep off your own folder.
