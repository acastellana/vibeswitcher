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

**It isn't**: a node that runs as the user's on a Mac. When this was written (2026-11-19) there was no LaunchAgent, no
node host beside the app's, no voice rule, no Mac seal list, no install script for the Mac. **Since (corrected
2026-11-26, the join of `v2-mac-seal-list` and `v2-mac-runbook`):** each of those is built and off, none of it running
as the user's: the LaunchAgent (step 5, "The LaunchAgent: start, stop and status"; `start` refused by
`NodeSystem.macUnbuilt`), the checked node host beside the app's ("The checked node start"; off behind
`HostImages.isCheckedMacNode` and `macServerRefusal`), the voice rule's `approval` mode (off behind
`NodeSystem.approvalMeasured`; row 3's two new lines settled, not built: "The rule's lines, settled from the
measurements"), the Mac seal list (step 8, "Built: `MacSealList`"; watched only by a checked node host's book) and the
install script (step 7, `install-node-mac.sh`, unproven by a real install). Still not built: the unified log (step 6)
and living beside the app (step 9). The node runs as the user's on a Mac only when the switch-on review and the user
turn those flags on.

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
| The voice rule's environment line (`VIBESWITCHER_SESSION`) | `PeerFacts`, `Platform.Processes.environment` (`KERN_PROCARGS2`) | the hosted runner (SIP off) shows another process's environment; a real Mac with SIP on was expected not to. **Measured (2026-11-25, M2): it does**, for every process of the user's but Apple's platform binaries; the peer's line comes back (the rule's lines, below) |
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
  **Measured otherwise (2026-11-25, the measurement record's M2):** with SIP on, a process of the user's reads
  another's environment, the user's own builds hardened or not; only Apple's platform binaries (`zsh`, `bash`,
  `login`) read empty. So the line can be read of the peer, never of its ancestors; a session drops it at will.
- Leave every trace of the session: `open -a Terminal x.command`, `osascript -e 'tell app "Terminal" to do script …'`
  (Automation consent the first time, often granted already), `launchctl submit`/`bootstrap` of its own agent. A
  Terminal window so opened is a real terminal, indistinguishable by process facts from one the user opened. This is
  where the Mac is weaker than Linux: `systemd-run --user` lands in the user's manager, which the cgroup line refuses;
  `open -a Terminal` lands in a context that *is* the user's terminal. **Measured (the user's keyboard session,
  2026-11-26, from a shell card; the measurement record's K-ESC-1 to K-ESC-3):** `open -a Terminal` and `osascript … do
  script` from a detached process each gave a shell in Terminal's own coalition, on a fresh terminal of Terminal's,
  without `VIBESWITCHER_SESSION`, its chain `login` → Terminal → launchd; no consent dialog was reported for the
  AppleScript one. A job the session bootstrapped itself ran with launchd its parent, no terminal, no variable and a
  coalition of its own.

**What it can't do.** Forge its audit token (the kernel's, `LOCAL_PEERTOKEN`, `Platform.PeerToken`); pass a cdhash
check as other code (`Platform.CodeIdentity.runs`, the host's app check today); click a system authentication dialog
(LocalAuthentication's, drawn by the system: synthetic events need Accessibility consent, which Terminal and Claude
Code don't have by default; **measured for a process not trusted for Accessibility** (2026-11-26, K-LA-7): an Escape
it posted while the dialog was frontmost didn't end it, the person's Cancel did 14 s later (dropped or ignored, not
told apart; no Escape by hand yet); a trusted process is not measured, and a key can at most cancel or type, never give the finger); read a Hardened Runtime process's memory without
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
| `responsibility_get_pid_responsible_for_pid` (the responsible process TCC uses) | which app a process is attributed to; inherited across fork, exec, `setsid` | escapes through `open`/AppleScript/launchd into Terminal's own attribution | the nearest thing to a cgroup, but private SPI and escapable: not a rule alone. **Measured (M5, K-ESC-1 to 3): not inherited under the app's session host (each process its own); Terminal's after `open -a Terminal`, each process its own after `osascript` and `launchctl`: no line** |
| The coalition (`PROC_PIDCOALITIONINFO`, private; launchd's per-job resource coalition) | which launchd job a process descends from: kept through fork, exec, `setsid` and reparenting (M4, K-AG-1) | a session's descendant stays in its host's job's coalition unless it goes through launchd: `open -a Terminal` and AppleScript land in Terminal's, a job of its own in a new one (K-ESC-1 to 3) | the nearest thing to Linux's cgroup for what doesn't go through launchd; escapable through launchd as the Mac is: a guard rail (added, below) |
| **LocalAuthentication, asked by the server per state change** (Touch ID, else the login password; the prompt's text built by the server from the card) | a person at the Mac agreed to *this* card | can make the prompt appear; can't answer it. The user sees an unexpected prompt naming the card, and declines | **stronger than Linux's cgroup rule against an autonomous session** (it needs the person), weaker against prompt fatigue; S12's signed approvals, early |
| The app's window (its existing code-identity channel) | the user clicked in the app | can't be the app | the strongest, but changes the app (main) |

**Decision (call; the user to confirm, with the order of work below).** The user's voice on the Mac is
**LocalAuthentication, asked by the server** (a signed, launchd-owned process) for each state-changing request
(`NodeWire.changesState`), the prompt's text the card's (what the engine built, never the board's), plus the peer's
code identity (the installed command line's cdhash) and the guard-rail lines. Read-only requests take the peer's uid
and code identity as on Linux. Until it is built and measured on a real Mac, the user's server there is on the closed
rule, and the user's node isn't started at all. Never the weaker rule by default. Later, the app's window as a second
voice, once main takes the change.

**Since: one Touch ID for the page, a 12-hour unlock (the user, 2026-11-25; device keys, 2026-11-26).** Touch ID per
state change stays the rule for the command line. For the page the user chose (2026-11-25, their answer 541E258F) **one
Touch ID** that allows the "page acts for you" mode, opens the page and confirms it, after which the page acts with no
prompt for **up to 12 hours** on loopback; the user accepted its stated cost, that during those hours anything able to
read the open page's secrets, a team's session included, could act as them (a design change with a security review).
The same day the remote-access choices made the unlock the device's: a device is paired once with its own key, and
opening the page after a while asks Touch ID (Face ID on the phone) for an unlock that lasts 12 hours; each guarded
change (update and rollback, hooks, a first config accept and changed rails, policy, review floors and models, adding a
plugin) asks its own Touch ID with the change shown, never by the 12-hour unlock alone (2026-11-25, N1). **The
device-keys design's review changes how the Mac does it (2026-11-26, I2): the Mac desktop's daily unlock is a browser
passkey** (still one Touch ID, the browser's prompt), and **the server's own Touch ID dialog, this section's, stays for
the first enrolment of the desktop's key and for guarded changes only**. So on a Mac node the server's dialog is asked:
for each state change the command line sends (the rule below), at the first enrolment, and for each guarded change; the
page's acts inside an unlock ask none. The rule's lines below judge the command line's callers; under the device-keys
design the page's requests are judged by the device's key, outside them.

### The rule's lines, settled from the measurements (row 3, 2026-11-26)

The measurement record's row 3: whether to add the coalition line (M4) and the peer's environment line (M2), and the
`approval` mode's guard rails, from [the measurements](../../process/v2-mac-measurements.md): M1 to M14 (2026-11-25, an
agent's session) and the user's keyboard session of 2026-11-26 (K-LA-1 to K-LA-7, K-ESC-1 to K-ESC-3, K-AG-1; run from a
VibeSwitcher shell card, not Terminal.app). **Settled, not built**: `ApprovalVoice` has neither new line yet;
`NodeSystem.approvalMeasured` stays false until the two lines are built, the independent review that precedes any
switch-on has read them, and the user says go.
**Built, off (2026-11-27, branch `v2-mac-approval-lines`):** both lines are in `ApprovalVoice.callerRefusal` (`ApprovalLinesTests`), each as this table words it, still off behind `NodeSystem.approvalMeasured`; the review owed reads them.

**What carries the guarantee for a state change: the dialog alone.** (A read asks no dialog: for reads these lines
are the whole gate, which K-ESC-1 to 3 now show an escape passes; "Open for the user: the Mac's reads" below.) Every
line in the table is a guard rail, the caller's code and the
Hardened Runtime included: a session runs the installed command line itself, and every process fact below it can shed
by going through launchd (`open -a Terminal`, AppleScript and a job of its own each pass every line, K-ESC-1 to 3), as
the design said. The code check keeps any program but the command line, and a steered one, off the server; the lines
refuse early and quietly what they can tell, so honest callers that aren't the user never reach the dialog. The review
counts the dialog (what it shows, and that only the person at the Mac can answer it) and none of the lines as the
boundary.

| Line | Refuses (and the record) | Lets through | A legitimate caller refused | Unreadable | Settled |
| --- | --- | --- | --- | --- | --- |
| The uid, the installed command line's code (the record's row), the Hardened Runtime | another user; any program but the installed command line; one that could be steered (M6, M7; rows 7, 10) | a session running the command line itself | none | refused | **kept** |
| Ancestry: no live session's program, the host or the server above the peer | a node session's descendant that didn't detach | a double fork (M3); every escape (K-ESC-1/2: `bash` → `zsh` → `login` → Terminal → launchd; K-ESC-3: launchd); item 11's fallback read the escaped chain whole through root's `login` (K-ESC-1/2, as M8) | a command line typed in a node session (meant) | refused | **kept** |
| The controlling terminal isn't a live session's | a peer on a session's terminal | `setsid`; an escape, which gets a fresh terminal of Terminal's (K-ESC-1/2: `ttys014`) | none | refused | **kept** |
| No branch code runner above | a peer under one | (not measured on the Mac) | none | refused | **kept** |
| **The coalition: the peer isn't in the server's own resource coalition** (the node job's: the host, the server and every session descend from it; the server reads its own once at its start, M4's `self`) | every descendant of a node session that didn't go through launchd, however detached: a process keeps its coalition through fork, exec, `setsid` and reparenting to launchd (M4); a `setsid` child of a LaunchAgent job is in the job's coalition while the job runs (K-AG-1, two runs) | the escapes through launchd: a job of its own gets a new coalition (K-ESC-3), `open -a Terminal` and AppleScript land in Terminal's (K-ESC-1/2) | none expected: the user's Terminal is Terminal's coalition (by inference from K-ESC-1, Terminal's process in it; **open**, closed by ANC-1), the app's shell cards the app's (1841, every caller block); a command line typed in a node session is ancestry's already | refused (for reads too, as every line: `callerRefusal` runs first): the installed command line is the user's hardened build, which M4 read detached and hardened; a private read (flavour 20, not in the SDK's headers) a later macOS may change makes every state change refused, loudly, never open | **added** (settled here on the records, for the review) |
| **The peer's environment: `VIBESWITCHER_SESSION` set on the peer itself** (never an ancestor: Apple's binaries read empty, M2 and K-ESC-1/2's chains) | any process carrying the variable: the Mac app's shell cards and agent sessions (`VIBESWITCHER_SESSION=set` in every caller block, K-ESC-1 to 3), which no other line refuses (not a node session, not the node's coalition: an app agent's Bash tool running the command line would otherwise reach the dialog); a node session's descendant that kept it | anything that dropped it: `env -u`, a re-exec with an environment of its own, a job a session loads itself (K-ESC-3: unset, `ppid=1`), an escape into Terminal (K-ESC-1/2: unset) | **the user's own shell cards in the Mac app, for reads as well as state changes**: `ApprovalVoice.judge` runs every line (`callerRefusal`) before it looks at the kind, so `status`, `board` and the other reads are refused there too; on a node the user runs the command line from Terminal, or uses the page; the refusal says so | refused (readable for the user's builds with SIP on, M2) | **added as an early refusal, not a boundary** (the lead's call, 2026-11-26, reversible): the approval's guarantee rests on the dialog alone (its words, open below; one Escape posted by an untrusted process didn't end it, K-LA-7), never on this line or any other, and the review is not to count it |
| The responsible process | — | — | — | — | **no line**: after `open -a Terminal` the escaped shell, `bash` and `zsh` name Terminal (K-ESC-1), after AppleScript each names itself (K-ESC-2), a self-loaded job itself (K-ESC-3), and under the app's session host every process names itself (M5, every caller block): no fact to judge by, and private |

**The `approval` mode's guard rails, with the dialog:**

- **The dialog from the server's place** (a LaunchAgent's process in `gui/<uid>`) appears and approves: K-LA-1 (Touch
  ID, 2.7 s) and K-LA-3 (approved, 3.8 s; the password route by the runbook's instruction, not in the record).
- **Every end but an approval is a decline**: Cancel (K-LA-2, 1.6 s) and the untouched dialog at the server's 60 s
  (K-LA-2, 60.0 s, gone from the screen); the command line waits 120 s (M14), so it always hears it. Kept: the 10 s
  cooldown after a declined, cancelled, timed-out or unavailable dialog; the dialog's text built by the server from the
  card (the tasks' "Before approvalMeasured flips", items 1, 2, 4).
- **One dialog at a time on the server** (`Requests.approvalJudgment`, a second refused while one waits): kept; it
  doesn't depend on the system. **Open**: what the system does with two LocalAuthentication dialogs at once, which is
  what the user sees when a session's own dialog (M9) comes while the server's is up: K-LA-6's first was cancelled
  before the second was asked. Closed by LA-6 with the first left up (the measurement record's owed step 3).
- **A synthetic key, so far**: one Escape posted by a process not trusted for Accessibility, with the dialog
  frontmost, didn't end it (K-LA-7); whether macOS dropped it or the dialog ignored it isn't told apart, and no Escape
  was pressed by hand on it (owed step 1 adds that control). Rail: the node's host, server and command line never ask
  for Accessibility or Automation. **Open**, and left so: a trusted process (an escaped shell is attributed to Terminal, K-ESC-1, so a
  Terminal holding Accessibility would lend it its trust) can at most cancel the dialog or type into it; approving
  needs the enrolled finger or the login password.
- **Open: the dialog's words** (its title, whether the request's word reads first after the program's name). No record
  holds them; the switch-on's own precondition (the tasks' "Before approvalMeasured flips", item 2). Closed by LA-1 with
  a screenshot or the words typed (owed step 1).
- **Open: the lid closed and ssh** (LA-4, LA-5 not run): whether a closed lid changes the route, and that an ssh
  login's ask is unavailable with nothing on the Mac's screen; `LimitLoadToSessionType Aqua` keeping the node out of an
  ssh login's `Background` session (ANC-2's `managername`). Owed steps 5 and 6.
- **Open: anything stronger than the variable to tell the app's sessions from the user's Terminal.** The coalition
  could: a process of an app session that doesn't go through launchd stays in the app's coalition (1841 in every caller
  block; M4), and the user's Terminal is in Terminal's (109496, by inference). A second coalition line, "not in the Mac
  app's coalition" (the app's read from its host, which the node can identify by code), would refuse the app's sessions
  without leaning on the variable, at the same cost (the user's shell cards) and with the same escape (launchd). Not
  decided: K-ESC-1/2 ran from a shell card, so no record holds the user's own Terminal shell's coalition and
  responsible process. ANC-1 in Terminal.app (owed step 2) closes the fact; the review then chooses between the second
  coalition line and the variable.

## The service: a LaunchAgent, not the app

**Call: a per-user LaunchAgent**, `~/Library/LaunchAgents/dev.vibeswitcher.node.plist`, loaded into `gui/<uid>` by
`launchctl bootstrap` (the session the server needs for LocalAuthentication), `RunAtLoad` only with `--at-login`,
`KeepAlive` false (the unit's `Restart=no`), `ProcessType` `Interactive`, the environment written in the plist (the
unit's `Environment=`/`UnsetEnvironment=`: `DYLD_*` cleared as `LD_*` are). Not started by the app: the app is
unchanged in this step, and a node that needs the app running isn't the node.

What launchd gives less than systemd, said now so later steps don't assume it:

- No cgroup: `launchctl bootout` kills the job's process group, not a session in a POSIX session of its own. So "every
  session ends with the unit" (`KillMode=control-group`) doesn't hold: the host ends its sessions itself on a stop, and a
  crashed host leaves them running, as the app's host does today (S9's row "A host exit"). Measured (step 5's "What
  `bootout` ends", and the user's AG-1, K-AG-1, twice): the job's process and its group end, a `setsid` child runs on
  (in the job's coalition while the job ran; its coalition after the `bootout` not read).
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
   command line swapped there after the start is not the installed one. Every place that takes the command line's
   identity, each checked: "Rows 7 and 10" in the LaunchAgent's section.
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
Mac host starts a `--node` server yet). **Corrected 2026-11-27 (the keeper design's K-M1, measured on this Mac, [its row in the
record](../../process/v2-mac-measurements.md)):** this section said, after the reviewer's `pair.c`, that a stream
pair's `LOCAL_PEERTOKEN` names the process that made the pair, fixed at creation. **It doesn't**: it names whoever last
sent, received or polled on the other end, as that process runs now; after an exec a fresh read names the new image
and Security accepts it, and a failed write or read moves it without a byte (K-M1 (a) to (c), (j), (g4)). So the
connector check above is open the same way: a host of a session's own that makes the connector, forks a holder of its
end and execs the genuine pinned host passes it, and the holder talks to the server as its host. It stays off with
the rest (no Mac host starts a `--node` server); its redesign is the keeper design's Mach form (the server judging a
message from its host by the message's own audit trailer: its parent's pid, a host row of the record, hardened, as
K4a-ii's child proof runs the other way), in step 11. Two things for item 13: after an in-place exec handover the connector's token, read afresh, names the new image
(K-M1 (b): it was thought stale, "Security refuses a token whose process exec'd", which holds only for a token kept
from before the exec), so it proves nothing about the handover either way, and a server carried across a handover
needs the Mach form's proof from its host again, or a restart; and the test is at the
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

**A switch (F6 narrowed; the fix round's re-check pending, as first written; since: re-checked, "not yet" on 2026-11-25 with I1 and I2, below, then after a second fix round "ready to offer for v2", 2026-11-26, corrected at the join of 2026-11-26).** macOS has no exec from a descriptor, so whatever is checked before the in-place exec, the
exec runs what the path names then. A checked node host's switch goes through a keeper (`MacHandoverKeeper`):

1. The path check as before (`HandoverTarget.macPinned`): the target's file, read once, is a pinned host; that read's
   cdhash is *expected* (never a second read of the path).
2. The target is started from the path as the keeper (`--handover-keeper FD`), a child of the host. Its first act is
   to make a fresh stream pair and send one end over the inherited channel; that end's `LOCAL_PEERTOKEN` names the
   keeper's own image, made after its exec. The old host requires that token to be its spawned pid, to run *expected*
   by Security's dynamic check, and to be hardened. Otherwise the keeper is ended and the switch refused: the old host
   and its sessions are as they were (a file swapped before this point was thought caught here, the long window F6
   named; **K-M1 refutes it**: code at the path can make the pair, send its end, fork a holder and exec a copy of the
   target, and the token then names the target at the spawned pid, so the holder takes the parcel. The keeper
   design's K4c moves this proof and step 4's to Mach messages judged by their trailers; until then this switch is
   open to that order, and it is off with the checked node).
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
`DYLD_*`, `SWIFT_*`, `Malloc*`, the locale, `XPC_*`). Every open descriptor above 2 that isn't close-on-exec, as the
kernel lists them (`PROC_PIDLISTFDS`, so one above a limit the starter lowered too), is closed but the keeper channel;
`umask` 077; the working folder `/`; no core files (`RLIMIT_CORE` 0, soft and hard)
(`MacCheckedLastTests/theResetClosesWhatItWasGivenAboveALoweredLimit`). What the reset can't undo:
variables the loader, the Swift runtime and malloc read before `main` have already acted on this process (the
Hardened Runtime refuses `DYLD_*`; the rest are debugging aids); the reset keeps them from its children. The other
resource limits stay as given (one set low only ends the node). What the sessions on a checked node lose under the
reset, for step 5 and the switch-on review: `SSH_AUTH_SOCK`, the user's `PATH`, `LANG`, `LC_ALL`, `LC_CTYPE` and
`__CF_USER_TEXT_ENCODING` from the host's environment; and they inherit its umask 077 and its hard `RLIMIT_CORE` 0 (no
session can raise it). `NodeAgent` writes `SWIFT_BACKTRACE` into the plist, which the reset drops. Step 5 owes how the
job gives the sessions what they need of these (the plist's own environment is a wrapper's to replace, so it is no
answer).

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
  name is `host.lock`), doesn't start; and once its lock is open, the descriptor itself is compared with the node's
  `host.lock` by device and inode (`HostImages.heldLockAllowed`, `HostServer.Config.heldLockIsAllowed`), so a lock that
  made the node's by opening it (another letter case, a dangling link) is refused, the descriptor closed
  (`MacCheckedLastTests/aHostOpeningTheNodesLockByAnotherNameIsRefused`). This is one check in place of refusing its
  test flags one by one. What no check at the start covers: a data root renamed into place after a host started on a
  lock in it (that host holds a lock that becomes the node's); this is inherent to a check made at the start.
- What (b) proves is that the sender held the node's lock. Who the sender was rests on (a), the mark (only a checked
  node's host writes `fromCheckedNode`, and the keeper takes a marked parcel only from a parent running a host the
  record pins), and on (c): a host that isn't a checked node can't start on the node's lock as it is at its start,
  by its path or by the descriptor it opened (a root renamed in later aside). The scratch hosts' `--handover-test-checked-parcel` is gone from the
  sources: it forged the mark on genuine code.
- **The handshake (the flake's cause).** Every pair is passed by the process that made it, which keeps its own copy of
  the end it passed until the receiver says, by a byte over the socket it came on (whose far end the receiver alone
  holds, so a receiver that went is seen at once), that it holds it; nothing is written over a pair whose other end is
  still in flight; every keeper read and write has the keeper's limit (`SO_RCVTIMEO`, `SO_SNDTIMEO`), and a poll that
  couldn't be made is tried again. Caught under load before (8 of 20 runs, 2026-11-25): the new image got the keeper's
  pair, read an end of file before the parcel was whole, and the keeper said it had given it ("the keeper's state
  didn't arrive whole"; 6 of 8); or the keeper's word to the old host failed ("the host has gone"; 2 of 8). Each time a
  socket in flight had been closed by its sender right after it was sent. That the kernel's collection of descriptors
  in flight broke it is inferred, not seen; what the runs show is that no failure came once the senders held their
  copies (100 runs, below).
- **What no test reaches**, with no record on this Mac: a keeper accepting a checked node's parcel (its parent proved
  against the installed record), so the re-check's route 2 (a scratch host of the pinned build given test flags) is
  tested only as far as the acceptance function (`mayTakeHandover`, `nodeLockRefusal`), and route 1 (a parent that is
  no host) end to end.
- **Why no end-to-end test shows a marked parcel refused by an unchecked image, until a record exists.** A parcel is
  marked only by a host holding a checked start (`HostServer.handoverState`: `fromCheckedNode` when `config.checkedNode`
  is set), which only the installed record gives; and a keeper passes a marked parcel on only from a parent running a
  host that record pins. With no record, no marked parcel reaches any image, so the refusal can't be reached end to end
  without a seam that forges the mark on genuine code, which the re-check removed. The property is carried by
  `HostImages.mayTakeHandover`'s first condition (a marked state and no checked start: refused), called for every Mac
  handover that isn't a checked node's switch (`main.swift`, the `mayTakeHandover(state, viaKeeper: kept != nil, …)`
  call), and tested by `MacCheckedFixRoundTests/aCheckedNodesStateGoesOnlyToACheckedStartThroughAKeeper`.
- **N6 once the keeper holds the state**: a keeper whose new image never asks exits at its limit with everything it
  held closed, and the session ends (`MacCheckedLastTests/aKeeperHoldingTheStateWithNoNewImageExitsByItsLimit`, a
  scratch host's `--handover-test-keeper-limit 3`).

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
  review's re-check of F1 was pending when written; since: re-checked twice, the last verdict "ready to offer for v2"
  on 2026-11-26, with F6 still narrowed and not closed as below; corrected at the join of 2026-11-26).** The reviewer first: it "is reliable, not a tight race: `HostServer.handOver`
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
    end. A wrapper that runs it with the node's own arguments is the node, and since the re-check it chooses only the
    values of `--node-root` and `--server` (bounded by the start: the row's server, by cdhash, in that folder): its
    environment is rebuilt from a fixed list and its descriptors, umask, folder and core limit reset at its start. What
    stays the wrapper's: what the loader, the Swift runtime and malloc read from the environment before `main` (the
    Hardened Runtime refuses `DYLD_*`; the rest are debugging aids, kept from its children), and its other resource
    limits (one set low only ends the node): for the switch-on review.
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

## The LaunchAgent: start, stop and status (step 5)

Written 2026-11-26 on the same Mac, before the code, on top of the checked start and the web port hold. What it
builds: `vibeswitcher start`, `stop` and `status` on the Mac as the user's LaunchAgent. All of it stays refused for the
user's node by `NodeSystem.macUnbuilt` (unchanged): the command line's Mac arm sits behind that refusal, and the tests
reach it with a scratch label, plist folder and data root (`NodeAgent.Place`) and a scratch record.

**Measured first (this Mac, 2026-11-26, from an agent's session in `Aqua`; scratch labels `dev.vibeswitcher.node.test-*`,
plists in the clone's `.build`, never `~/Library/LaunchAgents`).**

- *What the user sees.* A `launchctl bootstrap gui/501` of a scratch-path plist (`/bin/sleep 30`, `RunAtLoad`) and its
  `bootout`: the unified log for those seconds (`log show`, no sudo) has no line of Background Task Management's about
  the job (only its routine store saves and monitor updates, the same as before any load) and no notification
  (`usernoted`: another app's only). A plist in `~/Library/LaunchAgents` was not tried: that is the folder BTM watches,
  and the install (step 7) is where it is written.
- *`launchctl print`'s lines* (one tab in, as M11): before a run `state = not running`, `runs = 0`,
  `last exit code = (never exited)`; running, `state = running`, `pid = N`, `runs = 1`; after its process was killed,
  `state = not running`, no `pid`, `runs = 1`, `last terminating signal = Killed: 9` (and on a plain exit
  `last exit code = N`). With `ProcessType` Interactive launchd shows `exit timeout = 5`.
- *What `bootout` ends* (the measurement AG-1 asked for; its own script still is the user's): a job running
  `sh -c 'sleep 302 & perl -e "fork or (setsid, exec sleep 303)"; exec sleep 300'`: `bootout` returned once the job's
  process (`sleep 300`, pid N, group N) and the child in its group (`sleep 302`, group N) had ended; the child in a
  session of its own (`sleep 303`, parent pid 1) ran on. A process of the job killed by a signal took its group with it
  too (`sleep 302` gone, `sleep 303` running). So launchd ends the job's process group and nothing outside it: the host's
  sessions (each in a session of its own, `PTYSpawn`) and its server child (a group of its own) are the node's to end.
  The user's AG-1 (2026-11-26, twice; the measurement record's K-AG-1) gives the same, and adds that the `setsid`
  child was in the job's coalition while the job ran. Its coalition after the `bootout` was not read, so whether a
  process that detached and dropped `VIBESWITCHER_SESSION` (which `stop`'s search by the session ids environments
  carry misses) stays findable by the job's coalition is not measured: a sweep by coalition for `stop` is an idea for
  this step's review, to be measured first, not decided.

**The plist** (`NodeAgent.Job`, written by `NodeAgent.plist`, the same function `agent-plist` prints for the install):

| Key | Value | Why |
| --- | --- | --- |
| `Label` | `dev.vibeswitcher.node` (a test's scratch label) | the job's name in `gui/<uid>`; one job |
| `ProgramArguments` | `<builds>/<commit>/bin/vibeswitcher-host --node --node-root <builds>/<commit> --server <builds>/<commit>/bin/vibeswitcher-server` | exactly `HostImages.CheckedCommandLine`'s rendering for that build (a test parses it back to the same value): nothing a checked start refuses, nothing it doesn't read |
| `EnvironmentVariables` | `SWIFT_BACKTRACE` = `enable=no` | the only variable that acts: the Swift runtime reads it at load, before `main` and so before the reset; `HOME` and `PATH` are gone from the plist (the reset rebuilds both from the user database and the system) |
| `KeepAlive` | false | as the unit's `Restart=no`. A crash leaves the job loaded, not running (`last terminating signal`), and launchd starts nothing again: no loop of any speed, the sessions' terminals gone with the host (they get a hangup), and `status` says it with the signal. `start` again unloads the dead job and loads it afresh. A `KeepAlive` true would restart a host that dies at its start every 10 s for good (launchd's throttle), each time on the node's lock, and would bring back a host the user's `stop` through the server ended |
| `RunAtLoad` | true only with `--at-login` | the unit's `WantedBy=default.target`; without it `start` loads and then `kickstart`s the job |
| `ProcessType` | `Interactive` | the user's own work: not throttled as a background job; its LocalAuthentication dialog (step 4) is drawn in the session |
| `LimitLoadToSessionType` | `Aqua` | only the GUI login's domain takes it (an ssh login's `Background` doesn't) |
| `StandardErrorPath` | `<data root>/node.log` | where the checked start's one-line refusals and the host's stderr go: read, trusted for nothing |
| `StandardOutPath` | `/dev/null` | nothing is written there |

No `Sockets` (the host holds the web port, item 9), no `WatchPaths`, `KeepAlive` dictionary, `AbandonProcessGroup`,
`UserName` or `Program`: any key start doesn't write is a refusal (`NodeAgent.check`).

**Who writes it, and a changed or planted one.** `start` writes it when there is none: the bytes made for this build
as a new file at the plist's path (`open` with `O_EXCL` and `O_NOFOLLOW`, the user's, `0644` as LaunchAgents' are),
then read back and checked (a write cut short leaves a file the next `start` refuses, naming why). When there is one, `start` reads it (`O_NOFOLLOW`, a regular file, at most 64 KiB) and it must
be exactly what `start` would write for this build (`NodeAgent.check`: every key and value, nothing added, and byte for
byte, so a value of another type that reads back equal, an integer for a boolean, is refused); otherwise
it refuses, naming the key, and loads nothing, the file left as it is (the install of another build writes its own,
step 7). Between the check and `bootstrap` the path is read again by launchd: a file swapped in that gap is a program
launchd starts, and the check after the load (below) is what catches it: the job's process must run the job's own
command line as well as the pinned host's code, so the pinned host started with arguments of the swapped file's (its
own `--socket` and `--lock`, a plain host) is refused and booted out.

**How `start` knows the host is the one it meant: by audit token and code, never launchctl's text** (M11: `program` is
the configured program, any path's text a session can give). The build is chosen by code first: the command line finds
its own row in the root's record by its running code (`Platform.CodeIdentity.ownCdhash`, the row whose `cli` it is),
and that row's folder `<builds>/<commit>` must hold a host and a server with that row's cdhashes (read by path; the
host checks its own running code again at its checked start). A record that is missing, or a command line it doesn't
pin, refuses before anything is written. After the load `start` waits for the host's socket (`<data root>/host.sock`)
to take a connection, and takes the connection's `LOCAL_PEERTOKEN`: its pid must be launchd's `pid` for the job (the
one word of `launchctl print` used, as item 12 does), its running code (Security's dynamic check) the host the record
pins for that build, with the Hardened Runtime, and the process the same before and after those reads
(`Link.isProcess(of:)`); then the host's welcome, whose pid must be the token's; and the process's command line (the
kernel's, to its own user) exactly the job's (`Steps.jobArguments`: `NodeUnit.execStart` for the user's node). Only then
"the node runs". `status` and `stop` check the same, a switched node's process allowed the keeper's two flags and their
numbers after it (`NodeAgent.keeperFlags`): read from the switch, not run (no checked node runs here), a checked node's
next image is started as `<target build>/bin/vibeswitcher-host` with `NodeUnit.execStart`'s arguments for that build,
then `--handover-keeper-channel FD --handover-keeper-pid PID` (`MacHandoverSwitch.keeperArguments`, then
`HostHandover.exec`). While it
waits, a job whose process ended (`state = not running`) refuses at once with the end of `node.log`; at the limit
(30 s) it refuses; and every refusal after the load boots out what `start` loaded, so it leaves no job behind.

**A job of that label already there.** Running: the host at the socket is checked as above against any build the record
pins; it passes, and `start` says the node runs already (nothing loaded or written); it doesn't, and `start` refuses
("a job labelled … runs pid N, which isn't the node's host: …") and leaves it alone. Loaded and not running (a crash, an
exit) from the agent's own file (`print`'s `path`, by device and inode): nothing of it runs, so `start` boots it out and
loads its own checked plist; loaded from another file, it is refused and left loaded. A `bootstrap` that fails (a job of
the label loaded meanwhile, by a second `start` or a login) loaded nothing of this start's: nothing is booted out.

**`stop`: what it ends and what the user is told first.** The job's host checked as above (a job running another program
is refused and left alone, as `start` does). Then it says what ends: "the node's host (pid N, build C), its server and
its K sessions end, and the job is unloaded" (K the server's count, `status`'s `host.liveSessions`, as on Linux: the
host's welcome lists only the sessions its caller may end, none for the command line; "every session it runs" when no
server answers), and asks for the typed code (`TypedWord`). It
then asks the server to stop when one answers (it ends the leads and every session, and the host shuts down, as on
Linux), takes a snapshot of the host's children (pid and start), and boots the job out: launchd ends the host's group;
the sessions and the server child are outside it (measured above), and end with the host (the server's connector
closes, each session's terminal hangs up). `stop` waits, within a limit (30 s), until launchd has no such job, the
host's pid and every child of the snapshot have gone and the socket takes no connection, and removes the socket's
file once the host's lock is free. A process still there at the limit is named, and `stop` fails. Not loaded: "the
node isn't running" (69).

**`status`: from the host itself.** Not loaded: not running. Loaded, no pid: not running, with launchd's last exit or
signal. A pid: the host at the socket checked as above against every build the record pins, then its welcome: "the node
runs: build C (the record's row its running code is), host pid N since T", then the server's own status. A host that
fails the check is
said with why ("a job labelled … runs pid N, which isn't the node's host").

**Sessions' environment** (step 5's debt from the checked start's reset). A session's program on the Mac runs as
`$SHELL -l -i -c COMMAND` (`Platform.Tools.sessionShellArguments`), so the user's own login shell builds most of the
environment, as in Terminal and in the app's sessions: `PATH` (`/etc/zprofile`'s `path_helper`, then the user's
`.zprofile` and `.zshrc`: Homebrew, nvm), and whatever locale or variable the user's startup files export. What a
Terminal session gets from launchd and not from the shell, a checked node's host gives its sessions itself, never from
its starter (whose environment the reset dropped), and on the session's spawn alone, never in the base environment the
server child is started with:

- `SSH_AUTH_SOCK`: launchd's own value for the user's domain, `launchctl getenv SSH_AUTH_SOCK`, read by the host at its
  start (`/bin/launchctl`, `Platform.Service.launchctl`): taken only when it is an absolute path to a socket the user
  owns, not a link; else the sessions have none. Measured: a scratch job in `gui/501` running `launchctl getenv
  SSH_AUTH_SOCK` gets the same socket (`/var/run/com.apple.launchd.<random>/Listeners`) as a process outside launchd,
  and launchd gives the job the same in its own environment. *Residual:* the domain's value is any process of the user's to set
  (`launchctl setenv`), as for every Terminal opened after it; the Mac seal list (step 8) can't watch it (launchd's
  memory, not a file: "Built: `MacSealList`", what can't be sealed), only its persistent forms.
- `__CF_USER_TEXT_ENCODING`: `0x<uid>:<encoding>:<region>` as launchd gives it, from the user's
  `~/.CFUserTextEncoding` (home from the user database; two hex or decimal numbers), `0x<uid>:0x0:0x0` without one.
- `LANG`: `en_US.UTF-8` when nothing sets it, as the app's sessions get it (`HostedSession.environment`, unchanged): a
  GUI job has no locale from launchd either. `LC_ALL` and `LC_CTYPE` are the user's startup files' to set.
- `umask`: 022 for the session's program, set by the launcher (`--pty-exec`'s child, before it execs the program); the
  host itself keeps 077.
- The core limit: the reset's hard `RLIMIT_CORE` 0 stays (three reviews passed it); sessions inherit soft 0, which is
  launchd's own default (`launchctl limit core`: `0 unlimited`), so a session's crash writes no core file, as in
  Terminal, but `ulimit -c unlimited` is refused in it. For the reviewer: making the reset's hard limit the one given and
  only the soft one 0 would give it back (no process can change another's limits on the Mac, so soft 0 is what keeps the
  node from dumping).
- A variable the starter planted (the plist's, `launchctl setenv`'s, a wrapper's) never reaches a session: the reset
  dropped it from the host, and a session's environment is taken from the host's by name.

The same is given to the sessions of a scratch host started with `--test-checked-shape HOME` (a scratch host's test
flag, refused for the user's host and a checked node, and refused by the checked grammar): it resets itself as a checked
node does, with `HOME` the given scratch home in place of the user database's, so its tests run the login shell on a
scratch `.zprofile`, never the user's.

**`SWIFT_BACKTRACE`, which the reset drops.** The plist keeps `enable=no`: the Swift runtime reads it at load, so it acts
on the host itself before the reset. For the host's children a checked node puts `SWIFT_BACKTRACE=enable=no` in its base
environment as a fixed value (the server child, the launchers, the parsers and the sessions get it, as Linux's
`sessionEnvironmentFixed` gives it; `MacCheckedSessionsTests` sees it in a session): no Swift child of the node starts the backtracer, which reads the crashed process's
memory into its stderr (the server's is `node.log`). A crash of any of them still goes to the system's crash reporter
(`~/Library/Logs/DiagnosticReports`), as every process's does.

**The review's round (2026-11-26, "ready with fixes"; designed before the code).** What launchd loaded, and the job of
the label, are now bound as follows; each is a refusal that boots out only what this `start` loaded.

- *Measured first* (macOS 27.2): `launchctl print`'s job shows `properties = inferred program` for the agent's plist,
  `runatload | inferred program` with `RunAtLoad`, `keepalive | …` with `KeepAlive` (and a `KeepAlive` job runs at load
  with no `kickstart`, `immediate reason = speculative`); its `environment = { … }` block is the plist's
  `EnvironmentVariables` plus launchd's own `OSLogRateLimit => 64` and `XPC_SERVICE_NAME => <label>`; `arguments = { … }`,
  `stdout path` and `stderr path` are the plist's. A rename of a file away and back, and a hard link to it, change its
  ctime (`stat`, nanoseconds), so a file put back after a swap is not the file as it was.
- *I1, the file launchd read.* `start` keeps the descriptor its read-back checked open and takes its device, inode,
  ctime and size, and the plist folder's device, inode and ctime after its own write. Once the host is seen (token,
  code, command line, executable), the path must still name that inode, its ctime and size unchanged, its bytes read
  again from the descriptor still start's, and the folder the same with its ctime unchanged: any change to the file
  or its folder while launchd read it (a rename over it, one away and back, a write and a write back, a folder swapped
  and back) refuses. And launchd's own word for what it loaded must be the job's: `path` the agent's plist by device and
  inode, `arguments` the job's, the `environment` block the job's variables and launchd's two, `stdout path` and
  `stderr path` the job's, `properties` exactly the measured line for its `RunAtLoad` and no `keepalive`. (Superseded by
  the re-check's round below: that reading was partial, and launchd's raw text let a value add a `path` line.)
- *What can't be bound:* see the re-check's round below (its list replaces this one, whose keys `print` "shows
  nothing of" were wrong: `ThrottleInterval`, `Nice`, `ExitTimeOut` and `SoftResourceLimits` all print a line).
- *I2, a job of the label that runs.* `start`'s "runs already", `status`'s "runs" and `stop` take a running job only when
  launchd loaded it from the agent's own plist (`print`'s `path`, by device and inode), launchd's word for it is the
  job's (as in I1), its process's executable (the kernel's path of its image) is the job's program by device and inode
  (a byte copy elsewhere, or the same code at another path, is another file), its command line is the job's, and its
  token runs a pinned host. The plist on disk must be start's bytes too. *Residual:* a job loaded earlier from other
  bytes at the agent's path, put back to start's since, whose differing keys `print` doesn't show (above).
- *N1, stop asks once.* The server asked for `status` first: it answers, and what ends is said with its count, and the
  server's own stop is asked under the rule the other commands use (`TypedWord.said(approval: client.approvalRule)`: the
  typed code, or the Mac's dialog once `approvalMeasured` is on), its answer read: taken, the host shuts down in order,
  then the job is unloaded; refused, or an answer that can't be read (within `Requests.stopWait + 30` s, as on Linux),
  stop fails, says why and unloads nothing. A server that answers `status` with an error, or unreadably, is a refusal
  too (nothing stopped), and so (the re-check's note 6) is a listener that fails the server check or a hello that is
  garbage or late: only nothing listening at all (`connect` refused or no socket) is no server. Then stop says what
  ends and how ("nothing listens …: the host ends by launchd's bootout; its sessions lose their terminal"), asks the
  typed code, and boots out. A refusal names the manual `launchctl bootout gui/<uid>/<label>` for a wedged node.
- *N2, everything the host started that can be found.* Before the prompt, and again after it (what started while it
  waited), the host's descendants by parent links (every level) and every process in a POSIX session one of them leads;
  and, read at each look (a process that leaves its session between two looks still carries one), the session ids in
  their environments (`VIBESWITCHER_SESSION`, where the kernel gives a process's environment to
  its user: not for Apple's platform binaries), with which every process still carrying one is found at the wait.
  `stop` waits for all of them within its limit, names what is left, and fails rather than saying they ended; done, it
  says "every process of it stop could find has ended". *Can't be found on a Mac:* a process that left its session and
  lost its parent before a look, and whose environment can't be read or carries no session id (a platform binary
  started with an emptied environment).
- *N3.* After a crash, `stop` unloads the dead job and removes the socket's file under the same rule as a live stop
  (a socket, the lock free).
- *N4.* The plist folder must be a real folder (no link), the user's, writable by neither group nor others, with no
  access control list (the re-check's note 4), before
  anything is written or loaded; the plist itself the user's, a regular file, writable by neither, no ACL (launchd refuses a
  group- or world-writable plist; `start` says so itself first).
- *N5.* `status --json` checks the host as the plain `status` does, its line on stderr.
- A plist from the earlier installer (with `HOME` and `PATH`) is refused as any other; the refusal says to remove it and
  run `start` again (`start` writes its own), and the installer (step 7) must write exactly what `start` writes.

**What a real Mac proved (2026-11-26, this Mac, macOS 27.2, SIP on).** Red and green, exactly: `MacAgentTests`' five
launchd tests (a) to (e) and its three first function tests were red on the seams `01d34331` and are green from
`4c2f76b5`; in `MacCheckedSessionsTests` (f) the session's `SSH_AUTH_SOCK`, `SWIFT_BACKTRACE` and umask were red there,
while its `PATH`, locale and the dropped planted names were already green (the login shell and the session's list by
name gave them); `NodeAgentTests`' new cases were green on the seams (the plist as data came with them);
`MacSwitchedHostTokenTests` is a measurement, green when written; the four function tests the blind check's findings
added (`3abd3048`) use the steps that fix adds, so no run before the fix exists. With a scratch label in `gui/501`, a scratch plist folder and data root, and a
scratch record pinning hardened copies of the built host, server and command line: `start` writes and checks the plist,
loads the job, and its host comes up from the plist's exact arguments (the job's pid's arguments are them), known by its
socket's audit token and running code; `status` says so with its build; `stop` unloads it and leaves no job, no process
and no socket (`startLoadsTheJobAndStopLeavesNothing`). A plist that differs (`KeepAlive` true) is refused before any
load and left as it was (`aChangedPlistIsRefusedBeforeAnyLoad`). A job of the label running `/bin/sleep` is refused by
`start` and `stop` and runs on (`aJobOfTheLabelRunningAnotherProgramIsLeftAlone`). The job's host passes `see`; the same
host against a record pinning other code doesn't; a look-alike (`perl` started as `exec -a <the host's path>`, listening,
its first argument the host's path) doesn't (`theHostIsKnownByTokenAndCodeNotByThePathsText`). A killed host isn't
started again: launchd says `not running`, `runs = 1`, the signal; `status` says it; `start` loads it afresh
(`aCrashedHostIsNotStartedAgainByLaunchd`). A scratch host shaped as a checked node (`--test-checked-shape`, the checked
reset itself) gives its session the login shell's `PATH`, launchd's `SSH_AUTH_SOCK`, `en_US.UTF-8`, the text encoding,
`SWIFT_BACKTRACE=enable=no` and the umask 022, and not the starter's planted variable, `SSH_AUTH_SOCK`, `LANG` or
`SWIFT_BACKTRACE` (`MacCheckedSessionsTests`). After an in-place switch through a keeper (a scratch host, the listener
carried across the exec), a connection made afterwards has a token whose running code is the new image's and not the
old's, hardened, at the same pid (`MacSwitchedHostTokenTests`): so `see`, and with it `status` and `stop`, know a switched
host by the build it now runs. No Background Task Management item and no notification came of any of these loads (the
unified log after the runs).

**The re-check's round (2026-11-26, "not yet"): launchd's word read by one grammar.** The round above read `print`
leniently (lines found by their key, the last `path =` taken, any line it didn't know passed over), and launchd prints
values raw: a job's variable whose value holds a newline printed a `path` line of its choosing, and a key the reader
didn't know (a `KeepAlive` dictionary's `semaphores`) was never seen. The rule now, one of its kind for every reading of
launchd's word:

- **Nothing is searched for.** `print`'s whole output is read against a template derived from the job `start` wrote, line
  by line in launchd's order, as bytes (split at 0x0A; any byte but a tab, a newline or printable ASCII refuses). Each
  template line is either a literal made from the job (its label, its plist's path as launchd resolves it, its program,
  arguments, output paths, variables, `properties`) or a strict pattern for what launchd counts (`pid`, `runs`, `forks`,
  `active count`, `asid`, the coalition IDs, and five lines this Mac always prints with the same values, `jetsam priority`
  40, the two `jetsam memory limit`s `(unlimited)`, `jetsam thread limit` 32 and `sanitizer flags` `0x0`, kept as
  patterns, digits or hex: no key measured moves them, `JetsamProperties` included). A line the template can't place, a line after the closing `}`,
  or a value that differs is a refusal. Optional are only the groups measured coming and going: the running group (`pid`
  to `checked allocations flags`), the two coalition blocks, and one of the four last-exit lines. The `environment` block
  must hold exactly the job's variables and launchd's two, each once, any order (launchd's own order is by hash);
  `inherited environment` (the user domain's `launchctl setenv`, the job's to ignore: the reset drops it) only lines
  `NAME => VALUE` with a name, each name once; `default environment` exactly `PATH => /usr/bin:/bin:/usr/sbin:/sbin`.
- **What a value can and can't do.** launchd prints its own lines after an injected value too, so a value that adds
  lines adds them to a whole the template already fixes: the real lines then don't fit, or come after the closing `}`,
  and no key is looked up, so an added line can't be "the" path (always printed, at line 3, before any value), a second
  variable, or another key. *Except* a line launchd prints only for a key that is set: `stdout path` and `stderr path`
  (measured: neither prints without its key). A plist with no `StandardErrorPath` and `StandardOutPath` set to
  `/dev/null` followed by a newline and `\tstderr path = <the agent's log>` prints exactly the two lines the template
  wants, and is placed. But launchd never spawns such a job (measured by the re-check: it can't open that stdout path,
  which lies under `/dev/null`, under `/dev` that the user can't write; every start ends `last exit code = 78: EX_CONFIG`
  with no pid): the host never runs under it, `status` says it doesn't run (69), and `start` boots it out and loads its
  own. Every other key it could change still prints a line the template refuses, and the host's command line, program
  and code are the kernel's. (A plist's `OSLogRateLimit` prints a second line, which refuses; its `XPC_SERVICE_NAME` is launchd's own:
  measured, so no variable can stand in for launchd's two.)
- **The path** printed must be the agent's plist as launchd resolves it (`realpath` of the folder, then the file's name),
  and that path, by `lstat` (no link followed), the file `start` holds open (in `start`) or the agent's plist (`status`,
  `stop`) by device and inode: a link, a hard link elsewhere, another file refuses.
- **One reader, three answers.** `launchctl print`: exit 113 with "Could not find service" (measured) is "not loaded";
  exit 0 and placed is the job; anything else (exit 0 and unplaceable, another exit) is "loaded, not ours": refused,
  and in `start`'s wait it is "not yet" until the wait's limit, then the job is booted out. The bootout's own wait asks
  "not loaded" (113) and nothing else: a bootout that didn't unload says so (note 7).
- **The job refuses to be written** with anything but printable ASCII in its label, arguments, variables and paths (a
  home with a non-ASCII name then refuses: said with the reason).
- **The format is macOS 27.2's** (measured with scratch jobs, below). On another release a line that changed refuses: the
  node then doesn't start until someone looks, which is the intended failure.

*Measured (macOS 27.2, scratch jobs of the node's key set, under `/tmp`):* the states `not running` (loaded, never run:
`last exit code = (never exited)`), `xpcproxy` and `running` (with the running group), and after an exit `last exit code
= 0` (`= 1` bare, `= 78: EX_CONFIG` with its name, `last terminating signal = Terminated: 15` for a SIGTERM), a kill `last terminating signal = Killed: 9`, a code-signing refusal `last exit reason = OS_REASON_CODESIGNING`;
the coalition blocks from the first run on; `path` resolved (`/private/tmp/…`), `program`, `arguments` and `stderr path`
as the plist gives them; `immediate reason = non-ipc demand` after a `kickstart`, `speculative` with `RunAtLoad`. One job
per `launchd.plist` key, diffed against that baseline: `Nice` (`nice`), `ThrottleInterval` (`minimum runtime`),
`ExitTimeOut` (`exit timeout`), `Soft`/`HardResourceLimits` (`resource limits`), `Umask` (`umask`), `WorkingDirectory`
(`working directory`), `StandardInPath` (`stdin path`), `StartInterval` (`run interval`), `StartCalendarInterval`,
`WatchPaths` and `QueueDirectories` (`event triggers`, `event channels`), a `KeepAlive` dictionary (`semaphores`, and it
runs at load), `MachServices` (`endpoints`), `Sockets` (`sockets`, and it runs), `ProcessType` (`spawn type`), and in
`properties` `AbandonProcessGroup`, `EnableTransactions`, `EnablePressuredExit`, `inetdCompatibility`, `LaunchOnlyOnce`,
`LegacyTimers`, `LowPriorityIO`, `LowPriorityBackgroundIO`, `MaterializeDatalessFiles`, `SessionCreate`, `StartOnMount`,
`WaitForDebugger` and an unknown key (`partial import`): each a line the template refuses. No line at all (seven keys):
`AssociatedBundleIdentifiers`, `Debug`, `Disabled`, `InitGroups`, `LimitLoadToSessionType`, `POSIXSpawnType` and
`JetsamProperties`. With their other values (the re-check's measurement, real scratch jobs): `Disabled` true isn't loaded
at all (bootstrap 5, no override written); `LimitLoadToSessionType` `Background` or `LoginWindow` isn't loaded in `gui/`,
absent or `[Aqua]` prints the same; `POSIXSpawnType` `Background`, `Adaptive`, `App` or `TALApp` prints the same and runs
at the baseline's nice 0 and priority 31 (`ProcessType` Interactive wins); `InitGroups` false prints the same, `id` shows
the same groups; `Debug` true is launchd's own logging; `AssociatedBundleIdentifiers` names the job in System Settings'
Login Items only; `JetsamProperties` (`JetsamPriority`, `JetsamMemoryLimit` and its variants, `JetsamThreadLimit`) loads
and runs with every jetsam line at the baseline: launchd ignores it for a gui agent here. None runs other code, changes
the command line, environment, outputs or restarts, or gives a session anything.

*What start still can't bind, and what an attacker must already be able to do for each:*

| Not bound | What it takes |
| --- | --- |
| A key `print` shows nothing of (the seven above) in the plist launchd read | for a job `start` itself loads: a process of the user's renaming `~/Library` (or the home) away and back in the instant launchd reads the plist, with every app's files there gone meanwhile. For a job found loaded (`start`'s "runs already", `status`, `stop`, which bind the plist's bytes on disk as they are now): a process of the user's that rewrites the agent's plist with one of those keys, bootstraps it and writes start's bytes back, with no race. What it gets either way is at most those keys, with the effects measured above: none restarts, reconfigures or runs the host otherwise |
| A disk image mounted over the plist's folder for launchd's read (the covered folder keeps its inode and ctime); not run here (attaching may show UI) | a process of the user's attaching an image at that instant (`hdiutil attach -mountpoint`); its gain as in the row above, since every key `print` shows is still compared |
| Two different plists that print identically | a difference only in the keys of the first row, or the output paths of the next row |
| The job's output paths stood in by a value (no `StandardErrorPath`, `StandardOutPath`'s value carrying the `stderr path` line): placed, but never run | the same as the row above. launchd refuses to spawn such a job (exit 78 at every start, no pid), so nothing runs under it and no log is lost: `status` says it doesn't run, `start` replaces it |
| A server whose listen backlog is full looks like none (`connect` refused, as on the Mac it is) and gets the typed code and the bootout | a wedged server: the user's code is still asked first |
| An orphan in a session whose leader ended before stop's first look, its parent gone (stop's words stay "every process of it stop could find") | nothing: any session's program can leave such a child; found once a host-side record of its sessions' ids exists (owed) |
| A process that left its session and lost its parent before a look, with no readable session id | as the row above |

**What the re-check's round proved on this Mac** (red on `a290cb47`, green from `5fe57dda`): the re-check's tests,
taken over (`MacAgentRecheckTests`): a variable's value printing a `path` line, a job from another plist then made a
symbolic or a hard link to the agent's, a `KeepAlive` dictionary job (`semaphores`) swapped in after start's bootstrap,
each refused by start, status and stop; ACLs on the folder and the plist refused; a link to the user's lock (not yet
made) refused as the user's lock; a child leaving its session between stop's two looks, carrying the session's id, is
waited for; and `limitAnAncestorSwappedAndBackWithAnUnshownKey` (with `Debug`, a key `print` shows nothing of) and
`limitAnOrphanInADeadLeadersSessionCarryingTheId` hold as the table above states. The round's own
(`MacAgentGrammarTests`): the fixtures cut from this Mac's captures placed in each state and refused for every line the
grammar can't place; a job with a control character or a non-ASCII byte not written; this Mac's real launchd printing
the scratch host's job as the grammar says when running, killed and loaded (the canary for a newer release); one real
job per key `print` shows refused, the six it shows nothing of tested there placed (`JetsamProperties`, the seventh, measured by the final re-check); only no listener is no server; a failed bootout
said as failed; and `HostLockLinkTests` (a lock that is a link refuses the host's start, nothing made where it points).

**What the round proved on this Mac** (red on `5dfbde9b`, green from `abab3abd`): `MacAgentRoundTests`, the reviewer's
tests taken over (a swap to `KeepAlive` true or an extra variable at the bootstrap; the pinned host's exact command
line in a job from another plist, and a byte copy of it at another path; a plist folder that is a link; a grandchild in
a session of its own outliving a stop; a killed host's socket file after stop), and the round's own (the file and the
folder swapped away and back with `Nice` 5, a line the agent doesn't compare; a job loaded from other bytes at the
agent's own path, then start's bytes written back; a folder writable by others; a `0666` plist said by start; the
earlier installer's plist; the server's stop refused, taken, and not there; `status --json`); `MacCheckedSessionsRoundTests`
(nothing a starter plants, `ZDOTDIR`, `BASH_ENV`, `HOME`, `SHELL` and `LC_ALL` among it, reaches a session; the test
shape's lock by file). The reviewer's seventeen others pass as they did.

**What no test reaches while `macUnbuilt` and `isCheckedMacNode` are off, and what only the functions cover.** The
real plist's program: a `--node` host on the Mac refuses at once (`macNodeRefusal`), and a checked start needs the
installed root record, which no test chooses; so the plist's checked command line is tested as data (it parses back to
the build's folder and server, `NodeAgentTests/theProgramArgumentsAreACheckedNodesCommandLine`), and the jobs here run
a scratch host's arguments with a scratch environment (the real plist's `SWIFT_BACKTRACE` alone would leave the host's
`HOME`, and so its files, the user's). The command line's Mac arm (`MacAgentCommand`: the build by its own code in the
installed record, `~/Library/LaunchAgents`, the label `dev.vibeswitcher.node`) runs only past `usersNodeRefusal`, never
here. The server's stop inside `stop` is tested at function level only (refused, taken, none; no scratch job has a
server child: the server needs a checked node's connector check), and so a stop that ends sessions through it; with no server, the bootout ends the host and the host's sessions
lose their terminal (shown for the group and a session-leader child in the measurement above, not with a scratch job's
own sessions: a launchd job's stdin is `/dev/null`, so no app key reaches it and no session can be spawned there). The
`launchctl getenv` refusal of a loader variable (no test sets one in the user's launchd: that would reach every job of
the user's). The plist written at the user's login (`--at-login`, `RunAtLoad`).

**What it doesn't cover** (for the switch-on review):

- *The plist between its check and `bootstrap`* is read again by launchd by path: a file swapped in that gap is started
  by launchd, then refused by the binding after the load (the review's round, I1) and booted out. It ran, as any
  program of the user's can; an ancestor folder swapped and back with a key `print` doesn't show is the residual.
- *A switch rewrote no plist* (until rows 7 and 10, below: built, `v2-mac-anchored-cli`). After an in-place switch the
  job's `ProgramArguments` still named the build it was started as, while another ran; `status` and `stop` passed, and
  the next `start` after a `stop` started the plist's build, or refused the plist once the command line was another
  build's. The switch's follow-up now rewrites the plist for the build it went to, and `status` refuses a host whose
  build isn't the plist's.
- *`launchctl getenv SSH_AUTH_SOCK`* is any process of the user's to set (`launchctl setenv`), as for every Terminal
  opened after it; the Mac seal list (step 8) can't watch it, only its persistent forms (its "what can't be sealed").
- *Sessions keep a hard core limit of 0* (the reset's): soft-only in the reset would give `ulimit -c` back.
- *A session that ignores the hangup* outlives a `stop` without the server: `stop` names it by pid and fails after its
  limit (it doesn't kill what may be the user's own program).
- *The Mac's `start` is not Linux's start sequence*: no not-promised acknowledgment (S11), typed code, journal entry,
  interop refusal or preflight runs before it (the Mac has no journal yet, step 6). For the switch-on review to decide.
- *The plist outlives a refused start* once written (a failed bootstrap, a host that ended at its start, no host in
  30 s): with `--at-login` it is in `~/Library/LaunchAgents` with `RunAtLoad`, and launchd loads it at the next login
  unchecked (its host then runs its own checked start). And a plist written by a plain `start` refuses a later
  `start --at-login` (its `RunAtLoad` differs), with no command yet that rewrites or removes it.
- *The welcome is waited for 5 s* on each look: a checked node that listens but answers late on a loaded Mac makes
  `start` look again until its 30 s, then refuse and unload it.
- *Two `start`s at once* have no lock between them: the second's plist write (`O_EXCL`) or `bootstrap` fails and it
  refuses, touching nothing; a start lock as Linux's is an idea for the reviewer.

### Rows 7 and 10: the command line's anchor, and the host check across a switch (2026-11-26, `v2-mac-anchored-cli`)

The measurement record's rows 7 (item 3's owed half) and 10 (item 12, with item 15's owed "a switch must rewrite the
plist"). Off as the rest: `NodeSystem.macUnbuilt`, `HostImages.isCheckedMacNode`, `approvalMeasured` and
`macServerRefusal` untouched; proven on scratch labels, roots and records.

**Row 7 was already closed** (`v2-mac-anchor`, `b3849695`): nothing on the Mac takes the command line's identity from a
file under the node's root. The places that take it, each a path to "this request is the user's voice" or "this command
line may act for the node", and the check each now has with real signed images and audit tokens
(`NodePinsAnchorTests/everyPlaceTakingTheCommandLinesIdentityRefusesOneSwappedInTheBuild`: a command line renamed over
`<root>/bin/vibeswitcher` after the start refused by each with its reason, the genuine one taken; red with
`b3849695`'s hunk reverted, 14 issues):

1. the server's anchor, read once at its start (`ServerStart` → `ApprovalVoice.commandLineAnchor`: the record's row
   whose server is the server's own running code, `Platform.CodeIdentity.ownCdhash`, the kernel's);
2. a connection's hello, whose voice is the rule's read (`Requests.hello` → `ApprovalVoice.judge("status")`);
3. each request's voice before the one dialog's place (`Requests.approvalJudgment` → `ApprovalVoice.callerRefusal`):
   a swapped command line never reaches the person at the Mac;
4. the command line's own build (`MacAgent.ownBuild`, by its own running code): for `start`, and now for `switch`
   before anything is asked (its follow-up rewrites the plist).

What takes no command line identity on the Mac: `NodeFolders.installedBuild` (`/proc/self/exe`, Linux's: `start`,
`stop`, `switch` and `update` reach it only without code identity), `AppCode` (the app's code, and a checked node host
has none: `appExecutableInForce`), `vibeswitcher agent-plist` (prints a build's plist from its arguments), `stop` and
`status` (they take the record's builds and the host by its code, not the command line's row).

**Row 10: the host check across a switch.** launchd holds the job it loaded across an in-place switch: after a scratch
host's handover from build A to B its `print` is still placed, line for line, as A's job (measured here, the test
below), while the host at the socket runs B's code at the same pid. The rule, written before the code:

- *Which job.* `judge` places launchd's word against the job of the plist on disk first, as before. Only when it isn't
  that, and exactly one build's job of the record is the plist's bytes, it is placed against the record's other builds'
  jobs (the same `RunAtLoad`): the job launchd loaded may be another pinned build's than the plist's.
- *Which host.* `node`: the host's build, by the connection's audit token and running code (`see`), must be the plist's
  build, the one the next `start` starts; its command line that build's job's and its program that job's by device and
  inode. When launchd's job is another build's than the plist's, the host must have switched in place: the keeper's two
  flags follow its command line (`Switched.must`). A host whose build isn't the plist's is refused by `status` and
  `start`, naming both builds and the remedy (`vibeswitcher switch <the host's build>`); `stop` and the command line's
  server check take it when it switched in place (the keeper's flags), whatever builds launchd's job and the plist are
  of: a switch, a second one or a rollback whose follow-up hasn't run (the window between the handover and the rewrite,
  which the switch's own server checks cross; `aSecondSwitchBeforeItsFollowUpIsStillTheNodeToTheServerCheckAndStop`);
  and when it runs launchd's own job exactly while another process replaced the plist with another pinned build's (the
  review's N2: so the remedy `status` names, `vibeswitcher switch <the host's build>`, reaches its server and rewrites
  the plist; `aPlistReplacedUnderTheRunningJobIsPutRightByTheRemedyStatusNames`).
- *The rewrite* (`MacAgent.switched(to:folder:)`, the switch's Mac follow-up in `SwitchCommand.followUp`, after the
  handover, or when the host runs the target already): the record pins the target and its files; launchd's word judged
  as above; the job's process the target's host by token and code with the target's job's command line (the keeper's
  flags after it unless launchd's job is the target's) and program; then the plist replaced: the job `start` writes for
  the target (`Steps.job`, `NodeAgent.Job.node` for the user's node), its `RunAtLoad` kept, written to a new file beside
  it (`O_EXCL`, no link followed, `0644`, synced) in the folder `start` checks, renamed over the old (a reader sees the
  old bytes or the new); then `start`'s own checks of what is there with its descriptor held (`writtenPlist`), launchd's
  word judged again against the file held (still the job it loaded, the same pid), the host looked at again and the held
  file unchanged (`HeldPlist.changed`). It loads and unloads nothing. A refusal before the rename leaves the plist the old
  build's; one after puts the old bytes back the same way, said whether it could; launchd's job runs on untouched
  either way. Where the put-back fails (a link, or anything not a regular file, at the plist's path), no command of
  this program can tell the job is the node's any more (each judges the plist), so the refusal names the one way out:
  remove what is there, `launchctl bootout` by hand (it ends the host and its sessions), then `vibeswitcher start`
  (`aPutBackThatFailsNamesTheOnlyWayOutAndItWorks` follows it to a started node). Run again with nothing to do, it says
  so.
- *The command line's server check* (`ServerCheck`): the listener's expected parent is the host `MacAgent.runningHost`
  finds (`afterASwitch: true`), by token and code, never `launchctl print`'s text: before, the pid came from the lenient
  print and the host's code was checked only by the server, at its own start (F7). When the host isn't found every
  command says why and what to do (`MacAgent.serverCheckHost`: the plist's remedy, `vibeswitcher start` for no job), not
  only that the listener's code "can't be told" (the review's N1, `theServerCheckSaysWhyTheHostIsntKnownAndWhatToDo`).
- *A change in behaviour* (the review's N3): a job of the label loaded and not running from another pinned build than
  the plist's (launchd's A, the plist B) was refused by `start` and left loaded before this branch; `start` now unloads
  it, since it is placed as a pinned build's job at the agent's own plist and nothing of it runs, and goes on as from
  nothing: A's command line is then refused by the plist, B's starts B
  (`aStartOverAJobNotRunningOfAnotherBuildUnloadsItFirst`).
- *Where `launchctl print`'s `program` is still read, and what it decides:* `NodeAgent.placed` (the grammar: the line is
  a literal made from the job, a mismatch refuses); `NodeAgent.printed` (lenient), whose one reader is
  `MacAgent.printed()` in `start`'s wait, where a pid read decides only when to refuse sooner; `NodeCheck.macServerCode`
  takes a `job` that chooses nothing. launchd's word, once placed, picks which rule `node` applies (whether the host may
  or must carry the keeper's flags); it never picks which code passes: that is the token's, against the record.

**What a real Mac proved** (this Mac, macOS 27.2; `MacAgentSwitchTests`, red with the change reverted, `git diff 95d9f0b1
09d73c96 | git apply -R`, green from `09d73c96`): a scratch job of build A started; its host handed over in place to B
through a keeper, asked by this test process as the host's app (its code at the build's `bin/VibeSwitcher`, the key
enrolled on a keyless host); `status` refused while the plist was still A's, naming A, B and the remedy; `switched`
rewrote the plist to exactly B's job while launchd's job stayed A's; `status` and `runningHost` then took the host as B's
at the same pid; a second `switched` had nothing to do; `stop` left nothing; A's `start` was refused with nothing loaded
and the plist as it was; B's `start` started B from the plist's exact arguments
(`aSwitchRewritesThePlistAndStatusAndTheNextStartFollowIt`). A job whose `print` names A's pinned host's path while the
file there is another image (renamed over it before launchd started it again) is refused by `status`, `runningHost` and
`switched`, though its program is the job's by device and inode: only the token tells
(`aJobWhosePrintNamesThePinnedHostWhileAnotherImageRunsIsRefused`, green before as after; red with `see`'s check of the
token's code mutated away). At function level: B without the keeper's flags under A's job refused; A's host under B's
plist refused; `stop` takes a switch not followed up; a rollback's rewrite back to A; a rewrite refused while A still
runs; one whose new file can't be made leaves the old whole; one whose launchd word changes after the rename puts the old
back, no file left over, nothing loaded or unloaded (`statusFollowsThePlistTheSwitchRewrote`,
`aRewriteIsRefusedUnlessTheHostRunsTheTarget`, `aRewriteThatFailsPartwayLeavesTheOldPlistAndJobWhole`).

**What the switch-on review can rely on:** a switch's plist names the build the host runs once its follow-up ran, by
`start`'s own code and checks, and the next `start` starts that build and refuses the old build's command line; the
job's host is known by token and code in `start`, `status`, `stop`, `switched` and the command line's server check, and
no decision takes `launchctl print`'s `program` text; nothing of a switch's follow-up loads or unloads a job.

**What this can't bind:**

- *The loaded job after a rewrite.* Once the plist is the next build's, the job launchd loaded is bound by its `print`
  alone: the seven keys `print` shows nothing of are bound for it by nothing until the next `start` (before, a job found
  loaded bound them by the plist's bytes on disk, themselves the user's to write: the same reach, one file fewer).
- *The scratch host's switched command line.* A scratch host's next image carries `--handover <state>`, which a checked
  node's doesn't (its grammar takes none); the real-launchd test drops that pair from the kernel's arguments and nothing
  else. A checked node's switched command line is still tested as data (no `--node` job runs here).
- *The plist after the rewrite* is a file in a folder of the user's, as before the switch: any process of the user's can
  remove it or rename another over it. What isn't a pinned build's job is refused, and since the command line's server
  check now judges the plist too, every command that reaches the server refuses then, `stop` with them (`launchctl
  bootout` by hand ends the job): a process of the user's can make the node refuse, never pass. A plist naming another
  pinned build's job is refused by `status` while that build's host doesn't run.
- *One failed look at the host during a switch's wait for its server* (`settle`, through the server check) is now a
  refusal (77) of the switch's last steps, after the handover happened; the refusal says so, and that `vibeswitcher
  switch <build>` again finishes the switch once what it names is put right.
- *A follow-up that never runs* (the command line ended after the handover): the plist stays the old build's; `status`
  refuses saying so, and `vibeswitcher switch <build>` finishes it.
- *An older build's `start`* while the node runs a newer one says the node runs already, naming the newer build: it
  loads and writes nothing.
- *The record written by `sudo`* is a scratch record here (the anchor's seam): a trial at the user's keyboard would add
  the record's real owner and parents, an unprivileged write refused, and these checks against it.

**Owed:** a real `--node` job switched (`isCheckedMacNode` off: its switched command line, its server child's restart
and connector check across the switch); the command line's Mac arm of `switch` end to end (behind `usersNodeRefusal`:
no user's node runs); the plist's row in the seal's Mac list (step 8: a rewrite is then a held change until accepted).

**Where it is built.** `NodeAgent` (the plist as data: `Job`, `Place`, `check`, the `launchctl` lines and `print`'s
lines), `MacAgent` (VibeNode: `start`, `stop`, `status` with every step injected, and the host check by token and
code), the command line's Mac arm (`vibeswitcher-cli`, behind `usersNodeRefusal`), `CheckedSessions` (VibeHost: what a
checked node's sessions are given) and the launcher's umask flag. No `#if os(macOS)` in the node's targets: the Mac's
facts come through `Platform.Service`, `Platform.Sockets` and `Platform.CodeIdentity`; Linux's systemd path is
unchanged.

## The seal's Mac list

`LinuxSealList` stays empty on the Mac; a `MacSealList` beside it, by the same rules (a change waits for the user's
accept), starts from: `~/Library/LaunchAgents` (folder), the node's plist, the zsh startup files (`.zshenv`,
`.zprofile`, `.zshrc`, `.zlogin`) and what they source, Homebrew's prefix (`/opt/homebrew/bin` is the user's to write on
Apple Silicon and early on PATH: by listing), `~/.nvm` as on Linux, `~/.gitconfig`, Terminal's startup command
(`~/Library/Preferences/com.apple.Terminal.plist`), `launchctl`'s user environment, and the Xcode selection
(`xcode-select -p`). Each row measured on a real Mac before it is added, as Linux's were. (The plan as written
2026-11-19. What was built and measured, below, is newer and differs: `launchctl`'s user environment is not a row, being
launchd's memory and not a file ("What can't be sealed"), and the Xcode selection is read as `/var/db/xcode_select_link`;
noted at the join of 2026-11-26.)

### Built: `MacSealList` (step 8, 2026-11-26, `v2-mac-seal-list`; the measurement record's row 13)

Off as the rest: `NodeSystem.macUnbuilt`, `HostImages.isCheckedMacNode`, `approvalMeasured` and `macServerRefusal`
untouched; proven on scratch homes, roots and vaults. State at the join of 2026-11-26: built, fix round done (R1–R9
below, then 01a05734), re-check done ("ready with fixes", N1–N7 below); second fix round done on `v2-mac-seal-fix2`
(2026-11-26: N1, N2, N4, N5, N6 fixed; N3, N7 owed).

**What is built.** `MacSealList` (`Sources/VibeCore/V2/MacSealList.swift`) is the Mac's list in `LinuxSealList`'s shape:
the rows as data (`homeEntries`, `startupFiles`, `outsideEntries`), the same `ConfigSeal.Watched` kinds, Linux's
`sourced` reader, the rows outside the home read only for the account's own home (an `outside:` root for tests), every
row executing (a change waits for the user's accept whoever made it). It reaches the seal by the one path Linux's list
does: `ConfigSeal.homeWatched(home:macList:)` appends it, the vault's book hashes it at each look
(`LeadVault.Book.answer`), and its `judge` holds a change until the user's accept (`config held`, `config accept`, the
app's accept), as for every watched thing; no second mechanism. *Off unless asked:* only a book with `watchesMacList`
watches it, and only a checked Mac node host sets that, in the same place and on the same condition as
`recordsActions` (`HostServer.serverChild`'s `isMacNodeHost`: never the app's host, never a scratch host, never another
book in the process). The node's own code (its server's cards and refusals: `HeldChange`, `ConfigHoldStore`,
`Answers`) names the rows on the Mac (`MacSealList.namedByTheNode`), a superset of what its book holds: a row with
nothing recorded is no refusal and no card. The app's seal, and the Mac's `homeWatched` without `macList`, are today's
(`theMacListIsOnlyWhereAsked`, `LinuxSealListTests.theMacsListIsEmpty`). On Linux the list is empty whatever is asked.

One shared-code addition, approved by the lead (2026-11-26): `ConfigSeal.Watched.Kind.preferences`, an app's
preferences read as a property list: every top-level key but the ones measured to change as the app runs, each by its
parsed value in a canonical form (format and key order don't matter, a type does, nested values whole), and each
`ByHost/<domain>.*.plist` beside it (CFPreferences reads the current host's domain first); a link at the path, an
unreadable file, a non-plist, a ByHost file coming or going, or the ByHost folder unreadable each hash as themselves,
never as nothing to compare. Used by Terminal's row alone. Since the review's fix round: ByHost names matched in any
case and Unicode form, a linked ByHost folder read through with its target in the hash, a file past 16 MB or not a
property list hashed by its bytes, and dictionary keys walked as `NSDictionary`'s own and compared by their UTF-8 bytes
at every level (below).

The fix round added one more kind, `.sessions` (zsh's saved Terminal sessions, below), gave a listing per-entry hashes
for its card (one per top-level entry, from the same walk as its hash; the hash's bytes unchanged), let a listing read
its links' targets by name (Homebrew's two only, so no Linux row's bytes move), and made `sourced`'s caller shared
(`LinuxSealList.addSourced`: every level, each file read whole up to 16 MB, both lists).

**A folder's mode.** A `.folder` item doesn't see a folder's mode (`ConfigSeal.readFolder`; the security document's S11
item 8, main's to change). No Mac row is a `.folder`: the folders are `.listing` (each entry's name, type, mode, size,
inode, times with nanoseconds and link target, never contents) or `.entries` (Linux's shell snapshots, whose walk reads
every folder's mode), so a mode changed in place, of the folder or under it, is a change (`everyRowDetectsAChange`).

**What a real Mac measured** (this Mac, macOS 27.2, 2026-11-26; `stat`, `ls -le`, reading files; uid 501). Owner and mode
`owner:group mode`; "ACL" where `ls -le` lists one.

| Row | Kind | Measured: the thing, its parents | What writes it in normal use | Decided |
| --- | --- | --- | --- | --- |
| `~/Library/LaunchAgents` | listing | `501:staff drwx------`, xattrs `com.apple.provenance`, `com.apple.quarantine`, no ACL; `~/Library` `501:staff drwx------` (hidden) ACL `everyone deny delete`; `~` `501:staff drwxr-x---` ACL `everyone deny delete`; 11 plists of 7 vendors and the user's own tools, none a link | an app installing or updating its agent: the folder's last change 2026-11-09, one agent rewritten in place on 2026-11-15 (Steam's, ctime) | a row: each such write is code launchd runs at login, so it holds; `.listing` for the folder's and entries' modes, links and a rewrite kept to size and mtime (ctime); no `.DS_Store` there (one Finder writes would hold) |
| `~/Library/LaunchAgents/dev.vibeswitcher.node.plist` | file | absent (no node here); `start` writes it `0644` (`O_EXCL`, no link followed) in the folder above, which `start` requires the user's and writable by no one else | `start`, and a switch's rewrite (`MacAgent.switched`) | a row of its own, so a card names it; its contents and a link at it; a same-bytes replace, its mode and its folder are the folder's row |
| `~/Library/Preferences/com.apple.Terminal.plist` | preferences | `501:staff -rw-------`, binary; `~/Library/Preferences` `501:staff drwx------` ACL `everyone deny delete`; no `ByHost/com.apple.Terminal.*` file | cfprefsd, at each Terminal start and window move (rewritten 2026-11-24): against its `.bak` two weeks older only `LastTerminalStartTime` and `NSWindow Frame TTWindow Homebrew` differed; "Window Settings", "Default Window Settings", "Startup Window Settings" byte for byte the same; no `CommandString` or `Shell` set | a row by keys: `LastTerminalStartTime` and `NSWindow Frame …` left out (`MacSealList.churnKeys`, `churnPrefix`, compared by bytes), every other key hashed, so a key no one listed holds; its ByHost files in any case (R1) |
| `~/.zsh_sessions` | sessions | `501:staff drwx------`; 5 `<id>.session` files of 52 bytes, each the restore line alone (`echo Restored session: "$(/bin/date -r <time>)"`), 5 `.history` files, `_expiration_check_timestamp` | `/etc/zshrc_Apple_Terminal` (read, never run): at each window's close a `.session` file is written under a temporary name and renamed into place, holding the restore line and whatever the user's save hooks add; at a window's restore its file is sourced when its first line is that line, then removed; `.history` files appended at each close; files older than 2 weeks removed daily | a row of the `*.session` files only (any case): each by its bytes, but one that is the restore line alone (`MacSealList.isRestoreLineOnly`), which runs `echo` and `/bin/date` only; so ordinary closes and restores hold nothing (none of this Mac's 5 files would), and a line added to a saved session, or a session file of another form coming, changing or going, holds; a user with save hooks (`shell_session_save_user_state`) would see a card at each close; `.history` left out (read as history by `fc -R`, never run) |
| What the zsh files source | file | `~/.zshenv`, `.zprofile`, `.zshrc` `501:staff -rw-r--r--` (`.zlogin`, `.zlogout` absent; all of them `homeFiles` rows already); sourced: `~/.cargo/env` (`501:staff -rw-r--r--`, `~/.cargo` `drwxr-xr-x`, from `.zshenv`) and a key file under `~/.config/` (from `.zshrc`) | the user, by hand | a row each, by Linux's `sourced`, and what those source in turn, every level (R6; `addSourced`, at most 256 files read, each whole up to 16 MB); a key file is hashed, never shown (a card compares text only for `~/.claude/skills`: `ConfigSeal.difference(of:in:home:)` says there's no earlier text of anything else) |
| `/opt/homebrew/bin`, `/opt/homebrew/sbin` | listing | `501:admin drwxrwxr-x` (the user's, and the admin group's); `/opt/homebrew` `501:admin drwxr-xr-x`; `/opt` `root:wheel drwxr-xr-x`; `bin` 1,213 entries (1,205 links into the Cellar); on the login shell's PATH ahead of `/usr/bin` | `brew install` and `upgrade`: 24 entries of `bin` changed on 2026-11-18; none of the prefix's 487,688 entries in the 7 days before | a row each, the account's own home only; each link's target's line too (R7: type, mode, size, device, inode and times of what the link leads to, one `stat` each, 1,213 here), so a Cellar file rewritten in place behind a link holds; so does a rebuild of a target outside the Cellar that a `bin` link names (here `passage` → `/Applications/Passage.app`, `ygr-site` → `~/dev/ygr-sites`, conda in the Caskroom, npm's global packages): new code on PATH, a card each time (no target's ctime moved in the 3 days before 2026-11-26) |
| `/opt/homebrew/Library/Homebrew/brew.sh`, `utils/os.sh`, `cmd/shellenv.sh` | file | each `albert:admin -rw-r--r--` (22,020, 6,737 and 4,035 bytes); `bin/brew` (a regular file in the `bin` listing) runs `brew.sh`, which sources `os.sh` first, and for `shellenv` sources `cmd/shellenv.sh` and exits (read 2026-11-26) | `brew update` | a row each, by contents, the account's own home only (R7): what every login shell runs through `.zprofile`'s `eval "$(brew shellenv)"` |
| `/var/db/xcode_select_link` | file | `root:wheel lrwxr-xr-x` → `/Applications/Xcode.app/Contents/Developer` (`root:wheel drwxr-xr-x`); `/private/var/db` `root:wheel drwxr-xr-x`; `/var` a root link | `sudo xcode-select -s` only | a row (cheap, no churn), the account's own home only: only an administrator changes it; `DEVELOPER_DIR`, which overrides it, is the startup files' (their rows) |
| `~/.nvm` (`nvm.sh`, `versions/node`, `alias`) | file, listing | absent here | `nvm install`, `nvm alias` | Linux's rows, by its names: absent hashes as absent, made is a change |
| `~/bin`, `~/.local/bin`, `~/.local/share/claude/versions` | listing | `~/bin` absent; `~/.local/bin` `501:staff drwxr-xr-x`, 7 entries, `claude` a link into the versions (`501:staff drwxr-xr-x`, 5 versions); both on the login shell's PATH ahead of `/usr/bin` | Claude Code's update: the `claude` link rewritten on 2026-11-25 | Linux's rows (listings here, Linux's `~/bin` is a `.folder`): an update holds once, as on Linux, being new code every session runs |
| `~/.config/gh` | listing | `501:staff drwxr-x--x`; `config.yml` and `hosts.yml` `501:staff -rw-------` (the token's file: by metadata, never read); `~/.config` `501:staff drwxr-xr-x` | `gh auth`: `hosts.yml` rewritten on 2026-10-27, `config.yml` not since 2026-01-14 | Linux's row: an alias in `config.yml` runs as `gh <alias>`; a login holds once |
| `~/.claude/shell-snapshots`, `~/.codex/shell-snapshots` | entries | `501:staff drwxr-xr-x`, 18 snapshots, none rewritten after it was made (one's ctime 1 s after its birth); Codex's absent | each session's start writes one | Linux's rows by Linux's names, so an entry coming or going is no change and one changed in place is (`LinuxSealList.cameOrWent`) |
| `~/.gitconfig`, `~/.config/git/config` | (file) | `501:staff -rw-r--r--`; no `include`, `hooksPath` or `sshCommand` line | the user, `git config` | the Mac's `homeFiles` rows already: nothing added |
| `launchctl`'s user environment | none | no file: launchd keeps `launchctl setenv` in memory; `launchctl config user` persists under `/private/var/db/com.apple.xpc.launchd/config` (`root:wheel drwxr-xr-x`, empty) | any process of the user's | not a row (below) |

**Ordinary churn that doesn't fire** (`MacSealVaultTests.ordinaryChurnHoldsNothing`): Terminal's start and window
moves (cfprefsd's rewrite renamed over), a session's shell snapshot coming and going, and a Terminal window's close and
restore (its `.session` file the restore line alone, its `.history` appended:
`aSavedSessionIsHeldOnlyWhenItRunsMoreThanTheRestoreLine`). *What fires by design:* an
app's agent written into `~/Library/LaunchAgents`, `brew install` and `upgrade`, and Claude Code's update (as on Linux);
and each `start` and switch rewrite of the node's plist (below).

**The plist's row and step 5's rule.** `start` believes only the plist it wrote (its bytes, inode, ctime and folder,
checked against launchd's own word); the seal adds that a change to the plist holds the team's workers, verifiers and
merges until the user accepts it. A seal accept never makes `start`, `status`, `stop` or a switch take a plist: they
check it by their own rules whatever the seal says. Since nothing of step 5 tells the seal it wrote the plist
(`appWrite`), each `start` that writes it and each switch that rewrites it is a held change until accepted (the spec's
"a rewrite is then a held change"): left so, fail closed. Telling the seal (an `appWrite` around `MacAgent`'s two
writes, sealing only the bytes `start`'s checks then hold) changes step 5's code: for the switch-on review.

**What the switch-on review can rely on:** on a checked Mac node host, a change to any row (a file's contents, a file
replaced, a link put in its place, a folder's entries, modes, links and ctimes, Terminal's hashed keys) is held at the
vault's next look until the user's accept, and the next change after an accept is held again
(`aChangeToEachRowIsHeldUntilAcceptedThenTheNextAgain`); an accept with a card's hashes seals only what the card showed
(`anAcceptSealsOnlyWhatTheCardShowed`); a row removed or unreadable is held, never left out (no Mac row's fingerprint is
nil: `anUnreadableOrMissingRowFailsClosed`); no other host's book watches the list
(`aBookThatIsntANodeHostsWatchesNoneOfIt`, `MacCheckedStartTests`). Terminal's ByHost files are read whether its own
file is there or not (the blind check's finding: before, an absent domain file hid them). A checked node host's book
holds each Mac row's first read for the user's accept (R9, below), and a listing's card names the top-level entries that
changed ("claude changed, 2.1.333 added", "git added": R8).

**What can't be sealed, and why:**

- *`launchctl`'s user environment.* It is launchd's memory, not a file, so no look reads it; reading it would mean the
  vault running `launchctl` at each look. What of it reaches the node: a checked node's host rebuilds its environment
  from a fixed list, and takes one name from launchd, `SSH_AUTH_SOCK`, once at its start, only as an absolute path to a
  socket the user owns (`CheckedSessions`); a later `setenv` reaches no session until the host's next start, and a
  planted socket then is one a session of the user's could already talk to. Its persistent forms are sealed or root's:
  an agent that runs `launchctl setenv` at login is the LaunchAgents row; `launchctl config user` writes a root-owned
  file.
- *What Homebrew's links point at, beyond one stat.* `bin` and `sbin` are read by metadata, with each link's target's
  `stat` line, and `brew shellenv`'s three files by contents (R7); the Cellar's other files (a library a binary loads, a
  script a linked binary runs), the `opt` links (`/opt/homebrew/opt/libpq/bin` is on this Mac's PATH), and the files
  `brew.sh` sources for commands other than `shellenv` (`utils.sh`, `help.sh`, `utils/auto-update.sh`, `utils/curl.sh`,
  `utils/git.sh`, `utils/analytics.sh`, `utils/ruby.sh` and the `cmd/*.sh` it picks) aren't: the prefix's 487,688
  entries would be a 1.5 s listing at every look. They run when the user runs `brew`, not at a shell's start.
- *A PATH folder of the user's own tools.* This Mac's login shell puts `~/.grok/bin` and `~/.antigravity/…/bin` ahead of
  `/usr/bin`; the list can't know such folders. The startup file that adds one is a row; the folder isn't.
- *cfprefsd's cache.* A `defaults write com.apple.Terminal …` reaches cfprefsd first, and Terminal reads it from there;
  the seal reads the file, which cfprefsd writes after. A change Terminal took before the file was written is seen at the
  first look after it is.
- *Through CFPreferences.* The contract's first choice for Terminal's row was to hash the effective values of its
  startup keys (`Shell` and the three profile keys) as `CFPreferencesCopyAppValue` resolves them (ByHost, the app's
  domain, the global one). It is dialog-free (10 ms, measured read-only on this Mac's Terminal domain), but not sound in
  a long-lived process: measured on a scratch path domain, a process that read it once read the old value again after
  the file was rewritten and `CFPreferencesAppSynchronize` called (1 s later as at once), while a new process
  (`defaults read`) read the new one; so the stale copy is the client's own. The node's server
  (`HeldChange.refusal`) and its vault fingerprint the row in their own processes, so a hash from that cache could
  differ between them as well as miss a change. Not built: the row reads the files alone, and R1 is closed there.
- *The global preferences domain.* Terminal's own domain is sealed by keys, but a key it doesn't hold may be read from
  `NSGlobalDomain` (`~/Library/Preferences/.GlobalPreferences.plist` and its ByHost files: `defaults write -g Shell …`),
  if Terminal looks its startup keys up through the standard defaults (not measured: it would mean writing the user's
  domain). That file is every app's to write (rewritten on 2026-11-26 at 07:57 here), so a row needs its churn measured
  over days before its keys can be told from churn: owed, below. The effective read that would have closed it isn't
  sound in the host (above).
- *A saved session where zsh isn't told to look.* `~/.zsh_sessions` is the row; a `ZDOTDIR` set in `~/.zshenv` moves
  the folder to `$ZDOTDIR/.zsh_sessions`, which isn't read (the `.zshenv` change that sets it is held, as that file's).
- *A row's owner.* No kind reads one: a process of the user's can't give a file to another user (`chown` refused,
  `aRowsOwnerIsntAProcessOfTheUsersToChange`), and a group changed among the user's own changes ctime, which a listing
  reads (a file row reads contents only, which a group doesn't change).
- *A change made and undone between two looks*, as on Linux.

**The independent review and its fix round** (review-v2-s-mac-5, 2026-11-26, "ready with fixes"; its tests are
`MacSealReviewTests` and `MacSealReviewVaultTests`, copied as they ran, each named one red at `f4b22149`; the fixes and
the round's own tests, `MacSealFixRoundTests`, on top):

| Finding | What the review found | What changed |
| --- | --- | --- |
| R1 (important) | a ByHost file named in another case (`com.apple.terminal.<host>.plist`) is the one cfprefsd opens on a case-insensitive volume, and the seal's case-sensitive filter skipped it | ByHost names matched in any case and Unicode form |
| R5 (important) | `~/.zsh_sessions` wasn't read, though Terminal's zsh sources a saved `<id>.session` on restore | the `.sessions` row (the table) |
| R3 (important) | two profiles whose names are canonically equal (NFC and NFD "Café"): bridged to a Swift dictionary, one was dropped from the hash | dictionaries walked as `NSDictionary` with their own keys, ordered and compared by UTF-8 bytes, at every level and in the churn test; the card names each twin |
| R2, R2b (important) | a linked ByHost folder hashed as "not a folder", a file past 16 MB as "unreadable": blind after one accept | the folder read through the link, its target in the hash; a file not taken apart hashed by its bytes |
| R9 (important) | a Mac node's vault took every Mac row on trust at its first read (`VaultFirstLook` is Linux's) | a book that watches the list holds each Mac row it has nothing recorded for, at its first read, for the user's accept (`judge`'s `firstLookKeys`); the vault's whole first look stays Linux's |
| R8 (note) | a listing's card named nothing: Claude Code's update and a planted `~/.local/bin/git` read the same | per-entry hashes, one per top-level entry |
| R4 (note) | `UInt64.max` and `-1` had one canonical form | an unsigned 64-bit value tagged `u` |
| R6 (note, inherited) | one level of sourcing; a startup file past 1 MB named nothing | every level; 16 MB |
| R6b (note, inherited) | `source $ZSH/…` (a variable other than HOME) and a glob loop aren't read | owed (below); its test stands as a known issue |
| R7 (note) | a Cellar file rewritten behind a `bin` link; `brew shellenv`'s files | the three files as rows; each link's target's `stat` line |
| Global domain (note) | likely read by Terminal; the cheap close is the effective read | not sound in the host (measured, above): owed |

**The re-check and its second fix round** (re-check-v2-s-5, 2026-11-26, "ready with fixes": the first findings closed but
R5, reopened by zsh's compiled twins; its tests are `MacSealRecheckTests`, `MacSealRecheckFindingsTests` and
`MacSealRecheckVaultTests`, copied as they ran at 5a6044ab, one red per finding; the fixes and the round's own tests,
`MacSealFix2Tests`, on top, branch `v2-mac-seal-fix2` on `v2-mac-joined`):

| Finding | What the re-check found | What changed |
| --- | --- | --- |
| N1 (important) | zsh runs `<file>.zwc` (made by `zcompile`) in place of a startup file, a sourced file or a saved session when it is as new or the file is absent, and no row read one; a snapshot's twin came into the snapshots row as an entry coming | a `.file` row for each zsh startup file's twin (`~/.zshenv.zwc`, `.zprofile`, `.zshrc`, `.zlogin`, `.zlogout`: `MacSealList.twinnedStartupFiles`) and each sourced file's on the Mac (`addSourced`'s `twins`), absent hashed as absent; `<id>.session.zwc` (any case) read in the sessions row by its bytes, never as the restore line; a `.zwc` entry (any case) coming into or going from any `.entries` row judged as ever (`cameOrWent`), so held |
| N2 (important) | a link's target went into the preferences and sessions hashes with no length before it: a ByHost link whose target's name spelt key lines hashed as a real plist with `Shell=/opt/evil` | every link target in those hashes said as `link <bytes>:<target> ` (`MacSealList.linkSaid`; read by `readlink`, hex when not UTF-8); a listing's link whose target holds a newline said as ` ->x <hex>` (`LinuxSealList.targetSaid`), any other as before |
| N5 (note) | `sourced` took time in the square of a file's lines, rows had no cap: a 5,000-line `.zshrc` took 47 s, a 100,000-line one more than 30 minutes | `sourced` keeps a set of what it found; `addSourced` reads at most 1,024 rows' files (`maxSourcedRows`, twins counted) and 32 MB in all (`maxSourcedBytes`), each file whole up to 16 MB; at any cap it stops and adds one row, `~/(sourced files past the seal's cap)` (`Kind.capped`, hashed by which cap), so the look that crosses it holds a change; 100,000 lines return in well under the hang guard (`aHundredThousandSourceLinesAreBounded`) |
| N4 (note) | the 256-file read cap hid a file sourced past it, silently | the read cap is the row cap (a file read is a row), and hitting it holds (N5's row) |
| N6 (note) | a lone UTF-16 surrogate read as U+FFFD, so profiles `P\u{D800}` and `P\u{DC00}` hashed as one | a string or key with a lone surrogate hashed by its code units (`MacSealList.form`: `u<count>:<hex>`), at every level and at the top; a valid string's form is the one before |
| N3 (note) | at the 4,096-entry cap a listing's card says every sealed entry was removed | owed (below): neither fix passes both of the re-check's tests (`aPaddedListingStillHashesEveryEntry` asserts no keys past the cap) |
| N7 (note) | a new node book's first look takes the home files (`homeFiles`) as they are | owed (below), before `isCheckedMacNode` is lifted |

The zsh behaviour, probed in scratch homes only (`env -i HOME=<scratch> /bin/zsh`, zsh 5.9, 2026-11-26), each twin
compiled from `echo EVIL…` and its source rewritten benign with an older time: `zsh -i` printed the `~/.zshrc.zwc`'s
text; `zsh -l` ran `~/.zlogin.zwc` with no `~/.zlogin`; `zsh -c` ran `~/.cargo/env.zwc` sourced from `.zshenv`;
`. /etc/zshrc_Apple_Terminal` with `TERM_SESSION_ID=A` ran `A.session.zwc` beside a restore-line `A.session`; `source`
of a snapshot ran its twin; and `~/.zshrc.ZWC`, upper case, ran in place of `~/.zshrc`.

What a user sees once, when the list is lifted on a book that recorded the rows before this round: one card for each
new row (the twins, absent: a book that watches the list holds each Mac row first read, R9), and one for each recorded
row whose hash moved: a preferences or sessions row with a link in it (its target now said with its length), a
preferences row holding a lone surrogate, a listing with a link whose target holds a newline. No book records any of
them today (`isCheckedMacNode` is false), so no one sees these cards now.

What each read's work is bounded by (N5's audit): `addSourced` by its caps above; every file whose contents are hashed
(a `.file` row, a session or ByHost file, a folder's or entries row's file: `ConfigSeal.contentsDigest`) is read up to
256 MB (`digestLimit`), and past it hashed by its metadata (size, inode, times with nanoseconds), so a write to it is
still a change: a sparse file's size costs no disk, and `truncate -s 100T ~/.zshrc.zwc` would otherwise have a look
hash 100 TB of zeros (the round's blind check; `aSparseFilesRowIsBoundedAndStillSeesAWrite`); a preferences file is
parsed whole only up to 16 MB (past it, by its bytes, to that limit); a `.entries` row by `ConfigSeal.maxEntries` (cut,
held); a listing walks every entry, uncapped, one `lstat` each (Homebrew's `bin`, the largest, 1,213 here); the
sessions and ByHost folders read every matching file. That caps each file, not a row's total: a sparse file just under
256 MB costs an inode and no disk, and hashing one took 0.22 s here (`openssl dgst -sha256` of a 255 MB sparse file,
2026-11-26), so 20,000 of them in a `.entries` row (`maxEntries`) is about 73 minutes, and the sessions and ByHost
folders have no count cap at all. Owed (below): a total budget per row.

Shared code, for Linux: `LinuxSealList.sourced` keeps a set (same result, linear); `addSourced` caps as above (no twins
on Linux: bash reads none), so a Linux startup file that reaches a cap adds the cap's row where it named nothing before
(held at its first read in a book that holds its first look; elsewhere recorded as it is, the crossing held through the
startup file's own row, whose change made it); a `.zwc` entry coming into or going from any `.entries` row (the snapshots, the hooks, the launch folders, the
manager's `transient`) is held; a listing's link target holding a newline is said in hex; a file past 256 MB is hashed by
its metadata wherever the seal hashes contents (the app's seal on v2 too: one card for such a file, none exists here). A Linux listing's hash bytes
are otherwise unchanged (`MacSealRecheckTests.aListingsHashBytesAreUnchanged`, run here). What Linux must run:
`LinuxSealListTests`, `MacSealListTests.theListIsEmptyOnLinux`, the ConfigSeal suites,
`MacSealRecheckTests.aListingsHashBytesAreUnchanged`, and `MacSealFix2Tests`' tests without the Mac trait
(`aTwinComingIntoAnEntriesFolderIsHeld`, `aListingLinksNewlineCantSpellALine`, `aHundredThousandSourceLinesAreBounded`,
`eachSourcingCapAddsAHeldRow`, `aSparseFilesRowIsBoundedAndStillSeesAWrite`).

**Owed:**

- N7 (the re-check's, R9's remainder): a new node book's first look takes the home files (`ConfigSeal.homeFiles`: zsh's,
  bash's, `.gitconfig`…) as they are; only the Mac list's rows are held at their first read. Before `isCheckedMacNode`
  is lifted, a checked Mac node book holds its whole first look (`holdsFirstLook`, as Linux's node does) or is seeded
  from the app book's record with what that holds still held. `MacSealRecheckVaultTests.aNewNodeBooksFirstLookHoldsAPlantedZshrc`
  stands as a known issue.
- N3: at the 4,096-entry cap a listing's card names every sealed entry "removed" (the hash is whole, so the change is
  held; the card's words are wrong). The re-check's proposed fix, one "more than 4,096 entries" key, still says "git
  removed", so its own test stays red; keeping the first 4,096 keys contradicts its `aPaddedListingStillHashesEveryEntry`
  (no keys past the cap): either way a re-check test changes, the lead's call.
  `aListingsCardAtTheCapDoesntSayItsEntriesWereRemoved` stands as a known issue.
- A stalled look, in two parts that must both close before `isCheckedMacNode` is lifted (the second fix round's blind
  check and its follow-up, 2026-11-26):
  1. *A total budget per row*, so no look can be stalled: every row has one, in bytes hashed and in entries read, and a
     row past it is held as changed, never hashed without bound. Today each file is capped (256 MB, past it by its
     metadata), not a row's total: a 255 MB sparse file costs an inode and no disk and hashed in 0.22 s here, so 20,000
     of them in one row is about 73 minutes. The rows: the sessions row and the preferences row's ByHost files
     (`MacSealList.sessionFiles`, `preferenceFiles`: no count cap), the `.entries` rows (`LinuxSealList.readEntries`:
     up to 20,000 entries), and `ConfigSeal.readFolder`'s folders (the app's `~/.claude/skills`, agents, commands,
     hooks and `~/.vibeswitcher/bin`, the same walk: they need it too).
  2. *A look that fails or times out counts as something held*, for every gate that reads the record. Today the look
     hashes before it decides, so a stalled look seals and holds nothing; but the vault's calls carry a timeout, and
     `ConfigHoldStore.held` swallows the look's failure (`_ = try? vault.checkConfig`) and then reads the last completed
     record, as `LeadVault.heldConfig` reads it: while every look stalls, a later change (to `~/.zshrc`, say) is never
     recorded as held there. Traced: `HeldChange.refusal` (the switch's and the builds folder's) re-hashes in the server
     and blocks rather than passes; `ConfigHoldStore.held` (`config held`, the server's `lookAtConfig`) shows the stale
     record; `heldConfig` returns it. Not traced: whether `start_worker`'s and a merge's refusals need a look that
     finished, or pass on that record.
  The Mac rows are dormant while the list is off; `readFolder`'s folders and the `.entries` rows are read today (the
  app's seal, Linux's node), and the node's code above is the node's on Linux too, so there both parts are
  pre-existing.
- What lies past a sourcing cap (`addSourced`): after the cap's row is accepted, the files past it are unwatched until
  the startup files are under the caps again; and a compiled twin is hashed, never read for what it sources (as R6b).
- `$ZDOTDIR`'s startup files and their twins when `ZDOTDIR` is set (zsh reads them there, not in the home).
- The node's own folders under its root (`~/.vibeswitcher/v2/node`): the launch presets, the allowed projects, the
  roles' launch folders and the lead's accepted hooks, which Linux's list seals at `~/.vibeswitcher/…`; and the builds
  folder (`~/.vibeswitcher/v2/builds`). Linux's quiet rules for them (`cameOrWent`'s hooks and launch rules,
  `SessionPresets.sealName`, `SwitchSeal.buildsName` and the switch's refusals) key on Linux's names, so on the Mac
  they need the node root's names first; the builds folder's row turns on the switch's refusals, a change of step 5's
  switch. For the step that lifts `isCheckedMacNode`.
- `appWrite` around `start`'s and a switch's plist writes (above), for the switch-on review.
- The global preferences domain (above): whether Terminal takes `Shell` or a profile from it (a scratch account's
  measurement), and if it does, a `.preferences` row on `.GlobalPreferences.plist` with its churn measured over days.
  The effective read through CFPreferences was measured stale in a long-lived process on a path domain; what a
  keyboard session with the user would measure: a named scratch domain written through cfprefsd (`defaults write`),
  then read again by a process that read it before, to learn whether named domains refresh where path domains don't. A
  candidate close that keeps the hash a function of the disk alone: the same four keys (`Shell`, "Default Window
  Settings", "Startup Window Settings", "Window Settings") read from `.GlobalPreferences.plist` and its ByHost files by
  the `.preferences` code, the rest of that file's churn left out. Not built.
- R6b: a `source` or `.` whose path starts with a variable other than HOME (`$ZSH/oh-my-zsh.sh`) and a loop over a glob
  (`for f in ~/.zsh.d/*.zsh; do source "$f"; done`) name no row (a startup file past 16 MB, which named none, now adds the cap's row:
  N5). `MacSealReviewTests.sourceFormsThePatternMissesAreWatched` stands as a known issue (`withKnownIssue`), so it
  says when it starts passing.
- `$ZDOTDIR/.zsh_sessions` when `ZDOTDIR` is set (above), and bash's `~/.bash_sessions`, which
  `/etc/bashrc_Apple_Terminal` restores the same way (absent here: the user's shell is zsh).
- A real checked node host's book watching the list (`isCheckedMacNode` is false: `MacCheckedStartTests` proves the
  flag on a checked start's host built by hand).
- On Linux, `MacSealListTests.theListIsEmptyOnLinux` and `LinuxSealListTests` once there: this Mac reads none of
  Linux's paths (`LinuxSealListTests` skip their Linux-only cases here). The fix round's shared changes reach Linux's
  list: `addSourced` follows every level (a node book that holds its first look shows the new rows once), and a
  listing's card names its entries; a Linux listing's hash is unchanged (its link targets aren't read).

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
10. **Every spawn names what it keeps** (the keeper design's K4a-i, [2026-11-27-v2-mac-keeper-design.md](2026-11-27-v2-mac-keeper-design.md),
    "The host's side"; homed here by the re-check of 2026-11-27, its question 3): every `Platform.Spawn` in the host
    image and in the server names `keep` (`POSIX_SPAWN_CLOEXEC_DEFAULT`), its in-place forms too, with a lint over
    their targets. Behaviour-preserving; safe to build now; its own review. Needs: the hosted Mac for the tests.
11. **The host image's children prove themselves** (the keeper design's K4a-ii), **in the Mach form** (the keeper
    design's proof after K-M1: a pair's token can't prove a child, K-M1 (b), (c), (g4)): the parser and the server
    child spawned with a port of the host's as their bootstrap special port and no socket, each proving its code by
    one Mach message whose audit trailer must name the spawned pid running the expected code, hardened exactly when the
    image is (a message sent before an exec is refused, K-M1 (n2)), and only then given its link or connector as a
    fileport to a port it made, with its real bootstrap port back; the proof waited off the host's queue, at most 10 s,
    its spawn off that queue as well, the child at the limit reaped by an exit source, no thread held per proof, and a
    proof that only timed out told so, never that something replaced the helper (the narrow re-check's N4 (b)); the
    launcher written afresh at each host start; a pinned image gives ends only to its own code, its row's server, or
    across the checked node's own switch a target the record pins, with its test flags and by-path handover refused
    (the re-check's N1). Beside it, **the handover keeper's proofs in the Mach form** (the keeper design's K4c:
    `MacHandoverKeeper` is open today to K-M1 (b) with the pid matching) and the server's check of its host above.
    Every session's start on the Mac changes, the app's host included, with or without the keeper. After step 10; its
    cost measured first (K-M14, extended: the spawn's own time, a quarantined or stalled launcher, a burst of
    never-proving history reads, the host's own image started with a bootstrap port that isn't launchd's, a fileport's
    round trip); a hardened image that isn't pinned starts no server child and takes no test keeper or secret (its
    KP20f, the lead's choice (A)), and **keeps its by-path handover** (KP20f, settled: the keeper takes no socket end,
    so no end it hands out carries a request), so **the Mac app's own host (hardened, never pinned) keeps its handover
    at every app update** (`HostChildProofTests.theAppsHostStillHandsOverByPathAtAnAppUpdate`), with no exemption keyed
    on `ownsLaunchers`; `MacKeeperHandoverTests`' hardened arm moves to function level and to the keeper's K7; its own
    review; the app and its update checked in the sandbox. The keeper's K4 waits on steps 10 and 11. Then, once step 11
    is on v2, the pins record's `format 2` (the keeper design's K4b, which lands only after this step's Mach form is on
    v2), whose own install script refuses, unconditionally, any commit that doesn't contain step 11's commit (the
    floor, which the keeper's K5 raises to K4b's commit). **The keeper design's proof review of 2026-11-27 adds** (its
    rows K4a-ii and K4c, and KA1 to KA12): each child and handover process runs the image's first statement (every
    exception mask cleared, task and main thread, then the environment rule) before its proof, every host (the app's
    included) spawning its parser and handover keeper with exactly the fixed list; a hardened image's parser refuses
    `--parser-test-hooks`; each proof names its role and each receiver takes only its own; the server judges its host
    by the handout's own message (the Mach form of the server's check above); and this step is offered only after the
    keeper design's K-M16 trial part as well. Needs: this Mac's real signed hardened images.
12. **The node's removal** (the keeper design's answer to its re-check's question 2): an `install-node-mac.sh` remove
    form that stops the node's agent first, then runs the keeper step's `--remove`, or `--remove --forget-store` when
    you ask it to forget the node's record, said before the password (`KeeperStepTests.theNodesRemovalRemovesTheKeeper`
    is this step's). After the keeper's K5. The switch-on review checks that nothing removes the node without the
    keeper's removal. Needs: a real Mac, your `sudo` line for its real use.

Progress (2026-11-20, on Linux, checked on the hosted Mac only when pushed; each commit and what a real Mac must run are
in [the Mac's tasks](../../process/v2-mac-tasks.md)): step 2 is built (`Platform.Service.nodeRoot`; `--node` still
refused on the Mac). Step 3's code is built: the server child from a cdhash-checked file, its connector a stream pair
with the Hardened Runtime as non-dumpable; Hardened Runtime and `task_for_pid` wait for a real Mac. The user decided the
voice (2026-11-20: Touch ID or the login password for each state change, with the caller check); its code is built
behind a seam (`Platform.Approval`, `ApprovalVoice`) and not wired: step 4 measures it first. Since 2026-11-21 it is wired
(`VoiceRule.Mode.approval`, `Requests.approvalJudgment`, the command line asking no code under it) and still off: the
user's server takes it only once `NodeSystem.approvalMeasured` is turned on, after step 4 and a review. Step 5's agent is built as data (`NodeAgent`: the
property list, its check, the `launchctl` lines and `print`'s pid), not wired: `start` on the Mac is still refused.
Step 4 on this Mac (2026-11-25 and 26): the agent's measurements M1 to M14, then the user's keyboard session (part A of
the runbook, from a shell card: LA-1, 2, 3, 6, 7, ESC-1, 2, 3, AG-1; ANC-1, ANC-2, LA-4, LA-5 and the `sudo` trial not
run); row 3 settled from them ("The rule's lines, settled from the measurements"), its two lines not built; the page's
12-hour unlock and the Mac's browser passkey recorded in "The user's voice on the Mac".

**Progress since (corrected 2026-11-26, the join of `v2-mac-seal-list` and `v2-mac-runbook`).** "Step 5's agent is
built as data, not wired" above is the state of 2026-11-21: step 5 is now wired ("The LaunchAgent: start, stop and
status": `NodeAgent`, `MacAgent`; independently reviewed three times, last verdict "ready to offer for v2", 2026-11-26)
and still off, `start` refused by `NodeSystem.macUnbuilt` for the user's node. Built and off besides: the checked node
start (item 13, re-checked "ready to offer for v2", 2026-11-26), the web port held by the host (item 9), the anchor
(item 10, root-owned pins, the user's choice of 2026-11-25), rows 7 and 10 (reviewed, "still ready to offer"); step 7's
install script, unproven by a real install; step 8's seal list ("Built: `MacSealList`": built, fix round done,
re-check running). Not built: step 6 (the unified log) and step 9 (coexistence). The measurement record's table
("What stands between this Mac and `vibeswitcher start`") keeps each row's state.

## Open for the user: the Mac's reads

Under the Mac's rule a read asks no dialog: the caller check (uid, the installed command line's code, the Hardened
Runtime, the guard rails) is its only gate. Most reads are what any process of the user's already reads on disk. Five
are the user's alone on Linux, where the cgroup tells a detached session apart: `mail` (the projects' private record of
their leads' messages), `recent`, `shells`, `config.held` and `base.show`. On the Mac a session that detached itself
(`open -a Terminal`, AppleScript) passes the caller check with no dialog. **Open (the review of 2026-11-21):** take a
dialog for those five too, keep them as reads (they show what the files show), or refuse them on the Mac until the
app's window carries the voice. **Measured since (2026-11-26, K-ESC-1 to 3):** `open -a Terminal`, AppleScript and a job
a session loads itself each pass every caller line, the coalition and environment lines settled above included, so
the premise holds: a detached session reads these five with no dialog unless the user chooses a dialog or a refusal.

## Decisions

- **(call)** On the Mac, in this step, the user's node is refused by every command before anything is read or run
  (exit 69); a scratch node isn't.
- **(call)** `vibeswitcher-host --node` is refused on the Mac (it used to be ignored, making the app's host).
- **(call)** The user's server on a system with no cgroups is on the closed rule until the Mac's rule is built.
- **(call)** The node's root on the Mac is `~/.vibeswitcher/v2/node`, never the app's `~/.vibeswitcher`.
- **(confirmed by the user, 2026-11-20)** The user's voice on the Mac: LocalAuthentication (Touch ID or the login
  password) asked by the server per state change, with the peer's code identity and the guard rails; the app's window
  later, through main.
- **(the user, 2026-11-25; the device-keys review, 2026-11-26)** For the page: one Touch ID allows the acting mode,
  opens and confirms the page, then up to 12 hours with no prompt; the unlock is the device's, and on the Mac desktop a
  browser passkey (one Touch ID); the server's own dialog stays for the command line's state changes, the first
  enrolment and guarded changes (each its own Touch ID, never by the unlock alone).
- **(settled 2026-11-26 on the measurements, for the review; not built)** The rule's lines: the coalition line added;
  the peer's environment line added as an early refusal, not a boundary (the lead's call, reversible); no
  responsible-process line; the guard rails kept; what stays open named with its keyboard step.
- **(call)** The service is a LaunchAgent in `gui/<uid>`, not started by the app.
- **(call)** Events in the unified log, stderr in a file.
- **(for the user)** Signing the node's builds with `setup-signing.sh`'s identity, so the vault's Keychain key doesn't
  ask at each switch; and how the node and the app share `~/.claude` hooks.
