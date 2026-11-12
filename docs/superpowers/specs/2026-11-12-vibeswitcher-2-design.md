# VibeSwitcher 2: a node on every machine

Status: direction agreed with the user 2026-11-12; revised the same day after a three-way review
([its record](../../process/reviews/v2-design-review-2026-11-12.md)); revised again 2026-11-13 after five reviews of
stage 1 and the plans that follow it. As of 2026-11-13: stage 0 is done; stage 1 is nearly done
([plan](../plans/2026-11-12-v2-stage-1-core-on-linux.md)); stage 2 has [its plan](../plans/2026-11-13-v2-stage-2-session-host.md),
and the order to the bootstrap is in [the bootstrap path](../plans/2026-11-13-v2-bootstrap-path.md). What is built is
recorded in the plans and the recon, which are the source of truth for it.

The user, on the start: "port VS over to Linux (currently we're in Ubuntu WSL) in a way that will not be crazy to be
updating when changes happen to VS." On use: "running multiple project leads etc. like on the app." On the UI: "It
can be a web app … It just needs to be extremely real-time and slick." On plugins: "the wallet manager is something
that only I want, probably … maybe other people will want to do their own." On who builds it: "I want you to do it
totally from this computer." On the branch: "a completely separate branch … I don't want to go to main until
everything is working extremely well here. Let's make this the following major version." On the Mac: "whatever
plugins or interface … is specific to Mac should just be there and we can build it there, but I first want you to
build everything else here." On reach: "Let's imagine it's a headless Linux server … work on any computer, in the
cloud, and spread tasks across different devices. Let's think big." On security: "I lean towards stronger." On main: "Strict isolation.
I want the work to be done here and then eventually Mac to check." On reach again: "well architected, safe and can be
distributed broadly to other users/setups."

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
| 4 | Distributed teams | A lead places workers, verifiers and test runs on other nodes | here, with a second Linux node |
| 5 | The Mac on version 2 | The Mac runs a node; the native app is its client, with the Mac's own platform services | on the Mac |
| 6 | Cloud nodes | Nodes that join for a burst of work and leave | later |

This document designs milestone 1 in full, milestone 2 enough to build, and gives 3 to 6 their direction and the
rules that milestone 1's code must already follow for them. Each of 3 to 6 gets its own design when it starts.


## What exists (measured 2026-11-12, before stage 1)

| Part | Lines | Depends on | On Linux |
| --- | --- | --- | --- |
| `VibeCore` | 60,700 | Foundation, Darwin, CryptoKit; a few files on Security, Network, CoreGraphics, ImageIO | portable with a platform layer |
| `VibeHost`, `vibeswitcher-host` | 3,800 | VibeCore, SwiftTerm, Darwin, Security | portable; SwiftTerm's headless terminal builds on Linux |
| `vibeswitcher-hook`, `vibeswitcher-mcp` | 600 | VibeCore, Darwin | portable |
| `VibeSwitcher` (the app) | 49,700 | AppKit, SwiftUI, Combine and 15 more Apple frameworks | not portable |
| `Web/` (the phone app) | 2,300 | vanilla JS, no build step | already portable; polls on timers |

Mac-only calls in the portable parts: `proc_pidinfo` (29), `posix_spawn` (17), `sysctl` (13), `kevent`/`kqueue` (15),
`NWConnection`/`NWListener` (14), Keychain `SecItem*` (8), `SecCode*` (3), `LOCAL_PEERPID` and the audit token.
`osascript` and `launchctl` appear only as words in command classifiers, never run
([recon](../../process/v2-stage1-recon.md)).

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
6. What main gains while the branch lives reaches the branch by merge where the code is shared, and through the port
   ledger where it isn't, with nothing owed for more than a week.
7. Optional features are plugins: wallet is on for the user, absent for everyone else.
8. On the branch the Mac app still builds as on main, until milestone 5 changes it on a Mac.
9. On Linux the guard rails hold against a worker that tries, not only one that slips.
10. Someone who isn't the author can install a release, run it on their own setup, update it and remove it.

## Non-goals

- A native Linux GUI (GTK, Qt), a tray icon or menu bar dots.
- Terminal.app control, Spaces and desktop ordering, sidebar mode, the global hot key, open-at-login through
  ServiceManagement. These are the Mac's own, built on the Mac in milestone 5.
- Changing the Mac app's screens from here.
- Loading third-party plugin code. Plugins are compiled into this repository.
- Native Windows, or other distributions than Ubuntu LTS, as tested targets.
- Reaching a node over the open internet. Tailscale is the network between a person's devices and nodes.
- Several people sharing one node or one fleet.
- In milestone 1 **(call)**: dictation, the spoken briefing, the Statistics window, dev previews, freeze reports.
  Each is listed in [Parity](#parity) with what it would take.

## Anti-goals

Any of these makes the project a failure even if it runs:

- A branch that drifts: main's work has to keep arriving, by merge where the code is shared and through the port
  ledger where it isn't, until the day the branch lands.
- `#if os(...)` spread through the logic. Platform differences live in the `VibePlatform` module (below).
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
 │ web app       │◄─────────►│ server: stores, leads,   │   ┌─ lead (claude)
 │ (desk, phone) │  protocol │         API, peers       │   ├─ workers (claude, codex)
 ├───────────────┤           ├──────────────────────────┤──►├─ verifiers
 │ vibeswitcher  │           │ host: PTYs, vault, keys, │   └─ your own sessions
 │ (command line)│           │       approvals          │
 ├───────────────┤           └────────────▲─────────────┘
 │ Mac app (M5)  │                        │ the same protocol, node to node (M3, M4)
 └───────────────┘           ┌────────────▼─────────────┐
                             │ another node: a Mac,     │
                             │ a server, a cloud VM     │
                             └──────────────────────────┘
```

- **A node** hosts sessions and runs leads on one machine. It has no UI. Everything VibeSwitcher decides is decided
  in a node.
- **A client** shows a node, or a fleet through one node, and sends the user's actions. It holds only view state
  (what is selected, scrolled, searched) and reads no file: everything else comes over the live protocol.
- **A fleet** is the user's nodes. Each has a key of its own, made at install and kept by its host. A node joins
  when the user accepts it from a device with full rights.
- **Any mix of machines.** Nothing names a machine or a kind of machine. A node describes itself by what it offers:
  its system, cores and memory, the toolchains and plugins it has, the agent accounts logged in on it and their
  quota, whether it is on AC power, whether it is always on. Placement matches a task's needs against those.
- **Placement** (milestone 4): a lead asks its node for a worker, a verifier or a test run with what it needs, and
  the fleet's nodes offer. The code travels as git: the working node clones from the placing node, and the placing
  node fetches one ref back; it never accepts a push. Contracts, reports and findings travel as messages. Each node
  decides locally, by a policy a person set there, what it accepts.
- **Plugins** are what one user wants and another doesn't: wallet, shell. What one *system* has and another doesn't
  is the platform layer's, not a plugin.

### Rules from the first line

Milestone 1 runs on one machine and for one person. Its code still follows these, so that the fleet and other
people's setups add and don't rewrite. Each has a lint or a test where one can be written.

1. **Ids are fleet-wide.** A session, a task, a card, a device, a project is named by an id that stays unique when
   nodes meet; on the wire each carries its node. A project is an id, not a path: paths, ttys and worktrees are one
   node's attributes of it.
2. **Clients go through the protocol only.** No client opens a file, a socket to the host, or a path.
3. **The protocol is versioned and additive.** A message may gain fields; a kind nobody understands is skipped,
   except one marked must-understand (a revocation, a rights change), which closes the connection instead. A client
   older than the server says so and reloads.
4. **A lead reaches its team through one seam**: start a worker, read its result, message it, hear its report. One
   implementation today, on the same machine, and already shaped as it will be across machines: the worker gets a
   clone, and the result is one ref the lead's node fetches.
5. **Limits are a node's.** A fleet's are a later sum of them.
6. **Who acts is a principal**: a device with rights, a node with a short fixed list of things a node may ask
   (offer, run a placed task, return one ref, report), or a session with a role. Never "the app".
7. **An approval is signed by the device that gave it**, over the exact action, and checked by the host of the node
   it applies to. Nothing in between, server or peer, can make one.
8. **Order comes from sequence numbers**, with an epoch that changes when a server restarts; an action has an id
   that survives the restart, so it is done once.
9. **Each setting says whose it is**: this node's, or the user's everywhere.
10. **A node runs from its binaries alone.** No source checkout, no app bundle, no path fixed at build time: web
    assets and scripts are inside the binaries, tools are found on PATH, the version and commit are compiled in.
11. **Everything on disk carries a format version.** A node refuses a newer format, migrates an older one after
    keeping a copy, and a handover refuses a downgrade.
12. **Each agent CLI is behind an adapter** that says which versions it was tested with and is probed at start.
    Outside them the node shows status only and says why.
13. **No default is the author's.** Models come from what the account can run, prices from a data file that can be
    updated, limits from the machine's cores and memory, and committing a lead's records into the repository is a
    choice.

### Strict isolation

Decided 2026-11-12: everything is built on `v2`, on Linux, and main is not touched, not even to prepare it. The Mac
checks at the end. What follows from that:

- **`VibeCore` and `VibeHost` are shared with main**, and main changes them every day. On `v2` they change only at
  the platform layer's seams (a system call moved behind `VibePlatform`), so main's changes keep merging in. Version
  2's own code is in new files and folders.
- **The Mac app target is left as it is on `v2`.** It keeps building, checked by a macOS runner. Nothing in
  `Sources/VibeSwitcher` or `Web/` is edited from here.
- **The app's logic is not reused; it is rebuilt.** The review showed why it can't be shared by listing files:
  `LeadController`, `ChatModel`, `SessionStore` and the rest hold view types as stored properties, block on modal
  dialogs, and are one window's polling view models. The node gets its own layer, `VibeNode` (below), written here.
  Until milestone 5 moves the Mac onto it, that logic exists twice. The app's pure helpers may be copied, each with a
  ledger line; its tests' cases are ported into `VibeNode`'s as the spec of what is rebuilt.
- **Edits to shared files beyond the seams are few and counted.** Some rules can't be met at the platform's seams
  alone (the Linux app principal, the orphan sweep's parents, a handover record's new optional field, the config
  seal's Linux list). Such an edit is a hook of a line or two into a `v2`-only file, a `Config` field or member whose
  default keeps the Mac's behaviour, or an optional field in a record; each gets a line, with its merge cost, in the
  ledger's Non-seam edits section.
- **The port ledger pays for that.** [`docs/process/v2-port-map.md`](../../process/v2-port-map.md) names, for each of the Mac's logic files, what
  replaces it in `VibeNode`. At every merge from main a script lists the commits that touched a mapped file, and
  each gets a line: ported (with the commit), not needed (with the reason), or owed. The merge isn't finished while
  one is owed for more than a week. The same ledger tracks every new card and setting main adds.
- **`v2` keeps its own records.** A lead working on `v2` writes to `docs/lead-v2/`, so main's `docs/lead/` (733
  commits in 14 days) merges in without conflict.
- **What waits for the Mac** is written as it is found in `docs/process/v2-mac-tasks.md`: the Mac as a node, the
  native app as a client of `VibeNode` in the same process **(call)**, the Mac's platform services, removing the
  Mac's copies of the logic.

### Targets

```
VibePlatform          NEW: every system call, one form per system      (both, v2 only)
CVibePlatform         NEW: C headers VibePlatform alone imports        (Linux, v2 only)
VibeCore              shared model and rules; MacOnly/                 (both, shared with main)
VibeHost              PTYs, replay, socket server, vault; V2/          (both, shared with main)
VibeNode              NEW: stores, the lead engine, the wire types     (both, v2 only)
vibeswitcher-server   NEW: VibeNode + listeners + the web client       (both, v2 only)
vibeswitcher-cli      NEW: the command line, a client; installed       (both, v2 only)
                      as `vibeswitcher`
vibeswitcher-host, -hook, -mcp                                         (both, shared with main)
VibeSwitcher          the Mac app, as on main                          (macOS, untouched until M5)
```

The command line's target isn't named `vibeswitcher`: its folder would differ from the app's `Sources/VibeSwitcher`
only in case, and on the Mac's case-insensitive file system the two would be one folder. `VibeNode`'s first file
(stage 1) is the local session list `vibeswitcher status` reads.

### The platform layer

Every system call the shared code makes goes through one module, `VibePlatform`: static functions, one
implementation per system, compiled against glibc on Linux (musl is checked by the static build, after the
bootstrap). It knows nothing of VibeSwitcher but the settings folder's rule, which a test ties to `VibeCore`'s, so it
builds and is tested on Linux before anything else does. Nothing outside it imports Darwin, Glibc or an Apple-only
framework, or uses `#if os`; a lint test (`PlatformLint`) enforces that on both systems. Its exceptions:
`Sources/VibeCore/MacOnly/`, `PlatformExport.swift`'s one exported import, and the test files listed in each test
target's `MacOnlyTests.txt`. What only the Mac can have (the dev previews' proxy, the Keychain store, drawing the
status marks) moves file by file into `Sources/VibeCore/MacOnly/`, each file compiled only there; where portable code
calls a Mac-only body by name (the host's cdhash check, its Keychain key), the body moves into `VibePlatform`'s Darwin
form and the name stays as a forward. The exact functions and every call site are in
[the stage 1 recon](../../process/v2-stage1-recon.md).

| Service | macOS today | Linux |
| --- | --- | --- |
| Process table, process tree, cwd, tty | `sysctl`, `proc_pidinfo` | `/proc`; a terminal is named without a slash (`/dev/pts/3` is `ttypts3`) |
| A process's exit | a `DispatchSource` process source | a pidfd |
| Pseudo-terminals | `openpty` | `posix_openpt`, close-on-exec from the start |
| File and folder watching | `kevent` | inotify |
| Sockets, HTTP listener | Network.framework | POSIX sockets (the builder may choose swift-nio, pinned) |
| Hashing, HMAC, ChaChaPoly, P-256 | CryptoKit | swift-crypto (same API; named on both systems so `Package.resolved` matches, linked only on Linux, pinned exact) |
| Who is on the other end of a socket | audit token, `LOCAL_PEERTOKEN` (names the last sender) | `SO_PEERCRED` and the process's start ticks at accept, then `SCM_CREDENTIALS` on every read (stage 2); `SO_PEERPIDFD` where the kernel has it (6.5 and later; this machine has 5.15) |
| "Is this the app?" | cdhash + HMAC under a keychain key | the host's own server child, by pid and start time; see [Security](#security) |
| What the host starts sessions and parsers from | copies of itself under `~/.vibeswitcher/host` | its own image (`/proc/self/exe`), and images held open from its start |
| Secret storage | login Keychain | see [Security](#security) |
| Settings store | `UserDefaults` | a file under `~/.vibeswitcher` |
| Load, cores, memory, disk | `sysctl`, `host_statistics` | `/proc/loadavg`, `/proc/meminfo`, `statvfs` |
| Power: AC or battery, percent | IOKit | `/sys/class/power_supply`; unknown is shown as "power unknown", and Automatic Boost needs a known AC reading, so where power is unknown (WSL, often) it behaves as Off and says so |
| Keep awake | IOKit assertion | `systemd-inhibit` where there is a session bus; nothing on WSL |
| User presence (for Boost Automatic, reminders) | CGEventSource idle time | the web client reports activity over its connection |
| Notifications | UserNotifications | the browser: Web Notifications while a window is open, the existing web push otherwise |
| Login shell and PATH | `LoginShell` | the same approach; no `launchctl` |
| The shell that runs a branch's code | `/bin/zsh -f -c` (`Worktrees.swift`) | `/bin/bash --noprofile --norc -p -c`, with `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `PS4`, `BASH_XTRACEFD` and `BASH_FUNC_*` taken out of its environment; this machine has no zsh |
| Tools (`git`, a shell) | `/usr/bin/git`, `/bin/zsh` hard-coded in 16 places | found on PATH (checked at start once the node calls `Platform.Tools.missing()`) |
| The sessions' environment | today's list, `en_US.UTF-8` by default | no `SSH_AUTH_SOCK`, `WSL_INTEROP` or `DBUS_SESSION_BUS_ADDRESS`; `C.UTF-8` by default |
| Images (`LeadImages`, `MenuBarDots`) | ImageIO, CoreGraphics | `LeadImages`: size and type read from headers, no decode **(call)**; `MenuBarDots` stays Mac-only |

### VibeNode: stores, not view models

The node's logic is a set of **stores**, one per kind of thing, each keyed by id, each emitting a change event when
an entry changes: sessions, chats (one per session, as a timeline of items), projects and boards, teams, cards,
devices, settings, plugins. A store reads what `VibeCore` already computes (status rules, the board, the transcript
reader, the lead's tools) and adds no rule of its own.

- Every entry is a Codable value, and the wire's types are these types. There is no second schema.
- A store learns of changes from events (the host's socket, file watches on boards and transcripts, hook state),
  never from a timer.
- A change event is the delta: the entry's id, its new value or the items appended. A slow client's deltas for one
  entry are folded into the latest.
- Nothing in a store waits for a person. What the Mac app asks in a modal dialog (confirm a restart, a merge, a
  handover) is a card, and the action continues when the card is answered.
- No view state: selection, scroll, search and drafts belong to the client.
- No Combine. The stores are plain Swift with one small change-stream type, so nothing here depends on a library
  that Linux lacks.

The **lead engine** is the part of `LeadController` and the witness that isn't a view: starting and waking leads,
delivering messages and reports, watching for stalls, the limits, the questions. It is written against the team
seam (rule 4). Its outline, the app code each part is rebuilt from, and the order are in
[the bootstrap path](../plans/2026-11-13-v2-bootstrap-path.md#the-engine), and it gets a plan of its own. **(call)**
Until the bootstrap the engine refreshes on a 3 s timer, as the app does; that is the one exception to "never from a
timer", and stage 3's stores remove it after the bootstrap.

### The node's processes

- **`vibeswitcher-host`**: the PTYs, the vault, the node's key, the devices' keys, and the check of every approval.
  The root of trust. It starts the server and owns the listening sockets, which it hands to each server it starts (by
  number, in an environment variable, as systemd's socket activation does). On Linux the server child is the app
  (rule 6: a principal the host created): the host records its pid and start time when it starts it, takes any
  connection from that process as the app, checks each message's sender, and restarts it, from the image it held at
  its own start, when it exits.
- **`vibeswitcher-server`**: the stores, the lead engine, the live protocol to clients and, later, peers. It can
  crash and be restarted without a session ending or an approval being forgeable. It makes itself non-dumpable as
  its first statement.
- **`vibeswitcher`** (the `vibeswitcher-cli` target): `start`, `stop`, `status`, `attach ID`, `lead FOLDER --goal
  "…"`, `pair`, `doctor`, `report`, `update`, `uninstall`. A client like any other, and the first one built. In stage 1
  `status` and `hooks` read local files, as a probe; from the engine on, every command goes through the server.
- **Who starts the node on Linux:** `vibeswitcher start`, through a user systemd unit where the user's systemd runs
  (this machine's does, with lingering on), else as a process in a session of its own. See
  [the bootstrap path](../plans/2026-11-13-v2-bootstrap-path.md#who-starts-the-node-and-keeps-it-running).

Other terminals: a `claude` or `codex` started in any terminal on the machine is listed with its live status and its
chat is readable. It can't be brought to the front or typed into.

### The live protocol

One connection per client (a WebSocket for the web app, the same messages over a Unix socket for the command line,
and later between nodes).

- **Authentication in the first frame**, by the device's key; rights are checked on every action, and revoking a
  device closes its connections.
- **State as snapshot and deltas.** On subscribe the server sends the entries with a sequence number and epoch, then
  only changes. A gap, or a reconnect across an epoch, gets a new snapshot.
- **Subscriptions.** A client subscribes to what it shows. The server sends nothing else.
- **Terminal.** Raw session bytes as binary frames from the host's `attach`, input as binary frames back. Only the
  host's own parser answers a program's terminal queries; whatever a client's emulator would reply is dropped.
  Flow control: the server drops to the host's replay (`resync`) when a client falls behind.
- **Chat.** Items stream as the transcript grows.
- **Actions.** Each has an id; the server replies done or refused with a reason, and the state change arrives as a
  delta. The client shows the action at once and takes it back, saying why, on a refusal. An action that needs an
  approval carries the device's signature (rule 7).
- **Types.** The JavaScript side's validators and a set of JSON vectors are generated from `VibeNode`'s types at
  build time and checked in; a test fails when they're stale.

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

- A new client in its own folder, `WebApp/`, with a desktop and a phone layout. `Web/`, the Mac's phone app, isn't
  touched and isn't ported: the command line is the first client, and the phone gets `WebApp/`'s phone layout.
- **(call)** No build step and no npm: ES modules served as files, embedded in the server's binary. A small rendering
  library and a terminal emulator are vendored into `WebApp/vendor/` at exact versions, their hashes recorded and
  checked against upstream's in CI. The candidates are Preact with signals and xterm.js; a spike against the budgets
  decides before anything is built on them.
- **What an agent wrote is never markup.** The page runs under a content policy that allows its own scripts only,
  with Trusted Types; a lint refuses `innerHTML` and its relatives. Markdown, diffs and tool output are rendered to
  DOM nodes by the client's own code. Files and images an agent produced are served from a separate origin with no
  access to the app's, never as SVG or HTML, with `nosniff`. No remote image is loaded. Links open only for
  allow-listed schemes, after a confirmation for anything outside the project.
- **The terminal emulator is restricted**: no clipboard writes (OSC 52), links confirmed, no image or link add-ons.
- No type checker is installed. The wire's types are generated as validators, and the tests run every message
  through them.

### Security

Who is defended against, in order of how often it happens: a worker that slips; a worker turned by what it read (a
repository, a web page, a dependency) and now trying; another process or user on the machine or the tailnet; a node
of the fleet that was taken over. Not defended against: root, and the user's own unconfined programs.

The Mac's model rests on the audit token, code signatures and the Keychain. On Linux a file the user can read is no
secret and a file the user can write is no record, because sessions run as the user; and on some machines (WSL with
interop, a cloud VM's passwordless sudo, the `docker` group) every process is one step from root. So the design
doesn't rest on a second system user alone. It rests on five things, each a requirement here and designed in full in
the security architecture document (`docs/superpowers/specs/2026-11-13-v2-security-architecture.md`), which stage
2's first task writes and has reviewed before the host is ported, since they shape the host:

1. **Approvals are signatures.** A paired device holds a key that can't be read out of it (the browser's
   non-extractable keys; a security key or the platform's authenticator for pairing, Push, wallet and the guarded
   settings, which ask for the person's presence). An approval signs the exact action and a nonce from the host, and
   the host checks it. A stolen page token, the server, or a peer node can't make one.
2. **The person approves facts, not prose.** A card's deciding fields are derived by the host: the commit and its
   diffstat, the command as it will run, the decoded transaction, which principal asks. They are shown in a frame an
   agent's text can't imitate, never truncated, and are what the signature covers.
3. **Team sessions are confined.** Every worker, verifier and run of a branch's tests gets a sandbox of its own (a
   mount and a process namespace) and a clone of its own, not a worktree sharing the main `.git`. It doesn't see
   `~/.vibeswitcher`, other sessions' processes, the agents' binaries and config as writable files, `/mnt/c`, WSL's
   interop, or the docker socket. Its identity is a socket it inherited from the host, not its place in a process
   tree. A verifier and the code it judges are never in one sandbox. Its network goes through a proxy that refuses
   the tailnet, loopback and cloud metadata addresses. The lead is confined too, to its own narrower needs. Where a
   machine can't provide this (no user namespaces), the node says so at start and runs in the plain mode below.
4. **Listeners are split.** The host owns them. The local one is a loopback port that trusts no header. The remote
   one is a Unix socket that `tailscale serve` forwards to, and the tailnet login is a second lock on it, never the
   only one, since it names a machine and not a person. A bind to any other address is refused.
5. **What is installed is what was released.** A release is a tag signed with a key no agent can use; the updater
   checks it. A node never updates from a branch. (Building from source stays possible, and says what it is.)

Also required: per-message credentials on the host's socket (`SCM_CREDENTIALS`), since `SO_PEERCRED` is fixed at
connect; the host a subreaper; host and server non-dumpable; reply rights type only into confined sessions; view
rights get masked screens; the handover's state file owned by the host; logs without tokens, codes or terminal
text; the wallet's signing page on an origin of its own. Before the bootstrap: per-message credentials, and the
host, its parsers and the server non-dumpable. After it: the subreaper **(call)**, inside the sandbox's own process
namespace, because a host that reaps adopted orphans takes exit statuses from its own code that waits for its
children by pid, and adoption alone doesn't give an orphan back its session; the handover's state in sealed memory
instead of a file; reply rights only into confined sessions; masked screens; the logs' lint. The stage 2 plan says
what each deferral leaves open, and the security document lists it.

Measured on this machine (WSL2, kernel 5.15.167): there is no Yama, so any process of the user may ptrace any
dumpable process of the user. Until the sandbox exists, non-dumpable host, server and parser processes are what keep
a worker out of their memory. The socket buffer limit (`net.core.wmem_max`, 212992) caps the secret a handover can
carry through a socket; until sealed memory replaces it, a vault bigger than that makes the handover fail and the host
stay as it was.

**The plain mode** is the same without confinement: for machines that can't sandbox, for the tests and for CI. It
holds against a worker that slips. `vibeswitcher doctor` and the first-run page say which mode a node is in and what
that guarantees, per environment:

| Environment | Confinement | What a turned worker is kept from |
| --- | --- | --- |
| Linux with user namespaces | yes | the node's state, other sessions, approvals, the fleet |
| The same, where the user is one step from root | yes; the sandbox hides the step | the same, as long as the sandbox holds |
| No user namespaces (some containers, hardened kernels) | no | approvals (signed), nothing else |
| macOS (milestone 5) | the Mac's own (its design decides) | as today, plus signed approvals |

The six holes the earlier review found in a second-system-user design are answered by these, or fall away with it:
root without a password (3), what an install trusts (5), the port (4), one session acting as another (3), the
command line's standing (it is a paired device with a key, like any other), who runs root steps (none are needed).

### The config seal

The same hashes, over the Linux list: `~/.claude`, `~/.codex`, shell startup files, git config, the main checkout's
`.git`, `~/.vibeswitcher/bin`, and what runs by itself after a reboot (`~/.config/systemd/user`, the user's crontab,
`~/.config/autostart`). With confinement most of these can't be written by a team session at all; the seal stays for
the sessions that aren't confined.

### Feature plugins

A feature plugin is a folder that declares, in one place, everything a feature adds:

- the commands agents get (`vs-wallet`, `vs-shell`), and the MCP tools and hook handling behind them;
- its request type, its validation and its store;
- its cards, **as data**: title, the host-derived facts, body, severity, actions, and which actions need a signed
  approval. Every client renders any card with one component;
- its Settings section, as entries in the settings catalog;
- what it adds to an agent's brief;
- whether it is on, and where it can run.

A registry lists the plugins. A plugin that is off leaves no trace: no command installed, no tool listed, no
Settings section, no line in a brief. Shell is on by default. Wallet is off by default, and what is the author's in
it (the GenLayer chains) is its configuration, not its code. The Mac keeps its present wiring until milestone 5.

Later candidates: asks (deploy, database migration, secret access, open a PR, send a message), agent kinds (other
CLIs, through rule 12's adapters), notification channels, work sources, review gates. Other people's plugins would
be separate processes speaking a protocol, as the Wallet Manager is.

### Other people's setups

What "distributed broadly" asks of the design, beyond rules 10 to 13:

- **Releases, not a checkout.** CI builds x86_64 and arm64 archives with the Swift runtime linked in (a fully static
  build is tried in stage 0), a `.deb`, and an install script that checks the signature. Versions follow semver,
  with a changelog. `vibeswitcher update` installs a verified release; `vibeswitcher uninstall` removes everything
  it added, the hooks and the agents' trust entries included.
- **A support matrix**, kept in the repository and tested: Ubuntu and Debian, Fedora, Arch; WSL2; with and without
  systemd; with and without Tailscale (pairing over a forwarded port); a container; arm64. Each row says which mode
  it gets. Other systems may work and aren't promised.
- **`vibeswitcher doctor`** checks what a node needs and says what is missing in words a newcomer can act on: the
  agent CLIs, their versions against the adapters' ranges and whether each is logged in, git, file watching, the
  filesystem, user namespaces, Tailscale. **`vibeswitcher report`** makes a bundle for a bug report with secrets
  taken out. No telemetry.
- **The agents.** Claude Code only, Codex only, or both; subscription or API key. The lead needs Claude Code today;
  the adapter says so. A nightly run tries the latest versions of both CLIs and opens an issue when an adapter's
  range should move or its tests fail.
- **Licences**: third-party notices generated into every release (SwiftTerm, swift-crypto, the vendored JavaScript),
  and a line that the project isn't affiliated with the agents' makers.
- **The Mac**, at milestone 5, needs a Developer ID and notarization instead of the author's local signing identity.

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
| Phone access | yes, in stage 7 | `WebApp/`'s phone layout; `Web/` isn't ported |
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

Version 2 lives on `v2`, pushed to GitHub. Main is not touched. The routine, as commands:
[v2-branch.md](../../process/v2-branch.md).

1. **Main is merged into `v2`** at least every working day: its changes to `VibeCore` and `VibeHost` are the lead's
   own improvements, which version 2 wants, and they arrive by the merge. Conflicts are settled here. The merge is
   pushed only with both runners green.
2. **The port ledger** (see [Strict isolation](#strict-isolation)) covers what a merge can't carry.
3. **Checks on the branch** say at each merge what main brought that Linux can't take: `PlatformLint` (no Apple-only
   import and no `#if os` outside `VibePlatform` in the portable targets), and the Linux build and test jobs in CI,
   which are the check for what Linux's Foundation lacks (each break they find becomes a `VibePlatform` service or a
   test). Fixing what they find is part of the merge. A target main adds is mirrored into `Package.swift`'s Linux
   list.
4. **How much the merges cost is measured.** If they take more than a fifth of the working time, the user hears it,
   with the numbers.
5. **A parity file**, `docs/process/platform-parity.md`: every user-facing feature, and whether each client has it,
   with a section of test counts checked against the `MacOnlyTests.txt` lists (after the bootstrap).
6. **Landing.** `v2` reaches main only once the Mac is on version 2 (milestone 5) and the user says the whole works
   extremely well. The Mac app is built and tested on a real Mac at the end, as milestone 5 begins.

## The plan

Milestone 1 is stages 0 to 6, milestone 2 is stage 7, and stage 8 makes it something other people can install.
Each stage ends in something that runs and can be shown, and gets its own implementation plan
(`docs/superpowers/plans/`) when it starts. Security isn't a stage: each stage builds its part of the security
architecture, and stage 6 ends with an attack on the whole.

### The bootstrap

Decided 2026-11-12: Claude Code builds version 2 only until VibeSwitcher on Linux can run a lead end to end. From
then on a VibeSwitcher lead on this machine builds the rest of its own version 2, supervised from Claude Code. So
stages 1 to 4 are each cut to what a lead needs first, and the rest of each is the lead's own early work:

| Stage | Before the bootstrap | After it, built by the lead |
| --- | --- | --- |
| 1 | The platform services a lead's path uses (processes, spawning, file watching, clocks and `stat`, load and cores, the settings store with its format, tools on PATH), swift-crypto, the hook and tool server, `scripts/test.sh` on Linux, `VibeCoreTests` green, `vibeswitcher status` as a local probe, `vibeswitcher hooks install` | Dev previews' proxy, image thumbnails, power and keep-awake, `doctor`, the adapters with their version ranges and nightly run, resources inside the binaries, format versions in every other file, the static build and the binary decision, the parity file |
| 2 | The security architecture document; the host with PTYs, parsers, handover, per-message credentials, the server child as the app, the host, parsers and server non-dumpable, launchers and restarts from images held at start, the handover's target checked, the project allow-list | The sandbox itself (and in it the subreaper), the egress proxy, sessions identified by an inherited socket and clones for workers (both proposed, S2-D9 and S2-D10, until the user answers), the handover through sealed memory, strong mode |
| 3 | `vibeswitcher-server` with a small versioned request/reply protocol on a Unix socket, and the command line as its client | The sessions and chats stores with snapshot and delta, the WebSocket, device keys and pairing, the terminal spike, the two-node smoke test |
| 4 | The lead engine (a plan of its own), the merge gate, `auto_advance`, limits, `vibeswitcher lead` and answering from the command line, `vibeswitcher start`, the install step, the config seal's Linux list | The team seam with clones, boards and cards as stores, approvals as device signatures, launch rules checked against the adapters |

Rules 10 and 11 hold before the bootstrap only for the build's identity (the install's `build-info`) and the files
the node adds; the rest is the lead's. Moving sessions identified by an inherited socket and clones for workers to
after the bootstrap is the stage 2 plan's proposal (S2-D9, S2-D10) and waits on the user.

**(call)** What shapes the host (the app's principal, per-message credentials, what the host executes) comes before
the bootstrap; the sandbox comes after, because until then the only repository a lead works on here is
VibeSwitcher's own, which the user trusts. No other project runs on the node before stage 6's attack has passed.
Scratch hosts made by tests and end-to-end runs are exempt; the user's host enforces the rule with a project
allow-list (the stage 2 plan's S2-D11, held by the security document's S11).

- **The lead that builds is an installed build**, in its own folder, made on purpose from a commit of `v2` that both
  runners passed. It is never the working copy. A new build replaces it only by a deliberate install; if that build
  can't run a lead, the previous one is put back and the fault is fixed from Claude Code.
- The lead's base branch is `v2`, its records are `docs/lead-v2/`, and it pushes nothing: `v2` is pushed after its
  merges pass both runners.
- The lead runs on a clone of its own with base `v2`, never the checkout Claude Code edits. Commits move between the
  two on purpose, and each move is accepted as a base move.
- The user answers the lead from the command line until stage 5's web client exists. Until approvals are signed, an
  answer from the command line is taken only from a process no session owns, which a worker that tries can fake: a
  guard rail, acceptable on VibeSwitcher's own repository only. On Linux before the sandbox the same holds for
  verdicts and merges: with no Yama a worker can ptrace a session's agent or tool server and act as that session,
  the lead or a verifier included, and a worker can restart the host, emptying its memory-only vault, into whatever
  the install folder and the systemd unit then name (the stage 2 plan's S2-D1 and S2-D3).
- The order of the work, and what the user is asked once at its start, are in
  [the bootstrap path](../plans/2026-11-13-v2-bootstrap-path.md).

Done when (**the bootstrap**): from an installed build, a lead on this machine plans a real version 2 task, a worker
builds it, it is audited, and it merges into `v2` through the gate with the tests green.

### Stage 0: ground

- The `v2` branch and two CI workflows on it: macOS (build everything; run what a hosted runner can) and Ubuntu.
- The measured distance from compiling on Linux ([inventory](../../process/v2-linux-inventory.md)): 505 errors in 34
  of `VibeCore`'s 171 files, 142 in 8 of `VibeHost`'s 13.
- A spike: a fully static Linux build of one small binary, for x86_64 and arm64.

Done when: both runners are green on `v2`, and the inventory is in the repository.

### Stage 1: the core on Linux

Before the bootstrap:

- `VibePlatform`, a service at a time, each with tests that run on both systems
  ([plan](../plans/2026-11-12-v2-stage-1-core-on-linux.md)). One shared spawn wrapper removes a fifth of the errors.
- swift-crypto on Linux. Tools found on PATH. The settings file with its format version.
- `scripts/test.sh` on Linux, the tests' home guard in its Linux form, `vs-heavy` reading `/proc`.
- `VibeCoreTests` pass on Linux, except those about Mac-only things, which are marked so and counted.
- `vibeswitcher status`, as a local probe, and `vibeswitcher hooks install`.

After it (the lead's): resources inside the binaries (rule 10); a format version in every other file the core writes
(rule 11); the agent adapters (rule 12) and their nightly run; `vibeswitcher doctor`; the static build and the
binary decision.

Done when: `scripts/test.sh` is green on Ubuntu for the core, and `vibeswitcher status` shows a real session going
from working to needs-you to done.

### Stage 2: the security architecture, then the session host

Before the bootstrap ([plan](../plans/2026-11-13-v2-stage-2-session-host.md)):

- First, the security architecture as a document of its own, reviewed by someone who didn't write it: the five
  requirements above, in the detail a builder needs, each saying whether it is needed before the bootstrap.
- PTYs and session start, the parsers, the replay buffers, handover; a session's terminal named as the process table
  names it.
- The host's socket with per-message credentials; the server child as the app; the host, parsers and server
  non-dumpable; what the host executes held from its start; the project allow-list; the plain mode.
- `VibeHostTests` and the security audit's tests pass on Linux, with the new ones; the lead's tool server lists its
  tools under a host.

After it (the lead's): sessions identified by an inherited socket (proposed, S2-D9, until the user answers); the
sandbox and the clone for team sessions; the egress proxy; the subreaper; the handover through sealed memory; strong
mode; `vibeswitcher attach ID`.

Done when, before the bootstrap: a `claude` session under the host survives its client quitting, a handover and a
killed parser. After it: from inside a confined session, another session's screen, the node's state and the host's
memory are all refused.

### Stage 3: the protocol, with the command line as its first client

Before the bootstrap: `vibeswitcher-server`, started by the host, with a small versioned request/reply protocol on a
Unix socket, and `vibeswitcher` as its client (the engine's plan, part E1).

After it (the lead's):

- `VibeNode`'s first stores (sessions, chats) and the wire types generated from them; the engine moved off its timer
  onto them.
- The listeners the host owns; the live protocol over a Unix socket and a WebSocket; device keys, first-frame
  authentication, rights.
- `vibeswitcher` as a full client: the list, a session's chat, attach, reply.
- **The terminal spike**: one page, the emulator and the raw byte stream, measured against the budgets, before any
  more of the web client is built.
- A two-node smoke test: two servers on scratch homes on this machine, to keep rule 1 honest.

Done when (**first light**): `vibeswitcher start`, then the list and a live session from the command line, with
sessions surviving a server restart; and the terminal spike meets its budget in the browser.

### Stage 4: leads

Before the bootstrap:

- The lead engine, rebuilt from the app's code ([outline](../plans/2026-11-13-v2-bootstrap-path.md#the-engine)).
- The tool server's keeper, the merge gate, `auto_advance` on file watches, the node's limits, the config seal's
  Linux list.
- `vibeswitcher lead FOLDER --goal "…"`, and answering a lead's question from the command line; `vibeswitcher start`
  and the install step.
- End-to-end runs with real agents on scratch repositories, on Sonnet or smaller.

After it (the lead's): the team seam with clones for workers; boards, teams and cards as stores; approvals as signed
actions; the launch rules checked against the adapters.

Done when (**a lead on Linux**): on a scratch repository here, a lead plans, runs two workers, audits and merges a
task, and its question is answered, all from the command line.

### Stage 5: the web client

In slices, each usable at once: the frame, the list and a live terminal; the chat with composer, steering and cards;
starting a lead, the Team tab and strip; Settings and launch presets; ⌘K, notifications, the start page, onboarding.
The plugin registry arrives with the first card; shell, then wallet.

Done when: every row marked "yes" in [Parity](#parity) works in the browser and every budget is met on this machine.

### Stage 6: the attack, and a week of use

- A reviewer who didn't build it attacks the node as a turned worker, as another local process, and as a page
  showing hostile content: forge a verdict, approve a merge, pair a device, read the vault, reach another session,
  inject script through chat, a diff, a file name and the terminal, take the port, survive a reboot.
- The user runs their own leads on it.

Done when (**milestone 1**): every attack is refused or is on the written list of what a mode doesn't promise, and
the user has run their leads from it for a week without going back to a terminal for anything in the parity table.

### Stage 7: remote (milestone 2)

- The remote listener behind `tailscale serve`; pairing a device that isn't on this machine; a headless node's first
  device paired over ssh.
- `WebApp/`'s phone layout, with the reply rights and push notifications.
- A second full device on the same node: two windows on one session, both live.

Done when: the user runs their leads on a headless node from a laptop and answers them from a phone.

### Stage 8: other people

- Releases: the archives, the `.deb`, the signed tags, the install script, `update` and `uninstall`.
- The support matrix, each row installed and smoke-tested on a clean machine or container in CI.
- The defaults audit (rule 13), the guides for someone who isn't the author, the notices.
- Pre-releases for Linux, from tags on `v2` **(open)**.

Done when: someone who has never seen the repository installs a release on a machine of theirs from the guide alone
and runs a lead.

### After

Milestones 3 to 6 each start with a design of their own. Milestone 5 begins with the first build and full test run
of the branch on a real Mac; what that finds is fixed before anything new is built there. The branch lands after it.

### How the work is done

- Until the bootstrap, by Claude Code on this machine, on `v2`: a subagent per slice in its own git worktree, a
  reviewer that hasn't seen the slice before it joins the branch. After it, by a VibeSwitcher lead running here,
  with Claude Code supervising and taking what the lead can't.
- `AGENTS.md` applies as written: tests only through `scripts/test.sh`, fake ttys, nothing typed into a real session,
  nothing installed by an agent, a fix's test shown failing without the fix.
- Real agents in end-to-end runs use Sonnet or a smaller model.
- Nothing joins `v2` with either runner red.

### Risks

| Risk | What limits it |
| --- | --- |
| The logic exists twice until milestone 5, and main's side keeps changing | The port ledger; stores that only read what `VibeCore` computes, so most of main's changes arrive by merge; the cost measured |
| Merging main becomes the job | Daily merges; seams only in shared files; the lints; the measured fifth |
| The Mac is first run at the end, and something only a Mac shows has piled up | The macOS runner builds every push and runs what it can; the Mac target is untouched, so what reaches the Mac is main's app; milestone 5 starts by fixing what the first run finds |
| Confinement breaks what a worker legitimately needs (containers, services, a GPU) | The security architecture lists what a sandbox allows per project, set by the user; a project can run unconfined, and says so on every card |
| A machine can't sandbox | The plain mode, said plainly; signed approvals hold everywhere |
| Linux's Foundation behaves differently | The existing tests run on both; each difference becomes a test or a `VibePlatform` service |
| `--build-system native` is deprecated in Swift 6.4 | The toolchain is pinned; checked at each toolchain bump |
| musl isn't checked until the static build (after the bootstrap) | The static build job and the hook timing run, when they come |
| Hosted-Mac failures with no cause found, in new platform code | Each skip carries the experiment that will find its cause, and `docs/process/v2-mac-tasks.md` lists it for the real Mac; at most two pushes go to one before Linux work goes on |
| No Yama on WSL2: any of the user's processes may ptrace another | The host, its parsers and the server non-dumpable; the sandbox after the bootstrap |
| The engine, rebuilt from `LeadController`, misses or changes something the app does | The app's tests ported as the engine's spec; the port ledger |
| WSL stops the node when no Windows terminal is open | Measured before the bootstrap; the user decides how it stays up |
| SwiftTerm has a Linux problem under load | It builds; the host's tests and the terminal spike exercise it |
| Claude Code or Codex change under the node | The adapters' ranges, the probe at start, the nightly run |
| The browser can't meet the terminal budget | Stage 3's spike decides before stage 5 builds on it |
| Milestone 1 bakes in one machine or one person | The thirteen rules; the two-node smoke test from stage 3; stage 8's clean-machine installs |

## Verification

- Everything through `scripts/test.sh`, on both systems.
- The web client is tested in the Chrome already on this machine, headless, driven over its DevTools protocol by a
  small driver using Node 22's built-in WebSocket. The web bench measures the budgets that way, and that run is the
  one that can refuse a slice.
- The window the user really uses is a browser on another system. A bench page in the app measures the same budgets
  there and reports them; it informs, it doesn't gate.
- The security audit's tests run on Linux in both modes.
- A Linux counterpart of the sandbox (`scripts/sandbox-server.sh`: run, shot, quit) so UI changes are shown, light
  and dark.

## Decided

- Strict isolation: everything on `v2`, here; main untouched; the Mac checks at the end (2026-11-12).
- The bootstrap: Claude Code builds until a lead runs here, then VibeSwitcher builds its own version 2 (2026-11-12).
- `v2` lands on main only once the Mac is on version 2 (2026-11-12).
- The fleet is designed generically, for any mix of machines (2026-11-12).
- The stronger security; signing in the browser's wallet for the wallet plugin; real agents on Sonnet or smaller in
  test runs; remote use over Tailscale, with the phone app renewed.
- The platform layer is one module, `VibePlatform` (with a C shim, `CVibePlatform`, on Linux), not a folder per
  target: it compiles and is tested on Linux before `VibeCore` does, and the boundary is the compiler's (stage 1,
  2026-11-12).
- `stat`'s fields are read through functions (`Platform.Files.modified(_:)` and the rest), not an extension of
  `stat`: on Linux a file can meet CoreFoundation's copy of the type first, and an extension made on Glibc's copy is
  then not found (stage 1, 2026-11-12).
- A locked ticket file is made by link on both systems (`createLocked`: made under a name of its own, locked, linked
  to its name). The Mac's `O_EXLOCK` showed the same gap on the hosted runner (13 of 200 tickets seen unlocked), so
  the Mac changed too; `docs/process/v2-mac-tasks.md` lists it for the real Mac (2026-11-12).
- The command line's target is `vibeswitcher-cli`, installed as `vibeswitcher` on Linux, because a `vibeswitcher`
  target would differ from the app's `VibeSwitcher` only in case (2026-11-13).
- The order to the bootstrap, the engine's outline and what the user is asked at its start are in
  [the bootstrap path](../plans/2026-11-13-v2-bootstrap-path.md) (2026-11-13).

## Open decisions

For the user:

1. **Pre-releases for other people from `v2`** (stage 8), before the branch lands, or nothing public until then.
2. **What the renewed phone app keeps** from today's (stage 7 starts by listing it).
3. **First-version cuts**: dictation, the spoken briefing, Statistics, dev previews and freeze reports are "later".
4. **The stage 2 plan's decisions marked "the user confirms"** (the Linux app principal and what it leaves open before
   the sandbox, chiefly that a worker can restart the host into its own code and can act as any session; the vault
   in memory, with one `config accept` after every host restart; the subreaper deferred; the handover's file kept,
   checked by its hash; sessions by inherited socket and clones after the bootstrap; the project allow-list; the
   sessions' environment), and how the node starts (`Restart=no`) and stays up on WSL (a measurement only the user
   can make). Put once, together, as [the bootstrap path](../plans/2026-11-13-v2-bootstrap-path.md#what-the-user-is-asked)
   says.

## Left to the builder

- swift-nio or plain sockets for the listeners and the WebSocket; whichever it is, pinned exact and few.
- The rendering library and terminal emulator, after the spike.
- The change-stream type in `VibeNode`.
- How the generated wire types are produced.
- The sandbox's mechanism (bubblewrap, or the namespaces directly), within what [Security](#security) requires.
- The binary decision: one binary or several, from stage 1's static build and the hook's start-up time, after the
  bootstrap. Whichever it is, the host never trusts its server by the executable's identity.
- The order of slices inside each stage, and their contracts.
