# VibeSwitcher 2: the security architecture

Status: draft, written for stage 2's Task 1 ([plan](../plans/2026-11-13-v2-stage-2-session-host.md#task-1-the-security-architecture-document)).
Attacked by four reviewers on 2026-11-13 and revised; their findings and the answers are in
[Answers to the attack review](#answers-to-the-attack-review). **Stage 2's Task 2 doesn't start until the review record
of Task 1, Step 3 is written, the plan takes [the changes it needs](#changes-the-stage-2-plan-needs), and the user's
answers to [the decisions](#awaiting-the-user) are recorded in the design's Decided section (Step 4).**

This is the document the host's port is built against. It takes the design's five security requirements
([design, Security](2026-11-12-vibeswitcher-2-design.md#security)) and the stage 2 plan's decisions (S2-D1 to S2-D13)
and says, for this machine and for the code as it is: who may do what through the host's socket and the server's
socket, how the host knows who is asking, what a worker that tries can still do before the sandbox and signed
approvals, and which tests prove each promise. Where it changes the plan it says so
([Changes the stage 2 plan needs](#changes-the-stage-2-plan-needs)).

Sources: the design; the stage 2 plan; [the bootstrap path](../plans/2026-11-13-v2-bootstrap-path.md); the design
review's security findings ([record](../../process/reviews/v2-design-review-2026-11-12.md#security));
[architecture](../../guide/architecture.md#who-may-do-what) and [the security audit](../../security/SECURITY-AUDIT.md);
the code. Code references are at `6a590784` unless a line says otherwise.

Lines marked **(call)** are the author's choices; each can be overruled. Lines marked **The user confirms** are put to
the user once, with the bootstrap path's questions ([Decisions](#decisions)).

## Reading this document

Each numbered section, `## S1.` to `## S12.`, is one decision and has these parts:

- **Decision**, **Why**, and what it **Doesn't promise**.
- **Before the bootstrap:** `yes` or `no` first, then any part that differs, in brackets.
- **Built in:** the stage and task.
- **Held by:** tests that exist now, as `Suite.test` (the suite is the type that declares the test, an extension's
  included), and `planned: <plan> task <n>` (or the plan's list it is in) for what isn't written yet.
- **Tests to write:** the names a task writes. They move into `Held by:` in that task's commit.

`SecurityDocumentLintTests` (Task 1, Step 1) reads the numbered sections only: every name in a `Held by:` line exists
under `Tests/`, every section has a `Doesn't promise` part and a `Before the bootstrap:` line. A name is a backticked
token of the form `Identifier.identifier` with no `/` in it; paths stay out of backticks in `Held by:` lines. The
unnumbered sections (the principals, the threats, the Mac and Linux, the tests, the decisions, the changes, the
answers) are reference and aren't linted.

Two words are used with care. A **guard rail** holds against a worker that slips (a wrong command, a mistaken
script). A **lock** holds against a worker that tries (one turned by what it read, now working against the node). Most
of what holds before the sandbox is a guard rail, and this document says which.

## Before the sandbox, in one paragraph

On this machine, before the sandbox, a worker that tries can do what the user can do: it can read and write the
user's files, signal and trace the user's dumpable processes, talk to the user's systemd and, while WSL interop is on,
run Windows programs and become root with one command. **While interop is on, nothing below is a lock**: root reads
every process's memory. With interop off (the user's decision 2), and while nothing else puts root one step away (no
docker socket, no `sudo` used in this distribution while a team runs), a worker that tries can still: become the host
at the next host start, which it can cause; act as any session, the lead and the verifiers included, by ptrace; turn
the lead or a verifier with text it writes; send the user's answers by driving the user's own shell or Claude Code;
and change what the user is shown, because the command line, the hook, the tool server and `claude` are files of the
user's. What then holds against it: another user stays out; the host, the server and the parsers are non-dumpable
from their exec on and nothing they run loads a file the user can write after they loaded it, except the host's own
start by systemd; only the server child's connections are the app; a connection a worker writes on stops being
anyone's; a handover's state and secrets never touch the disk; an escape from a session (double fork, `setsid`,
`systemd-run`, `at`, cron) is never the user's voice. Everything else is a guard rail. That is why, until stage 6's
attack has passed, the only project the user's node runs is VibeSwitcher's own, which the user trusts, and the project
allow-list (S11) enforces it.

## S1. Threat model and modes

**Decision.** Who is defended against, most frequent first (the design's list, with one addition):

1. A worker that slips.
2. A worker turned by what it read (a repository, a web page, a dependency, a tool's output) and now trying, with the
   user's uid, from inside its session or from a process that escaped it.
3. **(new)** A lead or a verifier turned by what a worker wrote (its branch, its done report, its test output), with
   no OS access at all. Confinement doesn't touch this one. What holds against it: the review floor, which only the
   user sets (`setReviewFloor` is app-only); the user's approvals for sensitive paths; `audit_finders` of 2 or more
   with the verifiers on a model other than the worker's. `setReview` and `dismissFinding` are the lead's word, so a
   turned lead lowers everything above the floor.
4. Another process or user on the machine; later, on the tailnet.
5. Later (milestones 3 and 4): a node of the fleet that was taken over.

Not defended against: root; the user's own unconfined programs acting on their own; whatever is one step from root on
a given machine. **One step from root voids every lock in this document**, so the bootstrap closes the steps it can
(decision 2) and names the rest.

There are two **modes**. **Plain mode** is what runs before the bootstrap and on any machine that can't confine:
sessions run as the user with no sandbox, and the rules in S2 to S10 are what hold. **Strong mode** (after the
bootstrap, S12) adds the sandbox per team session, the egress proxy and the vault's key file. `status` says which
mode a node is in on a standing line (`doctor` after the bootstrap). Before the bootstrap there is only plain mode.

**This machine** (read 2026-11-12 and 2026-11-13, nothing changed):

| Fact | Value | What follows |
| --- | --- | --- |
| Kernel | 5.15.167.4-microsoft-standard-WSL2 | No `SO_PEERPIDFD` or `SCM_PIDFD` (6.5+): a peer is a pid number, not a handle (S5). `memfd_create` with sealing exists (S6, S8, S9) |
| Yama | absent (`/proc/sys/kernel/yama` doesn't exist; not built into this kernel) | Any process of the user may ptrace, `process_vm_readv` and `pidfd_getfd` any dumpable process of the user (S6) |
| Pid space | `pid_max` 4,194,304; `ns_last_pid` 3,983,868 | The pid space wraps in ordinary use here; a pid number names a process only while it lives (S5) |
| WSL interop | `binfmt_misc/WSLInterop` enabled; `/etc/wsl.conf` has no `[interop]` section; `/run/WSL/*_interop` are mode 0777, and `/run/WSL/1_interop` is the fallback when `WSL_INTEROP` is unset | Any process of **any** Linux user can run Windows programs as the Windows user, and `wsl.exe -u root` gives root without a password. Leaving `WSL_INTEROP` out of an environment stops nothing. Decision 2 turns it off |
| `/mnt/c` | 9p, read-write, owned by uid 1000, mode 0777 | The Windows user's files are the worker's, including `C:\Users\<user>\.wslconfig` (0777 here; its `kernel=` picks the kernel WSL boots next) and the Startup folder (0777 here; runs programs at the next Windows login). Decision 2 recommends automount off |
| `.wslconfig` | `networkingMode=mirrored` | Linux and Windows share loopback: every session reaches every Windows-side localhost service, and a later loopback listener of the node is reachable from Windows (S11) |
| WSLg | `/tmp/.X11-unix/X0` (0777), `/run/user/1000/wayland-0`, `/mnt/wslg` (PulseAudio) | A session can open windows on the Windows desktop (a channel for deceiving the user) and use the audio source, by fixed paths (S10, S11) |
| Agents by path | `/run/user/1000/gnupg/S.gpg-agent.ssh` and `S.gpg-agent` (the manager's `SSH_AUTH_SOCK` points at the first), `/run/user/1000/bus` | The user's ssh keys and gpg signing are reachable by fixed paths, whatever the environment says (S10) |
| Groups | `sudo` (password required: `sudo -n` refuses), `docker` (no daemon socket now) | `sudo` is a step from root whenever the user uses it here: a worker can ptrace the user's shell and ride its ticket, or read the password from the terminal; `docker` becomes one the day Docker's socket appears |
| `core_pattern` | `\|/wsl-capture-crash %t %E %p %s`; `fs.suid_dumpable` 0 | A piped core pattern isn't limited by `RLIMIT_CORE` (core(5)); only non-dumpable keeps a crashing host's memory out of a crash dump |
| `/proc` | mounted without `hidepid` | Every user sees every process and its command line |
| systemd | pid 1 is systemd; the user's `systemd --user` runs (pid 284), lingering on; `/run/user/1000/systemd/private` is the user's, 0700 | The user's manager is reachable by every process of the user, whatever its environment (S9) |
| cgroups | hybrid: v1 controllers plus `name=systemd` and `unified`. The user's terminals and Claude Code are in `/init.scope` (its `cgroup.procs` root's, 0644); the manager's services are under `user.slice/user-1000.slice/user@1000.service` (the user's) | A process of the user can't move itself into `/init.scope`: an escape from the node's unit (double fork, `setsid`, `systemd-run --user`) stays under `user@1000.service`, and `at` and cron land in system services (S3). `OOMPolicy=` has no effect here |
| Journal | persistent (`/var/log/journal`, root's) | Its trusted fields (`_PID`, `_CMDLINE`, `_SYSTEMD_USER_UNIT`) are stamped by journald: a process of the user can add entries but neither forge those fields nor delete entries (S2, S3) |
| Socket buffer | `net.core.wmem_max` 212992 | No longer a limit on the handover's secret, which goes through sealed memory (S8) |
| User namespaces | `user.max_user_namespaces` 384738; no AppArmor restriction knob in this kernel | The sandbox can be built without root here (S12). It also means any process of the user can hold `CAP_SYS_ADMIN` inside a user namespace it made (S5) |
| Swift | toolchain under `~/.local/share/swiftly` (the user's); a debug build's `RUNPATH` is that toolchain's `usr/lib/swift/linux` and loads `libswiftCore.so`, `libFoundation.so`, `libdispatch.so` from it; `swift_static` libraries are present | A dynamically linked binary loads code a worker can replace at every start (S9). The static build is possible now |
| git credentials | `credential.https://github.com.helper` is `gh auth git-credential`; `~/.config/gh/hosts.yml` exists (0600, the user's) | Any session can push to the user's GitHub repositories with the user's token, VibeSwitcher's `main` included (decision 11) |
| Tools | no `bwrap`, no `zsh`; `script`, `nc` installed; Codex installed (`~/.bun/bin/codex`) | The sandbox goes through the shim (S12); `script` gives any process a pty of its own (S3); Codex's own sandbox is unmeasured here (S10) |
| Claude Code's Bash tool | no controlling terminal (`tty` says "not a tty", measured) | A state-changing request can ask for a terminal, which an agent's tool doesn't have without effort (S3) |
| Accounts | one human account | "Another user" is a future case here, kept honest anyway |

**One step from root, here.** WSL interop, for any Linux process of any user (0777 sockets); any Windows process of
the Windows user, and anything a worker places where Windows runs it (`.wslconfig`'s kernel, the Startup folder,
both through `/mnt/c`); the user's `sudo`, whenever the user uses it in this distribution; the `docker` group if a
daemon socket appears. Before the sandbox the user closes the first two (decision 2) and keeps the third out of reach
by not using `sudo` here while a team runs (or `Defaults timestamp_timeout=0`). With interop on, this document's
locks are guard rails, and `start` and `status` say so.

**Why.** The design's order, plus the one attack that needs no OS access; the plain mode is what this machine can run
before the shim's sandbox exists, and the measured facts decide most of the rest of this document.

**Doesn't promise.** Anything against root or what is one step from it; anything in S11; anything against a lead or
verifier turned by text, beyond the floor and the user's approvals.

**Before the bootstrap:** yes.

**Built in:** this document; the interop and automount checks in the engine plan's E1 (`start`, `status`); stage 6's
attack checks it.

**The user confirms:** decision 2 (interop off, automount off, no `sudo` here while a team runs).

**Held by:** planned: stage 2 plan task 1.

**Tests to write:** `SecurityDocumentLintTests.everyNamedTestExists`, `everySectionSaysWhatItDoesNotPromise`,
`everySectionSaysWhenItIsNeeded` (Task 1). E1: `StartCommandTests.startRefusesWhileInteropIsOnUnlessTold`,
`statusSaysPlainModeAndInterop`.

## Principals: who may do what, and how the host knows

### How the host tells who is asking, on Linux

At **accept** (`HostServer.acceptAll`, `HostServer.swift:257-291`):

1. `SO_PEERCRED`'s uid must be the host's, or the connection is closed (`peerUID`, line 261). The socket file is 0600
   (`UnixSocket.listen`) in a 0700 folder (`VibePaths.ensurePrivateDirectories`).
2. `SO_PEERCRED`'s pid, with its start ticks read from `/proc/<pid>/stat` at that moment, is the connection's token
   (`Platform.Sockets.peerToken`, `Platform.PeerToken`: pid, uid, start ticks).
3. Otherwise `identify` (`HostServer.swift:663-668`): a process inside a live session, by its ancestry (the parent
   chain read from `/proc`, nearest session program first) or by its controlling terminal (`ttypts<N>`, Task 6), is
   that session, unless a `BranchCode` wrapper sits between it and the session (branch code is no session's,
   `HostServer.swift:672-689`); anything else is `.unknown`. **No connection through the path is ever the app on
   Linux**: the app's connections are made by the host itself, through the server child's connector (S2).

On **every read** (S5, Task 7): the bytes come with their sender (`SCM_CREDENTIALS`, `Platform.Sockets.receive`), whose
token must be the accepted one (`PeerToken.sameImage`: same pid, same start ticks); on an app connection, the server
child's. A different sender, a missing sender, or a frame made of two senders' bytes makes the connection `.unknown`
for good. Today's `checkPeer` (`HostServer.swift:642-654`) re-reads `SO_PEERCRED`, which on Linux names the connector
for the connection's whole life, so on Linux it only notices a connector that has gone; its comment ("the kernel names
whichever process last used the client's socket") is the Mac's. Task 7 gives it the per-message form. No user's host
runs on Linux before Task 7.

What that rests on: the kernel's pid number at connect and at each send, and `/proc` read by the host afterwards. A
process's identity is told once; it can leave its session's tree (by escaping, S3), and before Task 6's fixes it
could take a new session's terminal first (S4). A process that execs another program keeps its token on Linux (on
the Mac the audit token changes; S5).

### The principals

| Principal | How the host knows it | Host's socket | Server's socket |
| --- | --- | --- | --- |
| **The app**: the host's server child | the connections the host made for it through its inherited connector (S2) | everything `.app` may (below) | it *is* the server |
| **The user at the command line** | on the server's socket: same uid, and the "user's voice" rule (S3) | doesn't connect (rule 2); if a process of the user does, it is `.unknown` | the requests S3 lists |
| **A session with a role** (lead, worker, verifier) | ancestry or terminal, at accept (S4); the role is the vault's, bound by the lead's grant | its own session and those it started; a lead its team; the vault by role | `status`, `questions`; nothing else |
| **A session without a role** | as above | its own session and those it started; the vault as a session that holds nothing | `status`, `questions`; nothing else |
| **An unknown local process** (same uid, in no session) | none of the above | metadata and the vault's open reads only | `status`, `questions`; the user's-voice requests if it passes S3's rule |
| **Another user** | `SO_PEERCRED` uid | closed at accept | closed at accept |
| **Root** | not told apart | everything | everything |

#### The app (the server child)

- **Host's socket.** All of `.app`'s rights (`HostServer.authorized`, lines 370-388, and the vault's `caller == .app`
  checks): `hello` with every session; `spawn` (in the user's host, only inside the allow-list, S11); `attach`,
  `input`, `inputUnit`, `resize`, `screen`, `styledScreen`, `history`, `kill`, `remove` on any session; `census`;
  `shutdown` (only with no live session); `handover` (in the user's host only to an installed build whose hash
  matches, S9); in the vault, the app-only requests: `issue` a lead, `rotateLead`, `setReviewFloor`, `approve`,
  `settlePush`, `roster` of every team, sealing a message as the user's, sealing its own writes
  (`ConfigSeal.wroteKey`, `vault.appWrite`), and the requests the lead may also make (`setHead`, `setGuarded`,
  `acceptMove`, `pushRequest`). Not on Linux: `proveApp`, `enrollApp`, `replaceAppKey` (there is no app key; the
  principal has no `runsAppCode`, `HostServer.swift:301, 318, 327`).
- **Server's socket.** It is the server.
- **A worker that tries, before the sandbox:** can't connect as the app (it holds no connector); can't send on the
  app's connections (S5); can't take the connector or the server's memory (non-dumpable from its exec, S6, if Task 3's
  measurement holds); **can** kill or stop it (a denial of service, recorded in the journal); **can** make the next
  host start, which systemd makes from the installed files, run its own code (S9). Not promised; S11.

#### The user at the command line

- **Host's socket.** None: the command line talks to the server only (rule 2, S2-D13).
- **Server's socket.** The requests S3 lists, each with the voice it needs.
- **A worker that tries:** can no longer pass S3's rule by escaping its session (the cgroup check). It can still make
  the user's own processes act for it: ptrace of the user's shell or of a running `vibeswitcher` (both dumpable, both
  in `/init.scope`), the user's own Claude Code turned by text the worker wrote, PATH and aliases, the user's
  terminal; and it can replace the command line's own binary in the install folder. Not promised before signed
  approvals; S3, S11.

#### A session with a role

- **Lead.** Reaches its own session, the sessions it started and its team (`mayKill`, `LeadVault.leads`); types into
  its workers and verifiers (`mayType`); in the vault: `issue` and `bind` workers and verifiers it started, `retire`,
  `setReview`, `dismissFinding`, `replan`, `setHead`, `setGuarded`, `requestPush`, `roster` of its team, seals its
  messages to its team. Not: `approve`, `settlePush`, `setReviewFloor`, `issue` a lead, `handover`, `shutdown`. On
  Linux, the only session that may `spawn` (S2).
- **Worker.** Its own session and what it started; `reportDone` and `clearVerdict` for its own task, `ranGit` from its
  hooks; never its lead's terminal, a verdict, or another team; on Linux no `spawn`.
- **Verifier.** `submitVerdict` (or its ballot) for the task it audits, only from its tool server: what its Bash runs
  is branch code, no session's (`BranchCode.prefixVariable`, `VerifierBranchCodeHostTests`); on Linux no `spawn`.
- **Any of them, on the server's socket:** `status` and `questions` only.
- **A worker that tries, before the sandbox:** acts as any session, the lead and the verifiers included, by ptrace of
  that session's agent or tool server and `pidfd_getfd` of its descriptors (both dumpable, no Yama). It also has routes
  that need no ptrace and work on a machine where Yama restricts it: a launch file the lead wrote for a role (the
  prompt, while it is still a file), the lead's accepted git hooks copy between GitGuard's check and git's run, and a
  build renamed over `vibeswitcher-mcp` that the tool servers switch to in place (S9, S10). So it can call the lead's
  tools (`start_worker`, `merge`, the vault's lead requests) and cast a verifier's pass. Verdicts and merges are guard
  rails on Linux before the sandbox. Not promised; S11.

#### A session without a role

A session a lead started through `spawn`, or one the app opened before a role was bound to it. It reaches itself and
what it started; the vault treats it as a session holding nothing (`whoami` answers none; it may record `ranGit`). A
session the app opened, that no session started and that no other session typed into last, has its git commands
count as the user's (`isYours`, `HostServer.swift:627`): before the bootstrap the server opens only leads, which hold
a role, so this case is the lead's moment before `bind`. Its attacker is the worker's (above).

#### An unknown local process

A process of the user in no session: the user's shells and tools, a `claude` in another terminal and its hooks, branch
code under the wrapper, a worker process that escaped its session (S3). On the host's socket it gets `hello` with no
sessions, and the vault's reads that check no caller: `current`, `verdict`, `audits`, `ballots`, `head`, `guarded`,
`reviewFloor`, `approved`, `unaudited`, `startedOver`, `verify`, `verifyWalletRequests`
(`LeadVault.swift:917-1108`). Everything else is refused by the vault's own checks; no test sends a vault request from
an unknown process yet (`HostSecurityHardeningTests` covers session reads, mutations and subscriptions only), so Task
5b writes one. Those reads tell the team's state, not its secrets. On the server's socket it gets `status` and
`questions`, and the user's-voice requests if it passes S3's rule.

#### Another user

Closed at accept on both sockets (uid). It can't ptrace the user's processes or read their `/proc` files beyond the
world-readable ones. It **can** read every process's command line (no `hidepid`): paths, an agent's arguments, and the
launch settings a role's `claude` is given inline (S10, nothing secret in them). **While interop is on, another user is
one step from root too** (the interop sockets are 0777) and `/mnt/c` is 0777 to everyone: the uid check holds only
with interop off and automount off (decision 2). Before stage 3's later work there is no TCP listener at all; when the
loopback port comes, it trusts no header and asks for a device key in the first frame (design, requirement 4), and with
mirrored networking it is reachable from every Windows process of every Windows user.

#### Root

Everything. Not defended. On this machine root is one step from the user while interop is on (S1).

### The host's internal parts

Parsers talk to the host over a socket pair made at their start, not through the listening socket, and are
non-dumpable from their exec (S6). The host never takes a request from a parser as anyone's, and types a parser's
reply into a session only when it answers a query the host saw (S6). The probe of a handover is the new build, started
by the host from its sealed copy, reading the state from an inherited sealed descriptor and answering on a pipe; it is
no principal.

## S2. The app on Linux

**Decision.** S2-D1, **changed by this document**: the app on Linux is the server child the host started, and its
connections are the ones the host makes for it through a connector the child inherits. No connection made through the
socket's path is ever the app.

- The host is started with `--server PATH`. At its start it loads PATH into a sealed copy (S9: read once into a
  `memfd`, hashed from the copy's own bytes against `build-info`, sealed, made `0111`), makes a `SOCK_SEQPACKET`
  socket pair with `SOCK_CLOEXEC`, and starts the child from `/proc/self/fd/<copy>` with `keep: [connector]`, the
  connector's number in `--host-connector N` (a number, nothing secret). On its own queue, in the same turn as the
  spawn, it records the child's token.
- **The connector.** The server's `HostConnection` (a member whose default, nil, keeps today's connect-by-path; one
  Non-seam edit) asks for a new connection by sending one byte on the connector. The host makes a `SOCK_STREAM` pair
  with `SOCK_CLOEXEC`, registers its end as a client whose caller is `.app` and whose expected sender is the child's
  token, and passes the other end back with `SCM_RIGHTS`. Before it does, it checks that the child is still
  non-dumpable (`/proc/<child>/fd` is root's); otherwise it refuses, logs it and ends the child. Each message on an app
  connection is still checked by S5: the sender must be the child. App connections don't count toward `maxClients`.
- The server never connects to the host by path, so a socket squatted at the host's path never reaches it. The host
  tells the server what it needs to (a replaced path, its own restart count) as events on the app's connections.
- When the child exits: the connector closes, every app connection becomes `.unknown`, the child is reaped, and it is
  started again with a fresh connector after 1 s, doubling to 30 s, reset after 10 minutes up. While it runs the host
  doesn't exit idle.
- The server's first statements: close the inherited image descriptor, harden (already non-dumpable from its exec; kept
  for a build that runs from a readable file), check `TracerPid` and exit if traced, then settle SIGPIPE. **(call)** The
  server never execs: a lint refuses `execve`, `Platform.Spawn.replaceProcess` and `BinaryWatch` in
  `vibeswitcher-server`.
- **(call)** **The host keeps its path.** The user's host watches its socket's folder (`FolderWatch+Linux`) and, at
  each housekeeping (30 s), checks that its socket path and lock path still name the files it bound and locked (the
  inode recorded at `bind`; the lock descriptor's `fstat`). On a mismatch it binds a fresh listener at the path (with
  `SO_PASSCRED`), logs it, and tells the server, which shows it in `status`. The server does the same for its own
  socket. Task 8; E1 for the server.
- **(call)** **What happened is written where the server can't unwrite it.** The host writes its starts, the server
  child's exits and restarts, refused app connections and replaced paths to stderr, which the unit sends to the user
  journal. The command line reads `journalctl --user -u vibeswitcher-node` itself (with systemd's own start and stop
  lines and `systemctl --user show -p Result,ExecMainStatus,ExecMainStartTimestamp`) and shows starts, stops and
  server restarts that no `vibeswitcher start` or `stop` entry explains, and how the previous host ended (signal,
  OOM, exit code), until the user acknowledges them (`status --ack`). What the server says about itself is no
  mitigation once the server is seized; the journal is. Task 8 (stderr lines); E1 and E8 (the command line).
- The Mac is unchanged: `identify` still asks `AppCode.runs` (cdhash) and the app's HMAC proof; there is no connector
  there.

**Why.** The engine reaches the host through `HostCall` and `LeadVault.standard`, which open a new connection for every
call (`SessionDigest.swift:147-164`); a connector the child holds gives it as many connections as it wants, each made
by the host, with no pid on a path to trust. That closes four things the pid-on-the-path form left open: a socket
squatted at the host's path feeding the app lies, a listener copied in a handover feeding it lies, a reused pid passing
as the app, and the app locked out by full client slots. The plan's reason for no inherited descriptor
(`Platform.Spawn`'s `keep` keeps numbers) doesn't stand: the held image is already passed by number that way. Nothing
in `/proc` proves which code a process runs, and a key file is readable by every unconfined worker, so a process the
host started from a sealed copy and holds a descriptor for is the best principal plain mode has.

**What a worker can and can't do against it before the sandbox** (all of it void while interop is on, S1):

- Can't connect as the app: no connection by path is the app.
- Can't send on the app's connections: a message from another pid makes the connection nobody's (S5).
- Can't take the connector, the app's connections or its memory: the child is non-dumpable from its exec (S6), and
  every descriptor in the host and the server is close-on-exec from its creation (S6), so no other child inherits one.
- **Can** kill or stop the server (same uid): a denial of service, written to the journal.
- **Can** choose when the host next starts (`kill`, `systemctl --user stop|start|restart`), after editing what that
  start runs: the unit, its drop-ins, `~/.config/environment.d`, the manager's environment, the install folder and
  `build-info`. The unit's `UnsetEnvironment=` (S9) takes the loader's variables out of the host's start, so the
  edits that work are to files, which the seal sees at its next look. A host started from a worker's files is the
  worker's, and so is the app it starts. The journal shows a start no `vibeswitcher start` explains. On the Mac a
  replaced file never makes anyone the app (cdhash): this weakness is Linux's. Not promised.
- **Can** ptrace the host in its own start (systemd execs the installed file, which is readable): S6. Not promised.
- **Can** put its own socket at the host's path: sessions' tool servers and hooks reach it until the host binds the
  path again (seconds, by the folder watch). The server is unaffected. Not promised for sessions; S11.
- **Can** act as any session (S4) and work on the user (S3). Those are other principals' weaknesses, listed there.

**Doesn't promise.** That the app is the installed build's code after a host start a worker caused; the host's own
start window; anything while interop is on; anything in S11. If Task 3's measurement shows that a child started from a
sealed `0111` copy is dumpable at its exec, the server's restart window is open again and S6 and S11 say so.

**Before the bootstrap:** yes.

**Built in:** stage 2, Tasks 3 (sealed copies), 4b and 8 (the connector, the principal); the server's half of the
connector, its socket check and `status` in the engine plan's E1 and E8.

**The user confirms:** that until signed approvals the app on Linux is this principal, and that the residual risks in
S11 (chiefly: a worker that tries can restart the host into its own files, act as any session, and work on the user's
own shell and Claude Code) are acceptable while the only project on the node is VibeSwitcher's own and interop is off.

**Held by:** `LeadVaultHostTests.aConnectionWhoseProcessExecsTheAppIsntTheApp` (the Mac's rule, unchanged); planned:
stage 2 plan task 4b, task 8.

**Tests to write:** Task 4b: `HostIdentitySeamTests.theMacsAppIsStillTheCdhashCheck`,
`aConnectorConnectionIsTheAppWithNoChallenge`, `noConnectionByPathIsTheAppOnLinux`. Task 8:
`ServerChildTests.theServerChildsConnectorConnectionsAreTheApp`, `aConnectionFromAnotherProcessIsNotTheApp`,
`aChildOfTheServerIsNotTheApp`, `anotherProcessWritingOnTheServersConnectionMakesItNobodys`,
`theServerIsStartedAgainAfterItDies`, `aServerFileRewrittenInPlaceIsNotWhatRestarts`, `theServerChildSurvivesAHandover`,
`aHostWithAServerChildDoesNotExitIdle`, `theServerHelperIsNotDumpable`, `theMacStartsNoServerChild`,
`aServerChildThatIsDumpableIsNotTheApp`, `appConnectionsDontCountTowardMaxClients`, `aSquattedHostPathIsBoundAgain`,
`theHostWritesStartsAndServerRestartsToStderr`; `ServerLintTests.theServerNeverExecs`. The audit's Linux case in
`host-access.test.mjs`.

## S3. The user's voice before signed approvals

**Decision.** The command line talks to the server's Unix socket under `~/.vibeswitcher/v2/` (E1 names it): the file
0600, its folder 0700, the peer's uid checked at accept as the host does, and **each request's sender checked as the
host checks its messages (S5)** **(call)**: a request whose sender isn't the accepted process is refused and the
connection closed. The server checks its socket's inode as the host does (S2).

**The user's voice** is a peer of the user's uid, every field below read from `/proc` and **any field it can't read
counting as "not the user's voice"**:

- **(call, new)** whose cgroup (`/proc/<pid>/cgroup`, 0444: the `name=systemd` line and the `0::` line) is outside
  `user@<uid>.service` and outside the node's unit. Here the user's terminals are in `/init.scope`; with ssh they are
  in `session-*.scope`; E1 records which scopes it measured and accepts only those. A process of the user can't move
  itself out of `user@<uid>.service`, so a double fork, `setsid`, `script`, `systemd-run --user` (a transient
  `run-*.service`), `at` (`atd.service`) and cron (`cron.service`) are all refused;
- whose ancestry (the parent chain from `/proc`) contains no live session's program, no parser, not the server and
  not the host;
- whose controlling terminal is no session's;
- whose environment has no `VIBESWITCHER_SESSION`;
- that isn't under a `BranchCode` runner.

The server asks the host for the live sessions' programs and terminals (it is the app) and reads the rest from `/proc`.
Without a user systemd (the fallback start), there is no cgroup to tell by, the rule is the weaker four lines, and
`status` says so.

**(call, new)** **A state-changing request asks for the user's hands.** The command line shows what the request will
do (S7's lists, the answer's card) and asks for a word typed on its controlling terminal; with no terminal on stdin it
refuses, saying why. An agent's Bash tool has none (S1); `script` gives it one, so this is a guard rail against the
user's own Claude Code acting on text it read, not a lock. The user also puts deny rules for these subcommands in the
user's own Claude Code settings (decision 14).

**(call, new)** **What the user answers is built by the engine, not read from the board.** An approval card the command
line shows is made by the engine from facts it derives: the task, the full commit, the files and diffstat from git,
the verdict from the vault, the sensitive paths touched. The answer is bound to that card's id, held in the server's
memory, never to text in `board.json` (which any session can write, `LeadVaultApprovals.swift:5`). Questions come to
the server from the lead's tool server through the server's own socket, not by reading the board back. The lead's
question text is still the lead's (S1, item 3).

**(call, new)** **Answers at rest.** A user's-voice request the server accepts is recorded in the host's vault (an
app-only write) before it is acted on, and a restarted server takes answers and holds only from there, asking again
for anything it can't find. Nothing in a file the server or the engine keeps is taken as the user's answer.

Every request the socket takes, with the voice it needs; anything not listed is refused:

| Request | Voice | Why |
| --- | --- | --- |
| `status`, `questions` | anyone of the uid | reads; no secret in them |
| `start` (through the server, once it runs), `stop` | the user's | ends or starts every session |
| `status --ack` | the user's | clears the mark of a start or restart the user didn't make |
| `lead FOLDER --goal …` | the user's | opens an app session, whose git commands `isYours` treats as the user's; refused on a fresh vault until `config accept` and `base accept` are done (S7) |
| `answer CARD TEXT`, `hold ID` | the user's, typed | the user's answer to the lead, an approval included, bound to the card's id |
| `config held`, then `config accept ID`; `base accept` | the user's, typed | takes held config or a base move as the user's (S7) |
| `hooks install`, `hooks remove` | the user's, typed | written as the app (`vault.appWrite`), so sealed as the user's |
| any later request that changes state | the user's, typed | until signed approvals |

Each accepted user's-voice request is written to the journal by the command line (ids and hashes only: the journal is
readable by the `adm` group, so no answer text, goal or screen content goes there) and shown by `status`, with its
pid, cgroup and command line. A request journald saw from a cgroup that isn't a terminal's is marked.

**(call)** **The command line checks the server it reached**: on Linux, the listener (`SO_PEERCRED` on the client's
end) must be non-dumpable (`/proc/<pid>/fd` is root's), in the node's unit's cgroup (read from `/proc/<pid>/cgroup`,
not by running `systemctl` from PATH), and a child of the unit's `MainPID` (read with `/usr/bin/systemctl` by its
absolute path). A session's program is a child of the host too, but it is dumpable, so it fails the first check, and a
program a worker starts with `spawn` is refused before that: on Linux the user's host takes `spawn` only from the app
and from a session holding the lead role (S2). A worker that restarted the unit into its own server passes: that is
T3's route.

**Why.** Until stage 4's signed approvals there is no key the user holds that a worker can't read, so the user's voice
is told from the process. On the Mac the same answer comes from the app's window, which a worker can't drive without
Accessibility rights; on Linux the command line is a process like any other, and the cgroup is the one fact about a
process that a process of the user can't change.

**Doesn't promise.**

- A worker that drives the user's own processes passes: ptrace of the user's shell or of a running `vibeswitcher`
  (both dumpable, both in `/init.scope`), the user's own Claude Code acting on text the worker wrote (it is in
  `/init.scope` and passes every line of the rule; the typed word and the user's deny rules are guard rails), a
  `vibeswitcher` or `systemctl` earlier on the user's PATH, an alias or function in a shell startup file, and the
  user's terminal (`/dev/pts/N` is the user's: a worker can show the user text the user didn't run, and race the
  shell for the user's keys). Any of these can send the user's "no" as yes, or turn it into `config accept`.
- WSL interop, while it is on: `wsl.exe` starts a process in `/init.scope`. `ssh localhost`, if an ssh server runs.
- A worker can replace the command line itself: `~/.vibeswitcher/v2/builds/<commit>/bin/vibeswitcher` is the user's
  file, and running it by absolute path (the bootstrap path's question 6) only defeats PATH.
- A worker that restarted the unit with its own files is the server, and the check above passes.
- The text of the lead's questions: a turned lead asks what it likes. Only the card's facts are the engine's.

Acceptable only on VibeSwitcher's own repository, with interop off, until stage 4's signed approvals.

**Before the bootstrap:** yes.

**Built in:** the engine plan, E1 (the socket, the voices, the cgroup rule, the journal, the check of the server), E4
(`lead`), E6 (cards, answers at rest, holds), E8 (the restart path), and the bootstrap path's step 8 (`hooks install`).

**Held by:** planned: the engine plan task E1, E4, E6.

**Tests to write:** E1: `theServerIsNotDumpable`, `anUnknownRequestIsAnsweredNotFatal`,
`statusThroughTheServerMatchesTheProbe`, `aSessionsProcessCannotStopTheNode`, `anUnlistedRequestIsRefused`,
`anAcceptedAnswerIsShownByStatus`, `aRequestFromAnotherSenderOnTheServersSocketIsRefused`,
`theServersSocketIsTheUsersAlone`, `theCommandLineRefusesAServerThatIsntTheHostsChild`,
`theCommandLineRefusesADumpableListener`, `anAnswerFromTheNodesCgroupIsRefused`,
`anAnswerFromATransientUserUnitIsRefused`, `aPeerWhoseCgroupCantBeReadIsNotTheUser`,
`aPeerWhoseEnvironmentCantBeReadIsNotTheUser`, `aStateChangeWithNoTerminalIsRefused`. E4:
`aSessionsProcessCannotStartALead`, `aLeadIsRefusedOnAFreshVaultUntilAccepted`. E6:
`anAnswerFromASessionsProcessIsRefused`, `anAnswerFromAProcessCarryingASessionMarkerIsRefused`,
`anAnswerFromBranchCodeIsRefused`, `anApprovalCardIsBuiltFromGitAndTheVault`, `aQuestionWrittenToTheBoardIsNotShown`,
`anAnswerWrittenToTheServersFilesIsNotTakenAfterARestart`. Step 8: `aSessionsProcessCannotInstallHooks`.

## S4. Session identity

**Decision.** Before the bootstrap, today's rule, on Linux's `/proc`, with three fixes in Task 6:

- A process is the innermost live session whose program is in its ancestry, or, failing that, the session whose
  terminal is its controlling terminal (`ttypts<N>`, the same name in `HostSession.tty`, `ProcessTable`, the hook's
  state file and the steer inbox: Task 6).
- A `BranchCode` wrapper between the process and the session makes it no session's: merge's, an audit's and
  `init_command`'s runs of a branch's code, and every command a verifier's session runs (its Claude Code shell prefix).
  Merge's, audits' and init's runs start the wrapper in a POSIX session of its own (`Worktrees.swift:401`). **A
  verifier's commands don't, today**: `BranchCode.runPrefix` execs the wrapper with no `setsid`, so a command that
  double-forks without `setsid` keeps the verifier's terminal and the terminal rule names the verifier. **(call)** On
  Linux, `runPrefix` calls `setsid()` before its exec (Task 10, measured against Claude Code's timeout and interrupt in
  Task 12); the Mac is unchanged and gets a line in `docs/process/v2-mac-tasks.md`.
- **(call, new; Task 6)** **A session's terminal is its own from the start.** On Linux the launcher exits 127 when
  `TIOCSCTTY` fails or `tcgetsid(0)` isn't its pid (today `PTYSpawn.swift:16` ignores the result), and the host counts
  a session live only once `TIOCGSID` on the master names the launcher's pid. Otherwise an escaped worker that ran
  `setsid` and spins on `open("/dev/pts/N")` (N is the lowest free number) takes a new session's terminal first and is
  that session by the terminal rule.
- **(call, new; Task 6)** **Pid numbers are checked against start ticks.** A session's program is matched by its token
  (pid and start ticks), not its pid alone (`HostServer.session(of:)` matches `childPID`); each ancestor's start ticks
  must be no later than its child's, and a child's parent is read again after its parent's entry was read. A session
  reaped by `HostedSession.reap(_:until:)`, which runs on a queue of its own, must already count as not live; Task 6
  checks it.
- Told once, at accept: a process can leave its session's tree, never join another's.
- `VIBESWITCHER_SESSION` in a session's environment is a marker for the server's user's-voice rule (S3) and for
  `SessionStrays`, never an identity: anyone can set it.

After the bootstrap, with the sandbox (S2-D9), **the inherited connector** for sessions, the same mechanism as the
server child's (S2):

- One `SOCK_SEQPACKET` socket pair per session, made by the host at spawn. The host keeps one end, bound to the
  session's id. The other is passed to the session's program at a fixed number named in `VIBESWITCHER_HOST_FD`, not
  close-on-exec, through the launcher.
- `HostConnection` tries it first: it asks for a new connection on the pair; the host makes a fresh stream pair,
  binds the host's end to that session, and passes the other end back with `SCM_RIGHTS`. The path is used only by
  clients with no connector (the command line's tools, other terminals' hooks).
- The `BranchCode` wrapper unsets the variable and closes the descriptor before running branch code.
- A handover carries the host's ends in `descriptors` and each one's session in the sealed state (S8).
- **Open, to measure first:** Claude Code and Codex start their tool servers and hooks as child processes of their
  own, and whether an inherited descriptor N reaches them depends on how each starts its children. Nobody has checked.
  If it doesn't, the fallback is identity by **pid namespace**: each sandbox has its own, the host holds a pidfd for
  each sandbox's first process, and a peer's namespace is read from `/proc/<pid>/ns/pid`. Any unconfined process of
  the user owns every sandbox's user namespace, so it can `setns` into a sandbox, claim pids inside it (S5) and read
  that file even of a non-dumpable process: pid-namespace identity holds only against confined processes. The
  sandbox's design picks one.

**Why.** Process ancestry works and has years of tests behind it on the Mac. Before the sandbox a session connector adds
nothing: ptrace or `pidfd_getfd` of any session process takes it. The three fixes are a few lines each and close routes
that need no ptrace.

**Doesn't promise.**

- Before the sandbox, ancestry is no lock: a worker acts as any session by ptrace of its processes (S11).
- A pid number from the kernel names a process only while it lives, and the host reads ancestry afterwards: a worker
  that connects and writes, then exits, and has its pid reused by a process of another session, is taken as that
  session (S5). Ptrace makes this unnecessary before the sandbox; the connector (or the pid namespace) closes it.
- The wrapper is a dumpable bash known by its argv (`BranchCode.isRunner(pid:)` reads `cmdline`): branch code can
  rewrite its wrapper's argv with `process_vm_writev`, stop being "under a runner", and be the session above it (the
  lead in merge's tests). Before the sandbox the same code can ptrace the lead's tool server anyway; a hardened wrapper
  mode is after the bootstrap (S12).
- Whatever a session's program passes its descriptors to is that session, as its descendants are today.

**Before the bootstrap:** yes (today's rule on Linux, with the terminal, token and `setsid` fixes); no (the session
connector).

**Built in:** stage 2, Tasks 4b, 5 and 6; `runPrefix`'s `setsid` in Task 10; the connector after the bootstrap, with
the sandbox.

**Held by:** `LeadVaultHostTests.aWorkersShellCantGiveAVerdictSealAsTheUserOrTypeIntoTheLead`,
`LeadVaultHostTests.aWorkerCanReadItselfButCannotReadOrTypeIntoItsLeadOrAnotherProject`,
`LeadVaultHostTests.aLeadCanReadAndTypeIntoItsWorkerButCannotAccessAnotherProject`,
`VerifierBranchCodeHostTests.aVerifiersBashCantSubmitItsVerdictAndItsToolServerStillDoes`,
`HostSecurityHardeningTests.unknownClientsCannotReadMutateOrSubscribeToSessions` (on the Mac now; on Linux from Task
5b); planned: stage 2 plan task 6.

**Tests to write:** Task 6: `HostedSessionTerminalTests.aSessionsTerminalIsTheTablesName`,
`aProcessOnTheSessionsTerminalIsThatSessions`, `theHookStateFileOfASessionIsDirectlyInState`,
`aProcessThatTookASessionsTerminalFirstIsNotThatSession`, `aLauncherThatCantTakeItsTerminalExits`,
`aReusedProgramPidIsNotTheSession`, `anAncestorYoungerThanItsChildBreaksTheChain`. Task 10:
`VerifierBranchCodeHostTests.anEscapedVerifierCommandWithoutSetsidIsNobodys`. With the connector:
`aConnectorConnectionIsItsSession`, `branchCodeHasNoConnector`, `theConnectorSurvivesAHandover`, and the measurement
`claudePassesTheConnectorToItsToolServerAndHooks`.

## S5. Per-message credentials

**Decision.** S2-D4. The host's listener has `SO_PASSCRED` (`Platform.Sockets.enableCredentials`) before its first
accept (in `start()` and `start(restoring:)`), so every accepted connection carries senders from its first byte; the
host's ends of connector connections get it at creation. Each read is `Platform.Sockets.receive`, which stops where
the sender changes, so one read never holds two senders' bytes. The rule, `HostServer.senderKeepsIdentity(accepted:sender:)`:

- a sender whose token is the accepted one (for an app connection, the server child's) keeps the connection's
  identity;
- a missing sender (no credentials, or its `/proc` entry gone) or another sender makes the connection `.unknown` for
  good, drops its attachments and queued output;
- a frame made of two senders' bytes is handled as an unknown caller's request (refused beyond `.unknown`'s rights),
  not dropped, which is what the Mac does today (`ClientConnection.swift:153-157` calls `onRead` before it appends).

The kernel fills in the sender, and checks a pid a sender names itself: naming another process needs `CAP_SYS_ADMIN`
in the user namespace that owns the sender's pid namespace, and **any process of the user gets that with
`unshare -Urp`** (unprivileged user namespaces are on here). So a sender can name another process only inside a pid
namespace it made, which holds only its own processes: before the sandbox it can't pose as the host's other processes
this way. After the bootstrap, every unconfined process of the user owns every sandbox's user namespace, and so can
claim any pid inside a sandbox (S4, S12). Where the kernel has `SO_PEERPIDFD` and `SCM_PIDFD` (6.5 and later),
`Platform.Sockets` uses them: the host then compares process handles, not numbers **(call; after the bootstrap, not on
this machine)**.

The same rule holds on the server's socket (S3).

**Why.** `SO_PEERCRED` is fixed when the connection is made: a child that inherited a connection, or a process handed
it, would otherwise speak with its connector's identity. On the Mac `LOCAL_PEERTOKEN` already names the last sender.

**Doesn't promise.**

- Who reads from a connection: credentials name senders, not readers.
- That the sender didn't exec another program since it connected: the token keeps its pid and start ticks (on the Mac
  an exec changes the token).
- **Pid reuse.** Both `SO_PEERCRED` and `SCM_CREDENTIALS` give a pid number; the host reads its start ticks from
  `/proc` afterwards. If the sender exited and its pid was given to a new process before the host's read, the token is
  the new process's. A worker can arrange that by writing, exiting and cycling pids (here the space wraps in ordinary
  use, S1), and by stopping the host (`SIGSTOP`) to widen the moment. What it can pass as is a session's process that
  starts in that moment (dominated by ptrace, S4). It can't pass as the app, whose connections aren't by path (S2).
  `Platform.Sockets.receive`'s comment, "nil when … the sender has gone since", is true only while the pid isn't
  reused, and Task 7 corrects it.

**Before the bootstrap:** yes.

**Built in:** stage 2, Task 7; the platform half is built (`Sockets+Linux.swift`); the test shim's explicit
`SCM_CREDENTIALS` send in Task 3.

**Held by:** `SocketsTests.receivedBytesComeWithTheirSender`, `SocketsTests.eachMessagesSenderIsTheProcessThatWroteIt`,
`SocketsTests.sendersAreKnownOnlyFromWhenTheyWereAskedFor`,
`SocketsTests.aPeerTokenComparesEqualForTheSameProcessAndDiffersForAnother`,
`SocketsTests.descriptorsSentAlongAreClosed`; planned: stage 2 plan task 7.

**Tests to write:** Task 7: `PeerPerMessageTests.aForkedChildWritingOnALeadsConnectionMakesItNobodys`,
`aFrameSplitAcrossTwoSendersIsHandledAsNobodys`, `theAcceptedProcessKeepsItsIdentityOverAThousandWrites`,
`aMissingSenderMakesTheConnectionNobodys`; `SocketsTests.bytesFromAReapedSenderComeWithNoSender`,
`aSenderCannotClaimAnotherPid` (outside a namespace of its own: `EPERM`),
`aSenderInItsOwnPidNamespaceCanNameOnlyItsOwnProcesses`.

## S6. Hardening

**Decision.** S2-D5, **extended by this document**. The host and parser modes of `vibeswitcher-host`, and
`vibeswitcher-server`, begin with `Platform.ProcessSelf.harden()` (`PR_SET_DUMPABLE 0`, `RLIMIT_CORE 0`), then read
`TracerPid` from `/proc/self/status`: a traced process refuses to start, and a traced new image after a handover
refuses its secrets (closes them unread) and goes back; the fallback checks `TracerPid` too and, traced, ends. The
launcher mode doesn't harden (it execs the session's program at once). Session programs are left dumpable.

What non-dumpable does on this kernel, for a process of the same user without `CAP_SYS_PTRACE`:

- `ptrace` attach, `process_vm_readv`, `pidfd_getfd` are refused (`EPERM`);
- `/proc/<pid>/mem`, `environ`, `maps`, `fd/`, `fdinfo/`, `exe`, `cwd`, `root` are refused (`EACCES`), and the
  `/proc/<pid>` entries become root's;
- `stat`, `status` and `cmdline` stay readable (they are 0444): pid, parent, start ticks, `TracerPid`, arguments;
- no core dump: `fs.suid_dumpable` is 0. `RLIMIT_CORE 0` is kept but does nothing here, since a piped `core_pattern`
  isn't limited by it.

**(call, new) The exec windows are closed by sealed copies.** `execve` makes a process dumpable again, unless the
image it runs is one the process can't read: then the kernel makes it non-dumpable from the exec on. So every image
the host starts (the server child, the parsers, the launcher, a handover's probe, the new image of a handover, and
the fallback) is a **sealed copy** (S9): read once into a `memfd`, hashed from the copy's own bytes, sealed against
writing, and `fchmod`'d to `0111`, then run from `/proc/self/fd/<copy>`. Nobody but the host holds the copy (the host
is non-dumpable, so `/proc/<host>/fd/` is closed to others), so nobody can `chmod` it back. The host's own descriptors
were never reachable: it was non-dumpable from its first statement, and a child forked from it stays so until its
exec. Measured by a reviewer on this kernel (a sealed `0111` copy of `/bin/sleep`, run from `/proc/self/fd/N`:
`PTRACE_ATTACH`, `pidfd_getfd` refused, `/proc/<pid>/mem` refused); Task 3 measures it again in the suite. **If the
measurement fails** on a kernel, the windows below are open there, S11 lists them, and the rule on switches (S8)
applies.

| Window | Before this document | With sealed copies |
| --- | --- | --- |
| The host's start by systemd (or `vibeswitcher start` without systemd) | open: the host's code is the worker's | **still open**: systemd execs the installed file, which is readable. Not promised (S11) |
| The server child's start or restart | open: the app is the worker's | closed |
| A parser's start | open: that session's screen, and input typed into it (below) | closed |
| A handover's exec and its fallback | open: every session's terminal, the listener, the lock, the vault | closed |
| A handover's probe (up to 180 s) | dumpable for its whole run | non-dumpable from its exec |

**(call, new) Descriptors are close-on-exec from creation**, on Linux: `socket`, `socketpair` with `SOCK_CLOEXEC`,
`accept4(…, SOCK_CLOEXEC)`, `open` with `O_CLOEXEC`, `memfd_create` with `MFD_CLOEXEC`. Today `UnixSocket.connectOnce`
and `listen` set `FD_CLOEXEC` after `socket()` (`UnixSocket.configure`, `UnixSocket.swift:90-92`) and the host sets
it after `accept` (`HostServer.swift:259, 269`): a spawn on another thread in between inherits the descriptor, and
`Platform.Spawn`'s musl path closes only what was open when the spawn began (`Spawn+Linux.swift:9-11`). Non-dumpable
protects a process, not a descriptor that leaked into a dumpable child (git, the probe). Every spawn by the host and
the server names `keep` explicitly. A lint refuses a bare `socket(`, `accept(` and `open(` without the flag in
`VibeHost`, `VibePlatform` and the server. The Mac has no `SOCK_CLOEXEC` and keeps today's code.

**(call, new) A parser's reply is typed only as a reply.** The host writes a parser's `.reply` bytes into the session
while no client is attached (`HostedSession.swift:226-229`), and they don't change who typed last. On Linux the host
passes a reply only when it answers a query the host saw in that session's output since the last reply, and only in
the reply grammar (cursor position, device attributes, the colour and mode reports the headless terminal makes); any
other byte from a parser is dropped and logged. With sealed copies a parser can't be seized; this keeps a parser bug
from typing into the lead.

**Who reads `/proc` entries of other processes** must treat "unreadable" carefully: any process can make itself
non-dumpable (`PR_SET_DUMPABLE 0` needs no privilege). An unreadable process is **the host** only if its pid and
start ticks are the host's own, or a recorded parser's or the server's; any other unreadable process is "unknown,
still running", neither the host nor gone. `ProcessTable` (the host's executable and cwd), `SessionStrays`
(environments), `HostServer.executable(of:)` and the orphan sweep (arguments, still readable) follow this; S3's rule
counts an unreadable field as "not the user's voice". Task 9 checks each.

**(call)** Nothing secret goes in the arguments or the environment of the host, the server or a parser: the arguments
are world-readable. The test-only secret flags (`--handover-test-secret`, `--handover-test-secret-file`) are refused
by the user's host (S8).

**Why.** On this kernel, with no Yama, non-dumpable is the one thing that keeps a worker out of the vault's memory,
the screens and the host's descriptors, and sealed copies make it hold from the first instruction for every start the
host makes. The plan put `0111` after the bootstrap for two reasons (the handover target's check reads the image; the
worker can `chmod` the installed file back): neither applies to a private copy the host hashes before it seals it.

**Doesn't promise.** The host's own start window; a kernel where the measurement fails; a process of the user whose
`/proc` the host can't read being reported correctly by anything other than the host itself; anything against root,
and so anything while interop is on.

**Before the bootstrap:** yes (sealed copies included).

**Built in:** stage 2, Task 3 (the platform: harden, sealed copies, the measurement), Task 2 and 4a (close-on-exec
from creation), Task 8 (the server's helper), Task 9 (host, parsers, probe, fallback, readers of `/proc`); the
parser's reply grammar in Task 9; the server's own first statements in the engine plan's E1.

**Held by:** planned: stage 2 plan task 3, task 8, task 9.

**Tests to write:** Task 3: `ProcessSelfTests.aHardenedProcesssMemoryCantBeOpened`,
`aHardenedProcesssDescriptorsCantBeTaken`, `hardeningIsNothingOnTheMac`, `tracerPidIsReadFromStatus`,
`aChildStartedFromASealedCopyIsNotDumpableFromItsExec` (polled `pidfd_getfd` from another process),
`aSealedCopyCantBeWrittenOrChmoddedByAnotherProcess`. Task 4a: `CloseOnExecLintTests.noBareSocketAcceptOrOpen`,
`HostServerTests.aSpawnDuringAnAcceptInheritsNoConnection`. Task 8: `ServerChildTests.theServerHelperIsNotDumpable`.
Task 9: `HostHardeningTests.theHostIsNotDumpableAfterStartAndAfterAHandover`, `aParserIsNotDumpable`,
`aSessionsProgramIsDumpableAsUsual`, `aTracedNewImageGoesBackWithoutTheVault`, `aHandoverImageIsNotDumpableFromItsExec`,
`anUnreadableHostIsTheHostNeverGone`, `anotherHardenedProcessIsNotTakenForTheHost`,
`nothingSecretIsInTheHostsArgumentsOrEnvironment`; `ParserReplyTests.aReplyWithNoQueryIsNotTyped`,
`aReplyOutsideTheGrammarIsDropped`.

## S7. The vault's key per mode

**Decision.** S2-D3. In plain mode the vault lives in the host's memory only (`VaultStorage` with a nil key,
`VaultStorage.swift:11, 40`; on Linux `Platform.Keychain` answers nil). A handover carries it in sealed memory (S8).
The host log says "vault in memory only".

What a host restart erases: every team's roles and grants, verdicts and ballots, findings and audit rounds, review
levels and done reports, the lead's recorded heads, approvals, push requests, the guarded settings' hashes, the
review floor, the user's sealing key (sealed messages from before can't be verified), and the config seal's hashes
(`ConfigSeal.swift:10-14`). **A worker can cause a restart at will** (S2), and an OOM kill, an idle exit or a WSL
shutdown cause one too.

**A fresh vault takes nothing as its baseline that a worker could have written.** Today each record, once empty, is
filled from what is on disk at the next look: `changedSettings` records any guarded key with nothing recorded "as it
is" (`LeadVaultGuarded.swift:64-73`), so a worker-edited `workflow.md`'s `test_command`, `init_command`,
`merge_policy`, `sensitive_paths`, `audit_finders`, `auto_advance` and `remote` become the lead's; the engine's start
of a lead seeds the floor from `workflow.md` with `onlyIfUnset` (`LeadVault.swift:314-317`, from
`LeadController.swift:1037`); the main checkout's seal (`ConfigSeal.checkoutFiles` plus `.git/config` and
`.git/hooks`, `ConfigSeal.swift:319-350`) records what it first sees; and the lead's head is recorded from whatever
the branch is at. So on Linux, **(call, extended)**:

- `LeadVault.Book.holdsFirstLook` covers every record: the home seal, the main checkout's seal, the guarded settings
  (an unrecorded key is held, not recorded) and the floor (none is seeded from `workflow.md` on a fresh vault). It is
  kept in the vault's state, so a handover before the first look keeps it; it is true when the vault holds no restored
  secrets (`main.swift` on Linux), false by default (the Mac is unchanged).
- **The user accepts in two steps.** `vibeswitcher config held` lists everything held, each with its change time
  (ctime, which `touch` can't set back), size, hash prefix and, where a previous accept is known, what changed
  (below); a guarded key shows its value (the `test_command` text, the `merge_policy`); the floor shows the values
  `workflow.md` proposes. It prints an id bound to those hashes. `config accept ID` seals exactly those; anything
  changed since is held again.
- **`lead` is refused on a fresh vault until `config accept` and `base accept` are done.** The lead's own start is
  otherwise never held, so a lead started first would load a planted hook or settings before anything was accepted.
- **`base accept` shows what moved**: `git log <last accepted head>..<now>` for the lead's branch, or from a head the
  user names.
- **A diff aid, not a lock**: an unsealed "last accepted" snapshot under `~/.vibeswitcher/v2` (hashes, guarded values,
  the floor, each lead's last head), written at each accept. It turns "everything is new" into "these three changed";
  a worker can rewrite it, so the user reads the values, not just the marks.
- Workers, verifiers and merges wait until the accept, as the plan says.

Strong mode (after the bootstrap): a 0600 key file under `~/.vibeswitcher/keys`, never mounted into a sandbox, so the
sealed vault (`~/.vibeswitcher/lead/vault.sealed`) survives a restart.

**Why.** Before the sandbox a key file is no secret: any worker reads a 0600 file of the user's, and could then forge
a sealed vault. Memory only is honest about it, and the cost is that every record must be re-established by the user
rather than by the disk.

**Doesn't promise.** That team state survives a host restart; that a fresh vault's first look is clean (it holds it
for the user to judge, it doesn't judge it); that the user reads the list before `config accept` (the typed word is a
guard rail, S3); that the seal sees a change swapped in and restored between two looks (the seal compares points in
time: before a worker or verifier starts, after a merge's tests, at accept).

**Before the bootstrap:** yes (plain mode, the extended first look, the two-step accept); no (strong mode's key file).

**Built in:** stage 2, Task 4c (the Keychain's Linux form), Task 10 (`holdsFirstLook` over every record, kept in the
state); the engine plan's E4 (`lead` refused), E8 (the restart path, `config held`/`accept`, `base accept`, the
snapshot); strong mode after the bootstrap.

**The user confirms:** that a host restart ends the lead's team state, and that after every host restart the user runs
`config held`, `config accept ID` and `base accept`, reading the values, before starting the lead again.

**Held by:** `VaultHandoverTests.grantsVerdictsAndSealsSurviveAHandoverAndAWorkerIsStillRefused`,
`KeychainLintTests.onlyTheKeyStoresCallTheKeychain`; planned: stage 2 plan task 10.

**Tests to write:** Task 10: `ConfigSealFirstLookTests.aVaultThatHoldsItsFirstLookHoldsEveryHomeFile`,
`aVaultThatDoesntSealsItsFirstLookAsToday`, `aFreshVaultHoldsChangedGuardedSettings`,
`aFreshVaultHoldsTheCheckoutsGitHooks`, `aFreshVaultSeedsNoFloorFromWorkflow`,
`aVaultHandedOverBeforeItsFirstLookStillHoldsIt`. E4: `aLeadIsRefusedOnAFreshVaultUntilAccepted`. E8:
`aHostRestartSaysTheTeamIsGone`, `aHostRestartHoldsWorkersUntilTheConfigIsAccepted`,
`aStartTheUserDidntMakeIsShownUntilAcknowledged`, `configAcceptSealsOnlyWhatItShowed`,
`configHeldShowsChangeTimesSizesAndHashes`, `baseAcceptAfterARestartShowsWhatMoved`.

## S8. The handover

**Decision.** S2-D8, **changed by this document**: on Linux, before the bootstrap, the handover goes through sealed
memory and writes no file.

- The build handing over writes the state into a `memfd` (`MFD_CLOEXEC | MFD_ALLOW_SEALING`), seals it
  (`F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL`), and names it to the new image as
  `--handover /proc/self/fd/<n>`, `n` among the descriptors kept across the exec. `HostHandover.read(from:)` reads that
  path unchanged; a reopen of `/proc/self/fd/<n>` starts at the beginning, so the probe, the new image and the
  fallback each read the same bytes. The secrets (the vault) go into a second sealed `memfd` the same way, not the
  socket channel: no size limit short of memory, and they stay readable until the handover is done, so a fallback
  after a failed restore keeps the vault.
- Only non-dumpable processes hold these descriptors (the host, the probe and the new image from their exec, S6), and
  a sealed `memfd` can't be changed by anyone. So there is no state file to forge, spoil, read or leave behind, and
  no hash is needed. The state holds every session's output ring and pending input (`HostedSession.saved`), which is
  why it must not be a file.
- **The handover target and the new server image** are sealed copies too (S9): the host loads the target once,
  checks its hash against its build's `build-info`, and probes and execs that copy; it loads the same build's
  `vibeswitcher-server` the same way and passes it with the state. The new image restarts the server from it once
  idle, so after a switch the host and the server are the same commit.
- **The fallback** is the old image's sealed copy (S9), with the same descriptors and the same `--handover` path. It
  reads the state and the secrets as the new image would have. `goBack` today re-runs the fallback with the same path
  and, when that fails too, unlinks it and exits, hanging up every session (`main.swift:92-102`); with sealed memory
  the fallback reads exactly what the old build wrote, so only a fault in the old build itself ends the host.
- **A traced new image** closes the secrets unread and goes back; the fallback, traced, ends (S6).
- **The server child's record is checked again on restore:** its parent is this process, its start ticks match, it is
  no restored session's program and no parser; its connector is among the descriptors. Otherwise the record is
  cleared and the server started again.
- **A newer format is refused** (`HostHandover.format`, rule 11) and the host goes back.
- **The test-only flags** (`--handover-test-secret`, `--handover-test-secret-file`, `--handover-test-traced`,
  `--install-root`, `--test-app-pid`) are honoured only by a scratch host and stripped from `config.arguments`.
  Today `--handover-test-secret` is honoured by any host and kept across handovers (`main.swift:142-143`); Task 9 ends
  that.
- **A fresh host removes stale files**: after taking the lock, a host that isn't restoring removes any
  `host.lock.handover` and `.partial` (the Mac's format, or a scratch host's), and logs it.
- **(call; the user confirms) No switch of builds while a worker or verifier runs**, until Task 3's measurement has
  passed on this machine. With sealed copies the handover's exec is no longer a window; the rule costs the bootstrap
  little and stays as the fallback if the measurement fails. The server refuses a switch while a worker or verifier
  session is live, saying so; the lead may stay.

The Mac keeps its state file and socket channel, unchanged.

**Why.** The state file was a worker's to replace, spoil or read; a spoiled file made the fallback fail too and ended
every session (`main.swift:92-113`); and the forged-file test the plan named could not fail without its fix, because
the file is written again after the probe (`HostServer.swift:715`, then `737`). Sealed memory removes the file, which
removes all three, for a few dozen lines: `memfd_create` and seals exist on this kernel.

**Doesn't promise.** That a handover succeeds (a new build that can't restore goes back); the handover to a build the
worker placed in the install folder with a matching record (S9); anything on a kernel where the measurement fails,
beyond the rule on switches.

**Before the bootstrap:** yes (sealed memory, sealed target and fallback, the rule on switches until measured).

**Built in:** stage 2, Task 8 (the server child's record and image across a handover), Task 9 (sealed state and
secrets, the target, the fallback, formats, flags, stale files); the rule on switches in the bootstrap path's step 8.

**The user confirms:** that builds are switched only while no worker or verifier runs, until the measurement passes.

**Held by:** `HostHandoverTests.secretsReachTheNewBuildAndNeverTheStateFile`,
`HostHandoverTests.aBuildThatCantRestoreGoesBackToTheOldOne`, `HostHandoverStateTests.theStateFileIsPrivateAndReadBack`,
`HostHandoverStateTests.aStateOfAnotherFormatIsRefused`, `HostHandoverStateTests.secretsGoThroughAChannelAndNowhereElse`
(on the Mac now; on Linux from Task 5b, where the Linux forms replace the file and channel cases); planned: stage 2 plan
task 8, task 9.

**Tests to write:** Task 8: `aForgedServerChildInTheStateIsNotTheApp`, `aSwitchBringsTheNewBuildsServer`. Task 9:
`HandoverLinuxTests.aHandoverWritesNoFile`, `theStateAndSecretsAreSealed`,
`aFallbackAfterAFailedRestoreKeepsTheVault`, `aFallbackAfterAFailedRestoreKeepsEverySession`,
`theUsersHostIgnoresTestSecretFlags`, `aDowngradeIsRefused`, `aFreshHostRemovesAStaleStateFile`. Step 8:
`aSwitchWhileAWorkerRunsIsRefused`.

## S9. What the host executes

**Decision.** S2-D7, **changed by this document** from held `O_PATH` images to sealed copies, plus the static build.

- **Sealed copies.** An `O_PATH` descriptor names an inode, and the user can rewrite that inode in place whenever no
  process runs it (`ETXTBSY` holds only while one does): the server's image between its death and its restart, the old
  host image after a handover's exec. So at its start the host reads its own image and its `--server` image once each
  into a `memfd`, computes each hash from the copy's own bytes, checks it against `build-info`, seals the copy and
  makes it `0111` (S6). Sessions' launchers and parsers start from the host's own copy, the server from its copy, a
  failed handover falls back through the old image's copy (kept across the exec). A file changed on disk after the
  host loaded it is never what the host runs. Because `/proc/self/exe` then names `/memfd:…`, the host takes its
  install folder from an explicit `--node-root` (the user's host) instead of deriving it from its executable
  (`main.swift:30-38, 68, 124` do today), and so do the paths of `vibeswitcher-mcp`, `HostBuild` and the command
  folder.
- **The static build, before the bootstrap.** Every installed binary is built with `--static-swift-stdlib`
  (Foundation included; the toolchain has `swift_static`), so nothing it runs loads from the toolchain under
  `~/.local/share/swiftly`, which the user (and every worker) can write. Today's builds have that toolchain first in
  `RUNPATH` and load `libswiftCore.so`, `libFoundation.so` and `libdispatch.so` from it at every start, which would
  make every parser, server, tool server and fallback the worker's after one rename. What remains is the C library and
  its kin from root-owned `/lib`. The unit and the host's children get `SWIFT_BACKTRACE=enable=no`, so a crash
  doesn't start `swift-backtrace` from the toolchain.
- **The tool server's keeper** (`MCPKeeper`, which restarts a killed tool server from `Bundle.main.executablePath`,
  the file on disk, `vibeswitcher-mcp/main.swift:27`) restarts it from a sealed copy it made at its own start.
- In the user's host (`HostServer.Config.installRoot` = `~/.vibeswitcher/v2/builds`), a handover target must be inside
  the install folder and match the SHA-256 recorded for it in that build's `build-info`
  (`{"format":1,"commit":…,"binaries":{…},"swift":…,"resolved":…}`, a newer format refused), checked on the sealed
  copy that is then probed and run (no gap between check and use). A path in a worktree or a session's folder is
  refused. At its start the user's host checks its own image and its `--server` image against `build-info` and refuses
  to start otherwise. Scratch hosts have no install root and hand over as today.
- **How the node is started** (the bootstrap path): a user unit, `vibeswitcher-node.service`, started and not
  enabled, `Restart=no`, `ExecStart=<prefix>/<commit>/bin/vibeswitcher-host --node --node-root <prefix>/<commit>
  --server <prefix>/<commit>/bin/vibeswitcher-server` (the commit's folder, never `current`), and:
  - `KillMode=control-group` stated, with its consequence: when the host exits for any reason (crash, OOM, idle exit,
    a failed fallback, `stop`), every session, the server and every process left in the unit's cgroup get SIGTERM. A
    host exit ends every session, as the vault's loss already ends every team; `TimeoutStopSec=` set. The comment
    "Sessions outlive the host either way" (`main.swift:146`) is the Mac's;
  - `UnsetEnvironment=LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH GCONV_PATH BASH_ENV ENV VIBESWITCHER_HOME
    CFFIXED_USER_HOME SWIFT_BACKTRACE`, then `Environment=SWIFT_BACKTRACE=enable=no`, so `systemctl --user
    set-environment` can't reach the host's start; `start` and `status` compare `systemctl --user show-environment`
    with the expected set and name anything extra;
  - `Environment=HOME=…` and `Environment="PATH=/usr/local/bin:/usr/bin:/bin:<folder of the resolved claude>"`,
    quoted, with no `/mnt/` folder;
  - the user's host takes `VibePaths.root` from `getpwuid`, never from `VIBESWITCHER_HOME`, when started with `--node`
    (`ownsLaunchers` compares two paths derived from that same root today, `main.swift:32-34`);
  - the host raises its children's `oom_score_adj` (sessions and their agents +500), so the kernel's OOM killer picks
    a compiler or an agent before the host or the server.
- **git and systemctl from root's folders.** On Linux `Platform.Tools.git` is today the first `git` on the process's
  PATH (`Tools.swift:7-15`), while the Mac's is `/usr/bin/git`. On Linux it becomes the first `git` in a folder owned
  by root and writable by nobody else, up the whole path; the host and the server refuse to start without one. The
  command line runs `/usr/bin/systemctl` by its path.
- **(call)** **The tool server switches only to the build the user switched to.** Today a tool server watches its own
  binary (`BinaryWatch`, `MCPServer.swift:58`) and, once a probe passes, replaces itself in place with whatever is
  there. On Linux in the user's node it switches only when `<prefix>/current` names another commit whose `build-info`
  lists the file's hash, and it runs the sealed copy it hashed. A guard rail against a rename over the file a running
  tool server would switch to.
- **The install** (the bootstrap path's steps 8 and 10) builds from a clean, detached `git worktree add` of a commit on
  `origin/v2` that both CI runners passed (it refuses a dirty tree), with a toolchain the user installed outside
  `$HOME` (root's, decision 12) and a fresh package cache, records `swift --version` and `Package.resolved`'s hash in
  `build-info`, and the next install runs the previously installed build's script, not the working copy's.

**Why.** Sealed copies make "a file replaced on disk is never what the host runs next" true, where held `O_PATH`
descriptors and a dynamically linked runtime made it false; the static build is one flag and the toolchain already has
what it needs.

**Doesn't promise.**

- The install folder, `build-info`, the unit and its drop-ins, `environment.d` and the manager's environment are the
  user's to write before the sandbox; a host start a worker causes runs what they name (S2), and anything else the
  manager starts gets the manager's environment.
- What the install builds with, if the user keeps the toolchain in `$HOME`, and the package caches
  (`~/.cache/org.swift.swiftpm`, `~/.swiftpm`): a worker that patches the compiler, `swift-test` or a cached
  dependency makes every audit's and merge's tests pass and the next install build its code, which `build-info` then
  vouches for.
- The files every agent runs, the lead's included: `~/.vibeswitcher/bin/vibeswitcher-hook`, the agents' settings and
  hooks, `~/.local/share/claude/versions/*`, the shell startup files Claude Code's Bash tool sources. The config seal
  watches them (the bootstrap path's step 8 adds the Linux list: `~/.config/systemd/user`, `~/.config/environment.d`,
  `~/.config/autostart`, `~/.vibeswitcher/v2/projects`, `~/.vibeswitcher/v2/builds`, `~/.vibeswitcher/lead/run`,
  `~/.vibeswitcher/lead/git-hooks`, `~/.local/bin`, `~/.local/share/claude/versions`, the toolchain's `usr/bin`, every
  other user-writable folder on the unit's PATH, and, while `/mnt/c` is mounted, `.wslconfig` and the Windows Startup
  folder) and holds workers and merges once one changes: a detector at points in time, reset to "held until accepted"
  by a host restart.
- Signed releases (stage 8) are what make "what is installed is what was released" a lock.

**Before the bootstrap:** yes (sealed copies, the static build, the unit as above).

**Built in:** stage 2, Task 3 (sealed copies), Task 8 (the server from its copy), Task 9 (launcher, fallback, target
check, `build-info`, `--node`, `--node-root`), Task 10 (`Platform.Tools.git`); Task 11 (the keeper); the bootstrap
path's step 8 (the unit, the install script, the static build, the seal's list, the tool server's switch).

**Held by:** `MCPHandoverTests.aBuildReplacedDuringItsProbeIsNeverExecutedUnprobed`; planned: stage 2 plan task 3,
task 8, task 9.

**Tests to write:** Task 3: `ProcessSelfTests.aSealedCopyRunsAfterItsFileIsRewrittenInPlace`,
`aSealedCopysHashIsOfTheBytesItRuns`, `aPidsTokenIsItsPeerToken`. Task 8:
`ServerChildTests.aServerFileRewrittenInPlaceIsNotWhatRestarts`. Task 9:
`HostHardeningTests.aSessionStartedAfterTheHostsFileWasReplacedRunsThisBuild`,
`aFailedTakeOverGoesBackThroughTheSealedCopy`, `aFallbackImageRewrittenInPlaceIsNotWhatRuns`,
`anInstalledBinaryLoadsNothingFromAFolderTheUserCanWrite` (reads `/proc/<pid>/maps` of the host, server and parser),
`HandoverLinuxTests.aHandoverToAPathInsideAWorktreeIsRefused`, `aHandoverToABuildOutsideTheInstallFolderIsRefused`,
`aHandoverWhoseHashDiffersFromTheRecordIsRefused`, `aTargetRenamedOverAfterItsCheckIsNotWhatRuns`,
`aHandoverToAnInstalledBuildIsAllowed`, `aHostWhoseImageDiffersFromItsBuildInfoDoesNotStart`,
`aNewerBuildInfoFormatIsRefused`, `aScratchHostWithNoInstallRootHandsOverAsToday`,
`theNodesRootIsNeverFromTheEnvironment`. Task 10: `ToolsTests.theNodesGitIsNeverFromAFolderTheUserCanWrite`. Task 11:
`MCPKeeperTests.aToolServerFileReplacedWhileKeptIsNotWhatRestarts`. Step 8: `StartCommandTests` (the unit written,
`Restart=no`, `KillMode`, `UnsetEnvironment`, the PATH, the commit's folder), a write to each folder of the seal's
Linux list held, `anInstallFromADirtyTreeIsRefused`, `aToolServerSwitchesOnlyToTheBuildTheUserSwitchedTo`.

## S10. The sessions' environment

**Decision.** S2-D12, **extended by this document**. A platform answer (`Platform.Tools.sessionEnvironmentNames`,
`defaultLocale`). The Mac keeps today's list (`vibeswitcher-host/main.swift:27`) and today's login shell. On Linux:

- **Passed:** `HOME USER LOGNAME SHELL TMPDIR PATH LANG LC_ALL LC_CTYPE`. Not `XDG_RUNTIME_DIR` (no agent needs it,
  and it points at the gpg-agent, the bus and WSLg's sockets), never `SSH_AUTH_SOCK`, `WSL_INTEROP`,
  `DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, `WAYLAND_DISPLAY`, `PULSE_SERVER`, `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR`. A
  session's default `LANG` is `C.UTF-8`. A session's program starts with SIGPIPE at its default, though the host
  ignores it. The lead's session gets `VIBESWITCHER_CODEX_WORKERS=0` (decision 15) until Codex's sandbox is measured
  here.
- **A plain shell, not a login shell.** `HostedSession.arguments` starts every session as `$SHELL -l -i -c command`
  (`HostedSession.swift:117-120`); a login, interactive bash runs `.profile` and `.bashrc` and whatever they source
  (here, among others, a file in another repository and `mise activate`, which reads per-folder config from the
  worktree). On Linux team sessions start with `bash --noprofile --norc -c command`, with the PATH the unit holds;
  the Mac's reason for `-l -i` (Terminal's PATH) is met by that PATH.
- **What a spawn may add.** `SpawnRequest.env` from a caller that isn't the app may not set loader or shell-startup
  variables or any name in the "never" list above (`LD_*`, `BASH_ENV`, `ENV`, `SSH_AUTH_SOCK`, …); such a request is
  refused, saying which. On Linux only the app and a lead may spawn at all (S2).
- **A role's launch settings are given inline.** Today `LeadLaunch.prepare` writes a role's `mcp.json`,
  `settings.json` and `prompt.md` into `~/.vibeswitcher/lead/run/<key>/<name>/` (`LeadLaunch.swift:317-320`,
  `LeadVault.runFolder`), which a worker can rewrite between the write and `claude`'s read (the `Edit` deny rule
  doesn't bind Bash, and nothing watches the folder), making a verifier's `vibeswitcher` server its own script. On
  Linux the settings and the MCP config go to `claude` as JSON strings on its command line (`--settings`,
  `--mcp-config`; nothing secret in them); the prompt too, when it fits, else its file is named in S11. The folder goes
  on the seal's list as a detector.
- **The lead's accepted git hooks.** GitGuard runs the lead's git with `core.hooksPath` set to its accepted copy under
  `~/.vibeswitcher/lead/git-hooks/<key>/copy` (`Git.swift:77, 341-353`), which any worker can write; a hook placed
  there runs under the lead's tool server and is the lead's to the host. On Linux GitGuard checks the copy against the
  hashes the vault recorded at accept before each run, and refuses on a mismatch; the race between check and git's run
  stays (S11).

**(call) Linux's deny rules**, a platform answer added to `LeadLaunch.deny` for **every role, the lead included** (one
Non-seam edit; `LeadLaunch.swift` goes in Task 10's files): `strace`, `ltrace`, `gdbserver`, `perf`; `systemctl
--user`, `systemd-run`, `loginctl`, `crontab`, `at`; `wsl.exe`, `cmd.exe`, `powershell.exe`; `gh`, `git credential`,
`git -c credential*`; edits under `~/.config/systemd/**`, `~/.config/environment.d/**`, `~/.vibeswitcher/v2/**`,
`~/.vibeswitcher/lead/**`; reads and edits under `/mnt/c/**`. The Mac's `debuggers` list already holds `gdb`
(`LeadLaunch.swift:95`) and isn't in the lead's rules today (`LeadLaunch.swift:120-122`); on Linux the lead gets the
tracer rules too. They are Claude Code permission rules: they stop a slip (an agent "restarting the node to test it"
would end every session and the vault), not a worker that tries, and Codex has no per-session rules at all
(`LeadLaunch.codexUnenforced`).

**Why.** A session gets what it needs to run an agent and the user's tools, and not the user's keys to other systems.
Most of these are guard rails; the inline launch settings close a route that needed no ptrace.

**Doesn't promise.**

- Keeping a session away from the user's systemd: `systemctl --user` finds the manager at `/run/user/<uid>` with none
  of these variables.
- Keeping a session away from sockets found by path: the gpg-agent's ssh socket and its signing socket
  (`/run/user/<uid>/gnupg/`), the session bus (`/run/user/<uid>/bus`, libdbus's default address), WSLg's display and
  audio (`/tmp/.X11-unix/X0`, `wayland-0`, `/mnt/wslg`). Leaving the variables out stops a slip only. The user turns
  off the agent's ssh support or keeps no key cached during the bootstrap, and turns WSLg off (decision 9).
- Keeping a session away from Windows: the interop socket is found without `WSL_INTEROP` (`/run/WSL/1_interop`), and
  `/mnt/c` is mounted for everyone, until decision 2 turns them off.
- Keeping credentials away: whatever the user keeps in files (`gh`'s token, git's credential store, cloud tools' keys,
  `~/.gnupg`, the agents' own logins in `~/.claude` and `~/.codex`) is a worker's to read and use (S11).
- What Claude Code itself does with the user's shell: its Bash tool takes a snapshot of the user's shell
  configuration, so the startup files still run inside a session's agent. Task 12 measures it.
- Codex's sandbox (Landlock and seccomp) on this WSL kernel: unmeasured, so Codex workers are off (decision 15).

**Before the bootstrap:** yes.

**Built in:** stage 2, Task 10 (names, plain shell, spawn's env, deny rules, inline launch settings, GitGuard's
check); Task 12 (the measurements).

**The user confirms:** decision 9 (the gpg-agent's ssh support off or no key cached, WSLg off, during the bootstrap).

**Held by:** planned: stage 2 plan task 10.

**Tests to write:** Task 10: `SessionEnvironmentTests.aLinuxSessionGetsNoAgentSocketNoInteropNoBus`,
`aLinuxSessionGetsNoRuntimeDir`, `aTeamSessionRunsNoShellStartupFile`, `aSpawnAddingALoaderVariableIsRefused`,
`aSessionsProgramStartsWithSIGPIPEAtItsDefault`, `ToolsTests.theLocaleASessionGetsIsInstalled`, `theMacsListIsTodays`,
`LeadLaunchTests.aRoleOnLinuxIsDeniedTracersTheUsersManagerWindowsAndGh`, `theLeadOnLinuxGetsTheTracerRules`,
`theMacsDenyRulesAreTodays`, `aRolesLaunchSettingsAreInlineOnLinux`, `GitGuardTests.aChangedHooksCopyIsRefused`.
Task 12: `RealClaudeTests.whatClaudesBashToolSourcesIsMeasured`, `aVerifierCommandInItsOwnSessionStillTimesOut`.

## S11. What plain mode doesn't promise on Linux

**Decision.** This list is written down, shown in short by `status` on a standing plain-mode line (and by `doctor`
after the bootstrap), printed once by `start` with an acknowledgment recorded, and put to the user before the
bootstrap as part of S2-D1. It holds until the sandbox (S12) closes each item, and stage 6's attack passes or fails
against it. Each line says what reduces it now, if anything.

**One step from root**

1. While WSL interop is on, any process of any Linux user runs Windows programs and `wsl.exe -u root`; root then
   reads every process's memory, so **every lock in this document is void**. The user's `sudo` used in this
   distribution (a worker ptraces the user's shell and rides its ticket, or reads the password from the terminal), and
   a docker socket if one appears, are steps too. Reduced by decision 2 (interop off, automount off, no `sudo` here
   while a team runs); `start` refuses with interop on unless told, and `status` says it. S1.
2. While `/mnt/c` is mounted, the Windows side lasts past the session, the host, the distribution and a reboot: a
   worker writes `.wslconfig`'s `kernel=` (the next WSL boot runs its kernel) or a program into the Windows Startup
   folder (it runs at the next Windows login, and can run `wsl -u root`). Reduced by automount off (decision 2); the
   seal watches both while mounted, and `status` reports a `kernel=` line.

**Becoming the host**

3. A worker can restart the host at will (a signal; `systemctl --user stop|start|restart`), after editing what the
   restart runs: the unit, its drop-ins, `environment.d`, the install folder and `build-info`, and what the install
   builds with (the toolchain and package caches, if the user's). The restarted host and its server are then the
   worker's. Reduced by `UnsetEnvironment=` (the manager's environment no longer reaches the host), the commit-folder
   `ExecStart`, the start check (a slip caught), the seal (a detector) and the journal's record of starts no
   `vibeswitcher start` explains, which the command line reads itself. S2, S9.
4. The host's own start by systemd runs the installed, readable file: dumpable until its first statement, so a worker
   that waits for a start (one it caused, or the user's) can ptrace it and own it. S6.
5. A worker can put its own socket at the host's path: sessions' tool servers and hooks reach it until the host binds
   the path again (seconds). The server is unaffected (its connector). No more than ptrace of those sessions gives.
   S2.

**Acting as a session**

6. A worker can act as any session, the lead and the verifiers included: ptrace of a session's agent or tool server,
   or `pidfd_getfd` of its descriptors, puts it inside that session. So it can call the lead's tools or cast a
   verifier's ballot: verdicts and merges are guard rails. S4.
7. Routes into a role that need no ptrace: a role's prompt file while it is still a file (S10); the lead's accepted
   hooks copy, swapped between GitGuard's check and git's run; a build renamed over `vibeswitcher-mcp` that a running
   tool server switches to (reduced by the switch rule, S9); branch code rewriting its bash wrapper's argv (S4).
8. A worker can replace what every agent runs (the hook, the agents' settings and hooks, `claude`'s versions, the shell
   startup files Claude Code's Bash tool sources, folders on the PATH). The seal detects it at its next look and holds
   workers and merges; a change swapped in and restored between two looks is missed; a host restart resets the seal to
   "held until accepted". The Linux list (`~/.local/share/claude/versions` and the rest) arrives with the bootstrap
   path's step 8. S7, S9.
9. A worker can move the lead's base branch through the main checkout's shared `.git` (worktrees, not clones, until
   S2-D10's clones). The vault's head record and `judge` catch it; after a host restart `base accept` shows the
   commits since the last accepted head. S7.
10. Branch code (merge's tests, an audit's run, `init_command`) runs as the user, unconfined, with the user's
    toolchain: a worker that replaces `swift-test` or patches a cached dependency makes every audit and merge pass. It
    is no session's to the host, and can do everything in this list. Reduced for installs by a root-owned toolchain
    (decision 12), not for tests.
11. Writing a terminal query to a session's `/dev/pts/N` makes the host type the headless terminal's reply into that
    session (an escape sequence, ESC included): it can interrupt the lead's turn. The reply grammar keeps it to
    replies. S6.
12. A worker turns the lead or a verifier with text it writes, with no OS access (S1, item 3). The floor, the user's
    approvals for sensitive paths, and `audit_finders` of 2 or more on another model hold; decision 13 sets them for
    the bootstrap.

**Acting as the user, or deceiving the user**

13. The user's voice, after the cgroup rule (S3): ptrace of the user's shell or command line (both dumpable, in
    `/init.scope`); the user's own Claude Code turned by text the worker wrote (it passes the rule; the typed word and
    the user's deny rules are guard rails, decision 14); WSL interop while on; `ssh localhost` if an ssh server runs.
    Each user's-voice request is in the journal and shown by `status`.
14. The user's own processes acting for a worker: a `vibeswitcher` or `systemctl` earlier on the user's PATH, an alias
    in a shell startup file, and the user's terminal (`/dev/pts/N` is the user's: a worker can draw text the user didn't
    run, and race the shell for the user's keys and passwords). Reduced by running the command line by its absolute
    path (defeats PATH only).
15. A worker can replace the command line's binary in the install folder, so that what the user reads and sends goes
    through the worker. The seal watches the builds folder, shown through the command line itself. S3.
16. Another session's terminal (`/dev/pts/N`) is the user's to open, read and write. With WSLg on, a worker can open a
    window on the Windows desktop, styled as anything, asking for a password (decision 9 turns WSLg off).
17. Text the user reads: the lead's questions are the lead's to word; reports, records and commit messages are
    workers'. Approval cards are built from git and the vault and bound to their id (S3); `board.json` is never read
    back as a question.

**Reading what the user can read**

18. Every file of the user: the agents' logins (`~/.claude`, `~/.codex`), `gh`'s token (which pushes to the user's
    repositories, VibeSwitcher's `main` included, decision 11), `~/.gnupg`, cloud keys, other repositories, `/mnt/c`
    while mounted, and later the browser's profile (item 31). With no egress proxy, the network is open for sending
    them anywhere.
19. Sockets by fixed path under `/run/user/<uid>`: the gpg-agent (ssh and signing), the session bus; WSLg's display and
    audio. Leaving `XDG_RUNTIME_DIR` out stops slips only (S10, decision 9).
20. `/proc/<pid>/environ` and `cmdline` of the user's dumpable processes; `cmdline` of every process to every user,
    including the inline launch settings (nothing secret in them).
21. `SCM_CREDENTIALS` names no reader: whoever holds a connection's descriptor reads its replies.
22. With mirrored networking, every Windows-side localhost service (a browser's debugging port, Docker Desktop's API,
    dev servers) is reachable from every session.

**Lasting past the session**

23. A worker can make code run later as the user: the user's crontab (`/var/spool/cron`, which the seal's file reads
    can't reach; only `crontab -l` shows it), systemd user units and timers, `~/.config/autostart`, shell startup
    files, `environment.d`, the manager's environment (`systemctl --user set-environment`, no file; `start` and
    `status` compare it with the expected set), the Windows side (item 2). The seal watches the files. Under
    `KillMode=control-group` an escaped process still in the unit's cgroup ends with the host; one started through
    `systemd-run`, `at` or cron doesn't, and the orphan sweep ends only tool servers.
24. A session can run its own scratch host (`--lock` elsewhere): it has no allow-list and accepts the test flags, so a
    worker can point agents at any repository. The allow-list is a guard rail for that reason too. The real-agent
    config folder is passed per run, never in a startup file (decision 16), so a gate's tests never start real agents.

**Denial of service**

25. Signals: a worker can stop or kill the host, the server, the parsers. A killed host stays down until the user's
    `start` (`Restart=no`), every session ends with it (`KillMode=control-group`), and the vault is lost (S7). An OOM
    kill does the same; children's `oom_score_adj` makes the host and server the last picked. The journal says how the
    host ended.
26. A worker can fill the host's 128 client slots (`maxClients`, counted before identity), refusing every new
    session connection; the app's connector connections aren't counted (S2).
27. A host restart erases the team's state and asks the user for `config accept` and `base accept` before `lead`
    (S7).

**Records and logs**

28. The host's and the tool servers' logs aren't yet checked for tokens, codes and terminal text (a lint after the
    bootstrap). What the host and the server write to stderr reaches the user journal, readable by the `adm` group: no
    answer text, goal or screen content goes there. Records in `docs/lead-v2/` are the user's files and a worker's to
    edit; merge takes the base's copy.
29. Delivery records for steer messages (`<tty>.delivered`, `handedOver`) are outside the seal: a worker that copies
    the user's earlier sealed message back into the lead's inbox gets it delivered again, verified as the user's,
    until E6 consumes `.user` message ids in the vault on Linux.
30. Until the handover through sealed memory is built (Task 9), nothing; after it, no handover state on disk. A stale
    Mac-format file is removed by a fresh host (S8).

**Later, noted now**

31. **The browser's storage.** Requirement 1 says a paired browser holds a key that "can't be read out of it". A
    WebCrypto key made non-extractable can't be read by script, but as far as is known Chrome keeps it in the
    profile's IndexedDB files on disk, which on WSL are under `/mnt/c` for any process of the user. Approvals that
    need the person's presence (a security key or the platform authenticator, WebAuthn) don't have this hole. Stage 4's
    design checks it before approvals rest on browser keys.

**The project allow-list (S2-D11)** is what makes this list acceptable before stage 6: in the user's host on Linux a
`spawn` whose working folder isn't inside an allowed repository is refused, saying why. The list is
`~/.vibeswitcher/v2/projects`, one path a line, written by the user. A folder is inside an allowed repository when it
is the repository or one of its worktrees, found by reading files, never by running git in a folder a worker controls:
its `.git` file's `gitdir:`, that folder's `commondir`, and the allowed repository's `.git/worktrees/*/gitdir`
pointing back at the folder. `HostServer.Config.projectAllowList` is nil by default (the Mac's and every scratch host's
behaviour). The list goes when the user marks stage 6 passed. It is a guard rail: the file is the user's to edit, so a
worker can add a line; a worker can also write both halves of the worktree check (an entry in the allowed repository's
shared `.git/worktrees` and a `.git` file in any folder), and the pair passes; and a session can run a scratch host
with no list (item 24).

**What still holds against a worker that tries, before the sandbox**, only while nothing is one step from root
(item 1: interop off, no docker socket, no `sudo` used here while a team runs): another user is refused at both
sockets; the host, the server and the parsers are non-dumpable from their exec, so their memory and descriptors are
out of reach, except in the host's own start by systemd (item 4), and if Task 3's measurement holds; only the server
child's connections are the app (S2); a connection a worker writes on stops being anyone's (S5); a handover's state
and secrets are never on disk (S8); nothing the host starts runs a file changed after the host loaded it, or loads a
library from a folder the user can write (S9); an escape from a session is never the user's voice (S3); a crash of
the host or the server writes no dump. **While interop is on, none of these holds**, and plain mode on this machine
has no lock at all.

**Why.** Requirement: "a security property that holds on the Mac and silently doesn't on Linux" is an anti-goal. This
list is the "not silently".

**Doesn't promise.** That the list is complete: stage 6's attack and the review of this document add to it.

**Before the bootstrap:** yes (the list itself, the allow-list, the plain-mode line in `status`).

**Built in:** this document; the allow-list in stage 2, Task 10; `status`'s line and `start`'s print in the engine
plan's E1; `doctor`'s summary after the bootstrap.

**The user confirms:** the allow-list's place, and that the user (not an agent) writes its one line for the bootstrap
clone.

**Held by:** planned: stage 2 plan task 10.

**Tests to write:** Task 10: `ProjectAllowListTests.aSpawnOutsideTheListIsRefusedWithItsReason`,
`aWorktreeOfAnAllowedRepositoryIsAllowed`, `aForgedGitFileIsRefused`, `aForgedWorktreePairPassesAsKnown`,
`aScratchHostHasNoList`, `aMissingListRefusesEverySpawnAndSaysWhereTheListGoes`, `noGitRunsInTheHost`.

## S12. After the bootstrap

**Decision.** The lead's own early work, in this order, each closing items of S11. The handover through sealed memory,
the unreadable images and the static build, which the plan had here, are before the bootstrap now (S6, S8, S9).

1. **The sandbox through the shim** (`unshare` or `clone3` with new user, mount, pid, IPC and network namespaces;
   `pivot_root`; a devpts of its own with only the session's slave passed in), not bubblewrap, which isn't installed
   and an agent may not install. No uid 0 mapped inside, every capability dropped, `no_new_privs` set. Every worker,
   verifier and run of a branch's tests gets one; the lead one of its own, narrower; a verifier is never in the sandbox
   of the code it judges. Inside, a team session doesn't see `~/.vibeswitcher`, `/run/user/<uid>` (the manager, the
   gpg-agent, the bus), `/tmp/.X11-unix`, `/mnt/wslg`, other sessions' processes, `/mnt/c`, `/init` and `/run/WSL`
   (interop), or a docker socket; the agents' binaries and config, the toolchain, the package caches, the shell
   startup files and every user-writable folder on its PATH are read-only. Its own pid namespace ends ptrace of
   anything outside it, and in it the host can be the subreaper (S2-D6). Closes 3, 5 to 10 (10 for test runs), 13 (the
   escapes), 14 to 16, 18 and 19 (the reading half), 20, 23 and 25 for confined sessions. It doesn't close item 12
   (text), and it doesn't keep unconfined processes of the user out of a sandbox (S4, S5).
2. **The session's identity**: the inherited connector, or the sandbox's pid namespace, after the measurement (S4).
   Closes pid reuse for sessions (S5).
3. **Clones for workers** (S2-D10), the result fetched as one ref. Closes 9.
4. **The egress proxy**, refusing the tailnet, loopback (including the Windows side under mirrored networking) and
   cloud metadata addresses. Closes the sending half of 18 and closes 22.
5. **Strong mode**: the vault's key file; the AppArmor profile that allows unprivileged user namespaces on Ubuntu 24.04
   bare metal (`kernel.apparmor_restrict_unprivileged_userns=1` there; installed by the release, stage 8). Closes 27.
6. **`SO_PEERPIDFD` and `SCM_PIDFD`** where the kernel has them (S5).
7. **The logs' lint**. Closes 28.
8. **`vibeswitcher attach ID`**, through the server.
9. **The design's stage 2 Done-when, second half**: from inside a confined session, another session's screen, the
   node's state and the host's memory are all refused.
10. **A hardened branch-code wrapper**: a non-dumpable mode of the tool server's image instead of bash, so its argv
    can't be rewritten (S4).
11. **Signed approvals** (stage 4), with the person's presence for pairing, Push, wallet and guarded settings (item 31).
    Closes 13 to 15 and 17 for approvals.
12. **Signed releases** (stage 8). Closes the replacement half of 3 for installs.
13. **The support matrix rows** say which mode each environment gets.

**Why.** Confinement is what turns S11 from a list of what a worker can do into a list of what a confined worker
can't, and it needs the bootstrap's lead to build it.

**Doesn't promise.** Anything for a session the user runs unconfined (a project can, and says so on every card), or on
a machine with no user namespaces (plain mode, said plainly); anything against a lead or verifier turned by text
beyond the floor and approvals; anything while interop is on.

**Before the bootstrap:** no.

**Built in:** after the bootstrap, by the lead, each with a plan of its own.

**Held by:** planned: stage 2 plan, After the bootstrap (its list, renumbered to match this one; see Changes the stage
2 plan needs).

**Tests to write:** with each item's plan; the first is
`aConfinedSessionCantReadAnotherSessionsScreenTheNodesStateOrTheHostsMemory`.

## Threats

Each row: the attack, whether it works before the bootstrap, what limits it now, and what closes it. "Works" means for
a worker that tries; every row is refused or caught for a worker that slips unless it says otherwise. A row marked
**†** holds only while nothing is one step from root (S11, item 1); with interop on, it works.

| # | Who | Attack | Before the bootstrap | What limits it now | Closed by |
| --- | --- | --- | --- | --- | --- |
| T1 | worker | ptrace the lead's agent or tool server; call `merge`, `start_worker`, the vault's lead requests | works | allow-list (VibeSwitcher's repo only); deny rules for tracers (slips) | sandbox (S12.1) |
| T2 | worker | ptrace a verifier's tool server; cast a pass | works | as T1; `audit_finders` 2 on another model makes it two attacks | sandbox |
| T3 | worker | edit the unit, its drop-ins or the install folder, then restart the host | works | `UnsetEnvironment=`; commit-folder `ExecStart`; start check vs `build-info` (slip); seal; journal shows the unexplained start | sandbox; signed releases |
| T4 | worker | kill the host | works (DoS; every session and the vault lost) | `Restart=no`; the extended first look; `lead` refused until `config accept` and `base accept`; journal says how it ended | strong mode's key file |
| T5 | worker | kill the server; seize the restarted child before it hardens | refused † (sealed `0111` copy, if measured) | non-dumpable from exec | holds † |
| T6 | worker | rename a build over `vibeswitcher-mcp`; tool servers switch to it, or the keeper restarts it | switch: works (guard rail); keeper: refused | switch only to `current` with a matching hash; keeper's sealed copy | sandbox (install folder read-only) |
| T7 | worker | replace the hook, the agents' settings, `claude`, shell startup files, a PATH folder | works, caught at the seal's next look (swap-and-restore missed) | config seal holds workers and merges | sandbox |
| T8 | worker | bind its own socket at the host's path | fools sessions for seconds; the server never sees it | host binds the path again (folder watch); server's connector | sandbox (no `~/.vibeswitcher`) |
| T9 | worker | bind its own socket at the server's path, directly or from a program it had the host spawn | refused † | the command line's check (non-dumpable listener, the unit's cgroup, child of `MainPID`); `spawn` only from the app and a lead | holds †, short of T3 |
| T10 | worker | escape its session (double fork, `setsid`, `systemd-run`, `at`, cron) and send `answer`, `config accept` | refused | the cgroup rule (S3) | holds; signed approvals |
| T11 | worker | drive the user's shell or command line (ptrace, `/dev/pts`, PATH, aliases) | works | absolute path (PATH only); journal echo | sandbox; signed approvals |
| T12 | worker | replace the command line's binary | works | seal watches the builds folder (shown through the command line itself) | sandbox; signed releases |
| T13 | worker | pid reuse to pass as the app | refused | app connections are made through the connector | holds |
| T14 | worker | pid reuse to pass as another session | works | dominated by T1; program matched by token (Task 6) | connector or pid namespace |
| T15 | worker | duplicate the host's descriptors in a handover's exec window | refused † (sealed copies, if measured) | rule on switches until measured | holds † |
| T16 | worker | forge, spoil or read the handover state | refused | no file: sealed memory | holds |
| T17 | worker | have the host hand over to a build in its worktree, or swap the target after its check | refused | install root; hash of the sealed copy that runs | signed releases (for what the install folder holds) |
| T18 | worker | fork or pass a lead's connection to another process and write on it | refused † | per-message credentials | holds † |
| T19 | worker | read or take the host's, the server's or a parser's memory or descriptors | refused †, except in the host's start by systemd | non-dumpable from exec; close-on-exec from creation | holds † |
| T20 | worker | read or write another session's `/dev/pts/N`; a query written there for the host to answer into the session | works | reply grammar (replies only) | sandbox's own devpts |
| T21 | worker | read the user's credentials, `~/.gnupg`, the agents' logins, `/mnt/c`; send them out | works | automount off (decision 2) | sandbox; egress proxy |
| T22 | worker | run Windows programs; `wsl.exe -u root` | works while interop is on; refused with it off | decision 2; deny rules for `wsl.exe`, `cmd.exe`, `powershell.exe` (Claude Code, slips). Leaving `WSL_INTEROP` out limits nothing | interop off; sandbox |
| T23 | worker | persist: crontab, user units and timers, autostart, shell startup files, `set-environment`, `.wslconfig`'s kernel, the Windows Startup folder | works | seal watches the files (not the crontab); `start` and `status` compare the manager's environment; automount off | sandbox |
| T24 | worker | move the lead's base branch through the shared `.git` | caught; after a host restart, shown by `base accept` | vault's head record and `judge`; `base accept`'s log since the last accepted head | clones |
| T25 | worker | spawn a session in another repository | refused (guard rail) | allow-list; a forged worktree pair passes; a scratch host has no list | stage 6; sandbox |
| T26 | branch code | merge's tests or an audit's run do any of the above; a patched toolchain passes every test | works | no session's to the host; root-owned toolchain for installs | sandbox for test runs |
| T27 | worker | `LD_PRELOAD` and its kin into the host | refused for the unit's start | `UnsetEnvironment=`; static build | holds for the host; works for anything else the manager starts |
| T28 | worker | fill the host's client slots; `SIGSTOP` the host | works (DoS) for sessions | app's connector connections uncounted | — |
| T29 | worker | write a role's launch files, the lead's hooks copy | launch settings: refused (inline); prompt file and hooks copy: works, narrowed | inline settings; GitGuard's hash check (race); seal detects | sandbox |
| T30 | worker | get a host or server crash dump | refused † | non-dumpable; `suid_dumpable` 0 | holds † |
| T31 | another user | connect to the host's or the server's socket | refused † | uid at accept; 0600 in 0700 | holds † (interop's sockets are 0777) |
| T32 | another user | read command lines of the user's processes | works | none (no `hidepid`); nothing secret in them | not promised |
| T33 | root, Windows side | anything | works | none | not defended |
| T34 | worker | turn the lead or a verifier with text it writes | works | floor (app-only); approvals for sensitive paths; `audit_finders` 2 on another model (decision 13) | not by confinement; signed approvals for the user's part |
| T35 | worker | have a fresh vault take worker-written `workflow.md`, floor, checkout hooks or head as its baseline | held | extended first look; values shown; `lead` refused until accepted | strong mode |
| T36 | worker | push to GitHub (`main`, tags) with the user's `gh` token; a CI workflow change merged and pushed | works unless the token is narrowed | decision 11 (narrow token, protected branches); deny `gh` (slips); `.github/**` sensitive | the user's decision |
| T37 | worker | turn the user's own Claude Code with planted text; it sends the user's-voice request | works | typed word on a terminal (guard rail); deny rules in the user's Claude Code (decision 14) | signed approvals |
| T38 | worker | get a genuine approval for its commit through a card it wrote on the board | refused | cards built from git and the vault, bound to their id | holds |
| T39 | worker | open a window on the Windows desktop asking for a password | works while WSLg is on | decision 9 | sandbox |
| T40 | worker | reach Windows-side localhost services (mirrored networking) | works | none | egress proxy |
| T41 | worker | replay a sealed message of the user's into the lead's inbox | works until E6 | none | E6 (ids consumed in the vault) |
| T42 | worker | take a new session's terminal before its launcher does | refused (Task 6) | launcher checks `TIOCSCTTY`; host checks `TIOCGSID` | holds |

## The Mac and Linux

| Matter | The Mac (today, unchanged on `v2`) | Linux (version 2, before the bootstrap) | What follows |
| --- | --- | --- | --- |
| Who is the app | the app's code (cdhash beside the host) answering a challenge with an HMAC under the app's key | the connections the host makes for its server child through the child's inherited connector; no key | a replaced file never makes anyone the app on the Mac; on Linux a host start the worker causes does (S2) |
| Who is on the other end | audit token, `LOCAL_PEERTOKEN`, names the last sender; an exec changes it | `SO_PEERCRED` at accept, `SCM_CREDENTIALS` per read, start ticks from `/proc`; an exec doesn't change it; a pid number can be reused | S5 |
| Another process's memory | `task_for_pid` rules; Hardened Runtime; debuggers ask for a password | any dumpable process of the user (no Yama); host, server and parsers non-dumpable from their exec (sealed copies), the host's own start excepted | sessions are open to each other on Linux (S4, S11) |
| Root one step away | an admin password | WSL interop without one, while on; `sudo`'s ticket | S1; decision 2 |
| Library injection | Hardened Runtime refuses `DYLD_*` | `UnsetEnvironment=` in the unit; static build | S9 |
| Libraries loaded at start | the app bundle's, signed | the C library from `/lib` only (static build) | S9 |
| The vault across a restart | sealed on disk under a Keychain key; survives | memory only; lost; a fresh vault holds every record's first look, and `lead` waits for the user's accept | S7 |
| The config seal across a restart | survives | reset to "held until accepted" | S7 |
| What the host executes | private launcher copies under `~/.vibeswitcher/host` | sealed `0111` copies in memory, loaded and hashed at its start | S9 |
| Handover target | any executable the app names | in the user's host, an installed build whose sealed copy's hash matches `build-info` | S9 |
| Handover state | a file, trusted as written; secrets through a socket channel | sealed memory, inherited; no file | S8 |
| Who starts the host | the app | `vibeswitcher start`, a user unit with `Restart=no`, `KillMode=control-group` | S9 |
| A host exit | sessions outlive it, losing their terminal | every session ends with the unit | S9, S11 |
| An orphan's new parent | launchd (pid 1) | the user's systemd (a subreaper), found by a probe | S2-D6 |
| A session's terminal name | `ttys003` | `ttypts3` | S4 |
| The sessions' environment and shell | today's list, `SSH_AUTH_SOCK` included; `en_US.UTF-8`; login shell | no agent, bus, display or runtime-dir variables; `C.UTF-8`; `bash --noprofile --norc` | S10 |
| git | `/usr/bin/git` | the first `git` in a root-owned folder | S9 |
| The user's answers | the app's window | the command line, by the user's-voice rule with the cgroup check and a typed word | S3 |
| A socket squatted at the host's path | the app trusts any host there, and gives its key to one that says it holds none (`enrollApp`) | the server never uses the path; sessions as on the Mac until the host binds again | a line for `docs/process/v2-mac-tasks.md`; not changed from here |
| A verifier's commands | the wrapper isn't in a session of its own (`runPrefix`) | `setsid` before the exec | a line for `docs/process/v2-mac-tasks.md` |
| Signals | any process of the user | the same | DoS on both |

## What proves each promise

The tests by promise. "Now" are tests that exist (on the Mac today; on Linux once Task 5b runs them there); the rest
are written in the task named.

| Promise | Tests | When |
| --- | --- | --- |
| Only the server child's connector connections are the app on Linux; no path connection is | `HostIdentitySeamTests.aConnectorConnectionIsTheAppWithNoChallenge`, `noConnectionByPathIsTheAppOnLinux`; `ServerChildTests.theServerChildsConnectorConnectionsAreTheApp`, `aConnectionFromAnotherProcessIsNotTheApp`, `aChildOfTheServerIsNotTheApp`, `aServerChildThatIsDumpableIsNotTheApp`, `theServerIsStartedAgainAfterItDies` | Tasks 4b, 8 |
| The Mac's app check is untouched | `HostIdentitySeamTests.theMacsAppIsStillTheCdhashCheck`, `ServerChildTests.theMacStartsNoServerChild`, Task 5a's `theMacsTestHostHasNoPrincipal`; the app job's eleven files unchanged; `LeadVaultHostTests.aConnectionWhoseProcessExecsTheAppIsntTheApp` (now) | Tasks 4b, 5a, 8 |
| A squatted host path is bound again; starts and restarts are in the journal | `ServerChildTests.aSquattedHostPathIsBoundAgain`, `theHostWritesStartsAndServerRestartsToStderr`; E8's `aStartTheUserDidntMakeIsShownUntilAcknowledged` | Task 8, E8 |
| A message from another sender makes a connection nobody's | `SocketsTests.eachMessagesSenderIsTheProcessThatWroteIt` (now); `PeerPerMessageTests.*`; `SocketsTests.bytesFromAReapedSenderComeWithNoSender`, `aSenderCannotClaimAnotherPid`, `aSenderInItsOwnPidNamespaceCanNameOnlyItsOwnProcesses` | Task 7 |
| Sessions reach only themselves, what they started and (a lead) their team | `LeadVaultHostTests.aWorkerCanReadItselfButCannotReadOrTypeIntoItsLeadOrAnotherProject`, `aLeadCanReadAndTypeIntoItsWorkerButCannotAccessAnotherProject`, `aWorkersShellCantGiveAVerdictSealAsTheUserOrTypeIntoTheLead`; `HostSecurityHardeningTests.unknownClientsCannotReadMutateOrSubscribeToSessions` (now); an unknown process's vault requests (Task 5b, new) | on Linux in Task 5b |
| Branch code is no session's | `VerifierBranchCodeHostTests.aVerifiersBashCantSubmitItsVerdictAndItsToolServerStillDoes` (now); `anEscapedVerifierCommandWithoutSetsidIsNobodys` | Task 5b, Task 10 |
| A session's terminal is named as the table names it, and is its own from the start | `HostedSessionTerminalTests.*` | Task 6 |
| Host, parsers, server, probe and handover images are non-dumpable from their exec | `ProcessSelfTests.aHardenedProcesssMemoryCantBeOpened`, `aHardenedProcesssDescriptorsCantBeTaken`, `aChildStartedFromASealedCopyIsNotDumpableFromItsExec`; `HostHardeningTests.theHostIsNotDumpableAfterStartAndAfterAHandover`, `aParserIsNotDumpable`, `aHandoverImageIsNotDumpableFromItsExec`, `aTracedNewImageGoesBackWithoutTheVault`; `ServerChildTests.theServerHelperIsNotDumpable`; E1's `theServerIsNotDumpable` | Tasks 3, 8, 9; E1 |
| No descriptor leaks into a child | `CloseOnExecLintTests.noBareSocketAcceptOrOpen`, `HostServerTests.aSpawnDuringAnAcceptInheritsNoConnection` | Task 4a |
| A parser types only replies | `ParserReplyTests.*` | Task 9 |
| Nothing secret in argv or environment | `HostHardeningTests.nothingSecretIsInTheHostsArgumentsOrEnvironment` | Task 9 |
| Nothing the host runs comes from a file changed after it loaded it, or from a folder the user can write | `ProcessSelfTests.aSealedCopyRunsAfterItsFileIsRewrittenInPlace`; `ServerChildTests.aServerFileRewrittenInPlaceIsNotWhatRestarts`; `HostHardeningTests.aSessionStartedAfterTheHostsFileWasReplacedRunsThisBuild`, `aFailedTakeOverGoesBackThroughTheSealedCopy`, `aFallbackImageRewrittenInPlaceIsNotWhatRuns`, `anInstalledBinaryLoadsNothingFromAFolderTheUserCanWrite`; `MCPKeeperTests.aToolServerFileReplacedWhileKeptIsNotWhatRestarts` | Tasks 3, 8, 9, 11 |
| The user's host hands over only to an installed build whose hash matches, and runs what it checked | `HandoverLinuxTests.aHandoverToAPathInsideAWorktreeIsRefused`, `aTargetRenamedOverAfterItsCheckIsNotWhatRuns` and the five beside them | Task 9 |
| A handover writes no file and keeps the vault on fallback | `HandoverLinuxTests.aHandoverWritesNoFile`, `theStateAndSecretsAreSealed`, `aFallbackAfterAFailedRestoreKeepsTheVault`, `aFallbackAfterAFailedRestoreKeepsEverySession`, `aDowngradeIsRefused`, `theUsersHostIgnoresTestSecretFlags`; `HostHandoverStateTests.aStateOfAnotherFormatIsRefused` (now) | Tasks 8, 9 |
| No switch while a worker or verifier runs, until measured | `aSwitchWhileAWorkerRunsIsRefused` | step 8 |
| A fresh memory vault takes nothing as baseline a worker could write | `ConfigSealFirstLookTests.*`; E4's `aLeadIsRefusedOnAFreshVaultUntilAccepted`; E8's `configAcceptSealsOnlyWhatItShowed`, `baseAcceptAfterARestartShowsWhatMoved` | Task 10, E4, E8 |
| Sessions get no agent socket, interop, bus or runtime dir, and run no startup file | `SessionEnvironmentTests.*` | Task 10 |
| Roles on Linux, the lead included, are denied tracers, the user's manager, Windows and `gh` (slips) | `LeadLaunchTests.aRoleOnLinuxIsDeniedTracersTheUsersManagerWindowsAndGh`, `theLeadOnLinuxGetsTheTracerRules`, `theMacsDenyRulesAreTodays` | Task 10 |
| A role's launch settings aren't files | `LeadLaunchTests.aRolesLaunchSettingsAreInlineOnLinux` | Task 10 |
| A spawn outside the allow-list is refused, and the check runs no git | `ProjectAllowListTests.*` | Task 10 |
| Only the user's voice changes state through the server; escapes are refused | E1's, E4's, E6's and step 8's tests (S3) | engine plan |
| The tool server switches only to the build the user switched to | `aToolServerSwitchesOnlyToTheBuildTheUserSwitchedTo` | step 8 |
| A fresh `--app-executable` grants nothing; the server child's stand-in grants nothing to others | `host-access.test.mjs`, with its Linux case | Tasks 5b, 8 |
| The document stays true to the tests | `SecurityDocumentLintTests.*` | Task 1 |

All of these can be written on Linux. Six run only in the macos job: `theMacsAppIsStillTheCdhashCheck`,
`theMacStartsNoServerChild`, `theMacsTestHostHasNoPrincipal`, `hardeningIsNothingOnTheMac`, `theMacsListIsTodays`,
`theMacsDenyRulesAreTodays`.

## Decisions

### Awaiting the user

Put once, together with the bootstrap path's questions ([What the user is asked](../plans/2026-11-13-v2-bootstrap-path.md#what-the-user-is-asked)).
Each has the recommendation; the answers go into the design's Decided section before Task 2.

1. **S2-D1, the app on Linux, and the residual list (S2, S11).** Recommended: accept that until signed approvals the
   app is the host's server child, reached through its inherited connector, and accept S11's list in full while the
   only project is VibeSwitcher's own and interop is off. The list is longer than the plan's: it adds the routes into
   a role that need no ptrace (S10), the parser's reply loop, the user's own shell and Claude Code as the user's
   voice, the scratch host with no list, and the turned lead or verifier (S1).
2. **New: nothing one step from root during the bootstrap (S1, S11 items 1 and 2).** Recommended: the user sets
   `[interop] enabled=false` and `appendWindowsPath=false`, and `[automount] enabled=false`, in `/etc/wsl.conf`, then
   runs `wsl --shutdown`; doesn't use `sudo` in this distribution while a team runs (or sets
   `Defaults timestamp_timeout=0`); keeps Docker's daemon off. Cost: no Windows programs and no `/mnt/c` from Linux
   for the bootstrap's length (links aren't opened in the Windows browser; files cross through the Windows side's
   `\\wsl$`). Without interop off, plain mode on this machine has no lock at all, and `start` refuses unless told
   `--interop-is-on`. If the user keeps automount on, the seal watches `.wslconfig` and the Startup folder as a
   detector and `status` reports a `kernel=` line.
3. **S2-D3, the vault in memory only (S7), with the extended first look.** Recommended: accept that a host restart
   ends the team, and that after every host restart the user runs `config held`, `config accept ID` and `base accept`,
   reading the values shown, before starting the lead again.
4. **S2-D6, no subreaper before the bootstrap (S3), now with the cgroup rule.** Recommended: accept. Escapes from a
   session are refused; what remains is ptrace of the user's own shell and the user's own Claude Code (decision 14).
5. **S2-D8, changed: the handover through sealed memory before the bootstrap (S8).** Recommended: accept. It replaces
   "the state file checked by its hash", removes the file (forging, spoiling, reading and stale copies), and keeps the
   vault on a fallback.
6. **No switch of builds while a worker or verifier runs, until Task 3's measurement passes (S8).** Recommended:
   accept. It costs switching between tasks rather than during them.
7. **S2-D9, sessions identified by an inherited socket after the bootstrap (S4).** Recommended: accept, with the
   measurement of whether Claude Code and Codex pass a descriptor through, and the sandbox's pid namespace as the
   fallback. (The server child gets its connector before the bootstrap, S2.)
8. **S2-D10, clones for workers after the bootstrap.** Recommended: accept.
9. **S2-D12, the sessions' environment (S10), corrected.** Leaving the agent's variables out doesn't keep a session
   from the user's ssh agent here: the socket is at a fixed path. Recommended: during the bootstrap the user turns off
   the gpg-agent's ssh support (or keeps no key cached: `gpgconf --kill gpg-agent` before a team starts), and sets
   `guiApplications=false` under `[wsl2]` in `.wslconfig` so no session can open a window on the Windows desktop.
10. **S2-D11, the project allow-list (S11).** Recommended: accept `~/.vibeswitcher/v2/projects`, its one line written by
    the user for the bootstrap clone, removed when the user marks stage 6 passed; knowing that a worker can forge a
    worktree pair and run a scratch host with no list.
11. **New: the GitHub credential (S11 item 18, T36).** Any session can push to `main`, the Mac app's branch, with the
    `gh` token git uses. Recommended: before the bootstrap, replace it with a fine-grained token that reads this
    repository only (or log `gh` out and push with a credential typed at push time); add a ruleset on `main`, `v2` and
    tags requiring a pull request; the roles are denied `gh` (S10).
12. **New: what the install builds with (S9).** Recommended: the user installs a Swift toolchain outside `$HOME`
    (root's, for example under `/opt`) for installs only; installs use the static standard library, a fresh package
    cache, and a clean worktree of a commit both CI runners passed. Workers keep the user's toolchain for their own
    builds and tests, which stay guard rails (S11 item 10).
13. **New: the review floor for the bootstrap clone (S1, T34).** Recommended: the user sets, as the app would, a floor
    of `audit_finders` 2 with verifiers on a model other than the workers', and `merge_policy: ask_sensitive` with
    `sensitive_paths` covering `.github/**`, `scripts/ci/**`, `scripts/install-node.sh`, `Package.swift`,
    `Package.resolved`, `Sources/VibeHost/**`, `Sources/VibePlatform/**` and this document.
14. **New: the user's own Claude Code (S3, T37).** Recommended: the user adds deny rules to the Claude Code that
    supervises the bootstrap for `vibeswitcher answer`, `config accept`, `base accept`, `hooks install`, `start`,
    `stop` and `status --ack`, and for edits under `~/.vibeswitcher/v2/projects`; these requests are the user's to
    type.
15. **New: Codex workers off until measured (S10).** Recommended: `VIBESWITCHER_CODEX_WORKERS=0` in the lead's
    session until a measurement shows Codex's sandbox engaging on this kernel.
16. **The real-agent config folder (the bootstrap path's question 1), narrowed.** Recommended: the user passes
    `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` on the command line of each gated run, never in a shell startup file, so no
    gate's or audit's test run starts real agents.
17. **How the node starts (S9; the bootstrap path, question 3).** Recommended: a user unit, started and not enabled,
    `Restart=no`, `ExecStart` on the commit's folder with `--node`, `KillMode=control-group`, `UnsetEnvironment=` as
    listed, an explicit root-owned PATH, `SWIFT_BACKTRACE=enable=no`; and the user accepts that a host exit, for any
    reason, ends every session.

The bootstrap path's other questions (the WSL measurement, the allow-list line, running the command line by its
absolute path) stand as that document asks them.

### The author's calls the user doesn't need to confirm

From the plan: S2-D2 (the Mac-only bodies move into `VibePlatform`), S2-D4 (per-message credentials), S2-D5
(hardening, extended to sealed copies), S2-D7 (what the host executes, changed to sealed copies), S2-D13 (no
`attach` in stage 2).

New here, each **(call)**:

- The server child's inherited connector; the server never uses the host's path; app connections uncounted; the host
  checks the child is non-dumpable before each (S2).
- The host binds its path again when squatted; the server checks its own; starts and restarts go to the journal (S2).
- The server's socket checks the uid at accept and each request's sender; the user's voice adds the cgroup rule and a
  typed word; cards built by the engine; answers at rest in the vault (S3).
- The command line checks that the server it reached is non-dumpable, in the unit's cgroup and the unit's host's child
  (S3).
- The launcher's terminal check, token-matched session programs, ancestry start ticks, `setsid` in `runPrefix` on
  Linux (S4).
- Sealed `0111` copies for every image the host starts; close-on-exec from creation; the parser's reply grammar;
  unreadable means the host only by pid and start ticks (S6).
- The extended first look, the two-step accept, `lead` refused until accepted, the snapshot (S7).
- The static build and the unit's lines; git and systemctl from root's folders; the keeper's sealed copy; the clean
  install (S9).
- Plain shells, spawn's env filter, inline launch settings, GitGuard's check, Linux deny rules for every role (S10).

## Changes the stage 2 plan needs

For the plan's author to fold in before Task 2, each a Non-seam edit logged in the port map where it touches a shared
file; every change keeps the Mac's code paths as they are (a platform answer or a member whose default is today's).

| Change | Where in the plan | Section |
| --- | --- | --- |
| S2-D1 rewritten: the app is the connections the host makes through the server child's inherited connector (`SOCK_SEQPACKET` pair, `keep:`, `--host-connector N`, `SCM_RIGHTS`); drop "No inherited descriptor"; `HostConnection` gets a connector member (nil by default); app connections uncounted toward `maxClients`; the host checks the child is non-dumpable before making one | S2-D1; Tasks 4b, 8 | S2 |
| The host watches its socket's folder and binds the path again on a mismatch; tells the server over the app's connections | Task 8 | S2 |
| The host writes starts, server exits and restarts, refused app connections and replaced paths to stderr | Task 8 | S2 |
| A lint: `vibeswitcher-server` never execs | Task 8 | S2 |
| On Linux the user's host takes `spawn` only from the app and a lead; `SpawnRequest.env` from others refuses loader and startup variables | Task 4b (authorized), Task 10 (env) | S2, S10 |
| Sealed copies replace held `O_PATH` images: `Platform.ProcessSelf.sealedCopy(of:)` (read into a `memfd`, hash from the copy, seal, `0111`), and the measurement that a child started from one is non-dumpable from its exec | S2-D5, S2-D7; Task 3 | S6, S9 |
| The server, parsers, launcher, probe, handover target, new server image and fallback all start from sealed copies; `--node-root` replaces paths derived from `/proc/self/exe` in `main.swift` | Tasks 8, 9 | S6, S8, S9 |
| Close-on-exec from creation on Linux (`SOCK_CLOEXEC`, `accept4`, `O_CLOEXEC`, `MFD_CLOEXEC`); every spawn names `keep`; the lint | Tasks 2, 4a, 7 | S6 |
| The parser's reply grammar and query matching on Linux | Task 9 | S6 |
| Unreadable is the host only by pid and start ticks | Task 9 | S6 |
| S2-D8 rewritten: the handover's state and secrets in sealed `memfd`s, inherited, read as `/proc/self/fd/<n>`; no state file, no hash, no socket channel, no size limit on Linux; a traced image closes the secrets unread; a fresh host removes stale files; `aForgedStateFileIsRefused` replaced by the tests in S8 | S2-D8; Tasks 8, 9 | S8 |
| A switch brings the new build's server image, checked against that build's `build-info` | Tasks 8, 9 | S8, S9 |
| The launcher exits 127 when it can't take its terminal; the host checks `TIOCGSID`; session programs matched by token; ancestry start ticks; a reaped session is not live | Tasks 4a, 6 | S4 |
| `holdsFirstLook` covers the checkout seal, guarded settings and floor, and is kept in the vault's state | Task 10 | S7 |
| Linux sessions start with `bash --noprofile --norc`; `XDG_RUNTIME_DIR` not passed; Linux deny rules for every role, the lead included, with `gh`; inline launch settings; GitGuard's hash check; `runPrefix` calls `setsid` on Linux; `Platform.Tools.git` from root-owned folders; `LeadLaunch.swift`, `Git.swift`, `Worktrees.swift` and `Tools.swift` added to Task 10's files, with the edit kind named | Task 10 | S9, S10 |
| The keeper restarts the tool server from a sealed copy | Task 11 | S9 |
| Measurements: what Claude Code's Bash tool sources; a verifier command in its own session still times out | Task 12 | S10 |
| The test shim sends explicit `SCM_CREDENTIALS` and can do it inside a user and pid namespace of its own | Task 3 | S5 |
| `Platform.Sockets.receive`'s comment corrected (pid reuse); `checkPeer`'s comment made the Mac's | Task 7 | S5, Principals |
| An unknown process's vault requests tested | Task 5b | Principals |
| The lint's token grammar (`Identifier.identifier`, no `/`) | Task 1 | Reading this document |
| "After the bootstrap" renumbered to S12's list: the sealed handover, `0111` images and the static build leave it; `SO_PEERPIDFD` and the hardened wrapper join it; AppArmor stays with strong mode | After the bootstrap | S12 |
| Lines in `docs/process/v2-mac-tasks.md`: the Mac app trusts any host at the socket's path and gives its key to one that holds none; the Mac's `runPrefix` doesn't put a verifier's commands in a session of their own | Task 1 | The Mac and Linux |

**And for the other plans' authors** (not the stage 2 plan; listed so nothing falls between them):

- The engine plan. E1: the server's socket, the cgroup rule, the typed word, the journal entries, the command line's
  check of the server (non-dumpable, cgroup, `MainPID` through `/usr/bin/systemctl`), the server's own path check,
  `start` refusing with interop on, `status`'s plain-mode line and interop, automount and `kernel=` reports, the
  comparison of the manager's environment. E4: `lead` refused on a fresh vault until accepted. E6: approval cards built
  from git and the vault and bound to their id, questions from the lead's tool server and not from `board.json`,
  answers at rest in the vault, `.user` message ids consumed on Linux. E8: the restart path's `config held` and
  `config accept ID`, `base accept` with its log, the snapshot, no floor seeded on a fresh vault, the restart notice
  listing what was reset and how the host ended.
- The bootstrap path. Step 8: the unit's lines (S9), `--node` and `--node-root`, the static build, the clean install
  from a pushed commit with a root-owned toolchain, `build-info`'s `swift` and `resolved`, the seal's Linux list as in
  S9 (and `.wslconfig` and the Startup folder while `/mnt/c` is mounted), the rule on switches until measured, the
  server image on a switch. The questions: add decisions 2, 9, 11 to 16; narrow question 1 as decision 16 says;
  `~/.local/bin` is not first on this PATH, so the seal's list doesn't call it so.

## Answers to the attack review

Four reviewers attacked the first draft on 2026-11-13. Every finding was checked against the code at `6a590784` and
this machine. The review record (Task 1, Step 3) carries their text; this is where each is answered.

**Accepted and fixed in this document** (with the section): WSL interop voids every lock (S1, S11 item 1, decision 2,
† in the threats); `RUNPATH` loads the runtime from the user's toolchain (S9, static build before the bootstrap); a
fresh vault seeds its baseline from worker-writable files (S7); routes into a role without ptrace: launch files, the
hooks copy, the keeper (S10, S9); the Windows side's persistence (S11 item 2, decision 2); an `O_PATH` image is
rewritable in place (S9, sealed copies); the exec windows can be closed now with sealed `0111` copies (S6); the
spawned-session squat of the server's path and the command line's check (S3, spawn only from the app and a lead); the
server's parent check looks at the listener, not the acceptor (S2, the connector); status served by a seized server
(S2, the journal); `config accept` shows mtimes and accepts what it didn't show (S7); the parser's reply loop (S6, S11
item 11); approvals answered from board text (S3); the toolchain and package caches (S9, decision 12); a lead or
verifier turned by text (S1, decision 13); the handover file holds every screen and pending input (S8); a spoiled
state file ends every session rather than going back (S8); the forged-file window and its test (S8); the target's
check-then-use gap (S9); `holdsFirstLook` lost across a handover (S7); the lead's start loads planted config after a
restart (S7, `lead` refused); `runPrefix` doesn't `setsid` (S4); the server image on a switch (S8); "unreadable means
the host" (S6); `SCM_CREDENTIALS` and user namespaces (S5); the fallback gets no vault (S8); a tracer survives exec
(S6, S8); descriptors made close-on-exec too late (S6); the terminal race (S4); pid-reuse in the ancestry chain and
token matching (S4); the server's own exec (S2, lint); "tells the server" had no channel (S2); `checkPeer`'s Linux
form (Principals); login shells run the user's startup chain (S10); agents and WSLg by fixed path (S10, decision 9);
the `gh` token and `main` (decision 11); the cgroup rule (S3); the user's own Claude Code (S3, decision 14); PATH and
`Platform.Tools.git` (S9); `set-environment` and `VIBESWITCHER_HOME` (S9); answers at rest (S3); the journal (S2, S3);
`KillMode` and OOM (S9, S11 item 25); installing from an unclean tree (S9); the scratch host and the real-agent
variable (S11 item 24, decision 16); mirrored networking (S1, S11 item 22); stale handover files (S8); `doctor`
before the bootstrap (S11's `status` line); Codex's sandbox (S10, decision 15); the vault's size limit (gone with
sealed memory); `WSL_INTEROP`'s fallback (T22); `gdb` and the lead's deny rules (S10); another user through interop
(Principals, T31); post-bootstrap items missing from the plan's list (S12, Changes); the vault-refusal test and the
lint's path (Principals, Reading this document); the allow-list's two-sided forgery (S11); the default bus path
(S10); replay of sealed messages (S11 item 29, engine E6).

**Accepted in part, with a different fix:**

- *Hand the role's launch files over by a host-checked file or a memfd*: the settings and MCP config go inline on
  `claude`'s command line instead, which removes the file with no new channel; only the prompt may stay a file.
- *Count parser-originated input as `.another` for `isYours`*: rejected, because the headless terminal answers queries
  all the time and every lead would stop being the user's; the reply grammar and query matching are used instead.
- *Pass parser replies only while a client is attached*: rejected for the same reason (a headless program waits on
  its queries); replies are matched to queries instead.
- *Make the branch-code wrapper a hardened mode now*: deferred to after the bootstrap (S12.10). Before the sandbox the
  same branch code can ptrace the lead's tool server, so the fix buys nothing yet; S4 names the route.
- *A traced image closes the channel unread and the fallback holds its first look*: with sealed copies nothing can
  attach after the host's first statement, so a tracer at a handover means the host was traced from its start; the
  new image closes the secrets unread and goes back, and a traced fallback ends.
- *Require the listener's pid and start ticks to match the host recorded at the server's first statement*: not
  needed; the server never uses the path (the connector).
- *The supervising Claude Code confirms on a TTY*: accepted as a guard rail only (`script` gives an agent a pty); the
  deny rules in the user's Claude Code are the stronger half, and both are named as such.

**Rejected:** none outright. Two claims were checked and found narrower than stated: the static `reap` runs only for
sessions already closed (S4 asks Task 6 to confirm they count as not live), and the user manager's own PATH here is
root's folders only (the unit's PATH is what `start` captures, which is why S9 writes it explicitly).

## Order

1. This document is written (Task 1, Step 2) and revised after the attack review (this revision).
2. A reviewer who didn't write it reads it as an attacker, with the design, the stage 2 plan and the host's code, and
   records findings in a review record under `docs/process/reviews/` (Step 3). Each finding is answered here or in
   that record.
3. The stage 2 plan takes [the changes it needs](#changes-the-stage-2-plan-needs); the engine plan and the bootstrap
   path take theirs.
4. The user's answers to [the decisions above](#awaiting-the-user) are recorded in the design's Decided section (Step
   4).
5. `SecurityDocumentLintTests` passes (Step 5).
6. Only then does Task 2 start. A finding or an answer that changes a decision changes the stage 2 plan first.
