# The node on macOS

Step 1 of "V2 useful on the Mac": the VibeSwitcher 2 node (the `vibeswitcher` command line, `vibeswitcher-server`, the
node's host, the web page) on a Mac, next to the Mac app, with the app unchanged. Written 2026-11-19 on Linux, from the
code at `b5084905`, with no Mac at hand: every statement about what a Mac does is either read from this repository's
Mac code, or marked **(needs a real Mac)**. Read with [the design](2026-11-12-vibeswitcher-2-design.md),
[the security architecture](2026-11-13-v2-security-architecture.md) (S1 to S4, S7 to S9, S11, "The Mac and Linux") and
[the start plan](../plans/2026-11-16-v2-start-install-seal.md).

## What the node on a Mac is in this step, and what it isn't

**It is**: a node that builds on the Mac (the Mac's target list already holds `VibeNode`, `vibeswitcher-cli` and
`vibeswitcher-server`; `v2 macos` builds and runs `VibeNodeTests`), whose every Linux-only assumption is either behind a
platform seam (`Platform.Service`) or refused by name, so that on a Mac:

- `vibeswitcher start`, `stop`, `status --ack`, and every command that reaches the user's node's server (`status`,
  `lead`, `questions`, `board`, `answer`, `hold`, `tell`, `config`, `base`, `hooks`, `web`, `switch`, `rollback`) refuse
  at once, before they read or run anything, with one line saying the user's node isn't built for the Mac yet, and exit
  69 (`NodeSystem.usersNodeRefusal`). Before this step they failed late and obscurely (`/proc/self/exe` missing, a
  detached start of a host that ignored `--node`, `systemctl` not found), and the worst of them (below) could have
  started a host on the app's own lock.
- `vibeswitcher status --probe` (stage 1's local read of the agent sessions) still runs: it reads the process table and
  starts nothing.
- `vibeswitcher-host --node` is refused (`HostImages.macNodeRefusal`). It used to be ignored on the Mac, so a host
  started as the node's became an ordinary Mac host on `~/.vibeswitcher/host.lock` and `host.sock`: the app's host, or
  a second host fighting it for the lock. The app never passes `--node`; its host is unchanged.
- A user's server (`vibeswitcher-server --node`) started on a system with no cgroups is on the **closed** voice rule:
  no peer is the user's (`VoiceRule.at(…, usersNode:)`, `NodeSystem.voiceUnbuilt`). It used to get the weaker rule by
  default. (No host starts one on the Mac today, since `ServerChild` refuses there; this is the rule's own floor.)
- A scratch node (`VIBESWITCHER_HOME` naming a folder other than the account's `~/.vibeswitcher`) is not refused: its
  harness starts it, and its tests decide what runs on the Mac, as before.

**It isn't**: a node that runs as the user's on a Mac. No LaunchAgent, no node host beside the app's, no voice rule, no
Mac seal list, no install script for the Mac. Those are the steps below, each needing a real Mac.

## Where the node is Linux-only today

Read from the code. "Gate" is how the code tells the systems apart: `Platform.CodeIdentity.isAvailable` (true on the
Mac) is the one platform fact shared code may read (`PlatformLintTests`), now joined by `Platform.Service.manager`.

| Mechanism | Where | On the Mac today |
| --- | --- | --- |
| The server child (sealed copy in memory, connector) | `ServerChild.start/restore/carriedServer`, `HostConnector.connect` | refused: "this system has no server child" |
| The node's host (`--node`: root from `getpwuid`, its server checked) | `HostImages.startAsNode` | was ignored (host runs as the app's); **now refused** |
| Handover through sealed memory | `HostServer.handOverThroughMemory`, `HandoverMemory` | the Mac's file handover (the app's) |
| Hardening (non-dumpable, no tracer, the lock by inode) | `HostHardening`, `ServerStart.isTraced` | the Mac's forms: strings compared, nothing hardened |
| The vault's v2 record (retire, life, renewal of `.user` seals) | `LeadVaultV2.isOn`, `VaultV2Handler` | off; the host lists no `vaultV2` |
| The question post to the server | `NodeQuestionPost.enabled` | off |
| Host notes, `spawnNeedsLead`, `watchesItsPath` | `HostServer.capabilities`, `vibeswitcher-host/main.swift` | off |
| The voice rule's cgroup line | `VoiceRule.at`, `Voice.judge`, `Platform.Processes.cgroup` (nil on the Mac) | was the weaker rule; **now closed for the user's server** |
| The voice rule's environment line (`VIBESWITCHER_SESSION`) | `PeerFacts`, `Platform.Processes.environment` (`KERN_PROCARGS2`) | the hosted runner (SIP off) shows another process's environment; a real Mac with SIP on is expected not to, which fails the line for every peer **(needs a real Mac)** |
| The unit, `start`/`stop`, `daemon-reload`, `show` | `NodeUnit`, `NodeStarter`, `NodeStopper`, `StartSequence`, `StopSequence`, `ManagerConfig` | `systemctl` absent; **now refused before any of it** |
| The detached start (no systemd) | `NodeFolders.mode` (`/run/systemd/system`, `/proc/1/comm`), `NodeRecord` | `mode` said `.noSystemd` on the Mac; `NodeContext.current` and `StopSequence.kind` gated it by `CodeIdentity`, now by `Platform.Service` |
| The runtime folder | `NodeFolders.runtimeFolder` (`/run/user/<uid>`) | no such folder; `Platform.Service.runtimeFolder` is nil there |
| The journal (write, read, the ack rule) | `Platform.Journal` (send is a no-op on the Mac), `NodeJournal`, `NodeContext.journalctl` | no journald; `journalctl` now nil by `Platform.Service` |
| The server check (unit `MainPID`, cgroup) | `ServerCheck`, `NodeCheck` | `systemctl` absent; refused before it |
| The installed-build check | `NodeFolders.installedBuild(executable: "/proc/self/exe")` | no `/proc`; refused before it |
| The machine's facts (binfmt_misc, mounts, WSL interop) | `NodeFacts` | Linux files; refused before it |
| install-node.sh | static Linux build, `/opt/swift-*` toolchain, the loader's link check | Linux only |
| The seal's watched places | `LinuxSealList` (empty on the Mac), `ConfigSeal.homeFiles` | the Mac's seal is the app's |
| Process facts | `Platform.Processes` | both arms exist (sysctl, `proc_pidinfo`); ancestry and terminals read on the Mac |
| `claude` | `NodePreflight.claudeLink`, `Platform.Tools` | resolution is shared; the Mac's PATH and Homebrew are untested for the node |

## The root: beside the app, never in its place

The app owns `~/.vibeswitcher` on the Mac: its host's lock, socket and log, the lead vault (`lead/`), the hook binary
(`bin/`), `state/`, the signing keychain. On Linux the node's root is that same folder (no app there). On the Mac the
node's root must be its own, so its host never takes the app's lock or socket, and its vault, records and hooks are
apart: **`~/.vibeswitcher/v2/node`** (call), beside the builds (`~/.vibeswitcher/v2/builds`, the start plan's prefix),
its server socket at `~/.vibeswitcher/v2/node/v2/server.sock` (59 bytes for a 13-byte home, under the Mac's 104).
The app's launch repair (`PrivateRepair.atLaunch`) walks `~/.vibeswitcher` once ever (its marker): it makes files
0600/0700 and leaves programs runnable, so it does nothing to an install made after it; checked on a real Mac.

Two places stay shared, and are the node's to stay out of in this order:

- **Projects' `.vibeswitcher/`** (board, inbox, records): one project is led by the app or by the node, never both. The
  node's `lead FOLDER` will refuse a project whose app lead runs (the app's host lists it) **(later step)**.
- **`~/.claude/settings.json` and `~/.codex/hooks.json`**: the app installs its hooks there (`HookSetup`). The node's
  `hooks install` on the Mac is refused until the node reads the app's hook output, or the two share one hook binary
  that reports to both **(later step, a decision for the user)**.

## The user's voice on the Mac

This is the step's hardest question, and the reason it builds none of the rule: unbuilt is refused.

**What Linux leans on.** The cgroup line (S3): a same-uid process can't leave `user@<uid>.service`, so every session's
descendant, double-forked, `setsid`, `systemd-run --user`, `at`, cron, is told from the user's terminal (`/init.scope`).
The other four lines (ancestry, terminal, environment, branch-code runner) are guard rails; the typed word on
`/dev/tty` is a guard rail against the user's own Claude Code.

**What a same-uid process can do on the Mac** (read from the platform code and Apple's documented behaviour; each a
**(needs a real Mac)** measurement before the rule is written):

- Double-fork: an orphan's parent is launchd (pid 1, `HostServer.orphanParents`), so ancestry says nothing after it.
- `setsid` drops its terminal; `script` gives it a new one, as on Linux.
- Hide its environment from the server, or rather: the server can't read it. With SIP on, `KERN_PROCARGS2` is expected
  not to give another process's environment, so the environment line fails closed for everyone and must go.
- Leave every trace of the session: `open -a Terminal x.command`, `osascript -e 'tell app "Terminal" to do script …'`
  (Automation consent the first time, often granted already), `launchctl submit`/`bootstrap` of its own agent. A
  Terminal window so opened is a real terminal, indistinguishable by process facts from one the user opened. This is
  where the Mac is weaker than Linux: `systemd-run --user` lands in the user's manager, which the cgroup line refuses;
  `open -a Terminal` lands in a context that *is* the user's terminal.

**What it can't do.** Forge its audit token (the kernel's, `LOCAL_PEERTOKEN`, `Platform.PeerToken`); pass a cdhash
check as other code (`Platform.CodeIdentity.runs`, the host's app check today); click a system authentication dialog
(LocalAuthentication's, drawn by the system: synthetic events need Accessibility consent, which Terminal and Claude
Code don't have by default **(needs a real Mac)**); read a Hardened Runtime process's memory without
`get-task-allow`.

**What the Mac app's code identity already gives.** The app's host takes the app as the app's code (cdhash beside the
host) answering an HMAC challenge under the app's key: so on the Mac the user's clicks in the app's window are the
user's voice today, and no session can be the app. That is the strongest voice the Mac has, and the node can lean on
it only by changing the app (a main-side change, out of this step).

**Candidates, compared with Linux:**

| Candidate | What it proves | Against a session's process | Compared with Linux |
| --- | --- | --- | --- |
| Peer code identity: the server checks the peer's audit token runs the installed `vibeswitcher` (cdhash) | the request came through the node's own command line, so its typed word and confirmation ran | a session runs the same command line | a guard rail; Linux has no equivalent (an exec'd path proves nothing there) |
| The four non-cgroup lines (ancestry, terminal, branch-code runner; the environment line dropped) | not obviously a session's | passes after double-fork + `setsid` + `script`, or `open -a Terminal` | Linux's weaker rule, minus one line |
| `responsibility_get_pid_responsible_for_pid` (the responsible process TCC uses) | which app a process is attributed to; inherited across fork, exec, `setsid` | escapes through `open`/AppleScript/launchd into Terminal's own attribution | the nearest thing to a cgroup, but private SPI and escapable: not a rule alone |
| **LocalAuthentication, asked by the server per state change** (Touch ID, else the login password; the prompt's text built by the server from the card) | a person at the Mac agreed to *this* card | can make the prompt appear; can't answer it. The user sees an unexpected prompt naming the card, and declines | **stronger than Linux's cgroup rule against an autonomous session** (it needs the person), weaker against prompt fatigue; S12's signed approvals, early |
| The app's window (its existing code-identity channel) | the user clicked in the app | can't be the app | the strongest, but changes the app (main) |

**Decision (call; the user to confirm, with the order of work below).** The user's voice on the Mac is
**LocalAuthentication, asked by the server** (a signed, launchd-owned process) for each state-changing request
(`NodeWire.changesState`), the prompt's text the card's (what the engine built, never the board's), plus the peer's
code identity (the installed command line's cdhash) and the guard-rail lines. Read-only requests take the peer's uid
and code identity as on Linux. Until it is built and measured on a real Mac, the user's server there is on the closed
rule, and the user's node isn't started at all. Never the weaker rule by default. Later, the app's window as a second
voice, once main takes the change.

## The service: a LaunchAgent, not the app

**Call: a per-user LaunchAgent**, `~/Library/LaunchAgents/dev.vibeswitcher.node.plist`, loaded into `gui/<uid>` by
`launchctl bootstrap` (the session the server needs for LocalAuthentication), `RunAtLoad` only with `--at-login`,
`KeepAlive` false (the unit's `Restart=no`), `ProcessType` `Interactive`, the environment written in the plist (the
unit's `Environment=`/`UnsetEnvironment=`: `DYLD_*` cleared as `LD_*` are). Not started by the app: the app is
unchanged in this step, and a node that needs the app running isn't the node.

What launchd gives less than systemd, said now so later steps don't assume it:

- No cgroup: `launchctl bootout` kills the job's process group, not a session in a POSIX session of its own. So "every
  session ends with the unit" (`KillMode=control-group`) doesn't hold: the host ends its sessions itself on a stop, and a
  crashed host leaves them running, as the app's host does today (S9's row "A host exit").
- The server check: the listener's audit token, its cdhash against the installed build's server, and its parent the
  job's pid (`launchctl print gui/<uid>/dev.vibeswitcher.node`): stronger than Linux's "non-dumpable, in the unit's
  cgroup" on the code, weaker on containment.
- The plist is the user's to write, as the unit file is: the Mac seal watches `~/Library/LaunchAgents`.
- `launchctl setenv` puts variables in every job the user's launchd starts (the manager environment of ST-D2):
  `start` reads `launchctl getenv` for the names it refuses.

## Logs: the unified log for events, a file for stderr

**Call:** the start, stop, acknowledgment and accepted-request events go to the unified log (`os_log`, subsystem
`dev.vibeswitcher.node`), read with `/usr/bin/log show --style ndjson --predicate 'subsystem == …'`; the host's and
server's stderr go to the plist's `StandardErrorPath` under the node's root, for reading, trusted for nothing. logd
stamps each entry with the sender's pid and image path (`processImagePath`, `senderImagePath`), as journald stamps
`_PID` and `_SYSTEMD_CGROUP`: the ack rule (`NodeJournal.passes`) becomes "written by the installed command line's
image" on the Mac. Weaker than Linux's: logd records no cgroup, so a session's process running the command line writes
an entry that counts; the typed word stays its guard rail **(needs a real Mac: whether a same-uid process can write
under another image's name, and `log show`'s access without admin)**.

## Install: built from a v2 commit with Xcode's toolchain

`install-node.sh`'s order holds (provenance, the commit on v2 and passed by both runners, a fresh checkout, a staging
copy hashed once, the record): the Mac's arm differs in

- the toolchain: Xcode's (`/Applications/Xcode.app/Contents/Developer`, or the Command Line Tools), checked
  root-owned and writable by root alone, as `/opt/swift-*` is (an Xcode dragged in by the user is the user's: refused
  with what to do) **(needs a real Mac)**;
- the build: `swift build -c release` with the Mac's toolchain (no `--static-swift-stdlib`: the Swift runtime is the
  system's, in `/usr/lib/swift`);
- the link check: every load command (`dyld_info -dependents`, never running the binary) names `/usr/lib/` or
  `/System/Library/` only, no `@rpath` or `@loader_path` outside the build;
- signing: the linker's ad-hoc signature suffices for the cdhash checks; Hardened Runtime (`codesign -s - -o runtime`)
  keeps `DYLD_*` out and other processes' `task_for_pid` off, as non-dumpable does on Linux. The vault's Keychain key
  is pinned to the host's code: with an ad-hoc signature every switch changes the cdhash and macOS asks again, so the
  node signs with the local identity `scripts/setup-signing.sh` already makes for the app's builds (one decision for
  the user). Notarisation isn't needed: a build made on the Mac carries no quarantine, and nothing is distributed.

## The anchor: a root-owned record of the builds (the Mac's tasks, items 3, 10 and 12)

Written 2026-11-25 on the first real Mac (macOS 27.2, SIP on), after the user chose, of item 10's three anchors, the
root-owned record: one administrator password per install or update, nothing day to day. Until it, every fact the Mac's
checks compared against was the user's to write (the job's plist and label, the builds folder, `build-info`, the
program `launchctl print` names), so a session with a genuine host and a server of its own passed them.

**Where it lives.** `/Library/Application Support/VibeSwitcher/node-<uid>.pins` (`Platform.Service.nodePinsRecord`;
nil on Linux, which has no such record and whose checks are unchanged). A process of the user's can't write, replace,
rename over or shadow it, and the readers check each reason every time they read it, from `/` down, never trusting a
resolved path:

- **Every folder on the path** (`/`, `/Library`, `/Library/Application Support`, `…/VibeSwitcher`) is owned by root
  (uid 0) and writable by neither its group nor others, so no one but root makes, removes or renames an entry in it:
  a rename over the record, a link put in its place and a folder swapped above it all need write on a folder above.
  Measured here: `/` and `/Library` `root:wheel 755`, `/Library/Application Support` `root:admin 755`. The group test
  carries weight: the user is in `admin`, so a `775` there would be the user's to write. The administrator step makes
  `VibeSwitcher` `root:wheel 755`.
- **The file** is owned by root, a regular file, `0644` (readable by the user's processes, written by root
  alone), at most 64 KiB. Its link count isn't asked (the review of 2026-11-25, F2): macOS lets a user
  hard-link a root-owned file it can't write, a second name gives no write, and refusing it would let any process of
  the user's make every check refuse.
- **No link is followed.** The reader opens `/` and then each component with `openat(…, O_NOFOLLOW)` from the folder it
  holds, checks what it opened by `fstat` on that descriptor, and reads the record from the descriptor it checked: a
  link anywhere on the path is refused, not followed, and nothing is checked by one name and read by another.
- **No access control list.** Mode bits don't show an ACL's grant (`chmod +a "everyone allow add_file"`), so a component
  carrying any extended ACL is refused (`Platform.Files.hasExtendedACL`; none on the path today, `ls -le`).
- **Shadowing.** A mount over a folder on the path needs the covered folder to be the user's (macOS lets a user mount
  only on a folder they own) **(not measured here: unproven)**; a mount over it would also show its own root's owner and
  mode to the walk, which refuses anything not root's.
- **What SIP adds.** Nothing to the record: `…/Application Support` carries no `restricted` flag (`ls -lO`), so root
  writes it, which is the point (root is the administrator step). SIP keeps the tools the step and the checks run
  (`/usr/bin/sudo`, `/usr/bin/codesign`, Security) and the kernel's code-signing enforcement out of root's reach, and
  root is one password away (the security architecture's S1): the record moves only with that password.

The path, the folder the walk starts from and the owner it expects are parameters of the reader for tests only (a
scratch tree, an injected owner fact): in the node no environment variable, flag or file chooses them.

**What it holds.** Text, one fact per line, parsed whole and refused whole on anything unusual:

```
# VibeSwitcher node pins: written by the install's administrator step (scripts/node-pins-mac.sh); read by the node's checks
format 1
uid 501
build <commit, 40 hex> host <cdhash, 40 hex> server <cdhash> cli <cdhash>
build …
```

`uid` must be the reader's own. Each `build` line names a commit and the cdhashes of that build's
`vibeswitcher-host`, `vibeswitcher-server` and `vibeswitcher` (the command line), each this Mac's slice as the install
signed it (`mac_sign_hardened`, then `codesign -d -a <this Mac's arch>`): a process running another slice of the same
file (Rosetta's x86_64) has another cdhash and is refused. One to sixteen builds: the installed one first, then the
builds a rollback may go to. No commit and no cdhash twice; every other line, case, length or byte refused.

**Who writes it, and when.** Only the install's administrator step, `scripts/node-pins-mac.sh`, called by
`install-node-mac.sh` once the build is checked, before it is renamed into place (a step refused or cancelled leaves no
build installed: the install runs again whole). It takes values, not paths:
the new build's commit and three cdhashes, which the install read from the copies it signed and hashed (never read
again from the builds folder), and it carries the existing record's rows forward verbatim, after reading that record
with the same checks (never recomputed from files a session can write). It prints exactly what it will write and
where, then runs one `sudo` whose script is text inside it, not a file: it makes the folder (root, `755`, checked
afterwards), writes a temporary file in it as root, sets it `root:wheel 0644`, and renames it over the record. The
install checks the step's text against the commit's blob and runs it from memory, as it does its libraries, so what
`sudo` runs isn't a file a session could edit before the password is typed. A commit already in the record with other
cdhashes is refused (a build's pins never change). `--dry-run` prints and writes nothing. `--record` names only the node's record or a trial's
(`/Library/Application Support/VibeSwitcher-trial/node-<uid>.pins`), and the root half checks the path, the uid (sudo's
`SUDO_UID`) and every line it is handed by the record's pattern before it touches a folder (the review's F4). The step
drops every function its shell imported, as the install does, fixes `LC_ALL`, and runs as `/usr/bin/env -i /bin/bash
-p` (privileged mode imports no function, so an exported `builtin` can't defeat the drop; the install calls it so: F3,
F5, the re-check's N1). `--keep N` takes no values: it rewrites the record there, root's alone, to its first N rows, which root checks
against the record itself; after a security update `--keep 1` is the lever (below). Nothing else writes it: no check,
no start, no switch.

**How each check reads it** (every read through the walk above; anything unreadable is a refusal):

1. **The command line's server check.** The listener's audit token (bound as before: pid, link read before and after,
   `Link.isProcess(of:)`) must run, by Security's dynamic check, the cdhash of a server pinned in the record, with the
   Hardened Runtime. Which file is beside which program no longer matters: no path under the home chooses the row, and
   `launchctl print`'s `program` line drops out (item 12): the running image is read from the process bound to its
   token. Only `pid` stays from `launchctl print`, launchd's own word for the job's process: the listener must be its
   child, in its session, as before.
2. **The host's server child.** The Mac's node host finds its own build by its own running cdhash (`SecCodeCopySelf`,
   `Platform.CodeIdentity.ownCdhash`): no row, no start. Its `--server` file's cdhash must be that row's server; the
   child is then started only while the file still has it, and its connector answers only a child whose token runs it
   (`Image.checked`, as before, now holding the pinned value).
3. **The command line's anchor (item 3's owed half).** The server takes the command line's cdhash from the record's
   row whose server is its own running code, read once at its start: never from `<root>/bin/vibeswitcher`, so a
   command line swapped there after the start is not the installed one.
4. **A switch or a rollback.** The target's host image must be a host pinned in the record (its file's cdhash for this
   Mac's slice, checked by path before the handover), and the new image, once running, finds its row by its own
   running code (2) before it starts a server. A rollback goes only to a build the record still holds: one dropped
   from it is refused. The check is by path, then the switch goes through a keeper proven to run the cdhash that check
   read ("The checked node start", "A switch"); what a swapped file can still do is in "What it doesn't cover", F6.

**When it isn't right**, each refused with one plain line naming the record's path and what to do: install a newer
commit (`install-node-mac.sh`, whose administrator step writes the record from the build it checked). Never values by
hand: a build's cdhashes read from the builds folder are a session's to choose, and a checkout's copy of the step is
the user's file (the install runs the commit's checked blob); the step's no-values form, `--keep N`, only rewrites the
rows of the record there, root's alone, checked again as root. The cases: the record missing; unreadable; a link
anywhere on its path; any folder on it or the file not root's, or writable by its group or others, or carrying an ACL;
not a regular file, too large; not parseable, another format, another uid; and a running code that names no row (an
unknown build). A second hard link isn't one of them (the review of 2026-11-25, F2: any process of the user's can add
one to a root-owned file, so refusing it let a session make every check refuse).

**The fake host (closed at the server's start, the review of 2026-11-25, F7).** A session that re-bootstraps the job
with a host of its own that runs the genuine pinned server passes the command line's check (1): the listener is the
genuine server, the child of the job's process. Closing it from the command line would mean a pid looked up through
launchd and then checked, the racy shape this design avoids. The server closes it instead: at its start, before it
serves or writes anything, a Mac node server finds its own row by its running code and requires its connector's peer
token to run that row's host, hardened (`NodeCheck.macConnectorRefusal`, in `ServerStart`; off with the rest, since no
Mac host starts a `--node` server yet). Measured by the reviewer (`pair.c`): a stream pair's `LOCAL_PEERTOKEN` names
the process that made the pair (its pid and pidversion), fixed at creation: not "the last sender", as this section said
before. Two things for item 13: after an in-place exec handover that token is stale (Security refuses a token whose
process exec'd), so a server carried across a handover needs a new connector or a restart; and the test is at the
function, with a real pair's token (a node server's record path isn't a test's to choose). And from the re-check: a
server child checks its connector's peer once, at its start, so after a handover it would keep serving a swapped host
image; on the Mac the server child is ended and started again after every handover, so the check runs against the new
image (to build with item 13, not here).

## The checked node start (the Mac's tasks, item 13)

Written 2026-11-25 on the same Mac, before the code, on top of the anchor. What `HostImages.isCheckedMacNode` being true
will mean, in one sentence: **a `--node` host on the Mac runs a server child on the account's node lock, keeps the
vault's record of the user's actions (`vaultV2`) and its hooks only after it found its own running code in the
root-owned record and that row's server in its `--server` file, and it hands its state over only to an image whose
running code proved, by a fresh audit token, to be the pinned host it checked.** The constant stays false here: this
section is what makes it safe to turn on, and a later review turns it on.

**At a node start** (`HostImages.macNodeStart`, called by `main` behind `isCheckedMacNode`, before the vault is
opened from disk or anything is served), in this order, each failure a refusal that starts nothing (`notStarted`, exit
78, one plain line naming the record and the remedy):

1. `--node-root` (its build's absolute folder, `<builds>/<commit>`, as the unit and the agent start it; the row is
   found by code, never by this path) and `--server` given, and the lock the host takes is the node's data root's own
   (`<accountHome>/.vibeswitcher/v2/node/host.lock`, the home from the user database, compared by path and by file):
   any other lock is refused, as Linux's `mayStart` refuses it (the Mac's `mayStart` says nothing).
2. The record, read once (`NodePins.read()`, the walk from `/`): missing, unreadable, not root's alone, unparseable or
   another uid's refuses.
3. The host's own running code, from the kernel (`Platform.CodeIdentity.ownCdhash`, `SecCodeCopySelf`'s dynamic
   cdhash): unreadable, or no row's host, refuses ("this host's code is no host the node's record pins").
4. The `--server` file, opened once (`O_NOFOLLOW`, a regular file, the build folder's own `bin/vibeswitcher-server` by
   device and inode, as Linux's `openServer`), and its cdhash for this Mac's slice, read by path while the path still
   names the file opened (device and inode after the read), must be the row's server: another build's server, an
   unsigned or unreadable file, a link, a copy elsewhere refuses.

The result (`HostImages.CheckedNode`: the row, the server's cdhash) goes in the host's config, and only a host holding
one is a node host (`HostServer.isMacNodeHost`): it runs the server child by the row's server cdhash (each start
checks the file still has it, and the connector answers only a child whose token runs it), answers `vaultV2`, and its
vault keeps the record (item 14, below). No checked start, no node host: the refusals at the account's locks
(`macServerRefusal`) stay as they are. Tests reach the same function with an injected record, own cdhash and home;
nothing in the node lets a flag, file or variable choose them.

**A switch (F6 narrowed; the fix round's re-check pending).** macOS has no exec from a descriptor, so whatever is checked before the in-place exec, the
exec runs what the path names then. A checked node host's switch goes through a keeper (`MacHandoverKeeper`):

1. The path check as before (`HandoverTarget.macPinned`): the target's file, read once, is a pinned host; that read's
   cdhash is *expected* (never a second read of the path).
2. The target is started from the path as the keeper (`--handover-keeper FD`), a child of the host. Its first act is
   to make a fresh stream pair and send one end over the inherited channel; that end's `LOCAL_PEERTOKEN` names the
   keeper's own image, made after its exec. The old host requires that token to be its spawned pid, to run *expected*
   by Security's dynamic check, and to be hardened. Otherwise the keeper is ended and the switch refused: the old host
   and its sessions are as they were (a file swapped before this point is caught here, the long window F6 named).
3. On the old host's queue: the server child is ended and reaped (below), the state built, and the state's bytes and
   every descriptor it names (the lock, the listener, the secrets' channel, each session's terminal) sent to the
   proven keeper over the pair it made. Then the host execs the target with only its end of the channel, and with the
   target build's `--node-root` and `--server` in place of its own. Anything
   failing before the exec closes the keeper and leaves the host as it was (its server child started again).
4. The new image, first thing (`MacHandoverKeeper.takeIfAsked`), makes a fresh pair of its own and sends one end to the
   keeper, which requires: the token's pid its parent (the job's pid), the token running the keeper's own cdhash (the
   code proven in 2), hardened. Only then does it make a pair of its own, give one end to the new image, and send the
   state and descriptors over the other, and exit; the new image requires that pair's token to be the keeper's pid
   (`--handover-keeper-pid`, its child), running its own code, hardened (the review's N2). Otherwise the keeper closes
   every descriptor and exits: the image at the job's pid gets nothing (no state, no secret, no terminal, no lock, no
   listener). A keeper that sees no new image within its limit does the same (N6).
5. The new image has run its own checked start (1 to 4 above, and its arguments and environment, below) before it
   takes anything: a checked node's parcel says so (`fromCheckedNode`), and an image holding no checked start of its
   own takes nothing from it and exits; a checked start takes state only from a keeper it proved, never from
   `--handover PATH` (the review's F1 and N2). Then it restores from what it was given, renumbered, and starts a new
   server child.

**A checked node's command line: one parser, one value (the re-check of 2026-11-25, I1).** The gates prove code, not
mode: a wrapper renamed over the target can run the genuine pinned image with arguments of its own, and two readings
of one command line can disagree (a check that skipped each value unread, while `main` took each flag at its first
occurrence anywhere, let `--handover --log …` move the log). So on the Mac, a host whose arguments hold `--node`
anywhere is parsed once, by one strict parser (`HostImages.CheckedCommandLine.parse`), into a value, or refused:

- The grammar is closed: `--node`, `--node-root DIR`, `--server FILE`, and on a switch both of
  `--handover-keeper-channel FD` and `--handover-keeper-pid PID`, or neither. Each flag once; each value present, not
  starting with `-`, absolute where it is a path, a decimal number where it is a descriptor (above 2) or a pid (above
  1). Nothing else: no other flag, no `--x=v` form, no `--`, no positional word. `--handover PATH` is not in it: a
  checked node takes state only through a keeper, so there is no state file to read, decode, go back with or unlink.
- `main` then reads nothing more of the raw command line: for a checked node its `arguments` are the executable
  alone, so every `value(after:)` and `contains` that main or a helper does sees "absent" and takes its default (a
  reader added later fails closed the same way). What needs the node's values takes them from the value: the checked
  start (`macNodeStart(_:…)`), the server child (`ServerChild.adopt`'s arguments, rendered by the value), the build's
  folders, and what the next image of a switch is started with (`CheckedCommandLine.rendered`, which parses back to
  the same value).
- Read before the parser, and so in a class of their own: the mode dispatches at the top of `main` (each recognises
  its mode by its first argument, but the probe, `--handover-probe` anywhere, which only reads and prints a state
  file's format and exits, and the keeper, now its first argument too) and `HostHardening.refusal` (which reads
  `--handover` only when the start is refused, never on the Mac). None of them takes a node's state; a dispatch holding
  an inherited keeper channel never writes the handshake's byte the keeper waits for, so the keeper gives it nothing.
- A test scans the sources of `main` and of every helper it hands the arguments to (their `"--…"` literals and their
  flag constants, `HostHardening.testFlags` among them) and requires each flag found to be classified, in the grammar or
  refused, in a flag's place and in every value's place: a flag added later fails it until it is classified.

**What a checked node resets at its start** (before the record is read): its environment is built from a fixed list,
not filtered: `HOME`, `USER`, `LOGNAME` and `SHELL` from the user database, `VIBESWITCHER_HOME` the data root, the
descriptor limit it carries across its own exec, `PATH` the system's (`/usr/bin:/bin:/usr/sbin:/sbin`) and `TMPDIR`
the system's per-user folder (`confstr(_CS_DARWIN_USER_TEMP_DIR)`); every other variable is gone (`SSH_AUTH_SOCK`,
`DYLD_*`, `SWIFT_*`, `Malloc*`, the locale, `XPC_*`). Every descriptor above 2 that isn't close-on-exec is closed but the
keeper channel; `umask` 077; the working folder `/`; no core files (`RLIMIT_CORE` 0). What the reset can't undo:
variables the loader, the Swift runtime and malloc read before `main` have already acted on this process (the
Hardened Runtime refuses `DYLD_*`; the rest are debugging aids); the reset keeps them from its children. The other
resource limits stay as given (one set low only ends the node). The sessions lose `SSH_AUTH_SOCK` and the user's
`PATH` from the host's environment: step 5 owes how the job gives them (the plist's own environment is a wrapper's to
replace, so it is no answer).

**The switch's proof, both ways and bound to the node (the re-check, I2).** A keeper that proves only its own code,
and a new image that proves only that its keeper is its child running its code, let whoever starts the genuine image
park any state first. So:

- (a) **The keeper proves its parent** before it takes anything. The old host makes a pair after the keeper's proof,
  gives the keeper one end and sends the parcel over the other once the keeper has said it took that end. The keeper
  requires that end's token to be its parent's pid, hardened; and the parcel, when it says it is a checked node's
  (`fromCheckedNode`), only from a parent whose code is a host the root record pins (`NodePins.read`, never a value
  from its arguments). A keeper that finds no record, or a parent the record doesn't pin, takes nothing and exits.
- (b) **A checked start takes a parcel only when it is the node's**: the parcel says it is a checked node's (an
  unmarked one is refused), it came through a keeper the image proved, and its lock descriptor is the node's own
  `host.lock` held through that open file: the data root's lock opened afresh can't be locked (someone holds it),
  then the given descriptor can (so it is the holder), compared by device and inode, before the secrets are read.
  Anything else is refused with every descriptor closed (the image exits).
- (c) **Only a checked node starts on the node's lock**, by file: a host that isn't one, whose lock is the data root's
  `host.lock` by device and inode (or, before it exists, whose folder is the data root's by device and inode and whose
  name is `host.lock`), doesn't start. This is one check in place of refusing its test flags one by one.
- What (b) proves is that the sender held the node's lock; who the sender was rests on (a) (pinned host code) and (c)
  (no host but a checked node holds that lock). The scratch hosts' `--handover-test-checked-parcel` is gone from the
  sources: it forged the mark on genuine code.
- The handshake waits for the other side's byte before data goes over a pair just passed, and every keeper read and
  write has the keeper's limit.

What stays: a file swapped in the short window between the keeper's proof (2) and the exec runs at the job's pid. It
gets nothing, but the old image is gone by then: the keeper closes everything and the sessions end. And a wrapper that
runs the genuine pinned image passes both gates at any point (they check code): what bounds it is that image's own
start, above. "The old host keeps
running" holds for every refusal before the exec, not for that one; closing it too needs an exec bound to the checked
code (an open question for the reviewer: `LightweightCodeRequirements`' launch constraint, untested with an in-place
exec and ad-hoc signatures). A proven new image that can't restore doesn't go back (its fallback would be an unchecked
exec by path): it exits, and the sessions end, said in its log. Going back through a keeper of its own is an idea for
the reviewer.

**The server child after a handover.** On the Mac a server child checks its connector's peer once, at its start, and
a token taken before an exec is refused after it. So the checked node host ends its server child (its connector
closed, SIGKILL, reaped: `ServerChild.endForHandover`) before it parks the state, started again if the switch fails
before its exec, and the new image starts a new one from its own checked
start: its connector is a pair the new image made, so the server's check (`NodeCheck.macConnectorRefusal`) runs
against the new image's code. No Mac handover carries a server child.

**What a real Mac proved (2026-11-25, this Mac, macOS 27.2, SIP on):** the start's checks with this Mac's real signed
images and the kernel's own cdhash (`MacCheckedStartTests`); the keeper's proofs by fresh audit tokens of real
hardened host images, the in-place exec at the same pid, every descriptor carried over `SCM_RIGHTS` and renumbered,
and a real server child ended and started again (`MacKeeperHandoverTests`).

**What no test reaches while `macUnbuilt`, `approvalMeasured` and `isCheckedMacNode` are off:** a real `--node` host
process reading the installed record (the record's path isn't a test's to choose in a node process), a real node
server's connector check end to end, and a real job's pid. The tests drive the same functions with a scratch record
and this Mac's real signed images and tokens, and scratch hosts (`--handover-test-keeper`, a scratch host's test flag)
take the keeper's switch end to end.

**What it doesn't cover** (open, in the reviewer's words where they are the reviewer's):

- **A switch's target swapped between check and exec (F6): narrowed, not closed (the fix round of 2026-11-25; the
  review's re-check of F1 is pending).** The reviewer first: it "is reliable, not a tight race: `HostServer.handOver`
  checks the path, then probes the new build off the queue". With the keeper, what the probes show:
  - A file of other code renamed over the target after the path check: refused at the keeper's proof, the old host and
    its sessions as they were (`MacKeeperHandoverTests/aTargetSwappedAfterThePathCheckHandsOverNothing`).
  - The same in the window between the proof and the exec: the image at the job's pid gets no state, secret,
    terminal, lock or listener (`aTargetSwappedJustBeforeTheExecGetsNothing`), but the old image is gone and the
    sessions end.
  - A wrapper that runs a byte copy of the genuine pinned host with arguments of its own (the review's probe,
    `aWrapperThatRunsTheGenuineImageWithItsOwnArguments`) passes both gates: they prove code, not mode. Before the fix
    round its image "took over 1 sessions and 22 bytes of secrets" with the attacker's `--log` and `--app-executable`.
    Now the parcel goes only to an image holding its own checked start, which takes no argument but its own and keeps
    no variable of this program's (`MacCheckedFixRoundTests/aWrapperRunningThePinnedImageWithItsOwnArgumentsTakesNothing`,
    with a scratch host standing in for the checked node): the wrapper's image takes nothing and exits, and the sessions
    end. A wrapper that runs it with the node's own arguments is the node: what it still chooses is the values of
    `--node-root` and `--server` (bounded by the start: the row's server, by cdhash, in that folder) and every variable
    of the environment outside this program's (`PATH`, `TMPDIR`, the locale), which the sessions inherit as before:
    for the switch-on review.
- **The stale connector check after a handover: closed (item 13).** No Mac handover carries a server child: the node
  host ends and reaps it before the exec, and the new image starts one whose connector it made
  (`afterASwitchTheServerChildIsANewProcess`).
- **Every pinned build passes for good (F8).** "Every pinned build up to 16 back passes every check for good, so a
  session can re-bootstrap an old pinned build whole": an older build's host, server and command line are each the
  record's. The lever is the administrator step: on a security update, install with `--fresh` (or run
  `node-pins-mac.sh --keep 1` afterwards), so no older build stays pinned.
- **The install's own window**: a session that rewrites the staged build between its check and the administrator step
  is the install's S9, as on Linux.

**Where it is built.** `NodePins` (VibeCore: the format, the walk's rules, the lookups), `Platform.Files.readRootRecord`
and `hasExtendedACL`, `Platform.CodeIdentity.ownCdhash`, `Platform.Service.nodePinsRecord` (the seam; Linux's arms answer
nil and nothing on Linux calls them), the checks above in `NodeCheck` (the command line's and the server's connector check), `HostImages`, `HandoverTarget` and `ApprovalVoice`;
off, as the rest of the Mac node is, until items 5 and 13 and the switch-on (`HostImages.isCheckedMacNode`,
`NodeSystem.approvalMeasured`, `macUnbuilt` and `macServerRefusal` unchanged).

## The seal's Mac list

`LinuxSealList` stays empty on the Mac; a `MacSealList` beside it, by the same rules (a change waits for the user's
accept), starts from: `~/Library/LaunchAgents` (folder), the node's plist, the zsh startup files (`.zshenv`,
`.zprofile`, `.zshrc`, `.zlogin`) and what they source, Homebrew's prefix (`/opt/homebrew/bin` is the user's to write on
Apple Silicon and early on PATH: by listing), `~/.nvm` as on Linux, `~/.gitconfig`, Terminal's startup command
(`~/Library/Preferences/com.apple.Terminal.plist`), `launchctl`'s user environment, and the Xcode selection
(`xcode-select -p`). Each row measured on a real Mac before it is added, as Linux's were.

## The order of work

Each step is small, keeps the app unchanged, and says what it needs from a real Mac.

1. **This step** (done here): `Platform.Service` (manager, log, tools, runtime folder; both arms), the command line
   calling it, every user's-node command refused on the Mac before it reads or runs anything, `--node` refused by the
   host on the Mac, the user's server closed on a system with no cgroups. Needs from a Mac: the hosted runner's
   `platform`, `core` and `host` jobs (the Mac arms compile and their tests pass); by hand, that `vibeswitcher start`
   prints the refusal and exits 69 and that no host starts (`docs/process/v2-mac-tasks.md`).
2. **The node's root on the Mac**: `NodeFolders.nodeRoot` from a `Platform.Service` fact (`~/.vibeswitcher/v2/node` on
   the Mac), `HostImages.startAsNode` and the server's `--node` taking it; a scratch host proving it never touches
   `~/.vibeswitcher/host.*`. Needs: a scratch host on the hosted Mac.
3. **A server beside the Mac's host**: the server child on the Mac without a sealed memory copy (the server's file
   opened once and checked by cdhash, Hardened Runtime), the connector over `socketpair` (SCM_RIGHTS works there).
   Needs: the hosted Mac for the tests, a real Mac for Hardened Runtime and `task_for_pid`.
4. **The voice measurements** on a real Mac: the environment line under SIP, `open -a Terminal`/AppleScript/`launchctl`
   escapes and their process facts, the responsible pid, LocalAuthentication from a LaunchAgent in `gui/<uid>` (and with
   the lid closed, over ssh, with no Touch ID). Then the rule (`VoiceRule.Mode` gains the Mac's mode), its tests on the
   hosted Mac, a manual run on a real Mac.
5. **The LaunchAgent**: `start`/`stop`/`status` by `launchctl` (`Platform.Service.launchctl`), the plist written and
   checked, the server check by audit token and cdhash. Needs: a real Mac (the runner's launchd isn't a user's GUI
   session).
6. **The unified log** for events and the ack rule on `processImagePath`. Needs: a real Mac.
7. **install-node.sh's Mac arm** and the signing decision. Needs: a real Mac with Xcode.
8. **The Mac seal list**, measured. Needs: a real Mac.
9. **Coexistence**: `lead` refusing an app-led project; the hooks decision. Needs: a real Mac with the app.

Progress (2026-11-20, on Linux, checked on the hosted Mac only when pushed; each commit and what a real Mac must run are
in [the Mac's tasks](../../process/v2-mac-tasks.md)): step 2 is built (`Platform.Service.nodeRoot`; `--node` still
refused on the Mac). Step 3's code is built: the server child from a cdhash-checked file, its connector a stream pair
with the Hardened Runtime as non-dumpable; Hardened Runtime and `task_for_pid` wait for a real Mac. The user decided the
voice (2026-11-20: Touch ID or the login password for each state change, with the caller check); its code is built
behind a seam (`Platform.Approval`, `ApprovalVoice`) and not wired: step 4 measures it first. Since 2026-11-21 it is wired
(`VoiceRule.Mode.approval`, `Requests.approvalJudgment`, the command line asking no code under it) and still off: the
user's server takes it only once `NodeSystem.approvalMeasured` is turned on, after step 4 and a review. Step 5's agent is built as data (`NodeAgent`: the
property list, its check, the `launchctl` lines and `print`'s pid), not wired: `start` on the Mac is still refused.

## Open for the user: the Mac's reads

Under the Mac's rule a read asks no dialog: the caller check (uid, the installed command line's code, the Hardened
Runtime, the guard rails) is its only gate. Most reads are what any process of the user's already reads on disk. Five
are the user's alone on Linux, where the cgroup tells a detached session apart: `mail` (the projects' private record of
their leads' messages), `recent`, `shells`, `config.held` and `base.show`. On the Mac a session that detached itself
(`open -a Terminal`, AppleScript) passes the caller check with no dialog. **Open (the review of 2026-11-21):** take a
dialog for those five too, keep them as reads (they show what the files show), or refuse them on the Mac until the
app's window carries the voice.

## Decisions

- **(call)** On the Mac, in this step, the user's node is refused by every command before anything is read or run
  (exit 69); a scratch node isn't.
- **(call)** `vibeswitcher-host --node` is refused on the Mac (it used to be ignored, making the app's host).
- **(call)** The user's server on a system with no cgroups is on the closed rule until the Mac's rule is built.
- **(call)** The node's root on the Mac is `~/.vibeswitcher/v2/node`, never the app's `~/.vibeswitcher`.
- **(confirmed by the user, 2026-11-20)** The user's voice on the Mac: LocalAuthentication (Touch ID or the login
  password) asked by the server per state change, with the peer's code identity and the guard rails; the app's window
  later, through main.
- **(call)** The service is a LaunchAgent in `gui/<uid>`, not started by the app.
- **(call)** Events in the unified log, stderr in a file.
- **(for the user)** Signing the node's builds with `setup-signing.sh`'s identity, so the vault's Keychain key doesn't
  ask at each switch; and how the node and the app share `~/.claude` hooks.
