# VibeSwitcher 2: a node on every machine

Status: direction agreed with the user 2026-11-12; details open to correction. Nothing here is built.

The user, on the start: "port VS over to Linux (currently we're in Ubuntu WSL) in a way that will not be crazy to be
updating when changes happen to VS." On use: "running multiple project leads etc. like on the app." On the UI: "It
can be a web app … It just needs to be extremely real-time and slick." On plugins: "the wallet manager is something
that only I want, probably … maybe other people will want to do their own." On who builds it: "I want you to do it
totally from this computer." On the branch: "a completely separate branch … I don't want to go to main until
everything is working extremely well here. Let's make this the following major version." On the Mac: "whatever
plugins or interface … is specific to Mac should just be there and we can build it there, but I first want you to
build everything else here." On reach: "Let's imagine it's a headless Linux server … work on any computer, in the
cloud, and spread tasks across different devices. Let's think big." On security: "I lean towards stronger."

Lines marked **(call)** are the author's choices, not the user's; each can be overruled. Lines marked **(open)** need
the user.

## Intent

VibeSwitcher 2 is VibeSwitcher as a **node**: one headless program that runs on a Linux machine, a Mac or a cloud
VM, hosts the sessions there, runs the project leads and enforces their rules. What you look at is a **client** of a
node: the web app in any browser, on a desk or a phone; a command line; later the native Mac app. Nodes that belong
to one person form a **fleet**: one window shows every session on every machine, and a lead on one node can place
workers, audits and test runs on the others.

It starts as the Linux port, on this Ubuntu WSL2 machine, because the port forces the split between what runs agents
and what shows them. Drawing that split as a network boundary from the first line is cheap now and a rewrite later.

It is built on a branch, `v2`, pushed to GitHub and kept current by merging main into it, and reaches main only when
it is solid on both systems.

## Milestones

| # | Milestone | What the user gets | Built |
| --- | --- | --- | --- |
| 1 | One node on Linux, the web app | The whole lead workflow on this machine, in a browser | here |
| 2 | Remote | The full app from any of the user's devices over Tailscale; the phone app renewed on the same client | here |
| 3 | Fleet view | Every node's sessions and leads in one window | here, with a second node |
| 4 | Distributed teams | A lead places workers, verifiers and test runs on other nodes | here and on the Mac |
| 5 | The Mac on version 2 | The Mac runs a node; the native app is its client, with the Mac-only plugins | on the Mac |
| 6 | Cloud nodes | Nodes that join for a burst of work and leave | later |

This document designs milestone 1 in full, milestone 2 enough to build, and gives 3 to 6 their direction and the
rules that milestone 1's code must already follow for them. Each of 3 to 6 gets its own design when it starts.


## What exists (measured 2026-11-12)

| Part | Lines | Depends on | On Linux |
| --- | --- | --- | --- |
| `VibeCore` | 60,700 | Foundation, Darwin, CryptoKit; a few files on Security, Network, CoreGraphics, ImageIO | portable with a platform layer |
| `VibeHost`, `vibeswitcher-host` | 3,800 | VibeCore, SwiftTerm, Darwin, Security | portable; SwiftTerm's headless terminal builds on Linux |
| `vibeswitcher-hook`, `vibeswitcher-mcp` | 600 | VibeCore, Darwin | portable |
| `VibeSwitcher` (the app) | 49,700 | AppKit, SwiftUI, Combine and 15 more Apple frameworks | not portable |
| `Web/` (the phone app) | 2,300 | vanilla JS, no build step | already portable; polls on timers |

Mac-only calls in the portable parts: `proc_pidinfo` (29), `posix_spawn` (17), `sysctl` (13), `kevent`/`kqueue` (15),
`NWConnection`/`NWListener` (14), Keychain `SecItem*` (8), `SecCode*` (3), `LOCAL_PEERPID` and the audit token,
`osascript` (4), `launchctl` (1).

The part that decides the cost: the app target holds logic a Linux server needs, mixed with AppKit. `LeadController`
(2,295 lines), `ChatModel`, `ChatSync`, `SessionStore`, `HostClient`, `WindowModel`, `PhoneAccess` (the phone's API,
1,755 lines), `PhoneLeads`, `RemoteServer`, `Preferences`, `WalletDesk`, `ShellDesk`. Most import AppKit
for a handful of uses each; Combine runs through all of them (119 `@Published` properties in the files named).

## Goals

For milestones 1 and 2:

1. On Ubuntu 24.04 (WSL2, bare, or a headless server), one command starts the node; a browser window is the app.
2. Everything the lead workflow does on the Mac works: start a lead on a folder, plan, workers in worktrees (Claude
   and Codex), audits, the merge gate, the config seal and Accept cards, the limits and Boost, steering, questions as
   cards, the Team tab, the scorecard, receipts, provenance trailers, records in `docs/lead/`.
3. Sessions run in the session host and survive the server restarting or updating, as on the Mac.
4. The web app feels local: see [Real-time and slick](#real-time-and-slick) for what that means in numbers.
5. The full app from another device over Tailscale, with rights set per device.
6. What main gains while the branch lives reaches the branch by a merge, with no second implementation.
7. Optional features are plugins: wallet is on for the user, absent for everyone else.
8. On the branch the Mac app still builds and behaves as on main, until milestone 5 changes it on a Mac.
9. On Linux the guard rails hold against a worker that tries, not only one that slips.

## Non-goals

- A native Linux GUI (GTK, Qt), a tray icon or menu bar dots.
- Terminal.app control, Spaces and desktop ordering, sidebar mode, the global hot key, open-at-login through
  ServiceManagement. These are the Mac's platform plugins, built on the Mac in milestone 5.
- Changing the Mac app's screens from here.
- Loading third-party plugin code. Plugins are compiled into this repository.
- Native Windows, or other distributions than Ubuntu LTS, as tested targets.
- Reaching a node over the open internet. Tailscale is the network between a person's devices and nodes.
- Several people sharing one node or one fleet.
- In milestone 1 **(call)**: dictation, the spoken briefing, the Statistics window, dev previews, freeze reports.
  Each is listed in [Parity](#parity) with what it would take.

## Anti-goals

Any of these makes the project a failure even if it runs:

- A branch that drifts: main's work has to keep arriving by merge, cheaply, until the day the branch lands.
- `#if os(...)` spread through the logic. Platform differences live in one folder per target (below).
- A feature that has to be built three times (Mac, web desktop, phone) to exist everywhere.
- A security property that holds on the Mac and silently doesn't on Linux. Each difference is written down in
  `docs/guide/architecture.md` and, where it matters to a merge, enforced or refused.
- A web client that polls, or shows a terminal as snapshots of a screen.
- Milestone 1 code that milestone 3 or 4 has to rewrite: see [Rules from the first line](#rules-from-the-first-line).
- Reaching main with a slower or less stable Mac app. The existing benches (`scripts/test.sh --perf`, the UI bench,
  the freeze count) are the measure.


## Architecture

### Nodes, clients, fleet

```
 clients                         nodes                                  agents
 ┌───────────────┐   live    ┌──────────────────────────┐
 │ web app       │◄─────────►│ server: leads, witness,  │   ┌─ lead (claude)
 │ (desk, phone) │  protocol │         API, peers       │   ├─ workers (claude, codex)
 ├───────────────┤           ├──────────────────────────┤──►├─ verifiers
 │ vibeswitcher  │           │ host: PTYs, vault,       │   └─ your own sessions
 │ (command line)│           │       devices, identity  │
 ├───────────────┤           └────────────▲─────────────┘
 │ Mac app (M5)  │                        │ the same protocol, node to node (M3, M4)
 └───────────────┘           ┌────────────▼─────────────┐
                             │ another node: a Mac,     │
                             │ a server, a cloud VM     │
                             └──────────────────────────┘
```

- **A node** hosts sessions and runs leads on one machine. It has no UI. Everything VibeSwitcher decides is decided
  in a node.
- **A client** shows a node, or a fleet through one node, and sends the user's actions. It holds no state that
  matters and reads no file: everything comes over the live protocol.
- **A fleet** is the user's nodes. Each has a key of its own, made at install and kept by its host. A node joins
  when the user accepts it from a device with full rights. Nodes talk over the tailnet.
- **Placement** (milestone 4): a lead asks its node for a worker, a verifier or a test run with what it needs (a
  system, cores, a toolchain, an account with quota), and the fleet's nodes offer. The code travels as git: the
  placing node pushes the base to the working node, the working node pushes `agent/<task>` back. Contracts, reports
  and findings travel as messages. The merge gate is unchanged, since it already takes one exact checked commit, and
  its tests can themselves be placed (a Mac for a Mac project's suite).
- **Any mix of machines.** Nothing in the design names a machine or a kind of machine. A node describes itself by
  what it offers: its system, cores and memory, the toolchains and plugins it has, the agent accounts logged in on
  it and their quota, whether it is on AC power, whether it is always on. Placement matches a task's needs against
  those, so a laptop, a workstation, a home server and a rented VM are the same thing with different answers.
- **Plugins** are of two kinds. **Platform plugins** are what one system has and another doesn't: on the Mac,
  Terminal.app, the menu bar, Spaces, dictation capture, the Keychain; on Linux, systemd, `/proc`. **Feature
  plugins** are what one user wants and another doesn't: wallet, shell. A node says which it has, and a client shows
  only those.

### Rules from the first line

Milestone 1 runs on one machine. Its code still follows these, so that milestones 3 and 4 add and don't rewrite:

1. **Ids are fleet-wide.** A session, a task, a card, a device is named by an id that stays unique when nodes meet;
   on the wire each carries its node.
2. **Clients go through the protocol only.** No client opens a file, a socket to the host, or a path. Images,
   diffs and transcripts are served.
3. **The protocol is versioned and additive.** Nodes and clients of different builds will meet. A message may gain
   fields; a kind nobody understands is skipped; each side states what it can do (the host protocol's
   `capabilities` already work this way).
4. **A lead reaches its team through one seam.** Starting a worker, reading its branch, sending it a message and
   hearing its report go through one interface with one implementation today: same machine, same repository. No
   new code reaches into a worker's worktree around it.
5. **Limits are a node's.** `mac-limits.json` becomes the node's limits; the census is per node. A fleet's limits
   are a later sum of them, not a new mechanism.
6. **Who acts is a principal**: a device with rights, a node, or a session with a role. Never "the app".
7. **Order comes from sequence numbers**, never from comparing two machines' clocks.
8. **Each setting says whose it is**: this node's, or the user's everywhere. Only the first kind exists until
   milestone 3; the catalog records which is which from the start.

### Building without a Mac

Everything in milestones 1 to 4 is built on Linux, so nothing the Mac compiles can be run by its author, and main
keeps moving under the branch. Three rules follow:

1. **The branch's Mac build is checked by CI.** Every push to `v2` is built and tested by a macOS runner and an
   Ubuntu runner. The repository is public, so both are free.
2. **Only mechanical changes to code the Mac compiles**, until milestone 5. Allowed: putting a system call behind
   the platform layer; moving a file's Mac-only lines into a `+Mac.swift` file beside it; an import chosen by
   `#if canImport`. Not allowed from here: changing what the Mac app does, or how its views are built. This is
   also what keeps merging main cheap: a file that main changes a hundred times while the branch lives had better
   differ from main's by a few lines.
3. **What needs eyes on the Mac app waits for milestone 5**, on a Mac, with its tasks written as they are found in
   `docs/process/v2-mac-tasks.md`: the Mac running a node, the native app as its client, the Mac's platform
   plugins, the Mac's cards on card data, the wallet's extraction there.

### Targets

```
VibeCore              shared model and rules                           (both)
VibeHost              PTYs, replay, socket server, vault               (both)
VibeSwitcher          macOS: the whole app, as today                   (macOS)
vibeswitcher-server   Linux: the app's logic files + Server/ + Web/    (Linux)
vibeswitcher-host, -hook, -mcp                                         (both)
```

**(call)** One folder, two file sets. The app's logic stays where it is, in `Sources/VibeSwitcher`. On macOS the
`VibeSwitcher` target compiles all of it, exactly as today. On Linux the manifest (`#if os(Linux)`) defines
`vibeswitcher-server` over the same folder with a `sources:` list naming only the portable files, plus
`Sources/VibeSwitcher/Server/`, which the Mac target excludes. The same holds for the tests.

Why not a `VibeApp` module now: moving 15,000 lines across a module boundary means `public` on every type the views
touch and a rewrite of how the views observe them, in an app nobody here can launch. With two file sets the Mac's
build doesn't change shape at all, and main's changes to those files keep merging cleanly. The module split is the
right end state and is done as one mechanical move when the branch lands; the list is then the module's contents.

A lint (`PortableSourcesLint`) keeps the list honest: a listed file may not import AppKit, SwiftUI or another
Apple-only framework, and a file that every listed file depends on must be listed.

### The platform layer

Each portable target gets a `Platform/` folder holding a protocol per service and one implementation per system.
Nothing outside `Platform/` imports Darwin, Glibc or an Apple-only framework, or uses `#if os`. A lint test
(`PlatformLint`, in the style of the existing lints) enforces it, and runs on the Mac with no Linux toolchain.

| Service | macOS today | Linux |
| --- | --- | --- |
| Process table, process tree, cwd, tty | `sysctl`, `proc_pidinfo` | `/proc` |
| File and folder watching | `kevent` | inotify |
| Sockets, HTTP listener | Network.framework | POSIX sockets (the builder may choose swift-nio, pinned) |
| Hashing, HMAC, ChaChaPoly, P-256 | CryptoKit | swift-crypto (same API; Linux-only dependency, pinned exact) |
| Who is on the other end of a socket | audit token, `LOCAL_PEERPID` | `SO_PEERCRED`, then `/proc/<pid>` checked before and after use (start time), pidfd where the kernel has `SO_PEERPIDFD` |
| "Is this the app?" | cdhash + HMAC under a keychain key | see [Security on Linux](#security-on-linux) |
| Secret storage | login Keychain | see [Security on Linux](#security-on-linux) |
| Settings store | `UserDefaults` | a file under `~/.vibeswitcher` |
| Load, cores, memory, disk | `sysctl`, `host_statistics` | `/proc/loadavg`, `/proc/meminfo`, `statvfs` |
| Power: AC or battery, percent | IOKit | `/sys/class/power_supply`; unknown counts as AC, and the UI says "power unknown" |
| Keep awake | IOKit assertion | `systemd-inhibit` where there is a session bus; nothing on WSL |
| User presence (for Boost Automatic, reminders) | CGEventSource idle time | the web client reports activity over its connection |
| Notifications | UserNotifications | the browser: Web Notifications while a window is open, the existing web push otherwise |
| Login shell and PATH | `LoginShell` | the same approach; no `launchctl` |
| The shell that runs a branch's code | `/bin/zsh -f -c` (`Worktrees.swift`) | `/bin/bash --noprofile --norc -c`; this machine has no zsh |
| Images (`LeadImages`, `MenuBarDots`) | ImageIO, CoreGraphics | `LeadImages`: size and type read from headers, no decode **(call)**; `MenuBarDots` stays Mac-only |

### The portable file set: the app without a UI

Files join the list a slice at a time. Each file's AppKit lines (8 to 51 of them in the files measured) move to a
`+Mac.swift` extension beside it, with no change in behaviour:

1. `HostClient`, `SessionStore`, `AppStatus`, `Launcher`'s session starting.
2. `RemoteServer`, `PhoneAccess`, `PhoneLeads`, `WebAssets`: the phone's API, which gives Linux its first UI.
3. `LeadController` and the witness.
4. `ChatModel`, `ChatSync`, the composer's send, steer and queue.
5. `Preferences` as a model, `SettingsCatalog`.
6. The desks: `WalletOutbox`, `WalletDesk`, `ShellDesk`.

Never listed: views, windows, menus, `TerminalBridge`, Spaces, the hot key, dictation capture, speech, the benches,
the sandbox driver.

**Combine.** 21 files in the app import it and there are 217 `@Published` properties; Combine doesn't exist on Linux.
**(call)** The listed files import it through `#if canImport(Combine)`, and Linux gets OpenCombine (same API, a
Linux-only dependency pinned exact), so the models aren't rewritten. A spike in stage 0 confirms it builds with this
toolchain; the fallback is a small type of the project's own covering `ObservableObject` and `@Published` as the
models use them. The server turns each model's change notifications into events on the wire.

**Settings.** The tool server and `VibeCore` read the app's defaults domain themselves (`vibeswitcher-mcp/main.swift`,
`Pausing.swift`), so the settings store is a `Platform/` service in `VibeCore`, not the app's: `UserDefaults` on the
Mac, unchanged, and a file under `~/.vibeswitcher` on Linux that the server writes and the others read.

**Tests.** `Tests/VibeSwitcherTests` (177 files) gets the same treatment as the sources: on Linux a test target over
the same folder with a list. A file that joins the portable set brings its tests onto that list in the same slice.

### The node's processes

A node is two programs on one machine:

- **`vibeswitcher-host`**, the session host, as today and more: it owns the PTYs and the vault, and on Linux it is
  the root of trust (see [Security on Linux](#security-on-linux)) and starts the server.
- **`vibeswitcher-server`**, to Linux what the app process is to the Mac: it runs the witness and every lead's
  controller, serves the web client, and holds the live connection to each client and, from milestone 3, each other
  node.

And one command, **`vibeswitcher`**: `start`, `stop`, `status`, `pair`, `attach ID`, `lead FOLDER --goal "…"`,
`install`. It is a client like any other.

- The server listens on 127.0.0.1; Tailscale reaches it through `tailscale serve`.
- Started by hand (`vibeswitcher start`), by a systemd unit where systemd runs, or from the shell's startup file on a
  WSL without it.
- Updating: `git pull && scripts/build-linux.sh --install`. The host hands over to the new build without ending
  sessions and starts the new server; open windows reconnect by themselves.
- Other terminals: a `claude` or `codex` started in any terminal on the machine is listed with its live status (hooks,
  `/proc`) and its chat is readable. It can't be brought to the front or typed into: there is no Terminal.app to ask.

### The live API

One WebSocket per window, opened after the page loads, replacing every timer in `Web/app.js`.

- **State as snapshot and deltas.** On connect the server sends the window's whole state with a sequence number; then
  only changes, each numbered. A gap, or a reconnect with a number the server no longer has, gets a new snapshot.
- **Subscriptions.** A window subscribes to what it shows (the list always; one session's chat, terminal, board). The
  server sends nothing else.
- **Terminal.** Raw session bytes as binary frames from the host's `attach`, input as binary frames back. The browser
  runs a real terminal emulator. Flow control: the server drops to the host's replay (`resync`) when a window falls
  behind, never buffers without bound.
- **Chat.** Messages stream as the transcript grows, token-level where the agent's output allows.
- **Actions.** Each has an id; the server replies done or refused with a reason, and the state change arrives as a
  delta. The client shows the action at once and takes it back, saying why, on a refusal.
- **Types.** Every message is a Codable type in `Server/`. The JavaScript side's types and a set of JSON test vectors
  are generated from them at build time and checked in; a test fails when they're stale. Nobody writes a wire format
  twice.
- The phone's HTTP routes stay as they are, for `Web/` and for the Mac.

### Real-time and slick

Measured on the machine itself, with the web bench described under [Verification](#verification):

| What | Budget |
| --- | --- |
| A key typed in the terminal to its echo on screen, beyond the program's own time | under 16 ms at the median, 33 ms at p95 |
| A session's status change to the list showing it | under 100 ms at p95 |
| A click (answer a card, send a message, switch session) to visible response | under 50 ms |
| Switching to a session with 10,000 chat rows to first paint | under 150 ms |
| First load to a usable list, local | under 500 ms |
| Reconnect after the server restarts | by itself, under 2 s, with no lost input and no duplicate message |
| Scrolling a long chat or a busy terminal | no frame over 33 ms |

Slick also means: every command reachable from the keyboard with the Mac app's shortcuts where the browser allows
(⌘K, ⌘J, ⌘1–9, ⌥⌘2), installable as its own window (the manifest and service worker exist), light and dark, and the
Mac app's vocabulary and status colours. The Mac app is the design reference; the web client isn't a redesign.

### The web client

- **(call)** A new client in its own folder, `WebApp/`, with a desktop and a phone layout. `Web/`, the Mac's phone
  app, isn't touched: the Mac app serves it over its HTTP routes, and changing it from here would change the Mac's
  phone with nobody to look at it. On Linux, `Web/` is the first window (stage 3) and `WebApp/` replaces it. The Mac
  adopting `WebApp/` is milestone 5's.
- **(call)** No build step and no npm: ES modules served as files. A small rendering library and a terminal emulator
  are vendored into `WebApp/vendor/` at exact versions with their hashes recorded. `WebAssets` today serves a fixed
  list of nine paths under one fingerprint; the server gets a manifest of `WebApp/`'s files generated at build time,
  with the same fingerprint rule. The candidates are Preact with signals and xterm.js; a spike against the budgets
  decides before anything is built on them.
- No type checker is installed. The wire's types are generated from the Swift ones as validators and JSON vectors,
  and the tests run every message through them.
- Built in slices, each usable: the list and a live terminal; the chat with composer and cards; starting a lead and
  the Team tab; Settings; ⌘K, notifications, the start page and onboarding.

### Security on Linux

The Mac's model rests on three things Linux doesn't have in the same form: the audit token, code signatures and the
Keychain's per-app access. On Linux a file the user can read is no secret and a file the user can write is no record,
because every worker runs as the user. Two modes follow, one layered on the other.

**The plain mode** needs no root. Whatever the guard rails rest on (the vault's key, the paired devices, the node's
key) lives in the session host's memory only. After a cold start (a reboot, WSL shut down) the vault is empty, `merge`
says an audit needs running again, and the user pairs again, with a code `vibeswitcher pair` prints only while the
host has no session. It is what the tests, the sandbox and CI run, and what someone without root gets. It holds
against accidents; a worker that sets out to act as the user has ways around it, and the first-run page says so.

**The strong mode** is the one the user runs, and what milestone 1 is finished in:

- The session host runs as a system user of its own (`vibeswitcher`). The vault, the paired devices and the node's key
  are its files, which the user's processes can neither read nor write. They survive a reboot.
- The binaries are installed in a root-owned folder, so nothing running as the user can replace them, and the host
  starts every process from there with a clean environment.
- Sessions still run as the user, with the user's files and logins: the host starts them through a sudo rule that
  lets `vibeswitcher` run commands as that one user and nothing else. Nothing lets the user's processes run as
  `vibeswitcher`.
- **The host starts the server**, as the user, and hands it one end of a private socket at launch. That socket is
  the server's identity: there is no key to steal and no binary check to race. The server marks itself non-dumpable.
  When it dies the host starts another.
- **The user's sudo password is the proof of a person.** `sudo vibeswitcher pair` pairs a first device and
  `sudo vibeswitcher install` installs a build. A worker doesn't have the password. Later devices are paired from a
  card on a device that already has full rights.
- The install, once, with root: the system user, the install folder, the sudo rule, a system unit for the host.
  One user per machine **(call)**.

What both modes share:

- **Who is asking.** `SO_PEERCRED` gives pid and uid when the connection is made, and is fixed from then on, so the
  Mac's re-check of who last used the socket becomes credentials sent with each message (`SCM_CREDENTIALS`). The host accepts the user's uid
  (and its own), places the pid in a session's process tree through `/proc`, and guards against pid reuse by comparing
  the process's start time before and after each decision, with a pidfd where the kernel offers one. A connection
  inherited by a child counts as no one, as on the Mac.
- **Leaving the tree.** The host makes itself a subreaper (`PR_SET_CHILD_SUBREAPER`), so a session's process that
  double-forks comes back under the host and counts as "from a session, which one unknown": it gets nothing. A process
  a worker has something else start (`systemd-run --user`, cron, ssh to localhost) is unknown too, and unknown gets
  nothing either: in the strong mode there is nothing left for it to read or forge.
- **Devices and their rights.** A device is a browser or a command line that was paired. Its rights are a property
  of its pairing, not of where it connects from: **view** (read only), **reply** (the phone's rights today: typing
  behind its switch, credentials masked, answers to a lead's questions, no Accept or approval, the masked screen and
  not the raw terminal) or **full** (everything the Mac app can do). The server checks `Host` and `Origin` on every
  request and on the WebSocket upgrade, and a token is never in a URL.
- **Over Tailscale.** The node is reached through `tailscale serve`, as the phone is today, and takes requests only
  from the user's own tailnet account. A device still has to be paired; the tailnet identity is a second lock, not
  the only one. On a headless server the first device is paired over ssh (`sudo vibeswitcher pair` prints the address
  and the code).
- **The host's and the server's memory.** This machine's WSL kernel has no Yama (`ptrace_scope` is absent), so one
  process may attach to another of the same user. Both mark themselves non-dumpable (`PR_SET_DUMPABLE`), which refuses
  that to anyone but root, and a test tries it.
- **The config seal.** The same hashes, over the Linux list: `~/.claude`, `~/.codex`, shell startup files, git
  config, the main checkout's `.git`, `~/.vibeswitcher/bin`, and what runs by itself after a reboot:
  `~/.config/systemd/user`, the user's crontab, `~/.config/autostart`.
- **Settings a worker shouldn't change.** On the Mac any process can write the app's defaults. On Linux the settings
  that loosen a guard rail (the review floor, shells without asking, the limits, each device's rights) are the
  host's, changed only by a full device.
- **Agents' own sandboxes.** Claude Code and Codex sandbox differently on Linux (bubblewrap, Landlock). The lead's
  deny rules and the workers' launch flags are checked on Linux by the same tests that check them on the Mac
  (`LeadLaunch`), and any rule that can't hold there makes `start_worker` refuse, not run without it.

What isn't protected, in either mode: a process running as the user that reads a paired browser's own storage on the
same machine; signals; what the sessions themselves run. On WSL the Windows-side browser's profile is reachable
through `/mnt/c`; the first-run page says so.

**Open problems, found in review (2026-11-12).** The strong mode as written above has holes. They don't touch
stages 0 to 4, and stage 5 starts with a design of its own that settles them:

1. **Root without a password.** On WSL with interop on, as on this machine, any process can run `wsl.exe -u root`.
   The same holds for a cloud VM's passwordless sudo and for a user in the `docker` group. Where that is so, a second
   system user protects nothing.
2. **What `sudo vibeswitcher install` trusts.** The checkout, `.build/`, the build script and the toolchain are all
   the user's files, so a worker can change what the user's password then installs. The install has to build a named
   commit from a clean clone with a toolchain a worker can't write.
3. **The port.** The inherited socket proves the server to the host, and nothing proves it to a browser. A worker
   can end the server, take its port first and collect the tokens of devices that reconnect. The host should own the
   listener and pass it to each server it starts.
4. **One session acting as another.** Roles are decided by process tree. With no Yama, a worker can attach to the
   lead's or a verifier's agent, or replace the `claude` or `codex` binary in the user's home, and then speak as that
   role. Non-dumpable covers only the host and the server.
5. **The command line's standing.** `vibeswitcher attach`, `lead`, `stop` run as the user outside every session;
   a token for them in a file is a token a worker can read.
6. **Who runs the root steps** while this is built, since agents have no sudo here.

The direction the stage 5 design starts from **(call)**: confine team sessions as well as protecting the host from
them. Each worker and verifier runs in a sandbox of its own (a mount and a process namespace, as Claude Code's own
Linux sandbox uses): it sees its worktree and what it needs to build, and not `~/.vibeswitcher`, the other sessions'
processes, the agents' binaries and config as writable files, `/mnt/c`, WSL's interop or the docker socket. That
answers 1, 3 and 4 where a second user can't, and makes the config seal a lock instead of an alarm. The second user
stays for what must survive a reboot. What it costs in what a worker can still do (containers, system services) is
that design's first question.

`docs/security/` gets a Linux section, and the security audit's tests (`Tests/SecurityAudit/`) run on Linux in CI, in
both modes (a hosted Ubuntu runner has root).

### Feature plugins

A feature plugin is a folder that declares, in one place, everything a feature adds:

- the commands agents get (`vs-wallet`, `vs-shell`), and the MCP tools and hook handling behind them;
- its request type, its validation and its store;
- its cards, **as data**: title, fields, body, severity, actions. The Mac renders a card with one SwiftUI view for
  all plugins, the web with one component; a plugin may supply a custom view on a platform but never has to;
- its Settings section, as entries in the settings catalog;
- what it adds to an agent's brief;
- whether it is on, and where it can run (wallet's Passage transport is Mac-only).

A registry in `VibeCore` lists the plugins. A plugin that is off leaves no trace: no command installed, no tool
listed, no Settings section, no line in a brief. Wallet is off by default and on for the user **(call)**; shell is on
by default.

From here, the registry, the card data and the two plugins are built in shared code and used by the server and the
web client from their first card. The Mac keeps its present wiring (about 35 files outside the wallet's folder
reference it) until milestone 5 moves it onto the registry: that needs the Mac app on screen, so it is done
on a Mac, wallet first, shell second, then the Push, Accept and question cards.

Later candidates, not part of this project: asks (deploy, database migration, secret access, open a PR, send a
message), agent kinds (other CLIs), notification channels (Slack, Telegram), work sources (GitHub or Linear issues, CI
failures), review gates (scanners). Opening the interface to other people's plugins is a later decision; external
ones would be separate processes speaking a file or socket protocol, as the Wallet Manager is.

### Parity

| Feature | Linux, first version | Note |
| --- | --- | --- |
| Session host, window sessions, handover | yes | |
| Hooks, status detection (hooks, OSC 7501, titles, process table) | yes | titles only for window sessions |
| Project lead, board, workers, verifiers, auto_advance | yes | |
| Merge gate, risk check, config seal, review floor | yes | |
| Limits, Boost | yes | Automatic needs power and presence; on WSL power is often unknown, so Automatic behaves as Off and says so |
| Chat, composer, steer, queue, cards, Run blocks | yes | |
| Team tab, Team strip, scorecard, receipts | yes | |
| Settings, launch presets, ⌘K | yes | |
| Notifications | yes | through the browser |
| Phone access | yes | `Web/` as it is until stage 8, then `WebApp/`'s phone layout |
| Sessions in other terminals | listed, readable | no focus, no typing |
| Shell plugin | yes | |
| Wallet plugin | signing in the browser's wallet | the fallback that exists today; the Wallet Manager's transport (Passage) is a Mac app |
| Statistics window | later | the model is in VibeCore; needs web charts |
| Dictation | later | the browser's microphone, then the existing transcription |
| Spoken briefing | later | text first; speech through the browser |
| Dev previews | later | |
| Freeze reports, app health digest | later | a server watchdog, and the browser's long-task reports |
| Menu bar dots, sidebar mode, Spaces, hot key, Terminal.app | never | |

## The branch

Version 2 lives on `v2`, pushed to GitHub, and main is not touched until the user says it lands.

1. **Main is merged into `v2`**, at least every working day at first: main takes about 100 commits a day from the
   Mac's lead, and they are the lead's own improvements, which version 2 wants. Conflicts are settled here. The merge
   is pushed only with both runners green.
2. **Cheap merges are designed for**: mechanical changes only to files main also changes; version 2's own code in
   new files and folders (`Platform/`, `Server/`, `WebApp/`, the plugins); no file moved until the branch lands.
3. **Lints on the branch** say at each merge what main brought that Linux can't take: `PlatformLint` (no Apple-only
   import and no `#if os` outside `Platform/` in the portable targets), `PortableSourcesLint` (the listed app files
   stay free of AppKit and SwiftUI), `LinuxAPILint` (calls that exist on the Mac and not in Linux's Foundation; it
   grows by a line each time a merge breaks the Linux build). Fixing what they find is part of the merge.
4. **Wire types generated, not written twice**, with a staleness test. **Cards and settings as data**, so a new card
   or option appears in every client.
5. **A parity file**, `docs/process/platform-parity.md`: every user-facing feature, and whether each client has it.
   A lint fails when a new settings entry or card kind isn't in it, so a Mac-only feature is a recorded choice.
6. **Landing.** `v2` reaches main only once the Mac is on version 2 (milestone 5) and the user says the whole works
   extremely well. Until then the branch's Mac build is checked by the macOS runner; the Mac app is built and tested
   on a real Mac at the end, as milestone 5 begins, not at each stage. At the landing the lints run in the Mac's own
   merge gate, `AGENTS.md` tells the Mac's agents where platform code goes, and the branch ends.

## The plan

Milestone 1 is stages 0 to 7, milestone 2 is stage 8. Each stage ends in something that runs and can be shown, and
gets its own implementation plan (`docs/superpowers/plans/`) when it starts, written from what the stage before it
found. Work inside a stage goes in slices of a few hundred lines, each reviewed before it joins `v2`.

### Stage 0: ground

- Swift 6.4 is installed (swiftly). Node 22, Chrome, `claude`, `codex`, Tailscale and systemd are already here.
- The `v2` branch, and two CI workflows on it: macOS (build everything; run the test targets that pass on a hosted
  runner, the list found by trying) and Ubuntu (build and test the portable targets, the web tests).
- **Spike, thrown away:** build `VibeCore`, `VibeHost` and the pinned SwiftTerm on Linux with the Mac-only imports
  swapped crudely, and count the errors by kind. Build a model with OpenCombine. Check that the test targets'
  `@_section` guard works on Linux.
- `scripts/test.sh` gains a Linux path: the same scratch home, the same leftover-process check through `/proc`, no
  preferences check. `vs-heavy` works as it is (bash) once its process and core counts read `/proc`.

Done when: both runners are green on `v2` with main's code unchanged, and the error inventory has replaced the
guesses in the stage 1 plan.

### Stage 1: the core on Linux

- The `Platform/` layer in `VibeCore`, a service at a time (the table above), each with a test that runs on both
  systems against the same expectations.
- swift-crypto on Linux.
- `vibeswitcher-hook` and `vibeswitcher-mcp` build and run; the hook installer writes `~/.claude/settings.json` and
  `~/.codex/hooks.json` as on the Mac.
- `VibeCoreTests` (236 files) pass on Linux, except those about Mac-only things, which are marked so by name and
  counted in the parity file.
- `vibeswitcher status`: every `claude` and `codex` session on the machine with its status.

Done when: `scripts/test.sh` is green on Ubuntu for the core, and `vibeswitcher status` shows a real session going
from working to needs-you to done.

### Stage 2: the session host on Linux

- PTYs and session start, the parsers, the replay buffers.
- The socket server with Linux peer identity; the process-tree rules; the subreaper; non-dumpable.
- The vault in the plain mode; handover by re-exec with the inherited socket.
- `VibeHostTests` (56 files) and the security audit's tests pass, with the new Linux ones.
- `vibeswitcher attach ID`: a terminal client for a hosted session, for testing and for use over ssh.

Done when: a `claude` session started under the host survives its client quitting, a host handover to a new build,
and a parser killed under it; and a process inside one session is refused another session's screen.

### Stage 3: the server, and the phone app as the first window

- The first two slices of the portable file set (`HostClient`, `SessionStore`, then the phone's API).
- `vibeswitcher-server`, started by the host and known by its socket: start, stop, pair, the loopback listener,
  `Host` and `Origin` checks.
- The existing `Web/` client, unchanged, served from Linux, and reached the way the Mac's is: through
  `tailscale serve`, with the tailnet login the phone's API already requires (`PhoneAccess.swift`,
  `RemoteAccess.swift`). No loopback gate is added to that API; pairing on this machine without Tailscale arrives
  with the new client's own gate in stage 6.
- `scripts/build-linux.sh --install` and the systemd unit.

Done when (**first light**): `vibeswitcher start` on this machine, pair a browser on a device of the user's tailnet,
and the phone app
shows the list and each session's screen and transcript, and takes replies, with sessions surviving a server restart.

### Stage 4: leads on Linux

- `LeadController`, the witness and `PhoneLeads` join the portable set, with the team seam (rule 4) drawn.
- The tool server's keeper, worktrees, the merge gate, `auto_advance` on inotify, the node's limits on
  `/proc/loadavg`, the config seal's Linux list, `LeadLaunch`'s deny rules checked against Claude Code and Codex as
  they behave on Linux.
- `vibeswitcher lead FOLDER --goal "…"` (the Mac's `--lead`).
- The lead's page in the existing phone client answers its questions.
- End-to-end runs with real agents on scratch repositories, on Sonnet or smaller.

Done when (**a lead on Linux**): on a scratch repository here, a lead plans, runs two workers, audits and merges a
task, and its question is answered from the browser.

### Stage 5: the strong mode

- The install with root: the system user, the root-owned install folder, the sudo rule, the system unit.
- The host under its own user: the vault, the devices and the node's key as its files; sessions and the server
  started as the user.
- `sudo vibeswitcher pair` and `sudo vibeswitcher install`; device rights (view, reply, full); the guarded settings.
- The security audit's tests in this mode, in CI, and an attack list tried by a reviewer who didn't build it: forge
  the vault, pair a device, pose as the server, replace a binary, attach to the host, survive a reboot.

Done when: every item on that list is refused, and stage 4's lead runs the same in this mode. From here on the user's
own projects can run on it.

### Stage 6: the live connection

- The WebSocket, snapshot and deltas, subscriptions, actions, the generated wire types and their vectors, with the
  ids, versioning and principals of [Rules from the first line](#rules-from-the-first-line).
- The terminal as raw bytes both ways, with flow control.
- The web bench, measuring the budgets, under `--perf`.
- `WebApp/`'s frame on the connection: the list and a live terminal, enough to measure with.
- The spike that picks the rendering library and the terminal emulator.

Done when: the list and a terminal run on the connection with no timer, and the bench shows the terminal, status,
click and reconnect budgets met.

### Stage 7: the desktop client

In slices, each usable at once: the frame, the list and a live terminal; the chat with composer, steering and cards;
starting a lead, the Team tab and strip; Settings and launch presets; ⌘K, notifications, the start page, onboarding.
The plugin registry and card data are built with the first card; shell is the first feature plugin, wallet (signing
in the browser's own wallet, the fallback that exists today) the second.

Done when (**milestone 1**): every row marked "yes" in [Parity](#parity) works in the browser, every budget is met
on this machine, and the user has run their leads from it for a week without going back to a terminal for anything
on that list.

### Stage 8: remote (milestone 2)

- The node behind `tailscale serve`, taking only the user's tailnet account; the first device paired over ssh on a
  headless machine.
- `WebApp/`'s phone layout replaces `Web/` on Linux: the same connection, the reply rights as they are today, push
  notifications, and what the phone app does on the Mac that survives the revamp, listed first with the user.
- A second full device (a laptop) on the same node: two windows on one session, both live.
- The guides: getting started on Linux and on a server, the architecture's Linux section, the parity file.
- A security review of the whole against `docs/security/SECURITY-AUDIT.md`.

Done when: the user runs their leads on a headless node from a laptop and answers them from a phone.

### After

Milestones 3 to 6 each start with a design of their own. Milestone 5 happens on a Mac and decides, with the Mac in
front of someone, how the native app sits on its node; it also brings the Mac's cards and
wallet onto the plugins. It begins with the first build and full test run of the branch on a real Mac, and whatever
that finds is fixed before anything new is built there. The branch lands after it (see [The branch](#the-branch)).

### How the work is done

- By Claude Code on this machine, on `v2`: a subagent per slice in its own git worktree, a reviewer that hasn't seen
  the slice before it joins the branch. From stage 4 on, increasingly by a VibeSwitcher lead running here.
- `AGENTS.md` applies as written: tests only through `scripts/test.sh`, fake ttys, nothing typed into a real session,
  nothing installed by an agent, a fix's test shown failing without the fix.
- Real agents in end-to-end runs use Sonnet or a smaller model.
- Nothing joins `v2` with either runner red.

### Risks

| Risk | What limits it |
| --- | --- |
| The branch falls behind main, or merging becomes the job | Daily merges; mechanical changes only to shared files; the lints name what each merge broke. Measured: if merges take more than a fifth of the time, the user hears it |
| A change breaks the Mac and nobody here sees it | The macOS runner on every push; only mechanical changes to Mac-compiled code |
| The macOS runner can't run enough of the suite to mean much (keychain, GUI, load), and the real Mac only sees the branch at the end | Found in stage 0: the runner at least builds everything and runs what it can. Changes to Mac-compiled code stay mechanical, so what reaches the Mac at the end is main's own app plus small seams. Milestone 5 starts by fixing what the first real run finds |
| Linux's Foundation behaves differently (Process, FileHandle, dates, JSON key order, URLSession) | The existing tests run on both; each difference found becomes a line in `LinuxAPILint` or a `Platform/` service |
| OpenCombine doesn't hold up | The spike; the fallback type |
| SwiftTerm 1.19.0 has a Linux problem | The spike; a newer pinned version, checked on the Mac by CI |
| Claude Code or Codex behave differently on Linux (sandboxing, flags, hook events) | Stage 4's launch tests run against the real CLIs and a recorded session |
| The browser can't meet the terminal budget | Stage 6's bench decides before stage 7 builds on it |
| The strong mode's sudo rule or install is wrong in a way that gives a worker more, not less | The attack list; the security review; the rule is one line and reviewed by the user |
| Milestone 1 bakes in one machine | The eight rules, each with a lint or a test where one can be written; a two-node smoke test (two servers on scratch homes on this machine) from stage 6 |
| WSL: no Yama, the Windows-side browser profile, no inotify on `/mnt/c`, no battery | Non-dumpable; said on the first-run page; repositories must be on the Linux filesystem, refused otherwise; power unknown counts as AC |

## Verification

- Everything through `scripts/test.sh`, on both systems.
- The web client is tested in the Chrome already on this machine, headless, driven over its DevTools protocol by a
  small driver in `Tests/Web` using Node 22's built-in WebSocket: nothing to install. The web bench measures the
  budgets that way, the same each time, and that run is the one that can refuse a slice.
- The window the user really uses is a browser on another system (Chrome on the Windows side through WSL's relay, a
  laptop over the tailnet). A bench page in the app measures the same budgets there and reports them; it informs, it
  doesn't gate.
- The security audit's tests run on Linux in both modes, with new ones for pairing, `Host`/`Origin`, pid reuse, an
  inherited connection and an attach to the host's memory.
- A Linux counterpart of the sandbox (`scripts/sandbox-server.sh`: run, shot, quit) so UI changes are shown, light and
  dark, as they are on the Mac.

## Decided

- The fleet is designed generically, for any mix of machines (2026-11-12).
- `v2` lands on main only once the Mac is on version 2 (2026-11-12).
- The Mac app is built and tested on a real Mac at the end, not at each stage (2026-11-12).
- The strong mode on Linux; signing in the browser's wallet for the wallet plugin; real agents on Sonnet or smaller
  in test runs; remote use over Tailscale, with the phone app renewed.

## Open decisions

For the user:

1. **What the renewed phone app keeps** from today's (stage 8 starts by listing it).
2. **First-version cuts**: dictation, the spoken briefing, Statistics, dev previews and freeze reports are "later".

## Left to the builder

- swift-nio or plain sockets for the listener and the WebSocket; whichever it is, pinned exact and few.
- The rendering library and terminal emulator, after a spike against the budgets.
- The layout of `Platform/` and the names in it.
- How the generated wire types are produced.
- The exact sudo rule and unit files of the strong mode, within what [Security on Linux](#security-on-linux) says.
- The order of slices inside each stage, and their contracts.
