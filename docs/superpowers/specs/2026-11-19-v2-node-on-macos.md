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
