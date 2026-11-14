# VibeSwitcher 2, Stage 2 (The Session Host on Linux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The security architecture document is written, attacked and revised, its review is recorded and the user
has answered its decisions. Then `VibeHost` and `vibeswitcher-host` build on Ubuntu, and `VibeHostTests` and the host's
security audit pass there through `scripts/test.sh`. On Linux the host names a session's terminal as everything else
does (`ttypts<N>`) and owns it from the start; checks the sender of every message; counts as "the app" only the
connections it makes itself for its own server child, through the connector that child inherits; starts every image
it runs (the server, the parsers, the launcher, a handover's probe, new image and fallback) from a sealed in-memory
copy it loaded and hashed, so each is non-dumpable from its exec; hands over through sealed memory, writing no file;
and makes every descriptor close-on-exec from its creation. The lead's tool server lists its tools under a scratch
host, and a real `claude` under a scratch host survives its client quitting, a handover and a killed parser. The Mac
build and suite stay green.

This stage is cut to what the bootstrap needs ([the bootstrap path](2026-11-13-v2-bootstrap-path.md)). Confinement
(the sandbox, the egress proxy) comes after the bootstrap, as the design says, and so do sessions identified by an
inherited socket, clones for workers, the host as a subreaper and strong mode's key file: the list is the security
document's S12 ([After the bootstrap](#after-the-bootstrap-from-this-stage)). The handover through sealed memory, the
unreadable images and the static build, which this plan's first draft left for after the bootstrap, are before it now
(security document S6, S8, S9).

**Revised 2026-11-13** to take the security architecture document's
[changes](../specs/2026-11-13-v2-security-architecture.md#changes-the-stage-2-plan-needs). Where the document changed a
decision of this plan (S2-D1, S2-D5, S2-D7, S2-D8, S2-D12), the decision and its tasks are rewritten, not annotated.
Tasks the document names by number keep their numbers; a task too large to review as one slice is split into
lettered parts (Task 3 into 3a to 3c, and so on), so "Task 9" in the document means all of 9a to 9e.

**Architecture:** `VibeHost`'s Darwin calls switch to `VibePlatform` as `VibeCore`'s did. Its two Mac-only pieces
(the cdhash check in `AppCode.swift` and the Keychain half of `VaultStorage.swift`) move into `VibePlatform`'s Darwin
files, with Linux forms that answer "no such thing", and the names `AppCode.runs` and `VaultStorage.keychainKey()` stay
as forwards, so the Mac's path and its tests are unchanged. What the host does only for version 2 (the app's
connector, the server child, sealed images, the handover through sealed memory, the handover target's check, the
parser's reply grammar, the project allow-list, the spawn rules) lives in new files under `Sources/VibeHost/V2/`,
which main never has; the one client-side piece, the connector's other end, is `Sources/VibeCore/V2/HostConnector.swift`.
Each existing shared file gets a switched call, or a hook into a `V2/` file, each listed in
`docs/process/v2-port-map.md`.

**Tech Stack:** Swift 6.4.2 (language mode 5), SwiftPM `--build-system native`, SwiftTerm 1.19.0 (pinned; builds on
Linux), swift-crypto 3.15.1. The C shim `CVibePlatform` gains `posix_openpt`/`grantpt`/`unlockpt`, `TIOCSCTTY`,
`TIOCGSID`, `prctl` (`PR_SET_DUMPABLE`, `PR_GET_DUMPABLE`), `memfd_create` with `F_ADD_SEALS`/`F_GET_SEALS`,
`pidfd_getfd`, `accept4`, a descriptor sent and received with `SCM_RIGHTS`, and, for tests only, a send that names its
own `SCM_CREDENTIALS`. No `O_PATH`: held images are gone (S2-D7).

**Spec:** `docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md` (Security; The node's processes; The bootstrap;
Stage 2), and the security architecture document, `docs/superpowers/specs/2026-11-13-v2-security-architecture.md`
(S1 to S12, the threats T1 to T42, Changes the stage 2 plan needs). Where this plan and the document differ, the
document is right and this plan is corrected first. **Measured:** `docs/process/v2-linux-inventory.md` (`VibeHost`: 142
errors in 8 of 13 files), `docs/process/v2-stage1-recon.md` §1.2, §1.7, §1.9 (the host's four spawn sites mapped onto
`Platform.Spawn`). Code references are at `47636aaf`; the document's are at `6a590784`.

**Facts about this machine that shape it** (read 2026-11-12 and 2026-11-13; the document's S1 has the full table):

- Kernel 5.15.167.4-microsoft-standard-WSL2. No `SO_PEERPIDFD` or `SCM_PIDFD` (6.5+): a peer is a pid number, and the
  pid space wraps in ordinary use here (`pid_max` 4,194,304). `memfd_create` with sealing exists; no `vm.memfd_noexec`.
- No `/proc/sys/kernel/yama`: any process of the user may ptrace, `process_vm_readv` and `pidfd_getfd` any dumpable
  process of the user. `fs.suid_dumpable` is 0 and `core_pattern` is piped (so `RLIMIT_CORE` limits nothing).
  `/proc` has no `hidepid`.
- WSL interop is on (`/run/WSL/*_interop` 0777) and `/mnt/c` is mounted 0777: while they are, every lock in the
  document is void (the user's decision 2).
- pid 1 is systemd (`/etc/wsl.conf`: `systemd=true`); the user's own `systemd --user` runs (pid 284), with lingering
  on. No user units in `~/.config/systemd/user`. cgroups are hybrid; the user's terminals and Claude Code are in
  `/init.scope`, the manager's services under `user@1000.service`.
- Unprivileged user namespaces are on here (`user.max_user_namespaces` 384738); GitHub's Ubuntu runners may refuse
  them (Ubuntu 24.04's AppArmor restriction), so a test that needs one skips there, saying why.
- The Swift toolchain is under `~/.local/share/swiftly`, the user's; a debug build's `RUNPATH` loads `libswiftCore.so`,
  `libFoundation.so` and `libdispatch.so` from it. `swift_static` is present, so `--static-swift-stdlib` builds.
- No `bwrap` and no `zsh`. `script`, `nc` and util-linux's `unshare` are installed.
- `locale -a`: C, C.utf8 and POSIX only.
- `claude` is `~/.local/bin/claude`, a link to `~/.local/share/claude/versions/2.1.322`. Claude Code's Bash tool has
  no controlling terminal.
- The agent sandbox this work runs in allows memfd and seals, `PR_SET_DUMPABLE`, `PR_SET_CHILD_SUBREAPER`,
  `pidfd_open` and Unix sockets; non-dumpable makes `/proc/<pid>/mem` and `exe` refuse with `EACCES`.

## Global Constraints

- Everything in stage 1's Global Constraints holds: all work on `v2`; nothing under `Sources/VibeSwitcher`,
  `Tests/VibeSwitcherTests` or `Web/` is edited; tests only through `scripts/test.sh`; agents install nothing; a fix's
  test is shown failing without the fix; Swift here is set up with `. ~/.local/share/swiftly/env.sh`; every job green
  before the next task's first push, under stage 1 R3's time box for Mac-only failures.
- **Task 2 doesn't start until Task 1 is done**: the review record written, this plan and the bootstrap path holding
  the document's changes, the user's answers recorded in the design's Decided section, the document's lint passing
  (the document's [Order](../specs/2026-11-13-v2-security-architecture.md#order)). An answer other than a
  recommendation changes this plan first ([The user's decisions this plan assumes](#the-users-decisions-this-plan-assumes)).
- An edit to an existing file under `Sources/VibeHost`, `Sources/vibeswitcher-host` or `Sources/VibeCore` is one of:
  1. a call switched to `VibePlatform`;
  2. a type spelled through the platform (`audit_token_t` to `Platform.PeerToken`, which is the same type on the Mac);
  3. a whole file or a named block moved with `git mv`, or a block's body moved into `VibePlatform` with the old name
     left as a forward;
  4. a hook of one or two lines into a new file under `Sources/VibeHost/V2/` (or `Sources/VibeCore/V2/`);
  5. a `Config` field, or a member of `HostServer`, `HostConnection` or `HostedSession`, whose default keeps the
     Mac's behaviour (`HostedSession` added 2026-11-14 for Task 9e's `parserReplies`);
  6. a field added to a `Codable` record as an optional, so the format number stays and older builds still read it;
  7. a `HostRequest` kind with its `HostProtocol.Capability`, sent only to a host whose welcome lists it (Task 8b's
     `hostNotes`, the only one this plan expects).
  8. a member of `HostServer` made `internal` from `private`, so a `V2/` file in the same module can call it rather
     than copy it (added 2026-11-13 after Task 7 needed `log(_:)` and `updateAttachment(_:)`; Task 5a's
     `handoverState` argument is kind 4).

  Kinds 4 to 8 each get a line in `docs/process/v2-port-map.md`'s Non-seam edits: file, line, why, merge cost. The
  ones this plan expects are listed in its tasks; an executor who needs another stops and asks.
- **No behaviour change on the Mac.** Every Darwin form is the old body moved. Where Linux gains something (the
  connector, the server child, hardening, sealed images, the handover through sealed memory, the spawn rules), the
  Mac's form does nothing or keeps today's behaviour, and a test on the Mac says so. What the document found wrong on
  the Mac and this branch doesn't change goes into `docs/process/v2-mac-tasks.md` (Task 1).
- **How "on Linux" is decided outside `VibePlatform`.** `PlatformLint` forbids `#if os` there, so every switch this
  plan makes in `VibeHost`, `vibeswitcher-host`, `VibeCore` or a test reads one platform value:
  `Platform.CodeIdentity.isAvailable` (Task 4b1), true on the Mac (the cdhash check exists) and false on Linux. Where
  this plan says "on Linux" in a shared file or a test, it means `!Platform.CodeIdentity.isAvailable`, and the Mac's
  form of that switch is "does nothing", with a Mac test saying so where the task lists one. A platform call whose
  Darwin form is "does nothing" (for example `Platform.Sockets.enableCredentials`) says so in its doc comment.
- **Close-on-exec from creation, on Linux.** Every descriptor made in `VibeHost`, `vibeswitcher-host`, `VibePlatform`,
  `UnixSocket` and (when it exists) `vibeswitcher-server` is close-on-exec from the call that makes it
  (`SOCK_CLOEXEC`, `accept4`, `O_CLOEXEC`, `pipe2`, `MFD_CLOEXEC`), and every spawn there names `keep`. Task 4a's lint
  holds it. The Mac has no `SOCK_CLOEXEC` and keeps today's `fcntl` after the call.
- **Nothing secret in an argument or an environment variable** of the host, the server or a parser: arguments are
  world-readable here. A descriptor's number is not a secret.
- **Test-only flags** (`--test-app-pid`, `--test-app-connector`, `--handover-test-secret`,
  `--handover-test-secret-file`, `--handover-test-traced`, `--install-root`, `--parser-test-hooks`, `--server-arg`,
  `--hold-first-look`, the engine's `--test-user-seal-life`, the launcher's test delay, Task 9b's
  `--launcher-test-hold` (the 9b review fixes: a scratch host's launchers wait after making themselves dumpable until
  a file exists), Task 9a's
  `--test-stays-dumpable`, which makes a scratch host dumpable again so a test can count its descriptors from outside,
  and Task 9d's (approved by the lead, 2026-11-14): `--handover-test-fail-next` (the image handed over to is given
  `--handover-fail-restore`, as a script can't stand in for an installed build), `--handover-test-hold PATH` (a
  handover waits after its check, before its probe, until PATH exists), and from the 9d review
  `--handover-test-hold-check PATH` (a handover waits once its target's copy is loaded, before its check, the host's
  queue held) and `--server-test-replace-hold PATH` (a switch's start again of the server child waits until PATH
  exists, so a test can act while it is due))
  are honoured only by a
  scratch host (on a lock of its own) and, but for `--server-arg`, `--hold-first-look`, `--test-user-seal-life` and
  `--server-test-replace-hold` (which a scratch host carries across its handovers, so a test's settings survive one),
  are stripped from `config.arguments`. On the Mac, `--handover-test-secret` keeps today's behaviour (Task 9a).
- **Which host is the user's.** `ownsLaunchers` (the host holds the user's lock) carries the security rules (test
  flags refused, `spawnNeedsLead`, `watchesItsPath`); `--node` carries the install's (`build-info`, `installRoot`,
  the allow-list, `HOME` from `getpwuid`). So the two can't come apart on the real home, on Linux a host on the user's
  lock whose `VibePaths.root` is the account's own `~/.vibeswitcher` (from `getpwuid`) refuses to start without
  `--node`, `--node-root` and `--server` (Task 9b). A host on a scratch home's own lock (the tests' "user's host") is
  `ownsLaunchers` without `--node`.
- **Platform-specific tests use runtime traits** (`.enabled(if: !Platform.CodeIdentity.isAvailable)` and the
  reverse), not `#if`, so a file holding a Mac-only or Linux-only test isn't a partly wrapped file for Task 5b's count.
- **Script stand-ins.** A sealed copy is made `0111` only when it is an ELF image (its first bytes `\x7fELF`): an
  interpreter can't read a script from an unreadable copy (`/bin/sh: cannot open /proc/self/fd/3: Permission
  denied`, measured here). A script is sealed `0555`, so the tests' script builds (`HostHandoverTests`' failing, slow,
  copying and broken hosts) still run from copies, and the user's host (`--node`) refuses a script target outright.
  Stand-ins that must be non-dumpable (the server child) are ELF helper modes of the test binary.
- Host tests use scratch hosts on their own lock and socket (`TestHost`), never the user's `~/.vibeswitcher`.
- **Never harden the test process itself**, and never rely on a descriptor the test process holds being out of
  another process's reach: the test process is dumpable, and other tests read its `/proc` entries. Hardening, sealed
  copies that must stay private, and the connector's far end are tested in helper modes of the test binary.
- Tests that need an unprivileged user namespace skip, saying why, where the runner refuses one.
- Real agents only in gated tests, on Sonnet, in a Claude Code config folder the user prepared, named in
  `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` on the command line of each gated run, never in a shell startup file
  (decision 16), never the user's own `~/.claude`.
- What a task measures on this machine (Task 3b's sealed copy, Task 12b's) goes into `docs/process/v2-linux-inventory.md`
  with the date and the kernel.
- A new test suite whose name ends in `Lint` is named in `docs/guide/development.md`.
- Commit messages end with the attribution line the session gives.

## Decisions this plan makes

Each is the author's call, numbered S2-D1 and up (stage 1's Decision 6 is "the binary decision"). The security
document holds the reasoning in full (the section is named); this list is what the tasks build. The user's part is in
[the next section](#the-users-decisions-this-plan-assumes).

1. **S2-D1: The app on Linux is the connections the host makes for its server child, through a connector the child
   inherits** (S2; changed by the document from "the server child recognised by its pid and start time").
   - The host is started with `--server PATH`. At its start it loads PATH into a sealed copy (S2-D7), makes a
     `SOCK_SEQPACKET` socket pair with `SOCK_CLOEXEC`, and starts the child from the copy with `keep: [copy,
     connector]` and `--host-connector N --host-socket <its socket path>`, then `--node --node-root PATH` for a
     `--node` host, else `--root <its VibePaths.root> --node-root <its install folder>` (from `--node-root`,
     `--image-path` or, at a scratch host's fresh start, its executable's folder; the engine's E1 takes its install
     folder from there: a child run from a memfd can't find it from its own image), and on a scratch host each
     `--server-arg X` it was given. The real server refuses a `--host-socket` other than `<root>/host.sock` (the
     engine's EN-D3). On its own queue, in the same turn
     as the spawn, it records the child's token (`Platform.Processes.token`: pid, uid, start ticks).
   - **The connector.** The child asks for a connection by sending one byte on its end. The host checks that byte's
     sender is the child (S2-D4) and that the child is still non-dumpable (`/proc/<child>/fd` is root's; otherwise it
     refuses, logs it and ends the child), makes a `SOCK_STREAM` pair with `SOCK_CLOEXEC`, registers its end as a
     client whose caller is `.app` from its first byte and whose expected sender is the child's token, and passes the
     other end back with `SCM_RIGHTS`. App connections don't count toward `maxClients` and are sent no challenge.
   - **No connection made through the socket's path is ever the app on Linux.** On the client side,
     `HostConnection` reaches a path for which a connector is registered only through that connector, and never falls
     back to the path, so a socket squatted at the host's path never reaches the server. The host tells the server
     what it needs (a replaced path, its own restarts) through a request only the app may make (`hostNotes`, Task 8b).
   - When the child exits: the connector closes, every app connection becomes `.unknown`, then the child is reaped
     (its pid can't be reused while the record stands), and it is started again with a fresh connector after 1 s,
     doubling to 30 s, reset after 10 minutes up. While it runs the host doesn't exit idle.
   - The server never execs (a lint, Task 8a) and never connects by path; its first statements, and their order, are
     the engine's E1 (the canonical list: the image closed, hardened, traced exits, the connector marked
     close-on-exec, SIGPIPE settled, then its root, the socket check and git, and only then the connector registered).
   - *The Mac is unchanged:* `identify` still asks `config.appExecutable` through `AppCode.runs` (cdhash) and then
     `AppProof`'s HMAC, so the eleven app test files that build `HostServer.Config` with `appExecutable`
     (`AppKeyStoreTests`, `HostProofRefusedTests`, `InputUnitDeliveryTests`, `LeadRelaunchTests` and seven more) keep
     working; there is no connector there.
   - *Why the connector and not the pid:* the engine reaches the host through `HostCall` and `LeadVault.standard`,
     which open a new connection for every call (`SessionDigest.swift` 147-164); a connector gives the child as many
     as it wants, each made by the host, with no pid on a path to trust. That closes a socket squatted at the host's
     path feeding the app lies, a listener copied in a handover feeding it lies, a reused pid passing as the app
     (T13), and the app locked out by full client slots (T28). `Platform.Spawn`'s `keep` keeps numbers, which is all
     an inherited connector needs.
   - *What a worker can still do before the sandbox* (S2, S11): kill or stop the server (a denial of service, in the
     journal); choose when the host next starts, after editing what that start runs (the unit, its drop-ins,
     `environment.d`, the install folder and `build-info`), and so own the host and its app (T3); ptrace the host in its
     own start by systemd (T4); put its own socket at the host's path, fooling sessions until the host binds it again
     (T8); act as any session (S2-D4, S4). It can't connect as the app, send on the app's connections, or take the
     connector or the server's memory.
2. **S2-D2: The Mac-only bodies move into `VibePlatform`; the names stay.** `AppCode`'s cdhash check and
   architecture read become `Platform.CodeIdentity` (Darwin: the bodies moved; Linux: `runs` is false and the reads
   nil). `VaultStorage.keychainKey` and `removeKeychainKey`'s `SecItem` calls become `Platform.Keychain` (Darwin: the
   bodies moved; Linux: nil and nothing). `AppCode.runs` and `VaultStorage.keychainKey()` stay as one-line forwards,
   so `HostServer.identify`, `AppCodeTests` and `KeychainLintTests`' rule about who calls `keychainKey(` hold.
   `KeychainLintTests.onlyTheKeyStoresCallTheKeychain` gets the new path. *Why not `VibeHost/MacOnly`:* both names are
   called from portable code (`HostServer.swift:666`, `vibeswitcher-host/main.swift:129`), and a Linux stand-in would
   need an `#if` outside `VibePlatform`.
3. **S2-D3: In plain mode the vault lives in the host's memory only, and a fresh vault takes nothing as its baseline
   that a worker could have written** (S7, extended by the document). `VaultStorage` with a nil key keeps the vault in
   memory (`VaultStorage.swift:11, 40`); a handover carries it in sealed memory (S2-D8). A host restart (a worker can
   cause one at will, and so can an OOM kill, an idle exit or a WSL shutdown) erases every team's roles, grants,
   verdicts, ballots, findings, review levels, recorded heads, approvals, guarded settings' hashes, the review floor,
   the user's sealing key and the config seal's hashes; the host log says "vault in memory only".
   - `LeadVault.Book.holdsFirstLook` (false by default: the Mac's vault is unchanged; kind 5) covers **every record**
     on a fresh vault: the home seal and the main checkout's seal (`ConfigSeal.checkoutFiles`, `.git/config`,
     `.git/hooks`) hold what they first see instead of sealing it; a guarded setting with nothing recorded is held,
     not recorded; no floor is seeded from `workflow.md`. **A watched key never recorded is held for the user's
     accept whenever it is first read, for as long as the vault holds its first look** (as built in Task 10e's
     review, approved by the lead 2026-11-14: strictly more than "until the first accept"): the home seal and each
     main checkout's seal hold what they have nothing recorded for at the first look and at any later look that first
     reads it (`~/.claude.json` unreadable at the accept is no baseline at the next look), and only the app's accept
     that showed it seals it. **Each root's floor and rails are held until the app's accept for that root**: the
     app's `.setGuarded` carrying `ConfigSeal.checkKey` with shown hashes (what `checkConfig(root:shown:)` sends for
     the user's `config accept`), sealing with nothing held again, records the root in
     `Book.firstLookAccepted: Set<String>`. A second project's first look is held on its own. Both holds are in the
     `Book`'s own handlers, where the flag lives
     (`.setGuarded`, `LeadVault.swift:1033-1043`; `.setReviewFloor` with `onlyIfUnset`, 1045-1048), not in the
     client-side callers (`LeadVaultGuarded.changedSettings`, `LeadVault.startLead`), which run in the tool server or
     the engine and can't see it; each answers with a reply its caller already handles. Whether a root is still held
     is read as today, from its held lines (`guardedRecord(root:)`). Both are kept in the vault's own state, so a
     handover before the first look keeps them. `main.swift` sets it for a `--node` host whose vault holds no
     restored secrets, and for a scratch host only with `--hold-first-look`, so scratch hosts seal as today.
   - Workers, verifiers and merges wait until the user's two-step accept (`config held`, then `config accept CARD`)
     and `base accept CARD`; `lead` itself is refused on a fresh vault until both are done. Those commands, their change
     times, sizes and hashes, and the "last accepted" snapshot are the engine's (E4, E6, E8 in the bootstrap path).
   - Strong mode's 0600 key file comes after the bootstrap; before the sandbox a worker reads it.
4. **S2-D4: Each message's sender is checked** (S5). The host's listener has `SO_PASSCRED` before its first accept,
   and the host's ends of connector connections have it from their creation, so every connection carries senders from
   its first byte. Each read is `Platform.Sockets.receive`, which stops where the sender changes. A sender whose token
   is the accepted one keeps the connection's identity; a missing sender (no credentials, or its `/proc` entry gone),
   a different sender, or a frame made of two senders' bytes makes the connection `.unknown` for good. On the Mac
   `LOCAL_PEERTOKEN` already names the last sender (`checkPeer`, `HostServer.swift:642-654`). *Doesn't promise:* who
   reads from a connection; that the sender didn't exec another program; **pid reuse** (a sender that writes, exits and
   has its pid given to a new process before the host's read is taken as the new process; it can pass as a session's
   process, never as the app, whose connections aren't by path). A sender can name another pid only inside a pid
   namespace it made, which holds only its own processes. `SO_PEERPIDFD` and `SCM_PIDFD` come after the bootstrap,
   where the kernel has them.
5. **S2-D5: The host, its parsers, its server and every image it starts are non-dumpable from their exec**
   (S6, extended by the document).
   - The host and parser modes of `vibeswitcher-host`, and `vibeswitcher-server`, begin with
     `Platform.ProcessSelf.harden()` (`PR_SET_DUMPABLE 0`, `RLIMIT_CORE 0`), then read `TracerPid`: a traced process
     refuses to start; a traced new image after a handover closes its secrets unread and goes back; a traced fallback
     ends. The launcher mode doesn't harden (it execs the session's program at once). Session programs stay dumpable.
   - **The exec windows are closed by sealed copies.** The kernel makes a process non-dumpable from its exec when the
     image it runs is one it can't read. Every image the host starts is a sealed copy (S2-D7) made `0111`, run from
     `/proc/self/fd/<copy>`; nobody but the host holds the copy, and the host is non-dumpable from its first statement.
     Sessions' launchers start from a second copy of their own (the 9b review, below), and the host puts a copy's
     mode back before each start.
     Task 3b measures it in the suite. **If the measurement fails** on a kernel, the windows are open there, the
     document's S11 lists them and the rule on switches (the bootstrap path, step 8) stays.
   - **What that costs a process started so:** its `/proc/self/*` files are root's, so it can't write its own
     `/proc/self/oom_score_adj` (measured here: `EACCES`). The launcher, which must, sets itself dumpable again just
     before that write (Task 9b), after its terminal check and after closing its inherited image, so it holds nothing
     then that the session's program won't hold a moment later, but for its `/proc/<pid>/exe`: through it any process
     of the user can `chmod` the copy the launcher runs (the 9b review, 2026-11-14). That copy is therefore the
     launchers' own, never the parsers'.
   - **Descriptors are close-on-exec from creation** (Global Constraints; Task 4a).
   - **A parser's reply is typed only as a reply.** On Linux the host passes a parser's `.reply` bytes into the
     session only when they answer a query the host saw in that session's output since the last reply, and only in the
     reply grammar; anything else from a parser is dropped and logged (Task 9e).
   - **"Unreadable" means the host only by token.** Any process can make itself non-dumpable, so a reader of another
     process's `/proc` entries takes an unreadable process as the host only when its pid and start ticks are the host's
     own, a recorded parser's or the server child's; anything else unreadable is "unknown, still running" (Task 9a).
   - *Doesn't promise:* the host's own start by systemd, which runs the installed, readable file (T4).
6. **S2-D6: The host is not a subreaper before the bootstrap.** The design lists the subreaper under "also
   required". It is deferred, with the sandbox, whose own process namespace makes ancestry exact. *Why:* as a
   subreaper the host would adopt every orphan of its sessions, and reaping them takes exit statuses from code in the
   host that waits for its own children by pid (`Git.run` in the vault's base moves, `LeadBaseMoves.swift:121-133`;
   `PipeCommand+Linux.swift:128`; `HostHandover.swift:187`): a reaped `git merge-base --is-ancestor` reads as success.
   Nor would it give a double-forked process a session: `session(of:)` (`HostServer.swift:672-689`) finds a session by
   its program in the ancestry or by its terminal, and an adopted orphan's ancestry is `[orphan, host, …]`. *Instead:*
   on Linux the orphan sweep looks for a tool server whose parent is pid 1 or the subreaper an orphan of the host's
   gets (on this machine, the user's systemd), found at start by a probe that orphans a child of its own. On the Mac
   that set is `{1}`, as today. *What it costs now:* a worker process that escapes its session is nobody to the host;
   to the server's command-line socket it is refused by the cgroup rule (S3, the engine's E1), not by ancestry.
7. **S2-D7: What the host executes: sealed copies, and the static build** (S9; changed by the document from held
   `O_PATH` images, which the user can rewrite in place whenever no process runs them).
   - At its start the host reads its own image (`/proc/self/exe`, the inode it runs) and its `--server` image once
     each into a `memfd` (`MFD_CLOEXEC | MFD_ALLOW_SEALING`), seals it (`F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW |
     F_SEAL_SEAL`), hashes it from the copy's own bytes, and makes it `0111` (a script, which only a test uses, `0555`:
     Global Constraints). Sessions' launchers and parsers start
     from the host's copy, the server from its copy, a handover's probe and new image from the target's copy, a failed
     handover falls back through the old image's copy (kept across the exec). A child started from a copy gets it with
     `keep:` (`Platform.Spawn` closes everything else from 3 up before `execve` resolves the path) and closes it as
     its first act. A file changed on disk after the host loaded it is never what the host runs.
   - Because `/proc/self/exe` then names `/memfd:…`, the user's host takes its install folder from `--node-root`
     (with `--node`), and a scratch host on Linux from `--image-path`; neither is ever executed, only used to find
     `build-info`, `vibeswitcher-mcp` and the command folder.
   - **A handover gives the new image its own folders, never the old build's.** `--node-root`, `--server` and
     `--image-path` are in `handoverFlags` (`main.swift:76-78`), so they are dropped from `config.arguments`, and
     `handOver(to:)` appends the target's: with an install root, the build folder `HandoverTarget.check` returned, its
     `bin/vibeswitcher-server`, and no `--image-path`; without one (a scratch host), the old `--node-root` and
     `--server` unchanged and `--image-path <target>`. `goBack` appends the old image's own three. Otherwise the new
     build would check itself against the old build's `build-info` and fail every switch, or take the old commit's
     `vibeswitcher-mcp` and server.
   - In the user's host (`--node`), at its start, its own image and its `--server` image must match the SHA-256 that
     `<node-root>/build-info` records, or it doesn't start; `VibePaths.root` comes from `getpwuid`, never from
     `VIBESWITCHER_HOME`; a handover target must be inside the install folder (`~/.vibeswitcher/v2/builds`) and its
     sealed copy's hash must match its own build's `build-info`, checked on the copy that is then probed and run. A path
     in a worktree or a session's folder is refused. Scratch hosts have no install root and hand over as today (from
     their own sealed copies on Linux).
   - **The static build** (`--static-swift-stdlib`), the unit's `UnsetEnvironment=` and explicit PATH, and the
     install from a clean worktree with a root-owned toolchain are the bootstrap path's step 8. `Platform.Tools.git` on
     Linux is the first `git` in a folder owned by root and writable by nobody else (Task 10c). The tool server's
     keeper restarting it from a sealed copy (the document's S9) is **moved after the bootstrap** (Task 11b says why;
     decision 18).
   - The Mac keeps its launcher copies under `~/.vibeswitcher/host` and its by-path handover.
   - *Doesn't promise:* the install folder, `build-info`, the unit and the manager's environment are the user's to
     write before the sandbox, and a host start a worker causes runs what they name (S2-D1); signed releases (stage 8)
     make "what is installed is what was released" a lock.
8. **S2-D8: The handover goes through sealed memory on Linux, and writes no file** (S8; changed by the document from
   the state file checked by its hash and the secrets through a socket).
   - The build handing over writes the state into a sealed `memfd` and names it to the new image as `--handover
     /proc/self/fd/<n>`, `n` kept across the exec; `HostHandover.read(from:)` reads that path unchanged, and each reopen
     starts at the beginning, so the probe, the new image and the fallback read the same bytes. The secrets (the vault)
     go into a second sealed `memfd`, read from offset 0 and kept open until the restore succeeded, so a fallback after
     a failed restore keeps the vault. No size limit short of memory; no hash; no file to forge, spoil, read or leave
     behind (T16).
   - The handover target is loaded as a sealed copy (S2-D7), probed and exec'd from it. With an install root (Task
     9d), the target build's `vibeswitcher-server` is loaded and checked the same way and travels in the state; the
     new image restarts the server from that copy once idle, and only when its hash differs from the running
     server's. Without an install root (every scratch host) no server copy travels, and the server child runs on
     unchanged (Task 8b's `theServerChildSurvivesAHandover`, the engine's E8).
   - The fallback is the old image's sealed copy, with the same descriptors and the same `--handover` path.
   - Descriptors kept across an exec arrive without close-on-exec (`keep:` clears it). The new image, and the
     fallback, mark every one it keeps close-on-exec once restored (the sessions' masters, the state, the secrets
     until closed, the image copies, the connectors), as `start(restoring:)` already does for the lock and listener.
   - The server child's record is checked again on restore: its parent is this process, its start ticks match, it is
     no restored session's program and no parser, and its connector is among the descriptors; otherwise the record is
     cleared and the server started again.
   - A newer format is refused (`HostHandover.format`, rule 11) and the host goes back. A fresh host that isn't
     restoring removes any stale `host.lock.handover` and `.partial` (the Mac's format, or a scratch host's) and logs it.
   - The Mac keeps its state file and socket channel, unchanged.
9. **S2-D9: Sessions identified by an inherited socket come after the bootstrap.** Identity stays process ancestry,
   the session's terminal and `BranchCode`, with Task 6b's fixes (the launcher owns its terminal, programs matched by
   token, ancestry start ticks). The session connector (one `SOCK_SEQPACKET` pair per session, its number in
   `VIBESWITCHER_HOST_FD`) is specified in the document's S4 and built with the sandbox. *Why:* it needs Claude Code
   and Codex to pass a descriptor through to their tool servers and hooks, which nobody has measured; and until the
   sandbox, ptrace takes a connector anyway. The **server child's** connector (S2-D1) is before the bootstrap: it uses
   the same `VibeCore` hook (`HostConnection`'s connector registry), so the session connector later adds no new seam.
10. **S2-D10: Clones for workers come after the bootstrap.** They are `VibeCore`'s (`Worktrees`,
    `LeadToolset.start_worker`), not the host's, and exist for the sandbox.
11. **S2-D11: A project allow-list in the user's host on Linux** (S11). A `spawn` whose working folder isn't inside an
    allowed repository is refused, saying why. The list is `~/.vibeswitcher/v2/projects`, one path a line, written by
    the user. A folder is inside an allowed repository when it is the repository or one of its worktrees, found by
    reading files, never by running git in a folder a worker controls: its `.git` file's `gitdir:`, that folder's
    `commondir`, and the allowed repository's own `.git/worktrees/*/gitdir` pointing back at the folder (a forged
    `.git` file alone is refused). The list's place is `HostServer.Config.projectAllowList: URL?`, nil by default (the
    Mac's and every scratch host's behaviour; kind 5). It goes when the user marks stage 6 passed. A guard rail,
    written down as one: the file is the user's to edit; a worker can write both halves of the worktree check (and the
    pair passes); a repository cloned inside an allowed one is inside it; a folder swapped for a link between the
    check (which resolves it) and the session's start (in the folder as asked) is followed; a session can run a
    scratch host with no list. (The clone and the link are the two limits Task 10d found and named in
    `ProjectAllowList`'s doc comment; added here as approved by the lead 2026-11-14.)
12. **S2-D12: The sessions' environment is a platform answer** (S10; corrected by the document).
    - **Passed on Linux:** `HOME USER LOGNAME SHELL TMPDIR PATH LANG LC_ALL LC_CTYPE`, plus `SWIFT_BACKTRACE=enable=no`
      (which the parsers' fixed environment, `PATH=/usr/bin:/bin` in `ParserLink.start`, gains too).
      Not `XDG_RUNTIME_DIR` (it points at the gpg-agent, the bus and WSLg's sockets); never `SSH_AUTH_SOCK`,
      `WSL_INTEROP`, `DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, `WAYLAND_DISPLAY`, `PULSE_SERVER`,
      `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR`. A session's default `LANG` is `C.UTF-8` (`en_US.UTF-8` isn't installed
      here). A session's program starts with SIGPIPE at its default and its `oom_score_adj` raised by 500. The Mac keeps
      today's list (`vibeswitcher-host/main.swift:27`) and today's login shell.
    - **A plain shell, not a login shell, on Linux:** team sessions start with `bash --noprofile --norc -c command`
      with the PATH the unit holds, not `$SHELL -l -i -c` (`HostedSession.swift:117-120`), which runs the user's whole
      startup chain. So that PATH must hold what workers build with (the bootstrap path, step 8: the toolchain's and
      node's folders, named and watched), and `claude` is launched by its resolved absolute path.
    - **What a spawn may add:** `SpawnRequest.env` from a caller that isn't the app may not set a loader or
      shell-startup variable (`LD_*`, `BASH_ENV`, `ENV`, …) or any name on the "never" list; such a request is refused,
      saying which. In the user's host on Linux only the app and a session holding the lead role may spawn at all.
    - **A role's launch settings are given inline on Linux:** `--settings` and `--mcp-config` as JSON strings on
      `claude`'s command line, not files a worker can rewrite before `claude` reads them; the prompt too when it fits.
    - **The lead's accepted git hooks:** no run-time hash check before the bootstrap. The document's S10 asks GitGuard
      to compare the copy with its accepted record, but that record is `accepted.json` beside the copy
      (`Git.swift:428, 462, 533`, under `~/.vibeswitcher/lead/git-hooks`), which a worker who rewrites the copy
      rewrites too. The seal's Linux list (the bootstrap path, step 8) watches that folder, with the vault holding the
      hashes; that is the detector. Moving the record into the vault is after the bootstrap (decision 19).
    - **Linux's deny rules**, for every role, the lead included: tracers, the user's manager and timers, Windows'
      programs, `gh` and git's credential helpers, edits under the node's own folders, reads and edits under `/mnt/c`.
      They are Claude Code permission rules: they stop a slip, not a worker that tries.
    - *Doesn't promise:* keeping a session away from the user's systemd or from sockets found by fixed path (the
      gpg-agent, the bus, WSLg, interop); that is the user's decisions 2 and 9 until the sandbox.
13. **S2-D13: No `vibeswitcher attach` in this stage.** The command line talks to the server (rule 2), not the host.
    The proofs here are tests.

## The user's decisions this plan assumes

The bootstrap path's [Decisions awaiting the user](2026-11-13-v2-bootstrap-path.md#decisions-awaiting-the-user) is
the one list (the security document points there); "decision N" here is its tag DN. This plan is written on the
recommendations. Each task that depends on one says
so on an **Awaits:** line; this table says what a different answer would change, so it can be applied before the task
starts.

| # | Decision | Assumed | Tasks that rest on it | If the user answers otherwise |
| --- | --- | --- | --- | --- |
| 1 | S2-D1, the app on Linux, and S11's residual list | the server child, through its connector; S11 accepted while the only project is VibeSwitcher's own and interop is off | 4b2, 5a (the stand-ins), 7, 8a, 8b | Another principal: 4b2, 5a's stand-ins and 8a are rewritten before 4b2 starts. No Linux app before signed approvals: stage 2 is unchanged, but the bootstrap waits for stage 4 |
| 2 | Nothing one step from root (interop, automount, `sudo`) | interop and automount off; no `sudo` here while a team runs | none (the engine's E1 checks it) | Stage 2 unchanged; every lock it builds is a guard rail while interop is on, and `status` says so |
| 3 | S2-D3, the vault in memory, with the extended first look | memory only; the user accepts after every host restart | 4c (the Keychain's Linux form), 10e | A key file before the sandbox: 4c's Linux Keychain gets a file form, and 10e still holds the first look of a vault restored from a file a worker could have forged |
| 4 | S2-D6, no subreaper before the bootstrap | no subreaper; escapes refused by the cgroup rule | 4b1 (`orphanParents`) | A subreaper now: a task before 4b1 first makes every `waitpid` site in the host tolerate adopted children (the three in S2-D6), and 4b1's probe goes |
| 5 | S2-D8, the handover through sealed memory | sealed memory, no file | 8b, 9c | The state file with its hash through the secret channel (this plan's first S2-D8) replaces 9c, with a forged-file test whose swap happens inside the probe |
| 6 | No switch of builds while a worker or verifier runs, until measured | the rule, until Task 3b's measurement passes here | 3b (the measurement) | None in stage 2: the rule is the bootstrap path's step 8 |
| 7 | S2-D9, the session connector after the bootstrap | after, with the sandbox | 4b2 builds the server child's connector only | Before: a task after 8a builds the session connector (S4), preceded by the measurement of whether Claude Code and Codex pass descriptor N to their tool servers and hooks |
| 8 | S2-D10, clones after the bootstrap | after | none | Before: a plan of its own for `Worktrees` and `start_worker` |
| 9 | S2-D12, the sessions' environment; the gpg-agent's ssh support and WSLg off | as recommended | 10a (the list doesn't depend on the answer) | None in code; S11 items 16 and 19 stay open during the bootstrap |
| 10 | S2-D11, the project allow-list | `~/.vibeswitcher/v2/projects`, its line written by the user | 10d | Another place: 10d's path. No list: 10d is dropped, and S11 isn't acceptable before stage 6 |
| 11 | The GitHub credential | a narrow token, rulesets on `main`, `v2` and tags | 10b (`gh` denied to roles) | None in code |
| 12 | What the install builds with | a root-owned toolchain, static, a fresh cache, a clean worktree; the user's swiftly and node folders on the unit's PATH for workers' builds, named and watched (the bootstrap path, step 8) | none (the bootstrap path's step 8) | None in stage 2. Without those folders on the PATH, workers can't build or run `scripts/test.sh` |
| 13 | The review floor for the bootstrap clone | `audit_finders` 2 on another model, `ask_sensitive`, with `sensitive_paths` widened to the code that holds the security (the bootstrap path, step 10) | none (the bootstrap path's step 10) | None in stage 2 |
| 14 | The user's own Claude Code | deny rules for the user's-voice requests | none | None in stage 2 |
| 15 | Codex workers off until measured | off | none (the engine's E4) | None in stage 2 |
| 16 | The real-agent config folder, per run | named on each gated run's command line | 12a, 12b | None in code; the gated tests read the variable as they do |
| 17 | How the node starts | a user unit as S9 lists; a host exit ends every session | 9b (`--node`, `--node-root`), 8a (the server dies with the unit) | Without systemd: `--node` and `--node-root` stand; `KillMode`'s consequence doesn't apply, and the engine's E1 uses S3's weaker rule |
| 18 | The keeper's sealed copy after the bootstrap | after, with the sandbox | 11b (not built) | Before: 11b is built before the bootstrap, with `vibeswitcher-mcp`'s five uses of its own path reading the file's real path (a Non-seam edit each) |
| 19 | No GitGuard hash check before the bootstrap | none; the seal watches the hooks folder | 10c | Before: the accepted hashes recorded in the vault at accept (a `LeadVault` request, kind 7) and a hook in `Git.swift` that checks the copy before each guarded run |
| 20 | S12 gains items 14 to 16 | yes | none | None in stage 2 |

## Review Focus

1. No connection is `.app` on Linux except one the host made through its live server child's connector; nothing
   made through the socket's path is the app; a message on an app connection from any other process makes it nobody's;
   the child's own children are never the app; a dumpable child gets no connection (Tasks 4b2, 7, 8a).
2. The Mac's app check is untouched: a `Config` with only `appExecutable` set still makes the app's code the app after
   its proof, and the app's eleven test files that rely on it pass unchanged (Tasks 4b1, 4b2).
3. Without Yama, a worker can't open the host's, a parser's or the server's memory or descriptors, from their exec on,
   after start and after a handover; no descriptor of theirs leaks into a child (Tasks 3a, 3b, 4a, 9a, 9b).
4. A session's terminal is `ttypts<N>` in `HostSession.tty`, in `ProcessTable`, in the hook's state file name and in
   the steer inbox; a session is live only once its launcher owns its terminal; a session's program is matched by
   token (Tasks 6a, 6b).
5. Nothing the host runs comes from a file changed after the host loaded it: launcher, parser, server, probe, new
   image, fallback (Tasks 3b, 8a, 9b, 9c, 9d). A handover writes no file, and a fallback keeps the vault (Task 9c).
   A handover's new image gets the target's `--node-root` and `--server`, never the old build's, and a fallback gets
   its own back (S2-D7, Task 9d).
6. No test-only flag is honoured by the user's host (Tasks 5a, 9a).
7. A parser's bytes reach a session only as a reply to a query the host saw (Task 9e).
8. The Mac: every Darwin path is the old body; every "on Linux" switch reads `Platform.CodeIdentity.isAvailable` and
   does nothing on the Mac; the host and app jobs of `v2 macos` are green after every task.

## Order

1, 2, 3a, 3b, 3c, 4a, 4b1, 4b2, 4c, 5a, **6a**, 5b, 6b, 7, 8a, 8b, 9a, 9b, 9c, 9d, 9e, 10a, 10b, 10c, 10d, 10e, 11a,
then the gated 12a and 12b whenever the user's config folder exists (Task 11b is after the bootstrap). Task 6a comes
straight after 5a (its reason is in 5b). `VibeHostTests` builds on Linux only from 5a: the Linux tests of 4a, 4b1 and
4b2 are written there and run first in 5a, each shown failing then by reverting its change. Tasks 2 to 3c touch only `VibePlatform`, its shim and its
tests (no file shared with main).

---

### Task 1: The security architecture document

Written, attacked and revised before Task 2 starts.

**Files:**
- Create: `docs/superpowers/specs/2026-11-13-v2-security-architecture.md` (done, `e0bc9642`),
  `docs/process/reviews/v2-security-review-2026-11-13.md`
- Modify: `docs/process/v2-mac-tasks.md` (three lines); this plan and `docs/superpowers/plans/2026-11-13-v2-bootstrap-path.md`
  (the document's changes); `docs/process/v2-port-map.md` (the planned Non-seam rows); the design's Decided section
  (the user's answers) and the passages of its body Step 4 names
- Test: `Tests/VibeCoreTests/SecurityDocumentLintTests.swift`. Modify `docs/guide/development.md` (name the suite).

**Interfaces:**
- Numbered sections `## S1.` to `## S12.`, each with **Decision**, **Why**, **Doesn't promise**, **Before the
  bootstrap:** (`yes` or `no` first), **Built in:**, **Held by:**, **Tests to write:**. A test name is a backticked
  token of the form `Identifier.identifier` with no `/` in it; paths stay out of backticks in `Held by:` lines. The
  unnumbered sections are reference and aren't linted.

- [ ] **Step 1: The failing lint.** `SecurityDocumentLintTests.everyNamedTestExists`: each name token in a `Held by:`
  line of a numbered section names a function declared in a type or extension of that name under `Tests/`
  (`@Test func name(` or `func name(`); a `planned:` part is skipped. `everySectionSaysWhatItDoesNotPromise` (a
  `**Doesn't promise.**` part) and `everySectionSaysWhenItIsNeeded` (`**Before the bootstrap:**` then `yes` or `no`).
  Shown failing on a copy of the document naming a test that doesn't exist, on one whose section lacks its
  `Doesn't promise` part, and on one whose `Held by:` line puts a path in backticks.
- [x] **Step 2: Write it** (`e0bc9642`; attacked by four reviewers on 2026-11-13 and revised). As written:

  | § | Subject | Decision, in short | Before the bootstrap | Built in |
  | --- | --- | --- | --- | --- |
  | S1 | Threat model and modes | the design's adversaries plus a lead or verifier turned by text; plain and strong modes; this machine's facts; WSL interop voids every lock | yes | the document; the engine's E1 checks |
  | S2 | The app on Linux | the connections the host makes for its server child through an inherited connector (S2-D1); the host binds its path again; the journal | yes | 4b2, 8a, 8b; engine E1, E8 |
  | S3 | The user's voice | the server's socket; per-request senders; the cgroup rule; a typed word; cards built from git and the vault; answers at rest | yes | engine E1, E4, E6, E8; bootstrap step 8 |
  | S4 | Session identity | today's rule, with the launcher owning its terminal, programs matched by token, ancestry start ticks, branch code in a session of its own; the session connector after | yes; no (the connector) | 6a, 6b, 10c |
  | S5 | Per-message credentials | S2-D4, with pid reuse and user namespaces named | yes | 3c, 7 |
  | S6 | Hardening | S2-D5: sealed `0111` copies, close-on-exec from creation, the reply grammar, unreadable means the host only by token | yes | 3a, 3b, 4a, 8a, 9a, 9b, 9e; engine E1 |
  | S7 | The vault's key per mode | S2-D3, with every record's first look held and `lead` refused until accepted | yes; no (strong mode) | 4c, 10e; engine E4, E8 |
  | S8 | The handover | S2-D8: sealed memory, sealed target and fallback; no switch while a worker runs, until measured | yes | 8b, 9c, 9d; bootstrap step 8 |
  | S9 | What the host executes | S2-D7: sealed copies, the static build, the unit, git from root's folders, the tool server's switch, the clean install; the keeper after the bootstrap (decision 18) | yes | 3b, 8a, 9b, 9d, 10c; bootstrap step 8 |
  | S10 | The sessions' environment | S2-D12, corrected | yes | 10a, 10b, 10c, 12b |
  | S11 | What plain mode doesn't promise | the list of 31, and the allow-list (S2-D11) | yes | 10d; engine E1 |
  | S12 | After the bootstrap | seventeen items, in order | no | [After the bootstrap](#after-the-bootstrap-from-this-stage) |

- [ ] **Step 3: The review record.** `docs/process/reviews/v2-security-review-2026-11-13.md` carries the four
  reviewers' findings as they gave them, each with its answer: the section of the document that took it (the
  document's [Answers to the attack review](../specs/2026-11-13-v2-security-architecture.md#answers-to-the-attack-review)),
  or, for a finding taken in part or found narrower, why. A finding the document doesn't answer is answered there
  first.
- [ ] **Step 4: The plans take the changes.** This plan and the bootstrap path take the document's
  [Changes](../specs/2026-11-13-v2-security-architecture.md#changes-the-stage-2-plan-needs) (this revision,
  2026-11-13), and the bootstrap path's engine outline (E1 to E8) takes the engine's list. The port map's *planned*
  Non-seam rows are rewritten to match this plan: `appPrincipal` gives way to the connector (`HostServer`'s connector
  clients, `HostConnection`'s registry), the state's hash through the secret channel to `HandoverMemory`, and the rows
  this revision adds (`Config.spawnNeedsLead`, `launcherImage`, `watchesItsPath`, `launcherTestDelay`, the
  `hostNotes` request, the readers of `/proc`, `LeadLaunch`, `Git`, `Worktrees`, `MCPKeeper`, `LeadVaultGuarded`)
  are listed, with the rows the critics' round adds (`UnixSocket.swift`'s `makeSocket` and `accept`;
  `HostConnection.swift`'s registry and its `held` rule; the `SessionParser.swift` `--host-pid` check; the
  `PTYSpawn.swift`, `HostedSession.swift` (`executable: args[0]`) and `ParserLink` hooks; `ProcessTable` and
  `SessionStrays`; `HostHandover.State.testAppConnector`; `handoverFlags`; the `Book`'s first-look holds in
  `LeadVault.swift`). The edit-kind count is seven. Three lines go into
  `docs/process/v2-mac-tasks.md`, under a heading for what `v2` found on the Mac and doesn't change: the app trusts any
  host at the socket's path and gives its key to one that says it holds none (`enrollApp`); `BranchCode.runPrefix`
  doesn't put a verifier's commands in a POSIX session of their own, so a command that double-forks without `setsid`
  keeps the verifier's terminal; the Mac's user's host honours `--handover-test-secret` and hands that secret over as
  the next image's vault (`main.swift:142-143, 129`). Each with what to check on a real Mac.

  **The design's body is brought in line with the document** in the same commit, so the spec and the plans agree
  before Task 2: "The platform layer" table and "The node's processes" (the app is the connections the host makes
  through its server child's connector, not "the host's own server child, by pid and start time"; sessions start
  from sealed copies, not "images held open from its start"; the server binds its own socket under
  `~/.vibeswitcher/v2/`, a deviation from "the host owns the listening sockets" recorded with its cost: between the
  server's death and its restart nothing listens at the path, T9); "Security" (the handover through sealed memory is
  before the bootstrap, and "the handover's state file owned by the host" goes); "The bootstrap" table and the stage
  1 and 2 after-lists (the static build and the sealed-memory handover before the bootstrap); "Open decisions" 4
  closed by S8.

  **Done ahead, in the consolidation of 2026-11-13:** the security document took the plans' changes back (the
  bootstrap path's step 8 corrections to S9, the engine plan's six changes, the keeper and GitGuard as decisions 18 and
  19, the restart routine, the deny list, the floor, the unit's PATH), the design's body was brought in line as above,
  and the port map's planned rows were redone from this plan. This step checks they still agree when Task 1 is
  committed, and writes the `v2-mac-tasks.md` lines.
- [ ] **Step 5: The user's answers.** The bootstrap path's
  [Decisions awaiting the user](2026-11-13-v2-bootstrap-path.md#decisions-awaiting-the-user) (decisions 1 to 20 and
  the machine steps) are put to the user in one message, and the answers go into the design's Decided section. An answer other than the recommendation is applied to this
  plan ([the table](#the-users-decisions-this-plan-assumes)) and to the document before Task 2.
- [ ] **Step 6:** `bash scripts/test.sh --filter 'DocLinksLintTests|SecurityDocumentLintTests'`; push; both workflows
  green; commit ("v2: the security architecture document, its review and the user's answers").

**Done when:** the document, its review record and the plans' changes are committed, the lint passes, and the user's
answers are recorded.

---

### Task 2: The platform's terminals, sockets, pairs and pipes

**Files:**
- Modify: `Sources/VibePlatform/Terminals.swift`, `Sockets.swift`, `Sockets+Linux.swift`, `Sockets+Darwin.swift`, `Sys.swift`
- Create: `Sources/VibePlatform/Terminals+Linux.swift`, `Terminals+Darwin.swift` (the Mac's `openpty` with its lock,
  moved from `Sources/VibeHost/PTYSpawn.swift` 27-41 unchanged)
- Modify: `Sources/CVibePlatform/include/CVibePlatform.h`, `shim.c` (`vibe_openpt`, `vibe_make_controlling`,
  `vibe_terminal_session`, `vibe_accept_cloexec`)
- Test: `Tests/VibePlatformTests/TerminalsTests.swift`, `SocketsTests.swift`, `SysTests.swift`

**Interfaces:**
- `Platform.Terminals.PseudoTerminal { master: Int32; slave: Int32; devicePath: String; name: String }`, `name` being
  `Terminals.name(devicePath:)`.
- `Platform.Terminals.open(rows: UInt16, cols: UInt16) -> Result<PseudoTerminal, Platform.Errno>`. Both ends
  close-on-exec from their making on Linux (`posix_openpt(O_RDWR|O_NOCTTY|O_CLOEXEC)`, `grantpt`, `unlockpt`,
  `vibe_ptsname_r`, the slave opened `O_RDWR|O_NOCTTY|O_CLOEXEC`, then `TIOCSWINSZ`).
- `Platform.Terminals.devicePath(master: Int32) -> String?` (`ptsname_r`'s answer, for the host's existing line).
- `Platform.Terminals.makeControlling(_ fd: Int32) -> Int32` (`TIOCSCTTY`; 0 or the errno).
- `Platform.Terminals.launcherOpenFlags: Int32`: how a launcher's spawn opens the slave as its stdin. The Mac:
  `O_RDWR`, as `PTYSpawn.swift:68` does today. Linux: `O_RDWR | O_NOCTTY`. glibc's `posix_spawn` runs `setsid` before
  the file actions, so a child that opens the slave without `O_NOCTTY` already has it as its controlling terminal
  before any of its code runs (measured here); with `O_NOCTTY` only the launcher's own `TIOCSCTTY` takes it, which is
  what Task 6b checks.
- `Platform.Terminals.controllingSession(_ fd: Int32) -> pid_t?` (`tcgetsid`) and `session(ofMaster: Int32) -> pid_t?`
  (`TIOCGSID` on the master: the session whose controlling terminal the slave is; nil while none). Task 6b's checks.
- `Platform.Sockets.makeSocket(type: Int32) -> Int32` (`socket(AF_UNIX, type|SOCK_CLOEXEC)` on Linux; `socket` then
  `fcntl` on the Mac, as `UnixSocket` does today) and `accept(_ listener: Int32) -> Int32` (`accept4(…, SOCK_CLOEXEC)`
  on Linux; `accept` then `fcntl` on the Mac).
- `Platform.Sockets.pair(type: Int32) -> (Int32, Int32)?`: `SOCK_STREAM` or `SOCK_SEQPACKET`, close-on-exec from its
  making on Linux (`SOCK_CLOEXEC`); on the Mac `socketpair` then `fcntl`, as today. `SOCK_SEQPACKET` is Linux's alone: the Mac's Unix domain
  has none, and `pair` gives nil there (`theMacHasNoSeqpacketSocket`), so the seqpacket tests below run on Linux only.
- `Sys.pipeClosedOnExec(_ fds: inout [Int32]) -> Int32`: `pipe2(O_CLOEXEC)` on Linux; `pipe` and `fcntl` on the Mac.

- [x] **Step 1: Failing tests**, on both systems unless marked.
  - `aNewTerminalIsNamedAsTheTableNamesIt`: open one; start a helper mode of the test binary through
    `Platform.Spawn` with stdin `.path(devicePath, flags: Platform.Terminals.launcherOpenFlags)`, stdout and stderr
    `.sameAsStdin`, group `.ownSession`; the helper calls `Platform.Terminals.makeControlling(0)` and sleeps, as the
    host's launcher does (`execIfLaunched`). `Platform.Processes.record(pid)`'s terminal equals `name`; on Linux it
    starts `ttypts`.
  - `theMastersSessionIsTheLaunchers` (Linux): the helper, started as above, reports `controllingSession(0)` nil and
    waits for the test's word; the test reads `session(ofMaster:)` nil, tells the helper to call `makeControlling(0)`,
    then reads the helper's pid. Shown failing with `O_RDWR` alone as the flags (the terminal is already the
    helper's before its first statement).
  - `bothEndsAreClosedOnExecFromTheStart` (`fcntl(F_GETFD) & FD_CLOEXEC` on both, read right after `open`).
  - `theSizeGivenIsTheTerminals` (`TIOCGWINSZ` gives 40×120).
  - `aPairIsClosedOnExecFromItsMaking` (both types); `aSeqpacketPairKeepsMessageBoundaries` (two 1-byte sends are two
    1-byte reads); `aPipeIsClosedOnExec`; `aSocketIsClosedOnExecFromItsMaking`;
    `anAcceptedConnectionIsClosedOnExecFromItsMaking`.
- [x] **Step 2: Implement.** The Mac's `open` is the existing `openpty` body with `openptyLock` and the two `fcntl`
  lines, moved; the Mac's `makeSocket`, `accept` and `pair` are today's calls with their `fcntl`.
- [x] **Step 3:** push; both green (the host job too: nothing in `VibeHost` uses these yet); commit ("v2: terminals,
  sockets, pairs and pipes through the platform, close-on-exec from their making").

**Done when:** `bash scripts/test.sh --filter VibePlatformTests` is green on Linux and the Mac's platform job is green.

---

### Task 3a: The process's own hardening, and tokens of other processes

**Files:**
- Create: `Sources/VibePlatform/ProcessSelf.swift`, `ProcessSelf+Linux.swift`, `ProcessSelf+Darwin.swift`
- Modify: the shim (`vibe_set_dumpable`, `vibe_get_dumpable`, and `vibe_pidfd_getfd(pidfd, targetfd, flags)` beside
  the existing `vibe_pidfd_open`: glibc here has no wrapper and Swift can't call the variadic `syscall`);
  `Sources/VibePlatform/Processes.swift`, `Processes+Linux.swift`, `Processes+Darwin.swift`
- Test: `Tests/VibePlatformTests/ProcessSelfTests.swift`, `ProcessesTests.swift`, with helper modes of the test binary
  (as `replaceProcessKeepsOnlyWhatItWasTold` has one)

**Interfaces:**
- `Platform.ProcessSelf.harden() -> Bool`: Linux, `PR_SET_DUMPABLE 0` and `RLIMIT_CORE 0`; the Mac does nothing and
  returns false.
- `isDumpable() -> Bool?`; `tracer() -> pid_t?` (`TracerPid`; nil on the Mac) and `tracer(fromStatus: String) -> pid_t?`.
- `Platform.Processes.token(_ pid: pid_t) -> Platform.PeerToken?`, public: on Linux the pid, uid and start ticks from
  the stat line (what `Sockets.token(pid:uid:)`, internal, builds today); nil on the Mac, where an `audit_token_t`
  can't be had for another pid without privileges. Compared with `sameImage(as:)`, which both systems have.
- `Platform.Processes.isDumpable(_ pid: pid_t) -> Bool?`: Linux, false when `/proc/<pid>/fd` is root's while the
  process's uid isn't root's, true when it is the process's own uid's, nil when it can't be read (gone); nil on the Mac.

- [x] **Step 1: Failing tests.**
  - `aHardenedProcesssMemoryCantBeOpened` (Linux): the helper hardens and sleeps; the test's
    `open("/proc/<pid>/mem")` fails with `EACCES`. Without `harden()` it opens, which is the failing form.
  - `aHardenedProcesssDescriptorsCantBeTaken` (Linux): `pidfd_getfd` of the helper's descriptor 0 fails `EPERM`.
  - `aHardenedProcessReadsAsNotDumpable` (Linux): `Processes.isDumpable` of the helper is true before it hardens and
    false after.
  - `hardeningIsNothingOnTheMac`.
  - `tracerPidIsReadFromStatus` (fixtures with 0 and 4242).
  - `aPidsTokenIsItsPeerToken` (Linux): `Platform.Processes.token(pid)` of a helper equals the `peerToken` of a
    connection the helper opens; after the helper ends and a new one runs, the old token isn't `sameImage` as any
    new one. `thereIsNoTokenForAPidOnTheMac` (Mac).
- [x] **Step 2: Implement.** Helper modes only; never in the test process (Global Constraints).
- [x] **Step 3:** push; both green; commit ("v2: the process's own hardening, and other processes' tokens, through
  the platform").

**Done when:** the tests pass on Linux, and the Mac's platform job asserts the Mac's forms do nothing.

---

### Task 3b: Sealed copies, and the measurement

The mechanism of S2-D5 and S2-D7. **Awaits:** decision 6 rests on this task's measurement.

**Files:**
- Modify: `Sources/VibePlatform/ProcessSelf.swift`, `ProcessSelf+Linux.swift`, `ProcessSelf+Darwin.swift`; the shim
  (`vibe_memfd_create`, `vibe_add_seals`, `vibe_get_seals`)
- Test: `Tests/VibePlatformTests/ProcessSelfTests.swift`; `docs/process/v2-linux-inventory.md` (the measurement)

**Interfaces:**
- `Platform.ProcessSelf.SealedCopy { fd: Int32; path: String /* /proc/self/fd/<fd> */; size: Int;
  func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T }`: `withBytes` reads the copy through
  its own descriptor (a read-only private mapping), so a hash taken there is of the bytes that run.
- `Platform.ProcessSelf.sealedCopy(of path: String, name: String) -> Result<SealedCopy, Platform.Errno>`. Linux:
  `memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING)` (and `MFD_EXEC` where the kernel has `vm.memfd_noexec`, 6.3+;
  not here), the file read once through an `O_RDONLY|O_CLOEXEC` descriptor and written into it, `F_ADD_SEALS` of
  `F_SEAL_WRITE | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL`, then `fchmod 0111` for an ELF image and `0555` for
  anything else (a script, whose interpreter must read it: Global Constraints). `SealedCopy.isScript: Bool` says
  which. The Mac: `.failure(ENOTSUP)`, and every caller keeps today's path there.
- `Platform.ProcessSelf.adopt(_ fd: Int32) -> SealedCopy?`: an inherited descriptor taken as a sealed copy only when
  `F_GET_SEALS` shows all four seals and its mode is `0111` (a new image's own copy after a handover, Task 9c). A
  scratch host whose inherited copy can't be adopted (a script stand-in handed over to it) makes a fresh copy of
  `/proc/self/exe` instead and says so in its log; a `--node` host refuses to start.
- **How a sealed copy is started:** as a child, through `Platform.Spawn` with `executable: copy.path` and
  `keep: [copy.fd]` (Linux's `Platform.Spawn` closes every descriptor from 3 up before `execve` resolves the path,
  `addCloseFromThree`, `Spawn+Linux.swift:98-107`, so a copy not kept would make the path vanish), its number in
  `VIBESWITCHER_IMAGE_FD`; in place, through `Platform.Spawn(…).replaceProcess()`, with the copy kept when the new image
  needs it. `Platform.ProcessSelf.closeInheritedImage() -> Int32?` reads `VIBESWITCHER_IMAGE_FD`, unsets it and closes
  that descriptor (returning its number, for a new image that adopts rather than closes it): the first act of every
  image a sealed copy starts, so no dumpable program after it (a session's) ever holds a copy.

- [x] **Step 1: Failing tests** (Linux unless marked; each copy that must stay private is made in a hardened helper).
  - `aChildStartedFromASealedCopyIsNotDumpableFromItsExec`: a hardened helper makes a sealed copy of `/bin/sleep`
    and starts it as a child as above; from the moment its pid is printed until 2 s later, the test polls
    `pidfd_getfd(child, 0)` and `open("/proc/<child>/mem")`: every try is refused. The same child started from the
    readable `/bin/sleep` is taken at once, which is the failing form. This is **the measurement** the document's
    S6, S8 and S11 rest on: its result, the kernel and the date go into `v2-linux-inventory.md`. If it fails here,
    stop and report: S6's windows are open on this machine, and the rule on switches stays.
  - `aSealedCopyCantBeWrittenOrChmoddedByAnotherProcess`: against a hardened helper holding a copy, the test's
    `open("/proc/<helper>/fd/<n>", O_WRONLY)`, `chmod` of that path and `pidfd_getfd` are refused; the helper's own
    `write` and `ftruncate` on it fail `EPERM` (the seals).
  - `aSealedCopyRunsAfterItsFileIsRewrittenInPlace`: copy the test binary to a scratch path; a helper makes a sealed
    copy of it; the file is **rewritten in place** with a script printing "replaced" (no process runs the file, so
    there is no `ETXTBSY`: the case where held `O_PATH` images failed); the copy, started as a child in a helper mode,
    prints the helper's mark and reports that it closed its inherited descriptor.
  - `aSealedCopysHashIsOfTheBytesItRuns`: the bytes `withBytes` gives equal the file's at the copy, still do after the
    file is rewritten, and are the bytes the child runs (its mark).
  - `anAdoptedDescriptorMustBeSealedAndUnreadable`: `adopt` takes a copy `sealedCopy` made, and refuses a plain
    `memfd` and a sealed one left readable.
  - `aScriptsSealedCopyRuns`: a `#!/bin/sh` file's copy is `0555`, `isScript`, and runs as a child, printing its
    mark. Shown failing with the copy made `0111` (the interpreter's `EACCES`).
  - **What copies cost**, recorded with the measurement: the time and the shared memory (`Shmem` in
    `/proc/meminfo`) for copies of the debug `vibeswitcher-host`, `vibeswitcher-mcp` (56 MB here) and the test binary
    (201 MB here), and for ten at once. Every scratch host started as a process copies its own image, and Task 8a's
    hosts copy the test binary as the server stand-in: if ten at once exceed a quarter of a CI runner's memory (16 GB
    on GitHub's Ubuntu runners), `ServerChildTests` and the other suites that start hosts as processes run
    `.serialized` on Linux, said in their files.
  - `thereAreNoSealedCopiesOnTheMac` (Mac): `.failure(ENOTSUP)`.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; commit ("v2: sealed in-memory copies of the images the host starts, measured").

**Done when:** the tests pass on Linux, the measurement is recorded, and the Mac's platform job is green.

---

### Task 3c: Descriptors passed over a pair, and senders named for tests

The platform half of the connector (S2-D1) and of Task 7's namespace tests (S5).

**Files:**
- Modify: `Sources/VibePlatform/Sockets.swift`, `Sockets+Linux.swift`, `Sockets+Darwin.swift`; the shim
  (`vibe_send_descriptor`, `vibe_receive_descriptor`, and, for tests only, `vibe_send_claiming`)
- Test: `Tests/VibePlatformTests/SocketsTests.swift`, with a helper mode of the test binary

**Interfaces:**
- `Platform.Sockets.sendDescriptor(_ fd: Int32, over socket: Int32) -> Bool`: one byte with `SCM_RIGHTS`. The Mac:
  false, and its doc comment says the Mac has no connector.
- `Platform.Sockets.receiveDescriptor(over socket: Int32) -> Int32?`: `recvmsg` with `MSG_CMSG_CLOEXEC`; exactly one
  descriptor is taken, a message with none or more than one gives nil and closes what came. The Mac: nil.
- `vibe_send_claiming(fd, bytes, count, pid, uid, gid)` (tests only, so named in the header): a send with an explicit
  `SCM_CREDENTIALS` naming `pid`. Task 7 runs it from a helper started under `/usr/bin/unshare --user
  --map-root-user --pid --fork` (util-linux), which a runner may refuse: those tests skip there, saying why.

- [x] **Step 1: Failing tests** (Linux).
  - `aDescriptorSentOverAPairArrivesClosedOnExec`: a helper sends the write end of a pipe over a `SOCK_SEQPACKET`
    pair; the test receives it, it is close-on-exec, and bytes written to it come out of the test's read end.
  - `aMessageWithTwoDescriptorsGivesNone`: both are closed (the pipe's read end sees end-of-file once the helper's
    copies are closed too).
  - `aSenderClaimingItsOwnPidIsBelieved`: `vibe_send_claiming` with the helper's own pid arrives with that sender
    (the control for Task 7's refusals).
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; commit ("v2: descriptors passed over a pair, through the platform").

**Done when:** the tests pass on Linux and the Mac's platform job is green.

---

### Task 4: `VibeHost` compiles on Linux, in four slices

Each slice is its own commit and its own Mac proof. Measure after each file with
`scripts/ci/linux-core-errors.sh VibeHost`, then `vibeswitcher-host`.

#### Task 4a: Terminals, spawning, exit watches, and close-on-exec from creation

**Files:** `Sources/VibeHost/PTYSpawn.swift`, `HostedSession.swift`, `SessionParser.swift`; the accept in
`HostServer.swift` (`acceptAll`, line 259); the probe's pipe and `SecretChannel`'s pair in `HostHandover.swift`
(159, 264); `HostStart.swift:16` (`O_CLOEXEC`); the signal pipe in `Sources/vibeswitcher-host/main.swift` (149-150);
`Sources/VibeCore/UnixSocket.swift` (`connectOnce` and `listen`'s `socket(`; `configure` untouched: a second
`FD_CLOEXEC` on Linux is harmless); in `VibePlatform` (no file shared with main), the bare `pipe(` sites switched to
`Sys.pipeClosedOnExec` (`PipeCommand+Linux.swift:21, 22, 194`, `FolderWatch+Linux.swift:52`, `Tools.swift:201`,
whose Mac form stays `pipe` then `fcntl`). Test: `Tests/VibeCoreTests/CloseOnExecLintTests.swift` (name it in
`docs/guide/development.md`); `HostServerTests.aSpawnDuringAnAcceptInheritsNoConnection` (in
`Tests/VibeHostTests/HostServerTests.swift`, run on the Mac now and on Linux from 5a).

- [x] **Step 1: Switch each site, mechanically.**
  - `PTYSpawn.spawn` onto `Platform.Terminals.open` and `Platform.Spawn` (stdin `.path(devicePath, flags:
    Platform.Terminals.launcherOpenFlags)`, stdout and stderr `.sameAsStdin`, group `.ownSession`, directory,
    environment, `keep: []` stated; the slave closed once `start()` returns). `execIfLaunched` uses `Platform.Terminals.makeControlling(0)`, its result still
    ignored here (Task 6b checks it on Linux).
  - `HostedSession.spawn`: `ptsname_r` becomes `Platform.Terminals.devicePath(master:)`. The next line, which drops
    `/dev/` and so gives `pts/3` on Linux (160-162), is **kept as it is**: Task 6a changes it after its failing tests.
  - `isExiting` becomes `Platform.Processes.record(pid)` with `.zombie` or exiting. The Darwin record already carries
    `PROC_FLAG_INEXIT` as `exiting` (`Processes+Darwin.swift:48`), so the Mac keeps its "on its way out" case.
  - The exit source (line 348) becomes `Platform.ProcessExit.watch`, kept in `exitSource`'s place (a watch nobody
    keeps never reports), with the exit poll kept.
  - `ParserLink.start` uses `Platform.Sockets.pair(type: SOCK_STREAM)` and `Platform.Spawn` per recon §1.2 (`keep`
    stated), and `Platform.Sockets.noSigPipe(socket:)`.
  - `SessionParser.runIfAsked`: `DispatchSource.makeProcessSource` becomes `Platform.ProcessExit.watch(getppid())`,
    held for the run. The host passes its own pid as `--host-pid N` (`ParserLink.start`, one argument), and the
    parser exits when `getppid()` isn't N. Today's check (`getppid() != host || host == 1`, `SessionParser.swift:57-61`)
    compares with the parent read at the parser's start, so a host already gone by then (its parser reparented to the
    user's systemd on Linux, not pid 1) isn't noticed. Non-seam edit.
  - **Close-on-exec from creation:** `acceptAll`'s `Sys.accept` becomes `Platform.Sockets.accept`; `UnixSocket`'s
    `socket(` becomes `Platform.Sockets.makeSocket`; the probe's pipe and the signal pipe become
    `Sys.pipeClosedOnExec`; `HostStart`'s `open("/dev/null", O_RDONLY)` takes `O_CLOEXEC`; `SecretChannel`'s
    `socketpair` becomes `Platform.Sockets.pair`, its `SO_SNDBUF` rule unchanged (the Mac's channel; on Linux it goes
    in 9c); the `VibePlatform` pipes above become `Sys.pipeClosedOnExec`.
- [x] **Step 2: The lint and the race test.**
  - `CloseOnExecLintTests.noBareSocketAcceptOrOpen`, matching calls, not substrings: a name at a word boundary not
    preceded by `.` (so `ChaChaPoly.open(` and `posix_spawn_file_actions_addopen(`, which opens in the child, aren't
    matched). In `Sources/VibeHost`, `Sources/vibeswitcher-host`, `Sources/VibeCore/UnixSocket.swift` and, once it
    exists, `Sources/vibeswitcher-server`: no `socket(`, `socketpair(`, `accept(`, `pipe(`, `Sys.accept(`,
    `Sys.pipe(`; an `open(` or `Sys.open(` whose arguments name an `O_` flag names `O_CLOEXEC` (a local closure
    called `open`, as in `PipeCommand+Linux.swift:58`, names none). In `Sources/VibePlatform` the same, with three
    exemptions listed in the test by file, each with its reason: `Sys.swift` (the raw wrappers themselves); the
    `+Linux.swift` forms whose call carries the flag (`SOCK_CLOEXEC`, `O_CLOEXEC`, `MFD_CLOEXEC`, `accept4`, `pipe2`);
    and the `+Darwin.swift` forms that stay as they are because changing them would change the Mac
    (`PipeCommand+Darwin.swift:8-9`, `FolderWatch+Darwin.swift:23, 34`, and any other the first run finds, named).
    Shown failing on a fixture file with a bare `socket(`, and passing at this task's own commit.
  - `CloseOnExecLintTests.everySpawnInTheHostNamesWhatItKeeps`: each `Platform.Spawn(` in `Sources/VibeHost` and
    `Sources/vibeswitcher-host` sets `keep`.
  - `aSpawnDuringAnAcceptInheritsNoConnection`: a scratch host takes 200 connections from one thread while it spawns
    sessions whose program lists its own open descriptors (`/proc/self/fd` on Linux, `/dev/fd` on the Mac): each
    lists 0 to 2 and the one its listing opened, nothing else. Two guards hold this: `keep: []`, with which
    `Platform.Spawn` closes everything from 3 up in the child (`Spawn+Linux.swift:95-107`), and the connection
    being close-on-exec before any session spawn after its accept. `acceptAll` and the session spawns run on the
    host's one serial queue, and `acceptAll` marks each connection before it gives the queue back (accept4's
    `SOCK_CLOEXEC` on Linux, and `UnixSocket.configure`'s `FD_CLOEXEC` on both). So this test can't show accept4
    on its own: that is `SocketsTests.anAcceptedConnectionIsClosedOnExecFromItsMaking` and the lint, and accept4
    matters for a spawn on another thread. It is shown failing (in 5a, where it first runs on Linux) only with
    `PTYSpawn`'s `keep` made nil and the connections left open on exec (the accept made with plain `accept`, and
    no `FD_CLOEXEC` in `configure`); either guard alone holds it, which is why the lints carry both rules.
- [x] **Step 3:** push; the Mac's host and app jobs green (`VibeHostTests` there exercise each site); commit ("v2: the
  host's terminals, spawns and exit watches through the platform; descriptors close-on-exec from creation").

#### Task 4b1: The server's peers, identity and orphans

**Awaits:** decision 4 (no subreaper): `orphanParents` exists because of it.

**Files:**
- Modify: `Sources/VibeHost/ClientConnection.swift` (`peer: Platform.PeerToken?`), `HostServer.swift`,
  `AppCode.swift` (bodies to the platform; the name and its functions stay as forwards);
  `Tests/VibePlatformTests/PlatformLintPending.txt` (`Sources/VibeHost/AppCode.swift` taken out: once it no longer
  imports Security, `thePendingListHoldsOnlyFilesThatStillBreakTheRule` fails otherwise)
- Create: `Sources/VibePlatform/CodeIdentity.swift`, `CodeIdentity+Darwin.swift` (the cdhash check and
  `proc_archinfo` read, moved), `CodeIdentity+Linux.swift`
- Test: `Tests/VibeHostTests/HostIdentitySeamTests.swift`

**Interfaces:**
- `HostServer.executable(of:)` stays a static, now a forward to `Platform.Processes.executable` (the tests call it,
  and `TestHost`'s default `appExecutable` comes from it).
- `Platform.CodeIdentity.isAvailable: Bool`: true on the Mac, false on Linux. The one value every "on Linux" switch
  outside `VibePlatform` reads (Global Constraints).
- `HostProcesses.isOrphan(parent:…)` takes the set of parents an orphan can have, and
  `HostProcesses.orphans(running:)` (`HostServer.swift:946-955`, which today looks only at `children(of: 1)`) looks
  at the children of each member of that set. `HostProcesses.orphanParents` is `{1}` on the Mac and, on Linux, `{1}`
  plus the parent an orphan of the host's is given, found once at start by a probe (S2-D6): the host starts
  `/bin/sh -c 'sleep 30 & echo $!'` through `Platform.Spawn`, reads the pid, waits for the shell, reads that pid's
  parent from `Platform.Processes.record`, and ends it. Non-seam edit.

- [x] **Step 1: Failing tests.**
  - `theMacsAppIsStillTheCdhashCheck` (Mac): a `Config` with only `appExecutable` set; the app's code answering the
    challenge with the key is `.app`; another process is refused `proveApp`.
  - `anOrphanedToolServerIsFoundOnLinux` (Linux): a tool-server stand-in whose parent ended is listed by
    `HostProcesses.orphans`, and its new parent is in `orphanParents` (asserted that way, not by naming systemd or
    pid 1: the subreaper depends on where the tests run).
  - `aLiveToolServerWhoseParentIsTheTestIsNotAnOrphan` (Linux): a stand-in that is the test process's child, with
    the test process among the scratch host's ancestors, isn't listed.
- [x] **Step 2: Switch the sites.** `audit_token_t` to `Platform.PeerToken` (lines 13 and 663); `watch(owner:)`
  (line 197) to `ProcessExit.watch`, kept; `executable(of:)` (691) forwards; the `HostProcesses` reads (944-960) to
  `Platform.Processes.record`, and `orphans(running:)` over every member of `orphanParents`.
- [x] **Step 3:** push; the Mac's host job green, and its **app job** green with the eleven app test files unchanged:
  that is the proof the Mac's app identity is intact; commit ("v2: the host's peers and identity through the platform").

#### Task 4b2: The app's connector, and who may spawn

The host's and the client's halves of S2-D1's connector, before any server child exists; and S2's spawn rule.
**Awaits:** decision 1 (the app on Linux is the connector's connections).

**Files:**
- Create: `Sources/VibeHost/V2/AppConnector.swift`, `Sources/VibeCore/V2/HostConnector.swift`
- Modify: `Sources/VibeHost/HostServer.swift` (the connector's clients registered beside the accepted ones; the
  `maxClients` count over accepted clients only; `checkPeer` skips its `SO_PEERCRED` form for a connector client;
  `.spawn` in `authorized`; `Config.spawnNeedsLead`), `Sources/VibeCore/HostConnection.swift` (the connector registry
  and `viaConnector`). Non-seam edits: each, with a port-map line.
- Test: `Tests/VibeHostTests/HostIdentitySeamTests.swift`, `Tests/VibeCoreTests/HostConnectorTests.swift`

**Interfaces:**
- `HostServer.openAppConnector(expecting sender: Platform.PeerToken?, requireNonDumpable: Bool,
  onDumpable: ((pid_t) -> Void)?) -> Int32?`: makes a `SOCK_SEQPACKET` pair (Task 2), keeps the host's end with
  `enableCredentials` and a read source on the host's queue, and returns the other end (close-on-exec in the host; a
  caller passes it on with `keep:`). `setAppConnectorSender(_ token:, for connector:)` sets the expected sender after a
  spawn. `closeAppConnector(_:)`. nil on the Mac (no `sendDescriptor` there).
- **A request** is one byte on the host's end, read with `Platform.Sockets.receive`. It is answered only when its
  sender is the expected token (else dropped and logged) and, with `requireNonDumpable`, when
  `Platform.Processes.isDumpable(pid) == false` (else refused, logged, and `onDumpable` called, which ends the child,
  Task 8a). Then a `SOCK_STREAM` pair; the host's end registered as a `ClientConnection` whose `caller` is `.app` from
  its first byte, `peer` the expected token, `viaConnector` true, sent no challenge (it gets the welcome when it says
  `hello`); the other end sent with `sendDescriptor` and closed in the host.
- **Until Task 7** a connector client's sender isn't checked: `checkPeer`'s `SO_PEERCRED` re-read can't apply to it
  (the host made the pair, so `SO_PEERCRED` names the host itself), and Task 7's per-message check replaces it. No
  user's host runs on Linux before Task 7 (the document, Principals).
- `HostConnection.register(connector: Int32, for path: String)`, `unregister(path:)`, `connector(for:)`: a registry
  under a lock, empty by default (kind 5). `HostConnection.init(path:queue:appKey:patience:viaConnector: Bool = true)`:
  a path with a registered connector is reached only through `HostConnector.connect(over:timeout:)` (one byte sent,
  the descriptor received, under a lock; replies may cross between threads, which is harmless: every app connection
  is alike), **never by path, also when the connector fails** (it throws). `viaConnector: false` connects by path as
  today (a test's "another process" on the same socket). A registry, not one member, because the tests run many
  scratch hosts in one process; the server registers one.
- A `HostConnection` reached through a connector sets `held = nil` whatever its `appKey`: the host sends a connector
  connection no challenge, so a request held for a proof (`HostConnection.swift:82, 125-136, 265-277`) would wait
  forever, and many tests send requests with no `hello` (`InputUnitTests`, `ShellTidyHostTests`, most of
  `SecurityHardeningTests`), passing `TestHost`'s app key all the same.
- `HostServer.Config.spawnNeedsLead: Bool`, false by default (kind 5): when set, `.spawn` is authorized only for
  `.app` and for a live session the vault binds to the lead role. `main.swift` sets it for the user's host on Linux
  (Task 4c).

- [x] **Step 1: Failing tests.**
  - `HostIdentitySeamTests.aConnectorConnectionIsTheAppWithNoChallenge` (Linux): a scratch host built without
    `TestHost`'s stand-in opens a connector expecting a helper's token; the helper asks for a connection, sends
    `hello` and an app-only request (`census`, a `vault .issue(role: .lead, …)` on a scratch repository): its first
    event is the welcome, not a challenge, and the request is answered.
  - `noConnectionByPathIsTheAppOnLinux` (Linux): on the same host, a client by path answering the challenge with the
    host's app key (with `appExecutable` the test runner, as `TestHost` sets it) is refused every app-only request.
  - `aConnectorRequestFromAnotherSenderMakesNoConnection` (Linux): a child the helper forks writes the byte; no
    descriptor comes back, and the host's log says why.
  - `aSessionWithoutTheLeadRoleCantSpawnWhereOnlyLeadsMay`, `aLeadCanSpawnWhereOnlyLeadsMay` (both): with
    `spawnNeedsLead`, a session's process with no role is refused `spawn`, one bound as a lead is answered.
    `aHostWithoutTheRuleSpawnsAsToday` (both).
  - `HostConnectorTests.aRegisteredPathIsNeverReachedByThePath` (both): a listener at the path records any connect;
    with a connector registered for it (one whose far end is closed, or, on the Mac, any number), the connection
    throws and the listener records nothing. `anUnregisteredPathConnectsAsToday` (both).
  - `HostIdentitySeamTests.aConnectorConnectionHoldsNoRequestForAProof` (Linux; it needs a host, so it lives in
    `VibeHostTests` and first runs in 5a): through a connector, with an app key given and no `hello` sent, a
    `sessions` request is answered.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; the Mac's host and app jobs green; commit ("v2: the app's connector on Linux, and spawn only
  from the app and a lead where told").

#### Task 4c: The handover, the vault and the host's main

**Awaits:** decision 3 (the Keychain's Linux form answers nil: the vault in memory only).

**Files:**
- Modify: `Sources/VibeHost/HostHandover.swift`, `VaultStorage.swift`, `HostStart.swift`,
  `Sources/vibeswitcher-host/main.swift`, `Package.swift` (`VibeHost` and `vibeswitcher-host` into `portableTargets`),
  `Tests/VibePlatformTests/PlatformLintPending.txt` (its last line, `VaultStorage.swift`, goes: empty),
  `Tests/VibeCoreTests/KeychainLintTests.swift` (the
  Keychain's new path)
- Create: `Sources/VibePlatform/Keychain.swift`, `Keychain+Darwin.swift` (the `SecItem` bodies of
  `VaultStorage.swift` 122-149, moved), `Keychain+Linux.swift`

- [x] **Step 1: Switch.** `HostHandover.probe` uses `Platform.Spawn` with stdout `.descriptor` of the
  `Sys.pipeClosedOnExec` pipe and `keep: []`; `exec` uses `Platform.Spawn(keep:).replaceProcess()`.
  `VaultStorage.keychainKey()` and `removeKeychainKey` forward to `Platform.Keychain`. `main.swift`'s `sigaction` line
  through `Platform.Signals`; `config.spawnNeedsLead = ownsLaunchers && !Platform.CodeIdentity.isAvailable` (Non-seam
  edit).
- [x] **Step 2: Build.** `swift build --build-system native` on Linux builds every portable target, `VibeHost` and
  `vibeswitcher-host` included; `linux-core-errors.sh` reports 0; the lint's pending list is empty. Each Non-seam edit
  of Task 4 is in the port map.
- [x] **Step 3:** push; the Mac's host and app jobs green; commit ("v2: the session host builds on Linux").

**Done when** (Task 4): both systems build everything, `bash scripts/test.sh` on Linux is as green as before, the
close-on-exec lint passes, and the Mac's host and app jobs are green.

---

### Task 5: `VibeHostTests` and the host's audit on Linux, in two slices

#### Task 5a: Compile, the guard, the list, the job, the app's stand-ins

**Awaits:** decision 1 (the stand-ins are connectors, as the real app's are).

**Files:** `Package.swift` (`VibeHostTests` on Linux, with its `Fixtures` resource and `exclude: ["MacOnlyTests.txt"]`);
`Tests/VibeHostTests/` files as found; `TestHost` and `TestClient` in `HostServerTests.swift`; `TestHosts.swift`;
`Sources/VibeHost/HostHandover.swift` (`State.testAppConnector`);
create `Tests/VibeHostTests/MacOnlyTests.txt`; `Tests/VibePlatformTests/MacOnlyTestsLintTests.swift` (both lists);
`scripts/test.sh` (line 323's "skipped on Linux until the session host builds here" goes);
`.github/workflows/v2-linux.yml` (a `host` job, 90 minutes); `Sources/vibeswitcher-host/main.swift` and
`Sources/VibeHost/V2/TestAppPrincipal.swift` (the scratch host's stand-in).

- [x] **Step 1: Compile.** The 30 test files that import Darwin get the smallest change that compiles:
  `EndedSessionTests` uses `Platform.Processes.openDescriptorCount`; `HostStopReapsTests` uses
  `Platform.Processes.record`; `TestHostsTests` uses `Platform.ProcessExit`; `HostHandoverTests` uses
  `Platform.Processes.executable`; a test that runs `/bin/zsh` takes `Platform.Tools.loginShell`. Listed Mac-only with
  reasons: `AppCodeTests` (cdhash), `ParserCostTests` (`/usr/bin/footprint`), `UpgradeFromLeadHostTests` (`xcrun`).
- [x] **Step 2: The app's stand-ins on Linux.**
  - **In-process hosts.** On Linux, a `TestHost` whose `appExecutable` is the default (the test runner) opens an app
    connector expecting the test process's token, with `requireNonDumpable: false` (the test process is dumpable,
    Global Constraints), and registers it for its socket (`HostConnection.register`, unregistered in `deinit`).
    `TestClient(host, asApp: true)` and `HostCall` to that socket then go through it; `TestClient(host, asApp: false)`
    connects with `viaConnector: false` and is another process to the host, as on the Mac. A `TestHost` built with
    another `appExecutable` (`AppKeyTests`' and `LeadVaultHostTests`' `/usr/bin/nc`) means "the test process isn't the
    app" and opens no connector, so those tests keep testing a refusal. On the Mac no connector is opened, and the
    cdhash and HMAC proof are exercised as today: `theMacsTestHostHasNoPrincipal` (Mac).
  - **What the stand-in can't do.** A connector connection is `.app` without `runsAppCode`, and `prove`, `enrollApp`
    and `replaceAppKey` require `runsAppCode` (`HostServer.swift:301, 318, 327`). The tests of the app's key
    (`AppKeyTests`, the `proveApp` cases of `HostServerTests` such as line 223, the raw-socket proof clients of
    `LeadVaultHostTests.swift:100` and `HostConnectionDeliveryTests`, and any enroll or replace case found) are listed
    Mac-only, by test name, with the reason "the Linux app is a connector's connection and holds no key".
  - **Scratch hosts started as processes.** `TestHosts.authorize` (`TestHosts.swift:16-33`) makes the test process
    the app by copying the runner beside the host as `VibeSwitcher` and answering the challenge, which rests on
    `AppCode.runs` (false on Linux, S2-D2). On Linux it makes a `SOCK_SEQPACKET` pair, starts the host with one end
    kept and `--test-app-pid <getpid()> --test-app-connector <n>`, and registers the other end for that host's
    socket. The host takes the pid's token (`Platform.Processes.token`) as the connector's expected sender, without
    the non-dumpable rule. Both flags are honoured only by a scratch host (refused with a log line by the user's host,
    `ownsLaunchers`, as `--parser-test-hooks` is, `main.swift:71`) and stripped from `config.arguments`. **The
    connector is carried across a handover from this task on**, not from 8b: `HostHandover.State.testAppConnector:
    TestAppConnector?` (the descriptor and the test's pid; optional, kind 6) with its descriptor in `descriptors`
    (`HostHandover.swift:68`), so the exec keeps it and the new image registers it again. Without it every test that
    acts as the app after a handover (`HostHandoverTests`, `VaultHandoverTests`, `LeadToolServerHandoverTests`) would
    fail in 5b for that cause alone. Task 8b adds only the server child's record. Non-seam edits (`main.swift`, one
    hook into `V2/TestAppPrincipal.swift`; `HostHandover.swift`, the field). The files that start hosts this way (`HostHandoverTests`, `HostLogTests`,
    `EndedSessionTests`, `EndingASessionTests`, `OrphanSweepTests`, `TestHostsTests`, `VaultHandoverTests`,
    `LeadToolServerHandoverTests`, and any others found) then need no change for the app's rights.
  - **Audit case:** `host-access.test.mjs` starts a host in a scratch home with no `--lock` (so it is that home's
    user's host) with `--test-app-pid` of its own pid and `--test-app-connector 3` (a pipe on that number), and is
    refused every app-only request.
  - Each of the 29 files that use `TestHost` is checked, not assumed.
- [x] **Step 3: The home guard** in its Linux form (`.init_array`, SIGPIPE ignored), as in the other test targets.
- [x] **Step 4: 4a's, 4b1's and 4b2's Linux tests run**, each shown failing by reverting its change (4a's race test
  as 4a says: `keep` made nil, a plain `accept`, and no `FD_CLOEXEC` in `configure`).
- [x] **Step 5:** push; the new Linux `host` job runs; commit ("v2: VibeHostTests build on Linux, with the app's
  stand-ins as connectors").

#### Task 5b: Run and sort, and the audit

**Task 6a is done between 5a and 5b.** Until it is, a hosted session's tty is `pts/3` on Linux while `ProcessTable`
and the hook say `ttypts3`, and every test that matches a session by terminal fails for that one cause, which could
be misread as "the test assumes the Mac" or counted toward the tenth.

**Files:** `Tests/VibeHostTests/` as found; `Tests/VibeHostTests/MacOnlyTests.txt`;
`Tests/VibeHostTests/SecurityHardeningTests.swift` (the `HostSecurityHardeningTests` suite); `scripts/test.sh`.

- [x] **Step 1: Run and sort**, after Task 6a, in stage 1's order (the platform wrong; the test assumes the Mac; the
  Mac's own). Stop and report if more than a tenth of the 55 files (five) would be listed whole or wrapped by `#if`
  **beyond the ones this plan already lists** (`AppCodeTests`, `ParserCostTests`, `UpgradeFromLeadHostTests`); tests
  listed by name (5a's app-key cases) are counted apart, each with its reason, and this plan's own Mac-only and
  Linux-only tests use runtime traits (Global Constraints), so they list nothing. Stop too if a failure shows a change
  in the Mac's behaviour. `HostHandoverStateTests` (the state file, the secret channel) run on
  Linux against today's file and channel until Task 9c lists their file and channel cases Mac-only.
- [x] **Step 2: An unknown process's vault requests.**
  `HostSecurityHardeningTests.anUnknownProcessGetsOnlyTheVaultsOpenReads` (both): a process in no session, by path,
  gets answers to the vault's reads that check no caller (`current`, `verdict`, `audits`, `ballots`, `head`,
  `guarded`, `reviewFloor`, `approved`, `unaudited`, `startedOver`, `verify`, `verifyWalletRequests`) and is refused
  every other vault request (`issue`, `bind`, `seal`, `setReviewFloor`, `approve`, `submitVerdict`, …), each by the
  vault's own check (the document, Principals).
- [x] **Step 3: The audit.** `Tests/SecurityAudit/host-access.test.mjs` runs on Linux unchanged: a fresh
  `--app-executable` still grants nothing (lines 63-83). `library-injection.test.mjs` tests the Mac's Hardened Runtime:
  `scripts/test.sh` skips it on Linux, saying so; on Linux the unit's `UnsetEnvironment=` and the static build hold
  that line for the host's start (the document's S9, T27; the bootstrap path, step 8). The audit's Linux case for the
  server child is Task 8a's.
- [x] **Step 4:** push; both green; commit ("v2: VibeHostTests and the host audit pass on Linux").

**Done when:** `bash scripts/test.sh --filter VibeHostTests` and the audit are green on Ubuntu with every skip listed,
and the `v2 linux` host job is green.

---

### Task 6a: Terminal names (test first; done straight after Task 5a, before 5b's sort)

**Files:** `Sources/VibeHost/HostedSession.swift` (160-162); Test: `Tests/VibeHostTests/HostedSessionTerminalTests.swift`

The bug: `HostedSession.spawn` names the terminal `pts/3` on Linux (`ptsname_r`'s `/dev/pts/3` less `/dev/`), while
`ProcessTable`, the hook and the steer inbox use `Platform.Terminals.name`, which gives `ttypts3`. Every match by
terminal fails without an error: `session(of:)`'s terminal fallback, `VibePaths.stateFile(tty:)` (which would even
write `state/pts/3.json`), the steer inbox, `HostRuntime.steer`, `LeadAgent.running(on:)`.

- [x] **Step 1: Failing tests** (Linux; run on the Mac too, where they pass):
  - `aSessionsTerminalIsTheTablesName`: a scratch host spawns `sleep 30`; `HostSession.tty` equals
    `ProcessTable.info(pid:)?.tty` of the program, and starts `ttypts` on Linux.
  - `aProcessOnTheSessionsTerminalIsThatSessions`: a second process on that terminal is `session(of:)`'s session.
  - `theHookStateFileOfASessionIsDirectlyInState`: `VibePaths.stateFile(tty:)` for the session's tty has `state/` as
    its parent folder.

  Shown failing against lines 160-162 as Task 4a left them.
- [x] **Step 2: Fix.** The tty is `Platform.Terminals.name(devicePath:)` of the device path (a call switched to the
  platform; on the Mac `/dev/ttys003` still gives `ttys003`).
- [x] **Step 3:** push; both green; commit ("v2: a session's terminal is named as the process table names it").

**Done when:** the three pass on both systems.

---

### Task 6b: A session's terminal is its own from the start, and its program is matched by token

The document's S4 fixes (T14, T42). Linux only; the Mac's paths are unchanged.

**Files:**
- Create: `Sources/VibeHost/V2/SessionIdentityChecks.swift` (the launcher's terminal check, the live rule, the token
  and ancestry checks)
- Modify: `Sources/VibeHost/PTYSpawn.swift` (`execIfLaunched`: one hook), `HostedSession.swift` (the program's token
  recorded at spawn; live only once the terminal's session is the launcher's; a reaped program not live),
  `HostServer.swift` (`session(of:)`: one hook). Non-seam edits. `HostServer.Config.launcherTestDelay:
  TimeInterval?` (kind 5; a scratch host passes it to its launcher as an argument, the user's host never).
- Test: `Tests/VibeHostTests/HostedSessionTerminalTests.swift`

**Interfaces:**
- On Linux the launcher, after `makeControlling(0)`, checks that it returned 0 and that
  `Platform.Terminals.controllingSession(0)` is its own pid; otherwise it writes why on the terminal and exits 127,
  before any exec. Because the launcher opens its terminal `O_NOCTTY` (Task 2's `launcherOpenFlags`), nothing has
  made the terminal its own before `makeControlling`; the test delay sits just before that call, so the window the
  attack test needs is open for as long as the delay.
- On Linux a spawned session counts as live (in `session(of:)` and every rule that reads `isLive`) only once
  `Platform.Terminals.session(ofMaster:)` names the launcher's pid; a session whose launcher exited 127 is ended with
  its reason.
- `HostedSession.programToken: Platform.PeerToken?` (Linux; read at spawn, re-read on restore while the host is still
  the program's parent). `session(of:)` matches a chain entry to a session's program by token (pid and start ticks),
  not by `childPID` alone.
- The ancestry chain is checked: each ancestor's start ticks are no later than its child's, and a child's parent is
  read again after its parent's entry was read; a chain that fails is no session's.
- A session whose program `HostedSession.reap(_:until:)` (its own queue) has reaped counts as not live before the next
  identity question is answered.

- [x] **Step 1: Failing tests** (Linux).
  - `aProcessThatTookASessionsTerminalFirstIsNotThatSession`: a helper calls `setsid` and spins opening the lowest
    free `/dev/pts/N` (without `O_NOCTTY`, so it becomes its controlling terminal); a scratch host with a launcher
    test delay spawns a session, whose terminal the helper takes; the session never becomes live, ends with the
    launcher's reason, and the helper is no session's (`session(of:)` is nil, and a vault request from it is an
    unknown caller's).
  - `aLauncherThatCantTakeItsTerminalExits`: the launcher run with a terminal another session controls exits 127
    without running its program (a marker file the program would write is absent).
  - `aReusedProgramPidIsNotTheSession`: `session(of:)` given a chain whose entry has a session program's pid with
    other start ticks (a fixture through the hook's injected reader) is nil.
  - `anAncestorYoungerThanItsChildBreaksTheChain`: a fixture chain where an ancestor started after its child is no
    session's.
  - `aReapedSessionIsNotLive`: a program reaped by `reap(_:until:)` and not yet processed by the session's queue is
    not live to `session(of:)`.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; commit ("v2: a session's terminal is its own from the start; programs matched by
  token").

**Done when:** the five pass on Linux, the Mac's host job is green, and S4's `Held by:` names them.

---

### Task 7: Each message's sender

**Files:** `Sources/VibeHost/ClientConnection.swift` (`readAvailable`: `Sys.read` to `Platform.Sockets.receive`;
`onRead` passes each chunk's sender; the frame decoder notes the senders of a frame's bytes), `HostServer.swift`
(`checkPeer(_ client:)` and its body **unchanged**, for its five call sites (280, 393, 410, 815, 845): on the Mac the
four that read nothing (`handle`, `reply`, `deliver`, `broadcast`) re-read `LOCAL_PEERTOKEN`, which names whoever last
sent, even bytes the host hasn't read yet, and that stays; on Linux it skips connector clients (4b2) and is otherwise
a no-op re-read of `SO_PEERCRED`. A new `checkSender(_ client:, sender:)` (`V2/`, one hook from `onRead` at 280)
applies the per-read rule to accepted and connector clients alike; `Platform.Sockets.enableCredentials` on the
listener in `start()` and `start(restoring:)`, and on the host's end of each connector connection at its creation;
`checkPeer`'s comment made the Mac's, with a line for Linux), `Sources/VibePlatform/Sockets+Linux.swift` (`receive`'s
comment corrected: a sender's token is nil when it has gone **and its pid wasn't given again**; otherwise it is the new
process's). Non-seam edits: the `onRead` hook and the decoder's sender list. Test:
`Tests/VibeHostTests/PeerPerMessageTests.swift`, `Tests/VibePlatformTests/SocketsTests.swift`.

**Awaits:** decision 1 (for app connections the expected sender is the server child's token).

- [x] **Step 1: Failing tests**, both systems unless marked.
  - `aForkedChildWritingOnALeadsConnectionMakesItNobodys`: a client is bound as a team's lead; a helper started with
    that connection's descriptor (`keep: [fd]`) writes a `sessions` request; the connection's caller is `.unknown`, and
    the next lead-only request is refused.
  - `aFrameSplitAcrossTwoSendersIsHandledAsNobodys`: half a frame from the test, half from the helper, on a lead's
    connection; the connection is `.unknown`, and the frame is handled as an unknown caller's request (refused
    anything beyond an unknown caller's rights), not dropped. That is what the Mac does today: `readAvailable` calls
    `onRead` (`checkPeer`) before it appends and delivers (`ClientConnection.swift:153-157`), so the frame arrives
    after the caller became `.unknown`. Asserting a drop would change the Mac.
  - `theAcceptedProcessKeepsItsIdentityOverAThousandWrites`.
  - `aForkedWriterIsStillCaughtWhenTheHostBroadcasts` (Mac): a forked child writes on a lead's connection bytes the
    host hasn't read yet; the next broadcast to that connection makes it `.unknown`, as today (the Mac's re-read at
    `broadcast` kept).
  - `aMissingSenderMakesTheConnectionNobodys`: the rule as a pure function
    (`SenderCheck.keepsIdentity(accepted:sender:)` in the `V2/` file, `@testable`): a nil sender is never the
    accepted process.
  - `SocketsTests.bytesFromAReapedSenderComeWithNoSender` (Linux): a child writes, exits and is reaped before the
    test reads; the bytes come with no sender.
  - `SocketsTests.aSenderCannotClaimAnotherPid` (Linux): `vibe_send_claiming` naming the test process's pid from a
    helper outside any namespace of its own fails with `EPERM`.
  - `SocketsTests.aSenderInItsOwnPidNamespaceCanNameOnlyItsOwnProcesses` (Linux; skipped, saying why, where the
    runner refuses a user namespace): a helper under `unshare --user --map-root-user --pid --fork` can claim its own
    namespace's pids, which arrive as its own processes, and can't claim a pid outside it.

  On Linux the first two fail before the change, because `SO_PEERCRED` is fixed at connect. On the Mac they pass
  already, through `LOCAL_PEERTOKEN`, and keep passing.
- [x] **Step 2: Implement.** `PeerToken.sameImage` is the comparison. On the Mac `receive` returns the token after the
  read, so one code path serves both. `Platform.Sockets.enableCredentials` (`SO_PASSCRED`) on Linux; on the Mac it
  does nothing, since `LOCAL_PEERTOKEN` needs no option.
- [x] **Step 3:** push; both green; commit ("v2: each message's sender, on accepted and connector connections").

**Done when:** the tests pass on both systems (the namespace test where a namespace can be made), the host job is green
on both, and S5's `Held by:` names them.

---

### Task 8a: The app on Linux is the host's server child, through its connector

**Awaits:** decision 1 (the principal), decision 17 (the server is in the node's unit and ends with it).

**Files:**
- Create: `Sources/VibeHost/V2/ServerChild.swift`:
  - at the host's start, `Platform.ProcessSelf.sealedCopy(of: PATH)` of `--server PATH` (hashed against `build-info`
    from Task 9b on, when `--node-root` is set); the connector from `HostServer.openAppConnector(expecting: nil,
    requireNonDumpable: true, onDumpable: end the child)`; the child started from the copy with `Platform.Spawn`
    (`keep: [copy.fd, connector]`, `VIBESWITCHER_IMAGE_FD`, `--host-connector <n> --host-socket <the host's socket
    path>`, then `--node --node-root PATH` for a `--node` host, else `--root <the host's VibePaths.root> --node-root
    <the host's install folder>` as S2-D1 says (Task 9b adds `--node`, `--node-root` and `--image-path`; until then
    the folder is the executable's), each `--server-arg X` a scratch host was given (refused, with a log line, by an
    `ownsLaunchers` host), group `.ownGroup`, the host's base environment). The engine's E1 needs no further edit
    here;
  - on the host's queue in the same turn as the spawn, the record (`Platform.Processes.token(pid)`) and
    `setAppConnectorSender`, then the child's end closed in the host;
  - on its exit (`Platform.ProcessExit.watch`): the connector closed and every app connection made `.unknown`, then
    `waitpid` of that pid, then a restart from the same sealed copy with a fresh connector after 1 s, doubling to 30 s,
    reset after 10 minutes up; each exit and restart written to stderr;
  - `ServerChild.isRunning`, and a count of restarts.
- Modify: `Sources/VibeHost/HostServer.swift`: `tidy`'s idle test asks `ServerChild.isRunning` (one line; kind 4);
  `acceptAll`'s `maxClients` check counts accepted clients only (kind 4).
- Modify: `Sources/vibeswitcher-host/main.swift`: `--server PATH` in `handoverFlags` (dropped from
  `config.arguments`; `handOver(to:)` and `goBack` append the value S2-D7 says, so a switch brings the target's
  server); `--server-arg X`, scratch only, kept in `config.arguments`; the Mac takes no `--server` (no server child
  there). Non-seam edit. *As made:* `--server` stays in `config.arguments` until Task 9d (before an install root the
  value S2-D7 says is the same path), which moves it into `handoverFlags`; the port map says why.
- Test: `Tests/VibeHostTests/ServerChildTests.swift`; `Tests/VibeNodeTests/ServerLintTests.swift` (name it in
  `docs/guide/development.md`); `Tests/SecurityAudit/host-access.test.mjs` (the Linux case). The child is a helper
  mode of the test binary, chosen by its argv (`--host-connector`) in the test binary's load-time initializer, not
  by an environment variable as `SpawnTests.swift:13`'s is (the host's base environment filters any such variable
  out, `main.swift:27, 55`). It closes its inherited image descriptor, marks the connector close-on-exec, calls
  `Platform.ProcessSelf.harden()` (as `vibeswitcher-server` must, in the engine's E1), registers the connector for
  `--host-socket`, then does what a file beside that socket path tells it (`server-helper-actions`, one line each:
  `call census`, `handover PATH`, `spawn …`, `dumpable`, `sleep`), speaking to the host through `HostCall`.

- [x] **Step 1: Failing tests** (Linux unless marked).
  - `theServerChildsConnectorConnectionsAreTheApp`: the helper makes three `HostCall` calls (three connections); each
    app-only request (`vault .issue(role: .lead, …)` on a scratch repository, `spawn`) is answered.
  - `aConnectionFromAnotherProcessIsNotTheApp`: the test's own connection by path, on a scratch host built without
    `TestHost`'s stand-in, is refused app-only requests.
  - `aChildOfTheServerIsNotTheApp`: a process the helper starts (which inherits no connector: close-on-exec) is
    refused.
  - `anotherProcessWritingOnTheServersConnectionMakesItNobodys` (Task 7's rule on an app connection).
  - `theServerIsStartedAgainAfterItDies`: kill the helper; a new pid is the app; a connection the old pid left open
    is nobody's.
  - `aServerFileRewrittenInPlaceIsNotWhatRestarts`: rewrite PATH **in place** with a program printing "replaced"
    while the helper runs from its copy, kill the helper; what restarts reports the helper's mark.
  - `aServerChildThatIsDumpableIsNotTheApp`: a helper mode that makes itself dumpable again
    (`prctl(PR_SET_DUMPABLE, 1)`) before it asks for a connection gets none, and is ended; the log says why.
  - `appConnectionsDontCountTowardMaxClients`: with `maxClients` 2 filled by two clients by path, the helper's app
    connections are still made and answered.
  - `aHostWithAServerChildDoesNotExitIdle`.
  - `theServerHelperIsNotDumpable`: under a scratch host started as its own process (`TestHosts`), never an
    in-process `TestHost` (the test process is dumpable, and holds the copy then), `/proc/<helper>/mem` gives `EACCES`
    from its start (the sealed copy), not only after its `harden()`.
  - `theServerChildIsToldItsSocketAndFolder`: the helper reports the `--host-socket` it was given (a scratch host's),
    the `--root` (the scratch host's `VibePaths.root`) and the `--node-root` (for a host started with `--node-root`,
    that folder).
  - `theMacStartsNoServerChild` (Mac): with no `--server`, no connector is opened.
  - `ServerLintTests.theServerNeverExecs` (both): no `execve`, `execv`, `Platform.Spawn(…).replaceProcess`,
    `HostHandover.exec` or `BinaryWatch` in `Sources/vibeswitcher-server` and `Sources/VibeNode`, and no
    `viaConnector: false`. It passes vacuously until the engine's E1 creates the server, and is shown failing on a
    fixture.
  - `host-access.test.mjs`, a Linux case: a scratch host with `--server` set to a small script that only sleeps
    (sealed `0555`, so it runs; it never asks for a connection, so its being dumpable doesn't matter); the audit's
    own client and a client the script starts both get errors for `proveApp`, `replaceAppKey`, `handover`, `vault`
    and `spawn`.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; the host and app jobs green on both; commit ("v2: the app on Linux is the host's server child,
  through its connector").

**Done when:** the tests pass, S2's `Held by:` names them, and the Mac's host and app jobs are green.

---

### Task 8b: The server child across a handover, the host's path, and the journal

**Awaits:** decision 1; decision 5 (the record travels in the handover's state, which Task 9c puts in sealed memory).

**Files:**
- Modify: `Sources/VibeHost/HostHandover.swift`: `State.serverChild: ServerChildRecord?` (pid, start ticks, the
  connector's descriptor, the server copy's descriptor, the path), optional so the format stays 1 (kind 6), its
  descriptors in `descriptors` (`State.testAppConnector` is Task 5a's). Non-seam edit.
- Modify: `Sources/vibeswitcher-host/main.swift`: the new image restores the record only when the pid's parent is its
  own pid, its token's start ticks match, it is no restored session's program and no parser, and its connector is
  among the inherited descriptors; otherwise it clears the record and starts the server again from its sealed copy.
  Non-seam edit.
- Create: `Sources/VibeHost/V2/HostPathWatch.swift`: the user's host watches its socket's folder
  (`Platform.FolderWatch`) and, at each housekeeping (30 s), checks that its socket path and lock path still name the
  inode it bound and the file it locked (recorded at `bind`; the lock descriptor's `fstat`). On a socket mismatch it
  removes what is there, binds a fresh listener (`SO_PASSCRED` before its first accept), swaps it in for the accept
  source, and closes the old one. On a lock mismatch it takes the lock at the path again and holds both, or, when
  another process holds it, says so. Each is logged to stderr and counted for `hostNotes`. One hook in `serve()`
  (kind 4), active only for the user's host (`Config.watchesItsPath`, false by default, kind 5).
- Modify: `Sources/VibeCore/HostProtocol.swift`, `HostServer.swift`: `HostRequest.hostNotes`, app-only, answered with
  `HostEvent.hostNotes(HostNotes)` (`startedAt`, the server's restarts, replaced paths, refused app connections), under
  `HostProtocol.Capability.hostNotes` (kind 7). The server asks it on each refresh (the engine's E1).
- Modify: `Sources/VibeHost/HostServer.swift` and `main.swift`: the host's start, the server child's exits and
  restarts, refused app connections and replaced paths go to stderr as one line each (`vibeswitcher-host: …`), ids and
  counts only, never a goal, answer or screen text; the unit sends stderr to the user journal (the bootstrap path,
  step 8).
- Test: `Tests/VibeHostTests/ServerChildTests.swift`.

- [x] **Step 1: Failing tests** (Linux).
  - `theServerChildSurvivesAHandover`: after a handover to the same build, the same pid is the app over its
    connector, and an app-only request is answered.
  - `aForgedServerChildInTheStateIsNotTheApp`: the restore's own check, given a state (through `@testable`) whose
    record names a session's program (a child of the host, but not the server): the record is cleared, that process is
    refused app-only requests, and a new server child is started.
  - `aSquattedHostPathIsBoundAgain`: a scratch host with `watchesItsPath` set; a process renames its own
    listening socket over the host's path; within the folder watch's next event (or one housekeeping), a client by path
    reaches the host again, and `hostNotes` lists the replaced path.
  - `theHostWritesStartsAndServerRestartsToStderr`: a scratch host's stderr has its start, the server's exit with its
    status, the restart, and a refused app connection, each as one line with no screen text.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; commit ("v2: the server child across a handover; the host keeps its path and says
  what happened").

**Done when:** the tests pass, S2's and S8's `Held by:` name them, and the Mac's host and app jobs are green.

---

### Task 9a: Hardening at start, readers of `/proc`, and the test-only flags

**Files:**
- Create: `Sources/VibeHost/V2/HostHardening.swift` (`atStart(mode:)`: `harden()`, then `tracer()`; the tokens the
  host recorded for itself, its parsers and its server child: `HostHardening.isOurs(_ token:)`)
- Modify: `Sources/vibeswitcher-host/main.swift`: the host and parser modes call `HostHardening.atStart` first (the
  launcher mode doesn't: it execs the session's program at once); a traced host refuses to start. On Linux the
  test-only flags (Global Constraints) are taken only when `!ownsLaunchers`, as `--parser-test-hooks` is, and stripped
  from `config.arguments`: today `--handover-test-secret` is honoured by any host (`main.swift:142-143`), kept across
  handovers (not in `handoverFlags`), and the handed-over secret becomes the next image's vault (line 129). **On the
  Mac that stays as it is** (the switch reads `Platform.CodeIdentity.isAvailable`), and Task 1's line in
  `v2-mac-tasks.md` records it. Non-seam edits.
- **`ownsLaunchers` by the lock file's identity, not its spelling** (found by the commit security review of Task 5a,
  2026-11-13): today `ownsLaunchers` is `lockPath == VibePaths.hostLock.path` (`main.swift:34`), a comparison of
  strings, so `--lock ~/.vibeswitcher//host.lock`, a `..` or a symlink to the user's lock names the user's lock and
  yet makes a host that honours every test-only flag (`--test-app-pid`, `--test-app-connector` make any pid the app).
  On Linux it becomes "the lock this host holds is the user's lock file": the held descriptor's `st_dev` and `st_ino`
  equal those of `VibePaths.hostLock` (`lstat`, no link followed, a link being refused as a lock), through a
  `Platform.Files.sameFile(_ fd: Int32, _ path: String) -> Bool`. Tests: `aSecondSpellingOfTheUsersLockIsTheUsersLock`
  (`//`, `/./`, `..`, and a symlink, which is refused) and `aScratchLockIsNotTheUsers`. On the Mac the comparison
  stays as it is (a line in `v2-mac-tasks.md`).
- Modify, for "unreadable is the host only by token" (S2-D5). Step 1 first lists every reader of another process's
  `/proc` entries in `VibeCore`, `VibeHost` and the executables, with **the process it runs in**: the host
  (`HostServer.executable(of:)`, the orphan sweep in `HostProcesses`, `session(of:)`'s ancestry), the hook, the tool
  server, the engine, the command line. Every reader, in any process, takes an unreadable process as "unknown, still
  running", never "gone" (`ProcessTable`'s executable and cwd, `SessionStrays`' environments). Only a reader in the
  host takes one as the host, its parser or its server, through `HostHardening.isOurs` (a hook the host sets; kind 5,
  nil by default: today's reading). A reader outside the host that must name the host compares with the pid and start
  time its welcome gave it, and with no welcome says "unknown". Non-seam edits, one port-map line each.
- Test: `Tests/VibeHostTests/HostHardeningTests.swift`

- [x] **Step 1: Failing tests** (Linux unless marked).
  - `theHostIsNotDumpableAfterStartAndAfterAHandover`: `open("/proc/<host>/mem")` from the test fails `EACCES`, before
    and after a handover to the same build.
  - `aSessionsProgramIsDumpableAsUsual`.
  - `anUnreadableHostIsTheHostNeverGone` (the document's name): with a scratch host hardened, `SessionStrays` and `ProcessTable` called in the test
    process report it as still running, not gone; the host's own `isOurs` names it the host.
  - `anotherHardenedProcessIsNotTakenForTheHost`: a helper that hardens itself (any process may) is "unknown, still
    running" to every reader above, never the host.
  - `nothingSecretIsInTheHostsArgumentsOrEnvironment`: the host's `/proc/<pid>/cmdline` (readable) and the environment
    it was started with carry no key, grant, vault bytes or test secret, before and after a handover.
  - `theUsersHostIgnoresTestSecretFlags` (Linux): a host in a scratch home with no `--lock` (that home's user's host,
    `ownsLaunchers`, no `--node`) given `--handover-test-secret`, `--handover-test-secret-file`, `--install-root`,
    `--handover-test-traced` and `--test-app-pid`, and `--server` set to Task 8a's server helper, whose actions file
    says `handover <the same build>` (the helper is that host's app; nothing in the test can be, since the host
    refuses `--test-app-pid`). It hands over its real vault, takes no install root from the flag, reports no tracer
    and opens no test connector; its log names each refused flag, and none is in the arguments it hands over with.
  - `theMacsUsersHostKeepsTodaysTestSecret` (Mac): the same host, by today's `TestHosts.authorize`, still hands the
    test secret over, as at `47636aaf`. (As built, approved by the lead 2026-11-14: a unit test of the Mac's forms of
    `HostHardening`'s decisions, starting no host. A user's host on the Mac reads its vault's key from the real
    Keychain, which `KeychainLintTests` forbids a test, and `ServerChildHost(usersHost:)` throws there; a scratch
    host's carried test secret on the Mac stays `HostHandoverTests.secretsReachTheNewBuildAndNeverTheStateFile`'s.
    `docs/process/v2-mac-tasks.md` records it.)
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; commit ("v2: the host hardened from its first statement; unreadable is the host only
  by token").

**Done when:** these pass on Linux, S6's `Held by:` names them, and the Mac's host job is green.

---

### Task 9b: The host's own sealed images, its launcher and parsers, `build-info` and `--node`

**Awaits:** decision 17 (`--node` and `--node-root` are how the unit starts the host).

**Files:**
- Create: `Sources/VibeHost/V2/HostImages.swift`: at start, the own image's sealed copy from `/proc/self/exe` (the inode
  this process runs, which can't be written in place while it runs) on a fresh start, or adopted from the inherited
  descriptor after a handover (Task 9c); the server's from `--server`; with `--node-root`, each copy's SHA-256 (taken
  through `withBytes`) compared with `<node-root>/build-info`, and the host refuses to start on a mismatch or a missing
  record.
- Create: `Sources/VibeCore/V2/BuildInfo.swift` (in `VibeCore`, the 9b review: `ServerBuild` reads it), which **fixes the `build-info` format** (the bootstrap path's step 8
  writes it, `ServerBuild` reads it): `<installRoot>/<commit>/build-info`, JSON
  `{"format":1,"commit":"<40 hex>","binaries":{"vibeswitcher-host":"<sha256 hex>",…},"swift":"<swift --version>",
  "resolved":"<sha256 of Package.resolved>"}`, one entry per file in that build's `bin/`. A newer format is refused
  (rule 11).
- Modify: `HostServer.Config.launcherImage: Int32?` (kind 5, nil on the Mac and by default): the descriptor
  `PTYSpawn.spawn` and `ParserLink.start` keep in their child (one hook each, kind 4). `PTYSpawn.execIfLaunched` and
  `SessionParser.runIfAsked` close the inherited image first (`closeInheritedImage`), and on Linux the launcher, after
  its terminal check (Task 6b), calls `prctl(PR_SET_DUMPABLE, 1)` and then raises its own `oom_score_adj` by 500
  before its exec (one hook each, kind 4). Started from a `0111` copy it is non-dumpable, its `/proc/self/*` files are
  root's, and the write fails `EACCES` without that call (measured here); the program it execs next is dumpable
  anyway. A failed write is said on the terminal and the launch goes on.
- Modify: `Sources/vibeswitcher-host/main.swift`: on Linux `launcher: ownCopy.path` with `config.launcherImage =
  ownCopy.fd`, and no launcher copies are made (`ensureLauncher` and its cleanup loop run only where copies aren't
  sealed, i.e. on the Mac). `--node-root` is honoured by a scratch host too (the tests' build folders, with `--lock`);
  `--node` is what marks the user's host, and requires `--node-root` and `--server`; with it, before
  anything reads a path, `HOME` is set from `getpwuid(getuid())` and `VIBESWITCHER_HOME` and `CFFIXED_USER_HOME` are
  unset, so `VibePaths.root` never comes from the environment (`ownsLaunchers` compares two paths derived from that
  root, `main.swift:32-34`). On Linux a host that would hold the lock under the account's own `~/.vibeswitcher` (by
  `getpwuid`) without `--node` refuses to start, saying why (Global Constraints, "Which host is the user's"); a
  scratch home's host is unaffected. The paths derived from the executable today (`main.swift:30-38, 68, 124`: the
  build id, `vibeswitcher-mcp`, the command folder, the default app executable) come from `--node-root`, or on a
  scratch host from `--image-path` (appended by a handing-over host, S2-D7) or, at a scratch host's fresh start, its
  executable as today. `--node-root` and `--image-path` join `handoverFlags`. The server child is started with
  `--node-root` and `--node` from here on (Task 8a). Non-seam edits.
  A `--node` host also refuses a `--server` other than `<node-root>/bin/vibeswitcher-server` (compared after both
  are resolved, a link refused), before the hash check: the server is the install's by its place as well as its
  bytes (the commit security review of Task 8a, 2026-11-14: `--server` names the app's principal, so the user's
  host takes none but its own). Test: `theUsersHostTakesOnlyItsInstallsServer`.
- Test: `Tests/VibeHostTests/HostHardeningTests.swift`, `HandoverLinuxTests.swift`
- *As made:* no `Config.launcherImage`: `PTYSpawn.spawn` and `ParserLink.start` keep the descriptor the launcher's
  path names when it is `/proc/self/fd/N` (`HostImages.launching`), which the field would have had to reach through
  `HostedSession.spawn`, `restore` and `HistoryRead`. A host started from a sealed copy (a test's now, a handover's
  from Task 9c) adopts that copy as its own (`/proc/self/exe` is then unreadable to it). `--node-root` stays in
  `config.arguments` until Task 9d appends the target's, as `--server` does; on Linux the fallback is the image's path
  until Task 9c. `--node` also takes only the account's own lock (`HostImages.mayStart`). A start refused by these
  checks sends a handover's new image back rather than ending it. **Approved by the lead** (the 9b review,
  2026-11-14): no `Config.launcherImage`, as above; the review fixes make the case stronger, since sessions' launchers
  and parsers now start from two different copies, which one field couldn't name.
- *As made, the 9b review fixes (2026-11-14):* sessions' launchers start from a second sealed copy of the host's image,
  made from its own (`Platform.ProcessSelf.sealedCopy(of:name:)` taking a copy, `HostImages.forSessions`, one more hook
  line in `PTYSpawn.spawn`), never from the parsers' copy: a launcher made dumpable before its exec lets any process
  of the user `chmod` its `/proc/<pid>/exe`, which was the parsers' copy. The host puts a copy's mode back before
  each start from it (`Platform.ProcessSelf.restoreMode`). `BuildInfo` is in `Sources/VibeCore/V2/`, so
  `ServerBuild` (VibeCore, linked by `vibeswitcher-mcp`) can read it. Test:
  `aLaunchersImageChangedFromOutsideNeverReachesTheParsers` (with `--launcher-test-hold`), shown failing with the
  launchers started from the parsers' copy.

- [x] **Step 1: Failing tests** (Linux). The two `build-info` tests are in `HandoverLinuxTests`, as the document's S9
  places them; the rest in `HostHardeningTests`.
  - `aSessionStartedAfterTheHostsFileWasReplacedRunsThisBuild`: start a scratch host from a scratch copy, rewrite
    the file in place with another program (no process runs the file: the host runs its sealed copy), spawn a
    session; its launcher reports the first build's mark, and no `launcher-*` file exists under the scratch home's
    `host/`.
  - `aParserIsNotDumpable`: `/proc/<parser>/mem` gives `EACCES`.
  - `aSessionsProgramHoldsNoImageDescriptor`: a session's program lists its descriptors: no `memfd:` among them, and
    no `VIBESWITCHER_IMAGE_FD` in its environment.
  - `aSessionsProgramIsTheOOMKillersFirstPick`: its `oom_score_adj` is the host's plus 500, and nothing about it is
    on the session's terminal. Shown failing without the launcher's `PR_SET_DUMPABLE 1` (the write's `EACCES` is
    said on the terminal, and the value is the host's).
  - `aHostOnTheAccountsOwnHomeNeedsNode`: the start check as a pure function (`HostImages.mayStart(lockPath:,
    accountRoot:, node:)`): the account's own lock without `--node` is refused; a scratch home's lock isn't.
  - `aHostWhoseImageDiffersFromItsBuildInfoDoesNotStart` (a scratch `--node-root` whose `build-info` records another
    hash; the host exits non-zero, saying which binary).
  - `aNewerBuildInfoFormatIsRefused`.
  - `theNodesRootIsNeverFromTheEnvironment`: the function `main.swift` calls for `--node`
    (`HostImages.nodeEnvironment(_ environment:, accountHome:)`), given `VIBESWITCHER_HOME`, `CFFIXED_USER_HOME` and
    a `HOME` of a scratch folder, returns the account's home and neither variable. No `--node` host is started in a
    test: it would be the user's host, on the user's `~/.vibeswitcher` (Global Constraints).
  - `theNodeTakesItsFoldersFromNodeRootNotItsExecutable`: with `--node-root` and `--image-path` naming different
    folders, `vibeswitcher-mcp` and the command folder are the node root's.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; commit ("v2: the host runs its sealed copies; build-info and --node").

**Done when:** these pass on Linux, S6's and S9's `Held by:` name them, and the Mac's host job is green.

---

### Task 9c: The handover through sealed memory

**Awaits:** decision 5 (sealed memory instead of the state file).

**Files:**
- Create: `Sources/VibeHost/V2/HandoverMemory.swift`: the state written into a sealed `memfd` (`MFD_CLOEXEC |
  MFD_ALLOW_SEALING`, all four seals), returned as a descriptor; the secrets the same way; `secrets(from fd:)` reads
  from offset 0 with `pread` and doesn't close; the state's path is `/proc/self/fd/<n>`.
- Modify: `Sources/VibeHost/HostHandover.swift`: on Linux `write` gives way to `HandoverMemory` (the state's file and
  its `.partial` never made), `probe` starts the target's sealed copy with `keep: [copy, state]` and
  `--handover-probe /proc/self/fd/<state>`, `takeSecrets` uses `HandoverMemory.secrets` and leaves the descriptor open
  until the restore succeeded, and `State` gains `images: HandoverImages?` (the new image's own copy, the old image's
  copy for the fallback, and, with an install root, Task 9d's server copy; optional, kind 6). One hook each (kind 4).
- Modify: `Sources/VibeHost/HostServer.swift` `handOver(to:)` (700-758): one hook: on Linux the target is loaded as a
  sealed copy before anything else, probed and exec'd from that copy (the exec keeps the state, the secrets, the
  images and every session's descriptor); no state file is written or unlinked. Non-seam edit.
- Modify: `Sources/vibeswitcher-host/main.swift`: `goBack` on Linux execs the old image's sealed copy with the same
  descriptors and the same `--handover` path, and never unlinks it; a traced new image closes the secrets unread and
  goes back; a traced fallback ends; after a successful restore the state and secret descriptors are closed (not
  unlinked); a fresh host that isn't restoring, once it holds the lock, removes any `host.lock.handover` and its
  `.partial` and logs it; the new image adopts its own copy (`Platform.ProcessSelf.adopt`; a script stand-in's can't
  be, Task 3b) and checks it as Task 9b does, against the `--node-root` that `handOver(to:)` appended (the target's
  build, S2-D7); once restored it marks every descriptor it kept close-on-exec (S2-D8). Non-seam edits.
- Modify: `Tests/VibeHostTests/MacOnlyTests.txt`: `HostHandoverStateTests.theStateFileIsPrivateAndReadBack` and
  `secretsGoThroughAChannelAndNowhereElse` listed Mac-only by name, with the reason "Linux hands over through sealed
  memory; HandoverLinuxTests hold it".
- Test: `Tests/VibeHostTests/HandoverLinuxTests.swift`, `HostHardeningTests.swift`
- *As made (2026-11-14), approved by the lead 2026-11-14:*
  - **A traced new image leaves the secrets unread and open, not closed** (approved): this task's own test
    `aTracedNewImageGoesBackWithoutTheVault` wants the previous build to serve on with its vault, which it can't if
    the traced image closes the only descriptor of it (the fallback is the same process). The traced image never
    reads them; the fallback, traced too, ends, which closes them. A real tracer could not have attached to the
    non-dumpable old image, so it was there all along and closing gains nothing against it. S8's bullet says so.
  - `handOver(to:)`'s hook is one line into `HostServer.handOverThroughMemory` (`V2/HandoverMemory.swift`), which
    reads and sets `config`, `clients`, `handingOver` and `handoverState(secretFD:)`: four `private`s dropped (kind 8).
    `HostHandover.write` isn't edited (Linux never calls it); `probeIfAsked` gets a hook too: the probe closes its
    copy and hardens as a parser does.
  - The fallback's path (never executed: its build id, its folders) travels as `--handover-fallback-image`, a
    handover flag, and the new image of an ELF target gets `--image-path <target>` (a script stand-in execs a file
    that names itself).
  - On Linux `--handover-fail-restore` fails after the state and secrets were read (just before the restore), so
    the fallback tests read the secrets again from sealed memory; on the Mac it fails where it did.
  - `MacOnlyTests.txt` lists `HostHandoverTests.swift` (the two tests wrapped in `#if canImport(Darwin)`, as the
    list's lint requires of a listed file), not a runtime trait.
  - `aHandoverImageIsNotDumpableFromItsExec` opens `/proc/<pid>/mem` rather than `pidfd_getfd` (the test target has
    no shim; both need the process dumpable); it polls the probe whenever it catches one, the host at every poll.
  - The new image's scratch-only report is two lines in its log (`handover memory taken`, `handover memory kept`),
    and the old image's `handover memory written`; the user's host writes neither.

- [x] **Step 1: Failing tests** (Linux unless marked).
  - `HandoverLinuxTests.aHandoverWritesNoFile`: a folder watch on the scratch lock's folder sees no file made during a
    handover, and none is left.
  - `theStateAndSecretsAreSealed`: inside the new image (a scratch-only report), the state's and the secrets'
    descriptors show all four seals, and their bytes are those the old build wrote.
  - `aFallbackAfterAFailedRestoreKeepsTheVault`: `--handover-fail-restore`; the old build serves again with the vault
    it held (a grant issued before is still bound).
  - `aFallbackAfterAFailedRestoreKeepsEverySession`: the same, every session listed with its id and tty and still
    writable.
  - `aMegabyteOfSecretsIsHandedOver`: `--handover-test-secret-file` with 1 MB (argv can't hold it: one argument is at
    most 128 KiB here); the next image says it got them.
  - `aDowngradeIsRefused` (both): a state with a newer `format` is refused and the host goes back.
  - `aFreshHostRemovesAStaleStateFile`: a `host.lock.handover` and a `.partial` left in a scratch home are gone after
    a fresh start, and the log says so.
  - `HostHardeningTests.aTracedNewImageGoesBackWithoutTheVault`: a scratch host given `--handover-test-traced`
    (scratch only) reports a tracer and closes the secrets unread (the traced image never has the vault); the
    previous build, back through its sealed copy, serves on with its own vault (a grant issued before is still bound).
  - `everyDescriptorTheNewImageKeepsIsCloseOnExec`: inside the new image (the scratch-only report), each descriptor
    it kept (masters, state, image copies, connectors) is close-on-exec once restored; a session spawned after the
    handover lists none of them. Shown failing without the re-marking, with `PTYSpawn`'s `keep` made nil.
  - `aHandoverImageIsNotDumpableFromItsExec`: during the probe and right after the exec, `pidfd_getfd` on the probe
    and on the host is refused at every poll.
  - `aFailedTakeOverGoesBackThroughTheSealedCopy`: `--handover-fail-restore` with the old build's file removed; the old
    build serves again, from the copy carried across the exec.
  - `aFallbackImageRewrittenInPlaceIsNotWhatRuns`: the old build's file rewritten in place (it no longer runs, so no
    `ETXTBSY`) before the failed restore; what serves again reports the old build's mark.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; all of `HostHandoverTests` green on Linux; commit ("v2: the handover through sealed
  memory, with no file").

**Done when:** these and all of `HostHandoverTests` pass on Linux, S8's `Held by:` names them, and the Mac's host job
is green.

---

### Task 9d: The handover's target in the user's host

**Files:**
- Create: `Sources/VibeHost/V2/HandoverTarget.swift` (`check(_ copy: SealedCopy, path:, installRoot:) ->
  Result<BuildInfo, String>`: the path inside `installRoot`, under a build folder whose `build-info` records the
  SHA-256 of the copy's bytes, of a format this build reads; a path inside a worktree or a session's working folder,
  and a script (`copy.isScript`), refused by name)
- Modify: `HostServer.swift`: `Config.installRoot: URL?`, nil by default (the Mac's and every scratch host's
  behaviour; kind 5). Nothing more there: since Task 9c, `handOver(to:)` on Linux returns into
  `HostServer.handOverThroughMemory` (`Sources/VibeHost/V2/HandoverMemory.swift`) before any copy is loaded, so
  `handOver(to:)` holds no copy to check (the 9c review, 2026-11-14).
- Modify: `Sources/VibeHost/V2/HandoverMemory.swift` `handOverThroughMemory` (a V2 file, no port-map line): asks
  `HandoverTarget.check` on its sealed copy (`target`), only when `config.installRoot` is set. On success the same
  build's `vibeswitcher-server` is loaded as a sealed copy, checked against the same `build-info`, and put in
  `State.images.server`; the new image restarts the server from it once idle (no session request in flight), and only
  when its hash differs from the running server's (S2-D8). The exec's arguments, built there, carry the target's
  `--node-root` and `--server` (S2-D7). `HandoverMemory.finish` leaves `images.server` to `ServerChild`.
- Modify: `Sources/vibeswitcher-host/main.swift`: `config.installRoot` is `~/.vibeswitcher/v2/builds` for a `--node`
  host, or a scratch host's `--install-root`; `--server` joins `handoverFlags` (deferred from Task 8a, which left it
  in `config.arguments`: otherwise the exec has two `--server`s, and `value(after:)` takes the first, the old
  build's). Non-seam edit.
- Test: `Tests/VibeHostTests/HandoverLinuxTests.swift`, `ServerChildTests.swift`
- *As made (2026-11-14), approved by the lead 2026-11-14:*
  - `check(_:path:installRoot:sessionFolders:)` returns `Result<HandoverTarget.Build, HandoverTarget.Refused>` (the
    record and the build's folder, which the exec's `--node-root` needs; a `String` isn't an `Error`), and takes the
    sessions' working folders. A `.git` is looked for from the target's folder up to the install folder for a target
    inside it (a home kept in git refuses nothing), up to `/` for one outside; a session's folder refuses only when it
    doesn't hold the install folder (a shell in the home would refuse every build). The target must be
    `<install folder>/<build>/bin/vibeswitcher-host`, both resolved.
  - The build's server is loaded and checked, and `--server` appended, only when the host runs with `--server` (the
    node's host always does); a scratch host with an install root and no server hands over with `--node-root` alone.
  - "Once idle" is: no connection made through the running child's connector is open (each `HostCall` is a
    connection of its own), or 30 s (`ServerChild.idleLimit`) after the first look, whichever comes first; looked at
    every 0.2 s; the child's connector closed and SIGTERM (SIGKILL 10 s later), started again at once from the carried
    copy. The carried copy is taken only by the image it was carried for (its own copy is `images.own`); a fallback
    closes it. *The 9d review (2026-11-14), ruled by the lead: the 30 s bound stands for the bootstrap, where no switch is made while a worker or verifier runs (decision 6); the count of unanswered requests in `HostServer.handle` is after the bootstrap:* the bound is there because the server keeps a
    `HostConnection` open for the host's events (S2), so "no connection open" may never come; after it a request in
    flight is cut (the server is started again at once). "No request in flight" proper needs a count of unanswered
    requests in `HostServer.handle`, a Non-seam edit this plan doesn't list.
  - Until the child is started again, the record a handover carries says what it runs
    (`ServerChildRecord.runningImageSHA256`, an optional field, kind 6), and the replacement is tied to that pid: a
    second switch compares the carried server with what the child runs, not with the copy of its next start, and a
    fallback to the build that was to replace it, or a handover with no server carried, still starts it again (the
    9d review).
  - A session working in the install folder itself refuses every build there (the 9d review); only one whose folder
    strictly holds it (a shell in the home) refuses none.
  - The old build's own `--node-root` and `--server` travel as `--handover-fallback-node-root` and
    `--handover-fallback-server` (handover flags), which `goBack` gives back as its own. Two scratch-only test flags:
    `--handover-test-fail-next` (the image handed over to is given `--handover-fail-restore`: a script can't stand in
    for an installed build) and `--handover-test-hold PATH` (a handover waits, after its check, before its probe, until
    PATH exists); the 9d review added `--handover-test-hold-check PATH` (before the check) and
    `--server-test-replace-hold PATH` (carried). `--install-root` is not carried across a scratch host's handover, so a
    scratch host's second switch isn't checked as an installed build's (the node's `--node` is carried). The server helper says its image's
    hash when given `--server-arg report-image-hash`.

- [x] **Step 1: Failing tests** (Linux unless marked), with a scratch `--install-root` holding build folders and
  `build-info` files the test writes:
  - `aHandoverToAPathInsideAWorktreeIsRefused`; `aHandoverToABuildOutsideTheInstallFolderIsRefused`;
    `aHandoverWhoseHashDiffersFromTheRecordIsRefused`; `aHandoverToAnInstalledBuildIsAllowed`.
  - `aTargetRenamedOverAfterItsCheckIsNotWhatRuns`: the target file is renamed over while the probe runs; the new
    image reports the checked build's mark.
  - `aScratchHostWithNoInstallRootHandsOverAsToday` (both): `HostHandoverTests`' handovers to `<scratch>/new/` are
    unaffected.
  - `ServerChildTests.aSwitchBringsTheNewBuildsServer`: a scratch host started with `--install-root` and
    `--node-root <build A>` hands over to build B; the new image checks itself against B's `build-info` (not A's),
    names B's `vibeswitcher-mcp`, and the server child is restarted once idle from B's server and reports B's mark;
    a server whose file differs from B's `build-info` fails the handover before the exec, and A serves on.
  - `aFallbackGetsTheOldBuildsFolders`: the same with `--handover-fail-restore` on B: A serves again with A's
    `--node-root` and `--server` (its log and the server's mark say so).
  - `aScriptTargetIsRefusedByTheUsersHost`: with an install root, a target whose first bytes are `#!` is refused by
    name, before any probe.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; commit ("v2: the user's host hands over only to an installed build it checked").

**Done when:** these pass on Linux, S8's and S9's `Held by:` name them, and the Mac's host job is green.

---

### Task 9e: A parser's reply is typed only as a reply

**Files:**
- Create: `Sources/VibeHost/V2/ParserReplies.swift`: a table of query kind to reply grammar, **derived from SwiftTerm
  1.19.0's responders** (each `sendResponse` in `Terminal.swift`), not written from memory: device status and cursor
  reports (`CSI 5n`, `CSI 6n`, `CSI ? 6n` and its `CSI ? y;x;1R`, the other `CSI ? Pn n` reports at 4662-4719),
  device attributes (`CSI c`, `CSI > c`, `CSI = c`, 5731-5773), mode reports (`CSI ? Pn $p` and the ANSI `CSI Pn $p`,
  4373, 4521-4523), the kitty keyboard query (`CSI ? u`, 1018), DECRQSS (`DCS $ q`, 1139), XTVERSION (`CSI > q`,
  4170), the window reports (`CSI Ps t`, 3977-4016), colour queries (`OSC 4/10/11/12;?`, 2877-2903).
  Left out on purpose, so their replies are dropped: OSC 52 (the clipboard), the title reports (`OSC l`/`L`,
  4021-4025), DECRQCRA (3739), mouse reports. Queries are counted per kind since the last reply. A reply passes only
  when it matches a pending query's kind, one reply per query; when a client is attached and answers a query itself
  (the parser's reply then skipped), that query is no longer pending.
- Modify: `Sources/VibeHost/HostedSession.swift` (`startParser`, `link.onReply`, 226-229): one hook on Linux; the
  output path notes queries (one hook in `deliver`). The Mac unchanged. Non-seam edits.
- Test: `Tests/VibeHostTests/ParserReplyTests.swift`
- *As made (2026-11-14), approved by the lead 2026-11-14:*
  - The output hook is in `HostedSession.drain`, beside `focus.feed`, not in `deliver` (that is `HostServer`'s, and
    holds no session's state); the pending queries are a stored `HostedSession.parserReplies` (a `ParserReplies`),
    used on the session's queue. A third hook, one line in `SessionParser.run`'s test hook (`--parser-test-hooks`
    only): `OSC 7599 ; reply:HEX` makes the parser send HEX as a reply, which is how the tests' parser "sends a
    `.reply` the session never asked for". The hooks are kind 4, in the port map; **the stored
    `HostedSession.parserReplies` is outside the plan's eight kinds (kind 5 names `HostServer` and `HostConnection`
    members only): approved by the lead 2026-11-14, kind 5 now naming `HostedSession` too**, the smallest place for a session's pending queries.
  - The output is read for queries by a scanner that mirrors SwiftTerm's own state table (`QueryScanner`: its ground
    state, ESC, CAN and SUB, the C1 controls, a CSI's parameters and collected bytes, where an OSC or a DCS ends), so
    a query split between two reads counts, and a query SwiftTerm wouldn't answer doesn't.
  - `CSI = c` isn't in the table: SwiftTerm 1.19.0 doesn't answer it. Left out besides the plan's list: the kitty
    graphics replies (`KittyGraphics.swift`, `APC G`), the focus report, a user's input and the semantic prompt's
    click (the direct `tdel?.send` sites), and the linux console's unreachable DA2 echo; `everyResponderInSwiftTermIsListed`
    reads every `Sources/SwiftTerm/*.swift`, not `Terminal.swift` alone, and the direct `tdel?.send` sites too.
  - A dropped reply goes to the host's log through the session's `onParserTrouble` (so the line reads
    `watchdog: session X's parser (pid N) reply dropped, …`), a line a second at most, saying how many went unsaid.
    A reply skipped while a view is attached still answers its query; one with no query pending is logged then too.
  - Two pure tests more, on both systems: `everyQueryIsAnsweredInItsGrammar` (each query fed to a SwiftTerm terminal
    and to the scanner: as many seen as answered, each reply in its query's grammar, passing once) and
    `aQuerySplitBetweenReadsIsSeen`; and `droppedRepliesAreLoggedOnceASecond`.
  - The 9e review (2026-11-14): the program status query (`OSC 7501 ; ?`), which the host answers itself by typing
    `ProgramStatus.queryReply` when the parser forwards it, is a kind of its own (`programStatusQuery`): on Linux
    the host answers it only once per `OSC 7501 ; ?` the output asked (`admits`, a fifth hook, in
    `link.onProgramStatus`; `aStatusQueryTheProgramDidntPrintIsNotAnswered`, `theProgramStatusQueryIsAnsweredOncePerQuery`).
    A new parser's quiet replay primes the scanner (`prime(with:)`, a sixth hook, in `startParser`), so after a
    handover or a replacement a query the replay began counts when it ends (`aQueryBegunInTheReplayIsSeenWhenItEnds`,
    `aReplayLeavesTheScannerWhereItLeavesTheParser`). XTVERSION's grammar is this build's own reply exactly
    (`versionReply`, a headless terminal asked once; the parser is this build's image), not 128 bytes of free text
    (`theVersionReplyIsThisBuildsOnly`). The grammars are compiled once; a reply is matched only against the kinds
    with a query pending, and one longer than any reply not at all (3.8 µs a reply with all 22 CSI kinds pending,
    was 49 µs).

- [x] **Step 1: Failing tests** (Linux; the Mac's form passes every reply, as today, `theMacsParserRepliesAreTodays`).
  - `aCursorQueryIsAnswered`: a session's program writes `ESC[6n` and reads `ESC[r;cR` on its stdin.
  - `aReplyWithNoQueryIsNotTyped`: a parser (with test hooks) sends a `.reply` the session never asked for; nothing
    reaches the program, and the host's log says it was dropped.
  - `aReplyOutsideTheGrammarIsDropped`: a `.reply` of `\r` or text after a real query is dropped; the query's proper
    reply still passes.
  - `aQueryWrittenToTheSessionsTerminalFromOutsideIsAnsweredOnlyAsAReply`: a process writes `ESC[6n` to the
    session's `/dev/pts/N`; what the program receives is a cursor report and nothing else (S11 item 11's limit).
  - `everyResponderInSwiftTermIsListed` (both): reads `Terminal.swift` in the resolved SwiftTerm checkout and counts
    its `sendResponse` sites by the reply each builds; every one is in the table or in its list of left-out kinds, so
    a SwiftTerm bump that adds a responder fails here first.
  - `aQueryAnsweredByAClientIsNoLongerPending`: with a client attached that answers `ESC[6n`, a later parser reply of
    that kind is dropped.
  - Task 12a asserts the host's log shows no dropped reply while Claude Code starts and runs its five steps: a
    dropped reply it waits for would stall the lead.
- [x] **Step 2: Implement.**
- [x] **Step 3:** push; both green; commit ("v2: a parser's bytes reach a session only as a reply").

**Done when:** these pass, S6's `Held by:` names them, and the Mac's host job is green.

---

### Task 10a: The sessions' environment, their shell, and what a spawn may add

**Awaits:** decision 9 (the user turns off what the list can't keep out).

**Files:**
- Modify: `Sources/VibePlatform/Tools.swift` (`sessionEnvironmentNames: [String]`: the Mac's list unchanged, Linux's
  from S2-D12; `sessionEnvironmentFixed: [String: String]`: empty on the Mac, `SWIFT_BACKTRACE=enable=no` on Linux;
  `defaultLocale: String`: `en_US.UTF-8` on the Mac, `C.UTF-8` on Linux; `sessionShellArguments(shell:command:
  keepShell:) -> [String]`: the Mac's `[shell, "-l", "-i", …]` as `HostedSession.arguments` builds it today, moved;
  Linux `["/bin/bash", "--noprofile", "--norc", "-c", line]`, with `keepShell` then `exec /bin/bash --noprofile
  --norc -i`, and with no command `/bin/bash --noprofile --norc -i`; `spawnEnvironmentRefused(_ names:) -> [String]`:
  the loader and shell-startup names and the "never" list on Linux, empty on the Mac)
- Modify: `Sources/vibeswitcher-host/main.swift` (`inherited` becomes `Platform.Tools.sessionEnvironmentNames`, plus
  `sessionEnvironmentFixed`), `HostedSession.swift:117-120` (`arguments` forwards to the platform: kind 3), `:129`
  (`Platform.Tools.defaultLocale`) and `:152` (`PTYSpawn.spawn(… executable: args[0] …)` for `executable: shell`: the
  launcher runs `executable` with `args.dropFirst()`, `PTYSpawn.swift:73`, so on Linux, with any `SHELL` but bash,
  that shell would run with bash's options; on the Mac `args[0]` is `shell`, unchanged);
  `SessionParser.swift` (`ParserLink.start`'s fixed environment gains `Platform.Tools.sessionEnvironmentFixed`, empty
  on the Mac); `Tests/VibeHostTests/HostedSessionTests.swift` (lines 58-62 assert the Mac's `-l -i` arguments: each
  check made per platform)
- Create: `Sources/VibeHost/V2/SpawnEnvironment.swift`, with one hook where `HostServer` handles `.spawn`: a request
  from a caller that isn't `.app` naming a refused variable is refused, saying which. Non-seam edit.
- Test: `Tests/VibePlatformTests/ToolsTests.swift`, `Tests/VibeHostTests/SessionEnvironmentTests.swift`

- [ ] **Step 1: Failing tests.**
  - `SessionEnvironmentTests.aLinuxSessionGetsNoAgentSocketNoInteropNoBus` (Linux): with `SSH_AUTH_SOCK`,
    `WSL_INTEROP`, `DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, `WAYLAND_DISPLAY`, `PULSE_SERVER` and
    `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` in the host's environment, the session's `env` has none of them.
  - `aLinuxSessionGetsNoRuntimeDir` (Linux). A regression test: `XDG_RUNTIME_DIR` isn't in today's `inherited`
    either (`main.swift:27`), so it has no failing form; it keeps the new list from gaining it.
  - `aTeamSessionRunsNoShellStartupFile` (Linux): a scratch `HOME` whose `.bashrc`, `.profile` and `.bash_profile`
    each write a marker; a spawned session's command runs and no marker is written.
  - `aSessionRunsBashWhateverTheHostsShell` (Linux): with `SHELL=/bin/sh` in the host's environment, the session's
    program is `/bin/bash` (`/proc/<pid>/exe`) and runs its command. Shown failing with `executable: shell`.
  - `aParserGetsNoBacktracer` (Linux): a parser's environment holds `SWIFT_BACKTRACE=enable=no`.
  - `aSpawnAddingALoaderVariableIsRefused` (Linux): a session's process asking to spawn with `LD_PRELOAD`,
    `BASH_ENV` or `SSH_AUTH_SOCK` in `env` is refused, naming it; the app's spawn with the same `env` isn't filtered.
  - `aSessionsProgramStartsWithSIGPIPEAtItsDefault` (both): the host ignores SIGPIPE; a session's program reads its
    own disposition (on Linux `SigIgn` in `/proc/self/status`) and it is the default. A regression test: the launcher
    is spawned with every signal at its default (`PTYSpawn.swift:58-62`) and execs before `main.swift:15` ignores
    SIGPIPE, so it passes today; it keeps Task 9b's launcher hooks from changing that.
  - `ToolsTests.theLocaleASessionGetsIsInstalled` (Linux): `LANG`'s codeset compared as glibc normalises it
    (lowercased, `-` and `_` dropped), so `C.UTF-8` matches `locale -a`'s `C.utf8`; a plain case-blind comparison
    fails even when right.
  - `ToolsTests.theMacsListIsTodays` (Mac), with the Mac's shell arguments.
- [ ] **Step 2: Implement; push; both green; commit** ("v2: the sessions' environment and shell on Linux").

**Done when:** the tests pass, S10's `Held by:` names them, and the Mac's host job is green.

---

### Task 10b: The roles' launch on Linux: deny rules and inline settings

**Awaits:** decision 11 in part (`gh` is denied to roles; the token itself is the user's).

**Measured since (stage 1's R10, 2026-11-13):** Claude Code 2.1.323 starts in auto mode unless told otherwise, and
has no mode called `default` any more (`manual` asks before each unapproved tool). Today's role launches name no
`--permission-mode`, so on this version a role runs whatever its rules don't deny without asking, whichever mode the
lead's code assumed. This task first reads what mode each role's launch means on the Mac today (the lead's
`LeadLaunch` and the roles' settings), then names it on the command line (`--permission-mode <mode>`) on both
systems' launches, with a test per role. That edit to `prepare` is a fourth kind-4 hook, and its port-map line says
why: the Mac's launches change too, because the CLI's default changed under them.

**Files:**
- Modify: `Sources/VibePlatform/Tools.swift` (`roleDenyRules: [String]`: empty on the Mac; on Linux, as Claude Code
  rules: `strace`, `ltrace`, `gdbserver`, `perf`; `systemctl --user`, `systemd-run`, `loginctl`, `crontab`, `at`;
  `wsl.exe`, `cmd.exe`, `powershell.exe`; `gh`, `git credential`, `git -c credential*`; `Edit` and `Write` under
  `~/.config/systemd/**`, `~/.config/environment.d/**`, `~/.vibeswitcher/v2/**`, `~/.vibeswitcher/lead/**`; `Read`,
  `Edit` and `Write` under `/mnt/c/**`; `leadGetsTracerRules: Bool`: false on the Mac, true on Linux;
  `roleSettingsInline: Bool`: false on the Mac, true on Linux)
- Create: `Sources/VibeCore/V2/LinuxLaunch.swift`: `denyRules(for role:, base:) -> [String]` and
  `inline(_ prepared: Prepared) -> Prepared`, which, with `roleSettingsInline`, rewrites the prepared command so the
  role's settings and MCP config are on `claude`'s command line as JSON strings (`--settings '<json>'`,
  `--mcp-config '<json>'`, shell-quoted) instead of files in `LeadVault.runFolder`, removes those files, and inlines
  the prompt too while the whole command fits under the 128 KiB a single argument may hold here; otherwise the prompt
  stays a file, named in S11 item 7. Nothing secret is in either (they are world-readable in `cmdline`, S11 item 20).
- Modify: `Sources/VibeCore/LeadLaunch.swift`, two one-line hooks (kind 4, each named in the port map):
  `deny(_:base:records:)` (`LeadLaunch.swift:118-124`) appends `LinuxLaunch.denyRules` (empty on the Mac), and
  `prepare` (311-) returns its result through `LinuxLaunch.inline` (the identity on the Mac). `prepare`'s body is not
  rewritten.
  *As made, approved by the lead 2026-11-14 (kind 4):* five one-line hooks, not two. `deny` keeps its body and
  signature, and each of its three cases (lead, verifier, worker) appends `LinuxLaunch.denyRules(for:)` to the list it
  returns (the first version's wrapper and new `deny(both:base:records:)`, outside kind 4, the 10b review put back as
  these three); `prepare` adds `LinuxLaunch.permissionMode(command:)` before `--name` (the fourth hook, "Measured
  since" above) and returns through `LinuxLaunch.inline`. The port map's line names each, with its real lines.
- Test: `Tests/VibeCoreTests/LeadLaunchTests.swift`

- [ ] **Step 1: Failing tests.**
  - `LeadLaunchTests.aRoleOnLinuxIsDeniedTracersTheUsersManagerWindowsAndGh` (Linux): every role's rules include each
    of the Linux list.
  - `theLeadOnLinuxGetsTheTracerRules` (Linux): the lead's rules include `debuggers` and the Linux tracers.
  - `theMacsDenyRulesAreTodays` (Mac): every role's list equals the list at `47636aaf`.
  - `aRolesLaunchSettingsAreInlineOnLinux` (Linux): after `prepare`, no `settings.json` or `mcp.json` is left; the
    command carries both as JSON that parses back to what the files held; a prompt over the limit stays a file.
- [ ] **Step 2: Implement; push; both green; commit** ("v2: Linux's deny rules for every role; launch settings
  inline").

**Done when:** the tests pass, S10's `Held by:` names them, and the Mac's app and host jobs are green.

---

### Task 10c: git and branch code on Linux

**Awaits:** decision 19 (no GitGuard hash check before the bootstrap).

**Files:**
- Modify: `Sources/VibePlatform/Tools.swift`: on Linux `Platform.Tools.git` is the first `git` on PATH in a folder
  owned by root and writable by nobody else, every folder above it as well (a folder failing that is skipped); none
  found is `absentGit`, which `missing()` lists, and the host and the server refuse to start without one. The Mac's
  stays `/usr/bin/git`. The rule is a pure function, `Platform.Tools.trustedGit(path: String, status: (String) ->
  (owner: uid_t, mode: mode_t, isFile: Bool)?) -> String?`, which the cached `git` calls once with the process's PATH
  and `lstat` (it is cached, `Tools.swift:7-15`, so a test that changes PATH in the test process would prove nothing).
- **No GitGuard hash check** (S2-D12 says why: the accepted record sits beside the copy, writable by the worker it
  would check). The seal's Linux list (the bootstrap path, step 8) holds `~/.vibeswitcher/lead/git-hooks`.
- Modify: `Sources/VibeCore/Worktrees.swift` (`BranchCode.runPrefix`, 188-): on Linux, instead of `execve` in place,
  the command is started through `Platform.Spawn` with group `.ownSession` (a new child, so `setsid` can't fail with
  `EPERM` as it would in a caller that already leads its process group, which a Bash tool's process may), and
  `runPrefix` waits for it and exits with its status; SIGTERM, SIGINT and SIGHUP it gets are sent on to the command's
  process group. One hook into a `V2/` file, behind `Platform.Tools.branchCodeGetsOwnSession` (false on the Mac).
  Non-seam edit. A SIGKILL to the waiting process can't be passed on: whether Claude Code's timeout and interrupt
  still end the command is Task 12b's measurement.
- Test: `Tests/VibePlatformTests/ToolsTests.swift`, `Tests/VibeHostTests/VerifierBranchCodeHostTests.swift`,
  `Tests/VibeCoreTests/BranchCodeTests.swift` (new)

- [ ] **Step 1: Failing tests.**
  - `ToolsTests.theNodesGitIsNeverFromAFolderTheUserCanWrite` (Linux): `trustedGit` given a PATH whose first folder
    is the user's and holds a `git` (a stand-in status function) resolves past it to the root-owned one; given only
    the user's folder, nil. `theMacsGitIsStillUsrBinGit` (Mac).
  - `VerifierBranchCodeHostTests.anEscapedVerifierCommandWithoutSetsidIsNobodys` (Linux): a verifier's Bash command,
    through `runPrefix`, double-forks without `setsid`; the grandchild, still on the verifier's terminal, is no
    session's to the host and is refused `submitVerdict`.
  - `BranchCodeTests.aCommandGetsItsOwnSessionWhenItsCallerLeadsAGroup` (Linux): `runPrefix` called from a helper
    that is its own process-group leader runs the command with its own session id (setsid in place would have failed
    `EPERM`), passes on its exit status, and passes on a SIGTERM.
- [ ] **Step 2: Implement; push; both green; commit** ("v2: git from root's folders and branch code in a session of
  its own, on Linux").

**Done when:** the tests pass, S4's, S9's and S10's `Held by:` name them, and the Mac's jobs are green.

---

### Task 10d: The project allow-list

**Awaits:** decision 10 (its place and its one line).

**Files:**
- Create: `Sources/VibeHost/V2/ProjectAllowList.swift`, with one hook where `HostServer` handles `.spawn`, active only
  when `HostServer.Config.projectAllowList: URL?` is set (nil by default, kind 5). `main.swift` sets it to
  `~/.vibeswitcher/v2/projects` for a `--node` host. Non-seam edits (the `Config` field, the hook line, the `main.swift`
  line).
- Test: `Tests/VibeHostTests/ProjectAllowListTests.swift`

- [ ] **Step 1: Failing tests.**
  - `aSpawnOutsideTheListIsRefusedWithItsReason`.
  - `aWorktreeOfAnAllowedRepositoryIsAllowed`.
  - `aForgedGitFileIsRefused`: a folder whose `.git` names an allowed repository's worktree folder that doesn't point
    back.
  - `aForgedWorktreePairPassesAsKnown`: a folder whose `.git` and an entry the test writes in the allowed repository's
    `.git/worktrees` point at each other passes: the guard rail's known limit, asserted so that a change to it is
    seen.
  - `aScratchHostHasNoList`.
  - `aMissingListRefusesEverySpawnAndSaysWhereTheListGoes`.
  - `noGitRunsInTheHost`: the check reads files only; a `git` that records being run, first on PATH, is never run.
- [ ] **Step 2: Implement; push; both green; commit** ("v2: the project allow-list in the user's host").

**Done when:** the tests pass, S11's `Held by:` names them, and the Mac's host job is green.

---

### Task 10e: A fresh vault takes nothing as its baseline that a worker could have written

**Awaits:** decision 3 (the vault in memory, accepted by the user after every host restart).

**Files:**
- Modify: `Sources/VibeCore/LeadVault.swift` (`Book.holdsFirstLook: Bool`, false by default, kind 5, **kept in the
  vault's serialized state**, so a handover before the first look keeps it), and, in the `Book`'s own handlers where
  the flag can be read: `.setGuarded` (1033-1043), while it holds, records no rail that has nothing recorded when the
  caller isn't `.app` (it replies `.ok`, as today, and logs the key held; the client's `changedSettings`,
  `LeadVaultGuarded.swift:64-73`, ignores that reply, so the next call asks again); `.setReviewFloor` with
  `onlyIfUnset` (1045-1048), while **that root's** first look is held, records nothing and replies `.reviewFloor(nil)`
  (`startLead` already takes that with `try?`, `LeadVault.swift:317`), whoever asks, the app included. What ends a
  root's hold is named: the app's `.setGuarded` for that root carrying `ConfigSeal.checkKey` with shown hashes (what
  `checkConfig(root:shown:)` sends for the user's `config accept CARD`), once it sealed with nothing held again; it adds
  the root to `Book.firstLookAccepted: Set<String>` (kept in the serialized state, optional, kind 6). After it, the
  app's `setReviewFloor(onlyIfUnset: true)` for that root records (the engine's EN-D7 calls the two in that order), and
  another root stays held until its own accept. The seals' first look (the home seal's and each main checkout's)
  follows `holdsFirstLook` itself, not the accept: a watched key never recorded is held for the user's accept
  whenever it is first read, for as long as the vault holds its first look, so a key the accept couldn't read (an
  unreadable `~/.claude.json`) is held when it is first read after it, never sealed as it is (as built in the 10e
  review, `ConfigSealFirstLookTests.aHomeFileUnreadAtTheAcceptIsStillHeldWhenItFirstReads`; approved by the lead
  2026-11-14, strictly more than the "until the first accept" this task first named). `ConfigSeal.swift` needed no
  edit: the first look is the `Book`'s `judge` in `sealConfig`. Non-seam edits, one port-map line each; the
  port-map row names the handlers' lines, not the client's.
- Modify: `Sources/vibeswitcher-host/main.swift`: `holdsFirstLook` is true for a `--node` host whose vault holds no
  restored secrets, and for a scratch host only with `--hold-first-look` (so `VaultHandoverTests` and every other
  scratch host seal as today). Non-seam edit.
- Test: `Tests/VibeCoreTests/ConfigSealFirstLookTests.swift`

The lead's own start is never held by the vault: `lead` is refused on a fresh vault until the user's `config accept` and
`base accept` (the engine's E4), so nothing a lead's start loads was taken unaccepted.

- [ ] **Step 1: Failing tests.**
  - `ConfigSealFirstLookTests.aVaultThatHoldsItsFirstLookHoldsEveryHomeFile`.
  - `aVaultThatDoesntSealsItsFirstLookAsToday` (both).
  - `aFreshVaultHoldsChangedGuardedSettings`: a `workflow.md` whose `test_command` and `sensitive_paths` were edited
    before the first look: both are held, with their values, not recorded.
  - `aFreshVaultHoldsTheCheckoutsGitHooks`: a hook in the main checkout's `.git/hooks` at the first look is held.
  - `aFreshVaultSeedsNoFloorFromWorkflow`: the engine's start of a lead with `onlyIfUnset` records nothing while the
    vault holds its first look.
  - `aVaultHandedOverBeforeItsFirstLookStillHoldsIt`: the serialized vault, restored, still holds.
  - `aRootsAcceptLetsItsFloorBeRecordedAndHoldsTheNext`: on a vault holding its first look, the app's
    `checkConfig(root: A, shown:)` and then `setReviewFloor(onlyIfUnset: true)` for A record A's floor; the same
    floor call for B, never accepted, records nothing; a floor call for A before its accept records nothing.
- [ ] **Step 2: Implement; push; both green; commit** ("v2: a fresh memory vault holds every record's first look").

**Done when:** the tests pass, S7's `Held by:` names them, and the Mac's jobs are green.

---

### Task 11a: The lead's tool server under a scratch host

Moved here from stage 1 (its R9), because the tool server learns its role from the host.

**Files:** `Tests/VibeHostTests/ToolServerUnderAHostTests.swift`

- [ ] `theLeadsToolServerListsItsToolsAndServesStatus`: a scratch host with the test as app (`TestHost`'s connector
  stand-in); the test asks the vault for a lead grant (`.issue(role: .lead, root:)`) on a scratch repository, spawns a
  session whose program starts the built `vibeswitcher-mcp` with its stdin and stdout on two FIFOs in the scratch
  folder, and binds the grant to that session (`.bind`). Over the FIFOs: `initialize`; `tools/list` within 50 s (the
  tool server waits up to `roleWait`, 45 s, for a role) includes `start_worker`, `audit`, `merge` and `status`; a
  `status` call answers with the scratch board. Shown failing with the bind left out (no tools listed).

**Done when:** it passes on Linux and on the Mac.

---

### Task 11b: The tool server's keeper restarts it from a sealed copy (moved after the bootstrap)

**Awaits:** decision 18 (the keeper's sealed copy after the bootstrap; the document's S9 and T6 now say so).

Not built before the bootstrap. Two findings of the critics' round, checked in the code:

- **It would break the tool server.** A tool server started from `/proc/self/fd/N` has `Bundle.main.executablePath`
  `/memfd:…`, and `vibeswitcher-mcp/main.swift` reads that path for every worker's and verifier's MCP command
  (`HostRuntime.server`, 225-226), the verifier's hooks (123), its log line (155), the merge receipts' build
  (`ServerBuild`) and its `BinaryWatch` (474). After any keeper restart, new workers and verifiers would get a path
  that doesn't exist. Doing it right means the keeper passing the file's real path and five sites in a file shared
  with main reading it.
- **It buys nothing before the sandbox.** The keeper and the tool server are a session's processes, dumpable: a
  worker that can rewrite the install folder can ptrace the lead's tool server directly (T1), which this doesn't
  stop. The install folder's file is on the seal's Linux list (the bootstrap path, step 8).

After the bootstrap it is built with the sandbox (install folder read-only there), as one task: the keeper makes a
`0555` copy (the keeper is dumpable, so `0111` protects nothing, and the tests' builds are scripts:
`MCPKeeperTests`, `MCPHandoverTests.swift:10-12`), restarts from it with `keep:`, and passes the file's path, which
`main.swift`'s five sites read on Linux; the test is `MCPKeeperTests.aToolServerFileReplacedWhileKeptIsNotWhatRestarts`.

---

### Task 12a: A real `claude` under a scratch host

**Awaits:** decision 16 (the config folder named per run).

**Files:** `Tests/VibeHostTests/RealClaudeHostTests.swift`; `docs/process/v2-linux-inventory.md`

- [ ] **Step 1: The test.** `aClaudeSessionSurvivesItsClientAHandoverAndAKilledParser`, enabled only when
  `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` is set on the command line of the run (the folder the user prepared for stage
  1's R10). A scratch host spawns `claude --model sonnet` in a scratch repository whose trust entry was written into
  that folder's `.claude.json`, with `CLAUDE_CONFIG_DIR` passed through the request's `env` (which
  `LaunchPlan.validEnvName` passes, and which Task 10a's filter lets the app's spawn through). Then:
  1. a client reads the screen until Claude Code's prompt shows, and disconnects;
  2. a new client attaches, and the same screen is there;
  3. a handover to the same build (through sealed memory); the session is listed with the same id and tty;
  4. the parser is killed (`kill -9`), and a new parser's screen matches within 10 s;
  5. the session ends by `/exit` sent with an `inputUnit` request (there is no `type` request), and its exit is
     recorded;
  6. through it all, the host's log shows no parser reply dropped (Task 9e).
- [ ] **Step 2:** the run, the Claude Code version and each step's time go into the inventory.
- *As made (2026-11-14), approved by the lead 2026-11-14:*
  - **The DECSET 1004 change to 9e's reply table** (approved): Step 6 found that Claude Code turns focus events on as it starts (`CSI ? 1004 h`), which SwiftTerm answers at once
    with `CSI I`; 9e's table had that responder as a view's only (its As-made list "left out … the focus report"), so
    Linux dropped it. `Sources/VibeHost/V2/ParserReplies.swift` (outside this task's Files) now takes DECSET 1004 as a
    query answered by `CSI I` or `CSI O`, one per 1004 the setting names
    (`ParserReplyTests.aProgramTurningFocusEventsOnIsToldItHasFocus`); S6's grammar and `Held by:` and S11 item 11
    say so. This supersedes 9e's "the focus report" among the replies left out.
  - **Step 6 deviates from "no parser reply dropped":** the test allows drops of kitty graphics replies (`APC G`),
    which 9e leaves out on purpose; Claude Code probes kitty graphics as it starts and the headless terminal answers
    `APC G i=31;OK ST`. Approved as made: the allowance is kept, and the kitty graphics query is not answered (the
    other way, answering it with its `OK` reply only so step 6 could assert no drop at all, was not taken).
  - The 12a review: a drop within a second of the last logged line was only counted, and the count reached the log
    only on the next logged drop, so one held back when the parser stopped (the session ending, a handover's exec, the
    host quitting) was never logged. `ParserReplies.flushDropped` logs what was held back, naming the first four, from
    `HostedSession.stopParser` (a seventh hook, kind 4, in the port map); step 6 waits for the session's parser to
    stop and accepts a line only if every drop it counts is named and is a kitty graphics reply
    (`aDropTheOnceASecondLineHeldBackIsLoggedWhenTheSessionEnds`, `RealClaudeHostTests.onlyKittyGraphicsDropsPass`).
  - **The gated test does not pass with that fix.** Its run on 2026-11-14 16:25 (the slice's fourth, its last) failed
    step 6 only: one more drop, held back within a second of the kitty probe's, logged when the first host image's
    parser stopped for the handover, by a build that counted it without naming it. Unidentified; the next gated run
    names it. A likely candidate, not confirmed: Claude Code's binary holds a second kitty graphics probe
    (`s=1,v=1,a=q,t=f,f=32`) beside the `t=d,f=24` one whose reply was logged.

**Done when:** the gated test passed once here with the user's folder, and the record is committed. Until the folder
exists the test is skipped, saying why, and later work goes on.

### Task 12b: What Claude Code does on Linux, measured

**Awaits:** decision 16.

**Files:** `Tests/VibeHostTests/RealClaudeTests.swift`; `docs/process/v2-linux-inventory.md`; the security document's
S10 and S11 (each result, one line, with the inventory's date)

- [ ] `RealClaudeTests.whatClaudesBashToolSourcesIsMeasured` (gated as 12a): a session started as Task 10a starts
  one (`bash --noprofile --norc`), in a scratch `HOME` whose `.bashrc`, `.bash_profile`, `.profile` and `.zshrc` each
  set a marker variable; Claude Code's Bash tool is asked to print the markers. The result (which files its snapshot
  sources) is recorded; the test asserts only that it was measured.
- [ ] `RealClaudeTests.aVerifierCommandInItsOwnSessionStillTimesOut` (gated): a verifier role's Bash, through
  `runPrefix` with Task 10c's `setsid`, runs `sleep 600` with a short timeout and, separately, is interrupted; both end
  the command (no process of it left), and the times are recorded.
- [ ] commit ("v2: Claude Code's shell snapshot and a verifier's command in its own session, measured").
- *As made (2026-11-14), approved by the lead 2026-11-14:*
  - Both sessions run `claude --permission-mode manual` with an inline `--settings` that allows only the command the
    prompt names (no question was shown), not a role's `auto`; the verifier's is its environment
    (`LeadLaunch.verifierEnvironment`, in the same inline settings), not a whole `LeadLaunch.prepare`.
  - The command is `./hold.sh N`, a script that sleeps: 2.1.323's Bash tool refuses a standalone `sleep 600`.
  - **The timeout doesn't end the command on 2.1.323**: Claude Code moves it, prefix and all, to the background. The
    test asserts instead that the tree stays whole at the timeout (the prefix still runs), that the interrupt ends
    every process of it, and that `/exit` (its "Exit and stop tasks", answered with Enter) ends what the timeout
    left. Its "Move to background and exit", and a SIGKILL to Claude Code with a command running, aren't measured.
  - The snapshot run: every Bash command's shell reads `~/.bashrc` itself (stdin a socket, `SHLVL` 1: bash's own rule
    for a stdin that is a socket, bash(1)'s INVOCATION, upstream's and not Ubuntu's; Debian's `SSH_SOURCE_BASHRC` only adds the
    `SSH_CLIENT` check), and the snapshot's login shell reads the first of `~/.bash_profile`, `~/.bash_login` and
    `~/.profile` there is (the run's home had a `.bash_profile`; this node's has only `.profile`, which bash alone
    shows is then read: `theStartupFilesBashReadsInClaudeCodesShapesAreMeasured`, ungated), and its script
    `~/.bashrc`. Every command runs with the PATH the snapshot took from that login shell, not the unit's (line 374's
    "the PATH the unit holds" is the session's shell's only): on this node swiftly's `bin` and `~/.local/bin` ahead of
    `/usr/bin`. The gated test's second home, shaped like the node's, with each startup file changing PATH, is written
    and not yet run (the slice's four gated runs are spent). The record is in `docs/process/v2-linux-inventory.md`.

**Done when:** both ran once here with the user's folder and their results are recorded; until then they are skipped,
saying why.

---

## Done when

On Ubuntu, `bash scripts/test.sh` is green for `VibePlatformTests`, `VibeCoreTests`, `VibeNodeTests` and
`VibeHostTests`, with each Mac-only file and test listed with its reason, and `host-access.test.mjs` passes with its
Linux cases. The security architecture document is reviewed, its review recorded, its lint passes, and the user's
answers are in the design. On Linux:

- a session's terminal is `ttypts<N>` everywhere, is its launcher's from the start, and its program is matched by
  token;
- each message's sender is checked, on accepted and connector connections;
- the only app is what the host makes through its live, non-dumpable server child's connector; no path connection is;
- the host, its parsers, the server child, a handover's probe and new image are non-dumpable from their exec (Task 3b's
  measurement recorded), and every descriptor is close-on-exec from its creation;
- launcher, parser, server, probe, new image and fallback come from sealed copies the host loaded and hashed; the
  user's host checks its own images against `build-info` and hands over only to an installed build whose sealed copy's
  hash matches;
- a handover writes no file, and a fallback keeps every session and the vault;
- a parser's bytes reach a session only as replies;
- team sessions get no agent socket, runtime dir, bus or interop variable, run no shell startup file, and their roles
  are denied tracers, the user's manager, Windows and `gh`, with launch settings inline;
- the project allow-list holds in the user's host, and a fresh memory vault holds every record's first look;
- the lead's tool server lists its tools under a scratch host.

A real `claude` under a scratch host survived its client quitting, a handover and a killed parser, and Claude Code's
shell snapshot and a verifier's command in its own session are measured (or the gated tests wait on the user's folder,
as open items). Every Non-seam edit is in the port map. The `v2 linux` jobs and the `v2 macos` jobs are green on one
commit, as stage 1's R3 defines green.

## After the bootstrap, from this stage

Not tasks here; the lead's early work, in the security document's S12 order, each with a plan of its own:

1. The sandbox through the shim (`unshare` or `clone3` with new user, mount, pid, IPC and network namespaces;
   `pivot_root`; a devpts of its own with only the session's slave passed in), not bubblewrap: no uid 0 inside, every
   capability dropped, `no_new_privs`; every worker, verifier and run of a branch's tests in one, the lead in its own,
   a verifier never in the sandbox of the code it judges; in its pid namespace the host can be the subreaper (S2-D6).
2. The session's identity: the inherited connector (S2-D9), or the sandbox's pid namespace, after the measurement of
   whether Claude Code and Codex pass a descriptor through.
3. Clones for workers (S2-D10), the result fetched as one ref.
4. The egress proxy, refusing the tailnet, loopback (the Windows side included, under mirrored networking) and cloud
   metadata addresses.
5. Strong mode: the vault's key file; the AppArmor profile that allows unprivileged user namespaces on Ubuntu 24.04
   bare metal (installed by the release, stage 8).
6. `SO_PEERPIDFD` and `SCM_PIDFD` where the kernel has them (S2-D4).
7. A lint that the host's and the tool servers' logs carry no token, code or terminal text.
8. `vibeswitcher attach ID`, through the server.
9. The second half of the design's stage 2 Done-when: from inside a confined session, another session's screen, the
   node's state and the host's memory are all refused.
10. A hardened branch-code wrapper: a non-dumpable mode of the tool server's image instead of bash, so its argv can't
    be rewritten.
11. Signed approvals (stage 4), with the person's presence for pairing, Push, wallet and guarded settings.
12. Signed releases (stage 8).
13. The support matrix rows say which mode each environment gets.

Added by this revision, and in the document's S12 as items 14 to 16 (decision 20):

14. The keeper's sealed copy (Task 11b, with the sandbox).
15. GitGuard's accepted hooks recorded in the vault and checked before each run (S10's check; S2-D12 says why it
    isn't before).
16. The design's deferred requirements that neither list carried: reply rights type only into confined sessions;
    view rights get masked screens; the wallet's signing page on an origin of its own (the design's Security,
    "Also required"; stages 3 and 4, where rights and the wallet's page exist).
- **A switch replaces the server child when no request is in flight**, by a count of unanswered requests in
  `HostServer.handle`, in place of Task 9d's 30 s bound (`ServerChild.idleLimit`).
- **What a spawn other than the app's may add to a session's environment becomes an allow-list with the sandbox**
  (today a list of refused names, Task 10a); the document's S12 item 17.
