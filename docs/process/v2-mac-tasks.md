# What a real Mac has to check

Each change to the Mac's behaviour made on `v2`, with its commit and what to check on a real Mac when milestone 5
begins ([the design](../superpowers/specs/2026-11-12-vibeswitcher-2-design.md#milestones)): the branch is built and
tested on GitHub's hosted Mac until then, and the runner's limits are below. A Mac-only failure in new platform code
that two pushes haven't explained comes here too, with the experiment that will find its cause
([the branch's routine](v2-branch.md#pushing)).

## The runner's limits

- **System Integrity Protection is off** on the `xcode-27` image: it shows another process's environment, runs an
  unsigned build's probe and lets an injected library into a Hardened Runtime binary, all of which a Mac refuses.
- **3 cores**, where the boost's and the heavy slots' expectations were written for a Mac with more.
- **No Keychain prompts**: nothing that asks the user for the Keychain's consent runs there.
- **No benches**: the design's anti-goal is measured by `--perf`, the UI bench and the freeze count, and a hosted
  runner runs none of them. Each is run on a real Mac against main's numbers.

## Changes to the Mac's behaviour, by commit

- **`ffd4068d`**: `Shell.Spawned` no longer calls `posix_spawnattr_setpgroup(0)` for a session of its own (without
  the SETPGROUP flag the kernel never read it, and 0 is the attributes' start). Check: a session started so is its
  own session and group leader (`ps -o pid,pgid,sid`), as before.
- **`71e8aed5`**: `ProcessTable.record` answers for any user's process, so its five callers that counted on the Mac
  refusing another user's record (`ProcessUsage.usage`, `SessionStrays.record`, `TestLock.startTime`,
  `WalletCourier`'s start, `LoadRecorder.processes`) compare the owner with `geteuid()`; `LoadRecorder` leaves out
  zombies, at two calls per process. Check: a root process never shows in usage, strays, the test lock or the load
  record; `LoadRecorder`'s sample takes no longer than on main.
- **`9aef7377`**: `LeadAdvance` gets no thread when `kevent` can't register the board folder (it had one waiting for
  the stop alone); `WalletFolderWatch` fails at creation when descriptors run out (the platform makes a kqueue and a
  pipe for it). Check: a board change still starts a pass; a wallet watch under a low descriptor limit says it can't
  be watched.
- **`0bfdfc38`**: `LaunchPreflight`'s git look is split (`lookAtGit`, `lookAtGitItself`, `developerToolsApply`), the
  same calls in the same order on the Mac. Check: a Mac without the Command Line Tools is still told so at a start.
- **`865e57ef`**: `WebPush`'s random bytes come from `SystemRandomNumberGenerator`, with no failure path where
  `SecRandomCopyBytes` had one. Accepted: both are a CSPRNG. Check: a push still reaches a subscribed phone.
- **`47636aaf`**: `createLocked` makes, flocks and links on the Mac too, no `O_EXLOCK` (on the runner a reader locked
  13 of 200 tickets `O_EXLOCK` had just made). A crash between making and linking leaves a file under its making name.
  Check: `TestLock`'s waiters under a full suite; that such a leftover is harmless and cleaned.
- **`aa9eee06`**: the signal tests hold one lock (`SignalTestLock`) across the test targets, and `SignalsTests`
  delivers on a thread of its own, because the Mac's kernel refuses `pthread_kill` to a work-queue thread (`ENOTSUP`),
  which is what a Swift Testing test runs on. Check: the three skips it removed pass on a real Mac
  (`SignalsTests/aFatalHandlerIsInstalledToRunOnce`, `aFatalHandlerRunsAndTheDefaultIsBack`,
  `anInformedHandlerStaysAndIsToldTheSender`).
- **`fbd11963`**: socket writes go through `Platform.Sockets.send` (`write(2)` on the Mac, whose sockets carry
  `SO_NOSIGPIPE`); the hook ignores SIGPIPE as its first statement (it did only in its two stdout branches); the tool
  server's caught handler moved to just after its mode dispatches; its read-only permission branch ignores SIGPIPE
  before answering, so it exits 0 instead of dying of SIGPIPE when its reader is gone. Check: the hook lives through a
  host closed mid-write, and the git it starts gets SIGPIPE at its default; the read-only branch with its stdout
  closed exits 0.
- **`b8911886`**: `MCPLogTests` puts SIGUSR2 back as ignored, not at its default: on the Mac `sigpending` sees only
  the calling thread's signals, so a kill still in flight could meet the default and end the run. Check: a full core
  run on a Mac never ends on SIGUSR2.
- **`939ce080`**: `MacLoad.simulatedProcessors`, a task-local core count that only tests bind (nil by default, so the
  app reads the machine's as before); boost's tests run at the machine's cores and at 1 to 128. Two Boost tests in
  `Tests/VibeSwitcherTests` (`BoostMarkTests`, `BoostWatchTests`) are still skipped on the runner, because `v2` doesn't
  edit that folder: fix them on the Mac with the same pattern (`$simulatedProcessors.withValue`).
- **`578741a4`**: `Platform.lines`, whose Mac branch is the original `components(separatedBy: "\n")` call. The
  assertion in `SmallTests.linesAreCutAtEachLineFeedAsTheMacCutsThem` about a combining mark after an LF expects
  `["a", "\u{301}b"]`, as read from swift-foundation, unconfirmed on a real Mac. Check: the test passes there.
- **`9c77316a`**: `DiskSpace` asks `Platform.Files.allocatedSize`, which on Linux is `st_blocks` × 512 (Linux's
  Foundation said 8 times the truth) and on the Mac Foundation's keys, as before. Check: a folder's size matches
  main's for the same folder.
- **`a5499162`**: the config seal hashes a big named file's contents too where ctime is coarse: Linux only
  (`Platform.Files.changeTimeIsCoarse` is false on the Mac). Check: a seal written by main still verifies.
- **`6da32dd2`** (stage 2 Task 10b): every role's launch (the lead, workers and verifiers) names
  `--permission-mode auto` on both systems (`LeadLaunch.prepare`'s `LinuxLaunch.permissionMode(command:)`), unless the
  project's Claude command names a mode itself (`--permission-mode x`, `--permission-mode=x`,
  `--dangerously-skip-permissions`), which it keeps. On main a role's launch named no mode, so Claude Code's own
  default (auto mode since 2.1.284, measured on Linux in 2.1.323) or the user's `permissions.defaultMode` decided it;
  now a `defaultMode` in the user's settings no longer reaches a role. The tests
  (`LeadLaunchTests.eachRoleIsLaunchedInAutoModeByName`, `aProjectsOwnPermissionModeIsKept`) run on the hosted Mac,
  which has no real Claude Code. Check on a real Mac: the Claude Code installed there accepts `--permission-mode auto`
  (one older than auto mode would refuse every role's launch); a role started where `~/.claude/settings.json` sets a
  `defaultMode` (`plan`, `acceptEdits`, `manual`) runs in auto mode; the lead's, workers' and verifiers' approvals
  behave as they do on main.
- **`e1df3188`** (the node on the Mac's step 1, [its design](../superpowers/specs/2026-11-19-v2-node-on-macos.md)):
  `vibeswitcher-host --node` is refused on the Mac (`HostImages.macNodeRefusal`); it was ignored, so a host started as
  the node's ran as an ordinary Mac host on the app's `~/.vibeswitcher/host.lock`. The app never passes `--node`. The
  command line's user's node is refused on the Mac before anything is read or run (`NodeSystem.usersNodeRefusal`, exit
  69: `start`, `stop`, `status --ack` and every connection; `status --probe` still runs), and a user's server
  (`--node`) on a system with no cgroups is on the closed voice rule (`VoiceRule.at(…, usersNode: true)`), where it got
  the weaker one. New platform code, written on Linux and never run on a Mac: `Platform.Service`'s Darwin arm
  (`Service+Darwin.swift`). The hosted Mac checks `ServiceTests`, `NodeSystemTests`,
  `VoiceRuleTests.theUsersServerWithoutCgroupsIsClosedUntilItsRuleIsBuilt` (its "this system's default" arm) and
  `HostHardeningTests.theNodesRootIsNeverFromTheEnvironment` (its Mac arm). **Needs a real Mac run**, by hand, with the
  app running and no node installed: `vibeswitcher start`, `stop`, `status`, `status --ack` and `lead ~/x` each print
  the refusal and exit 69 at once, no prompt; `vibeswitcher status --probe` lists the sessions; a built
  `vibeswitcher-host --node --node-root X --server X/bin/vibeswitcher-server` exits 1 with the refusal, and the app's
  host and its `~/.vibeswitcher/host.*` files are as they were. The design's measurements (the environment line under
  SIP, the voice candidates, LocalAuthentication from a LaunchAgent) are its steps 4 to 9.
- **`ea63e9eb`** (the node on the Mac's step 2, the root): the user's node's root is a `Platform.Service` fact,
  `Platform.Service.nodeRoot(accountHome:)`: `~/.vibeswitcher` on Linux (unchanged), `~/.vibeswitcher/v2/node` on the
  Mac, beside the app's folder. `NodeFolders.nodeRoot` reads it, so the command line's socket, record and log for the
  user's node are there; the `--node` host's environment (`HostImages.nodeEnvironment`) and the user's server
  (`ServerStart.nodeRootVariable`) set `VIBESWITCHER_HOME` to it on the Mac (unset on Linux, as before), so the host's
  lock, socket, launcher copy, log and vault would be there, never at the app's `~/.vibeswitcher/host.*`;
  `NodeFolders.isUsersRoot` takes both the node's root and the account's folder as the user's node (a
  `VIBESWITCHER_HOME=~/.vibeswitcher` on the Mac is the user's node, refused, never a scratch node on the app's files).
  `--node` is still refused on the Mac (its text now names the root). The hosted Mac checks
  `NodeRootHostTests.aHostInTheNodesEnvironmentKeepsItsFilesInTheNodesRoot` (a scratch host in that environment: its
  socket at `<home>/.vibeswitcher/v2/node/host.sock`, the app's folder holding only `v2/node`), `ServiceTests`,
  `NodeSystemTests.theNodesRootAndTheAccountsFolderAreBothTheUsersNode`,
  `HostHardeningTests.theNodesRootIsNeverFromTheEnvironment` and `StartCommandTests.aMachineWithoutSystemdStartsTheNodeDetached`
  (its Mac arms). **Needs a real Mac run**, with the app running: the app's launch repair (`PrivateRepair.atLaunch`)
  leaves a `~/.vibeswitcher/v2/node` made after its marker alone, and a node made before it (0600/0700, programs kept
  runnable); the server socket's path for the real home is under 104 bytes. **Left for step 5** (inert on the Mac
  today, each a Linux-only arm): the host's `mayStart` is given `<home>/.vibeswitcher` as the account's root
  (`vibeswitcher-host/main.swift`, shared with main), and `ProjectAllowList.place` and `HandoverTarget.installRoot`
  return nil on the Mac; each is decided against the node's root when `--node` runs there.
- **`87de7244`, `e98a89d6`, `0546967b`** (the node on the Mac's step 3, the server beside the host): new Darwin
  code, written on Linux and never run on a Mac. `Platform.Sockets.connectorType` is a stream on the Mac (no
  `SOCK_SEQPACKET` in its Unix domain); `sendDescriptor`/`receiveDescriptor` pass one descriptor by `SCM_RIGHTS`, the
  control message laid out in Swift (12-byte `cmsghdr`, 4-byte alignment; the Mac's package has no C shim), close-on-exec
  right after `recvmsg` (no `MSG_CMSG_CLOEXEC` there). `Platform.CodeIdentity.runs(_:cdhash:)` and `isHardened(_:)` (the
  dynamic status word: valid, `CS_RUNTIME`, no `CS_GET_TASK_ALLOW`, not `CS_DEBUGGED`). The host's `ServerChild` on the
  Mac reads the `--server` file's cdhash at its start and starts the child from the file only while its cdhash is still
  that; its connector (`HostServer.openServerChildConnector`; `openAppConnector` stays nil on the Mac, so the app's tests
  and the app are as before) answers only the child's pid running that code, under the Hardened Runtime; the server's
  connector watch is `Platform.Sockets.waitUntilPeerHasGone` (a kqueue's `EV_EOF` on the Mac, whose `poll` asked for
  no event registers nothing). The hosted Mac checks `SocketsTests.aDescriptorPassesOverAConnectorPair`,
  `theConnectorsPairIsEachSystemsOwn`, `CodeIdentityTests`, `HostConnectorTests` (now on both systems) and
  `MacServerChildTests` (a copy of the built server signed `codesign -s - -o runtime` is the app; the build's own
  linker-signed one is refused and ended; a file replaced after the start starts nothing). **Needs a real Mac run**:
  the three `MacServerChildTests` with SIP on (the runner's is off); that a hardened server can't be reached by
  `task_for_pid` or `DYLD_INSERT_LIBRARIES` from a process of the user's (by reading the status word, not by trying a
  debugger: the hard rules); that Security's dynamic check refuses a token after the child execs another program; that
  a universal server's running slice is the one whose cdhash the host read (the host reads this machine's default
  slice: a single-arch build is safe); and what happens to the old child across a handover (no record is carried on
  the Mac: the exec closes its connector, it exits, and the new image starts another; check it is reaped, not left a
  zombie).
- **`8f8b7e20`** (the user's voice on the Mac, decided 2026-11-20: Touch ID or the login password for each state change,
  with the caller check): `Platform.Approval` (LocalAuthentication's `deviceOwnerAuthentication` on the Mac, with a
  timeout; Linux: unavailable) and `ApprovalVoice` in VibeNode (the uid, the installed command line's cdhash, the guard
  rails without the environment line, then the card's text as the dialog's reason for a state change). **Not wired**:
  the user's server on the Mac stays on the closed rule and the user's node refused, until the design's step 4.
  `ApprovalVoiceTests` (a fake authenticator, both systems) and `ApprovalLintTests` (no test asks). **Needs a real
  Mac** (step 4): the dialog from `vibeswitcher-server` as a LaunchAgent in `gui/<uid>`, its title (the program's
  name, which the reason follows), with the lid closed, over ssh, with no Touch ID enrolled (the password then), and
  `.notInteractive`/`.passcodeNotSet` read as unavailable; what a second dialog does while one is open; whether a
  process of the user's can answer it (Accessibility consent); then the rule wired: `VoiceRule.Mode` gains the Mac's
  mode, `Requests` judging each request by `ApprovalVoice` with the card each kind acts on, and the server's start
  reading the installed `bin/vibeswitcher`'s cdhash.
- **`1a6c4688`, `9130a33a`** (the Mac's rule wired, 2026-11-21, `v2-small-rows`; still off): `VoiceRule.Mode.approval`
  (`VoiceRule.at` gives it to the user's server on a system with no cgroups only when `NodeSystem.approvalMeasured` is
  true; it is false, so that server stays on the closed rule and the user's node refused); `Requests.approvalJudgment`
  (the action id, a card's code, stopping and the host's welcome answered before any dialog; a read judged at once; a
  state change put to `ApprovalVoice` on a queue of its own, one at a time, a second refused while one waits; its reason
  the server's own words for the request, `Requests.approvalCard`: a card's first lines, else the request's own
  arguments, inert and short); `NodeServer` passing each peer's audit token; the server's start reading the installed
  `bin/vibeswitcher`'s cdhash; the command line showing what a request does and asking no code when the hello's rule is
  `approval`, waiting 120 s for a state change. Tests: `ApprovalJudgmentTests` (both systems, the hosted Mac's core job:
  a read unasked, a state change only once approved, declined, unavailable, a stranger, a session's descendant, no
  action id, a held card refused unasked, not-yet before a dialog, one at a time) and `ApprovalRequestsTests` (Linux, a
  scratch host: the whole request, the vault's record and the act). **Needs a real Mac** before `approvalMeasured` is
  turned on, besides step 4's measurements above: one `vibeswitcher set` and one `answer` end to end from Terminal (the
  dialog appears once, names the setting or the card, Cancel refuses with nothing recorded, Touch ID does it); the same
  from a Claude Code session's Bash tool (refused before any dialog: its ancestry); from `open -a Terminal x.command`
  and `osascript … do script` started by a session (the escape the design names: the dialog then appears, and the
  person must decline it; record what the dialog shows); a second request while a dialog is open (refused, saying so);
  and the CLI's 120 s wait against the dialog's 60 s. An independent review of `ApprovalRequests.swift`,
  `ApprovalCard.swift` and the `Requests.handle` split before it is turned on.
- **The LaunchAgent as data** (2026-11-21, `v2-small-rows`; the design's step 5, not wired): `NodeAgent` makes
  `~/Library/LaunchAgents/dev.vibeswitcher.node.plist` from the unit's inputs (the commit's own host with `--node`,
  `--node-root` and its server; `HOME`, `PATH`, `SWIFT_BACKTRACE`; `KeepAlive` false; `RunAtLoad` only at login;
  `ProcessType` Interactive; `LimitLoadToSessionType` Aqua; stderr to `<node root>/node.log`), checks a file read back
  is exactly that (a key added or changed is found), gives the `launchctl` lines (`bootstrap gui/<uid>`, `kickstart`,
  `bootout`, `print`, `getenv`) and reads `launchctl print`'s job `pid` and `program`. `NodeAgentTests`, both systems.
  `start` on the Mac is still refused. **Needs a real Mac** before `start` uses it: `launchctl bootstrap gui/<uid>` of
  the written file loads it and `kickstart` starts the host (and with `RunAtLoad`, at the next login); whether
  `LimitLoadToSessionType` Aqua keeps it out of an ssh login's background session; `launchctl print`'s real output (the
  job's own lines one tab in, `pid = ` and `program = ` as parsed; a nested block's deeper); `bootout` ends the host's
  process group and what it leaves (sessions in sessions of their own stay, as the design says); `launchctl getenv` for
  each of `NodeAgent.refusedManagerNames` after a `launchctl setenv`; the stderr file's mode and growth; and
  LocalAuthentication's dialog from this agent (the voice's step 4 above).

## Before approvalMeasured flips

The independent review of the Touch ID voice (2026-11-21): no path reaches `voiced` without `.approved`, and today's
path fails closed (`NodeSystem.approvalMeasured` is false). Before it is turned on, each of these is done, measured
or decided. Done on Linux, tested on both systems (`ApprovalJudgmentTests`, `ApprovalVoiceTests`):

1. **(HIGH, done in `6f367200`)** The dialog's text per kind from validated arguments (`Requests.approvalCard`): the
   request's word first; the decisive part whole (an answer's words, an approval's commit and tasks, a shell card's
   command and folder under "run an agent's command in your login shell", a config card's held-item count and changed
   guard rails, a setting and its value) or nothing asked; the lead's and agents' words marked “…” and cut after it,
   saying so; no argument key shown; a field a kind doesn't take refused before any dialog.
2. **(HIGH, done in `6f367200`, `03f406c9`)** Attribution: the dialog starts with `NodeIds.code(action:)` of the
   request's action id, which the command line prints before it sends; the busy refusal never tells the person to
   answer the dialog on screen (it says that one is someone else's when its word isn't theirs). **Real Mac**: that the
   word reads first in the dialog as drawn (the system's title precedes the reason).
3. **(MEDIUM-HIGH)** The caller check: the Hardened Runtime is required of the peer (done, `6f367200`:
   `ApprovalVoice.hardened`, `Platform.CodeIdentity.isHardened`). **Owed**: the node's command line signed with
   `--options runtime` (the install's signing decision, step 7). **Built 2026-11-25 (`v2-mac-anchor`, off with the rule,
   needs a review)**: its cdhash is anchored in the node's root-owned record (item 10), not re-read from the writable
   `<root>/bin`: the server takes the command line of the record's row whose server is its own running code
   (`ApprovalVoice.commandLineAnchor`, `Platform.CodeIdentity.ownCdhash`), read once at its start.
   `NodePinsAnchorTests/aCommandLineSwappedInTheBuildAfterTheStartIsRefused` (red on the old anchor, green now; real
   signed images and audit tokens on this Mac): a command line renamed over `<root>/bin/vibeswitcher` after the start is
   refused, the genuine one taken. Unproven: a real server started by a node host reading the installed record (no Mac
   node host runs yet, item 13). **Real Mac**: `DYLD_INSERT_LIBRARIES` into the command line refused (measured
   2026-11-25, branch `v2-mac-step4`'s M6: refused with `--options runtime`);
   the connect-write-exec race (a process connects, the command line's code then execs in its place: Security's dynamic
   check on a token after exec); Accessibility driving the password fallback (synthetic typing into the dialog).
   **Row 7 (2026-11-26, `v2-mac-anchored-cli`): already closed, proven through every place.** The places that take the
   command line's identity: the server's anchor at its start, a connection's hello voice, each request's voice before
   the dialog, the command line's own build (`start`, and now `switch` before anything is asked). Each refuses a command
   line renamed over `<root>/bin/vibeswitcher` after the start, with its reason, and takes the genuine one, with real
   images and tokens (`NodePinsAnchorTests/everyPlaceTakingTheCommandLinesIdentityRefusesOneSwappedInTheBuild`; red
   with `b3849695`'s hunk reverted). Nothing re-reads a file under the node's root for it; the list, and what takes no
   command line identity, in the design's "Rows 7 and 10". *Still owed:* the signing with `--options runtime` (step 7),
   the real record (a `sudo` trial), and the real-Mac items above.
4. **(MEDIUM, done in `6f367200`)** Values per kind: send's words cut only saying how many there are, presets' env
   values shown, sessions by terminal and folder, no forgeable "; key value" (no key is shown).
5. **(MEDIUM, done in `6f367200`)** The uid, code, Hardened Runtime and guard-rail checks before the one dialog's place;
   a 10 s cooldown after a declined, cancelled, timed-out or unavailable dialog; a truthful busy refusal.
6. **(MEDIUM, for the user)** The reads with no gate a detached session can't pass on the Mac (`mail`, `recent`,
   `shells`, `config.held`, `base.show`): written into the design note as open.
7. **(BLOCKER, built 2026-11-21, `v2-small-rows`; each needs an independent review and a real-Mac run)**
   - Darwin ancestry (`c1eeb472`): `Platform.Processes.link` reads `proc_pidinfo(PROC_PIDTBSDINFO)` (parent, start
     in microseconds, controlling terminal by `devname`); `isProcess(of:)` is the same pid and the audit token still
     found by Security (`SecCodeCopyGuestWithAttributes`) after the link was read, so a reused pid or an exec fails it.
     Owed on a real Mac: a link read for a process of another user (refused, nil), a zombie, a process that execs
     between the read and the check; `HostHardening.isOurs` stays Linux-only (`atStart`/`watch` never run there).
   - The record of the user's actions on a Mac node's host (`03f4044a`): `vaultV2` answered, and listed in the
     welcome, only by a host with a server child and a vault (`HostServer.isMacNodeHost`); the Mac app's host
     unchanged. The record's rules are Linux's (`LeadVaultV2.answer`). Owed: the Mac node host's vault on disk
     (its keychain-held key) measured, and the record surviving a handover there.
   - The command line's server check by code identity (this commit): on the Mac, the listener's audit token must run
     the `vibeswitcher-server` beside the LaunchAgent job's program (an installed build, `NodeCheck.installedServer`)
     by cdhash with the Hardened Runtime, be the job's child and in its session; a scratch or detached node is
     refused there. Owed: a run against a real job.
   - The install's Mac signing (2026-11-21, `v2-small-rows`): `scripts/lib/mac-sign.sh`'s `mac_sign_hardened` signs a
     product ad hoc with `--options runtime` and checks it back (valid for every slice, the runtime flag);
     `Platform.CodeIdentity.isSignedHardened(atPath:)` reads the same from disk; `MacSigningTests` (the Mac runner) signs
     copies of the built server and command line and checks them, and a copy signed without the runtime fails. **Owed**:
     `scripts/install-node.sh` has no Mac arm yet (its checks are Linux's throughout: `getent`, the ELF interpreter,
     `readelf`, `sha256sum`, the root-owned toolchain), so nothing calls the signing; the Mac arm calls
     `mac_sign_hardened` on each staged copy before its first hash, and adds `lib/mac-sign.sh` to the libraries it
     checks against the commit's blobs. Done as its own script (below).
   - The Mac's install, `scripts/install-node-mac.sh` (2026-11-21, `v2-small-rows`; install-node.sh untouched): the
     same steps and exit codes with the Mac's tools (`id -P` for the home, `shlock`, BSD `stat`/`realpath`/`mv -h`,
     `shasum`, `/usr/bin/jq`); GitHub's compare and runs through `/usr/bin/curl` with gh's keychain token (no gh binary:
     Homebrew's is the user's); the developer folder's toolchain and SDK root's; a release build without
     `--static-swift-stdlib`; each product Mach-O, arm64/x86_64 slices with this Mac's, an executable, loading only
     `/usr/lib/…` and `/System/Library/Frameworks/…`, no run path but `/usr/lib/swift`, no `LC_DYLD_ENVIRONMENT`; signed
     (`mac_sign_hardened`) before its first hash; `lib/mac-sign.sh` checked and sourced from the commit's blob; then
     `vibeswitcher agent-plist` (`NodeAgent.installed`) writes `<prefix>/dev.vibeswitcher.node.plist` and the
     launchctl lines are printed, never run. Its dry run (`scripts/ci/macos-install-dry-run.sh`, its own workflow
     `v2 macos install`, which install-node.sh's CI check doesn't ask until it has been green a while) builds HEAD for real from a scratch origin into a scratch prefix with an injected green
     answer, and checks the refusals it can reach. **Needs an independent review** (it is the Mac's S9). **Only a real
     Mac**: gh's token in the login keychain (`security find-generic-password -s gh:github.com`, its
     `go-keyring-base64:` form), GitHub's answers through curl, an App Store Xcode passing the toolchain check (and how
     long its `find` takes), launchd taking the written agent and the host starting from it, and whether the host
     needs entitlements build-app.sh gives the app's (`VibeSwitcherHost.entitlements`). Known gap: BSD `mv` has no
     `-T`, so the build's rename checks its target absent under the lock, then checks the result.
     **The toolchain's run paths (2026-11-22, the first dry run):** a release build for this package's deployment
     target carries an `LC_RPATH` into the developer folder (Swift's back-deploy folder,
     `…/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx`), a folder the user can write. The install deletes every run
     path under the developer folder, and any other but `/usr/lib/swift`, from each staged copy before it signs it
     (`install_name_tool -delete_rpath`), the check then refuses any non-system run path left, and the installed
     command line must start (`vibeswitcher help`). **This assumes macOS 26 or later**, whose `/usr/lib/swift` holds the
     Swift 6.2 runtime the products link (they load nothing through a run path: absolute system paths only). The
     cleaner fix, for a main merge and the user's call: raise the package's macOS deployment target to 26, so the
     back-deploy run path isn't added at all (Package.swift is shared with main, and the target decides which Macs
     the app runs on).
   - A card for a kind with no arguments (`stop`, `start`, `web.revoke`): done, `approvalCard` names what each does
     (`stop` the live sessions it ends).
8. **(LOW, done in `6f367200`, `03f406c9`)** A replayed action id answered before any dialog; the command line's
   approval rule per connection, so its own confirmations (`status --ack`) always ask the code.
9. **(BEFORE THE MAC NODE STARTS; built 2026-11-25, `v2-mac-web-port`, proven on a real Mac) The Mac's own H1.** On
   Linux the host holds the web page's listening sockets (H1, merged 2026-11-21); the Mac's server bound them itself
   (`WebBind.forServer` gave `.direct` on its stream connector), so a process of the user's could take the port in the
   gap between one server and the next. **Built:** the host holds the web socket on the Mac too and hands it to its
   server with `SCM_RIGHTS` over the stream connector, the web messages framed (`Platform.Sockets.sendConnectorMessage`,
   `receiveConnectorMessage`, `receiveConnectorRequest`: Linux's are the `SOCK_SEQPACKET` calls as before; on the Mac a
   byte other than `w` is a one-byte message, as the connection's request and answer were, and a message starting with
   `w` runs to its newline, its descriptor on its first byte, read a byte at a time; a message cut, too long or with a
   descriptor on a later byte fails, and the host ends the connector). A web request is the server child's on the Mac
   when it comes on the child's own connector from the pid its first request named running the code the host loaded
   (no token is read at the spawn there). `WebBind.forServer` is always the host's: the server never binds the web.
   **Route:** this, not launchd's `Sockets` in `NodeAgent`: launchd binds at the job's load (shape (b), where H1 built
   (a): the port free before `web` and after a revoke, LW-D3), a plist names no kernel-picked port, plugin page or
   tailnet address, and a scratch host isn't a launchd job, so the real path couldn't be tested (launchd's own socket
   options not measured). **What a real Mac proved** (2026-11-25). `MacWebHeldByHostTests`, on a scratch host with its
   server child: the server gets the host's socket over the stream connector and serves the page on it; a bind of
   127.0.0.1:P with `SO_REUSEADDR` is refused while the server runs, once it is killed (before or as the host starts the
   next) and once the next runs; a page's request made between two servers
   waits in the host's socket and the next server answers it on the same port; nothing reaches it on another address
   of the Mac; a port another process already holds (with `SO_REUSEPORT` or without) refuses the web with "127.0.0.1:P
   couldn't be bound: …" in `web.open`'s reply, `status` and the host's log, and nothing is bound elsewhere (item 32's
   last line: the web's start fails, not the host's, which binds on demand). A C probe on the same Mac, against a
   standalone holder of 127.0.0.1:P (`SO_REUSEADDR`, no `SO_REUSEPORT`): no bind of 127.0.0.1:P or
   `::ffff:127.0.0.1`:P succeeds with `SO_REUSEADDR`, `SO_REUSEPORT`, both or neither; a holder with `SO_REUSEPORT` loses
   127.0.0.1's connections to a squatter with it. The Mac's `AF_UNIX` has no `SOCK_SEQPACKET` (`EPROTONOSUPPORT`), and a stream read runs on past a
   descriptor's message, hence the framing. **The Mac's residual** (as Linux's `SO_REUSEADDR` one, item 32): a socket
   on the wildcard (`0.0.0.0` or `[::]`, with `SO_REUSEADDR` or `SO_REUSEPORT`) or on `[::1]` binds beside the host's
   (BSD's rule; the host dropping `SO_REUSEADDR` changes nothing), but a connection to 127.0.0.1, the page's one name,
   still reaches the node (`aWildcardSocketBesideTheHostsNeverTakesTheLoopbackPage`); a host holding with `SO_REUSEPORT`
   would lose its connections to a squatter, so it never sets it. **Unproven:** a handover on the Mac with the web on: its
   state carries the held sockets by the same code as Linux's (`State.webListeners`, `ServerChild.adopt`), and its
   server child isn't carried there (the new image starts the next, which asks again), but no Mac handover was run
   here; the tailnet's place on the Mac; the plugin page's place (it now goes through the host on the Mac too, and no Mac
   test asks for it); a user's node started by launchd (`web` stays refused until the Mac node starts: `NodeSystem.macUnbuilt`,
   `HostImages.isCheckedMacNode` unchanged); Linux's run of this change: the connector calls are Linux's own by
   reading, but the new and changed cross-platform tests (`ConnectorMessagesTests`, `HostConnectorTests`' web asks, whose
   stand-in host now sends a connection's answer with `sendDescriptor`, `HostWebListenTests`) were never compiled there
   (CI's).

10. **(BLOCKER before approvalMeasured, design; the review of 2026-11-21, its fifth finding)** A fake server passes the
   command line's server check on the Mac with no race. Every anchor the check uses is the user's to write: the job's
   label and plist (`launchctl bootout`, then `bootstrap` a plist from any path with the same label and a program of
   one's choosing), the builds folder (`~/.vibeswitcher/v2/builds/<commit>/bin/…` can be made by any session with a
   genuine host and an evil server, so `NodeCheck.installedServer` and the cdhash read from that file vouch for
   nothing), and any reference file beside them. (The server's path is now resolved and must be the file itself.) Needs an anchor a session can't write. Options:
   - **cdhashes pinned at install in a root-owned place** (`/Library/Application Support/VibeSwitcher/<uid>/pins`,
     written by a one-time `sudo` step or a privileged helper): the command line checks the server's running cdhash
     against the pin, not against a file. Costs a password at each install; the pin moves only with root.
   - **A Keychain item bound to the command line's code** (an access control list naming the CLI's designated
     requirement, written by the install): holds the expected server cdhash; a session's process can't read or
     rewrite it without the CLI's code. Ad-hoc signing changes the requirement at every build, so the install rewrites
     the ACL, and the item needs the user's login keychain unlocked.
   - **A Developer ID team identifier**: check the server against a requirement on a team the user can't sign as.
     Needs a paid signing identity; then the requirement is fixed and no pin is needed.
   Until one is built, the Mac's server check proves only "a hardened binary the user's account could have placed".
   **Built 2026-11-25 (`v2-mac-anchor`; the user chose the root-owned record; needs a review)**, as the node on the Mac's
   design's "The anchor" says: `/Library/Application Support/VibeSwitcher/node-<uid>.pins`, every folder from `/` root's
   and writable by neither group nor others, no link followed (walked by `openat(O_NOFOLLOW)`, checked by `fstat` on the
   descriptor read), no ACL (`Platform.Files.readRootRecord`); it pins each build's host, server and command line by
   cdhash (`NodePins`), written only by the install's administrator step (`scripts/node-pins-mac.sh`, one `sudo`, run by
   `install-node-mac.sh` from the commit's verified blob, `--dry-run`). The command line takes only a listener whose
   running code is a pinned server (`NodeCheck.macServerCode`); the host finds its own build by its running code and
   starts only that row's server (`HostImages.macServerPin`); a switch goes only to a pinned host
   (`HandoverTarget.macPinned`, by path before the exec: a file swapped between the two isn't caught, listed in the
   design's "What it doesn't cover"). Proved on this Mac by `NodePinsAnchorTests` (red on the old anchor, green now): the
   fake server of this item (a genuine host, another server image in the builds folder, the job's program rewritten)
   refused; a record missing, a link, writable by its group or others, under such a folder, with an ACL, a second link,
   another uid, unparseable or (by an injected owner fact) the user's, refused, and the same scratch record refused with
   the node's own facts. **Unproven**: the record written for real by `sudo` (the user's trial: the step on a throwaway
   path, its owner, mode and parents, an unprivileged write refused); a mount over a folder on the path (refused to a
   user by macOS, not measured); the checks against a real running node (none runs: items 5, 9, 13). **The review of
   2026-11-25** ("ready for v2 with fixes"), fixed on `v2-mac-anchor`: the own cdhash read from the kernel, not the
   file at the path (F1, `OwnCdhashTests`); a second hard link no longer refuses (F2); the administrator step's mend
   takes no values (`--keep N`), drops imported functions, writes only the node's or a trial's record and checks every
   line as root, under `env -i` (F2 to F5); a re-bootstrapped job whose own host runs the genuine pinned server is
   refused by the server at its start, its connector's peer checked against its row's host (F7,
   `ConnectorPeerTests`; off with the rest). **Open** (the design's "What it doesn't cover"): a switch's target swapped
   between check and exec (F6), and every pinned build passing for good (F8: `--fresh` or `--keep 1` on a security
   update). **The first upgrade** from a build older than this
   branch writes no record (the install runs the installed commit's own script, which has no administrator step): the
   record starts with the first install made by a build that has it, and a rollback to an older build is refused.
11. **(BLOCKER before approvalMeasured; the review's sixth finding; built 2026-11-22, `v2-small-rows`, needs a real
   Mac and a review)** Built: `Platform.Processes.link` falls back to the kernel's record (sysctl `KERN_PROC_PID`, any
   user's) where `PROC_PIDTBSDINFO` refuses; `PeerFacts.runner` takes a root-owned ancestor with unreadable arguments
   above a non-root sender as no runner (a runner is the user's code), every other unreadable one still nil (refused).
   Tests: `ProcessesTests` (launchd's link on the Mac runner), `PeerRunnerTests`. Was: the Mac's ancestry is unreadable for a Terminal or
   ssh user: `proc_pidinfo(PROC_PIDTBSDINFO)` is refused for root's processes (`login`, `sshd-session`), and so is
   `KERN_PROCARGS2`, so a chain through them ends unread and the peer is refused. The fix reads the short record
   (`PROC_PIDT_SHORTBSDINFO`, any user's: parent and start) and `sysctl KERN_PROC_PID` for the rest, each still bound
   to the token as `Link.isProcess(of:)` binds it; never "unreadable is fine". **Real Mac**: a chain from Terminal and
   one from ssh read whole.
12. **(BEFORE the Mac node's switch; the review's eighth finding)** `launchctl print`'s `program` line is the job's
   configured program, not the running image: after an in-place switch (the job's plist rewritten, the host handed
   over to the next build) the check would compare the genuine server against the next build and refuse it. And
   `launchctl print`'s output isn't an API (its format changes between releases). Options: the host reports its own
   build to the command line over a channel the check already trusts, or the check reads the host's executable by
   its pid and token (`proc_pidpath` bound to the token) instead of the job's line. **Built 2026-11-25
   (`v2-mac-anchor`, with item 10's record)**: neither: the check reads the running image of the process bound to the
   listener's audit token (Security's dynamic check of its cdhash) against the servers the record pins, so no path is
   read at all and the job's `program` line drops out; only `pid` is taken from `launchctl print` (whose format
   `NodeAgent.printed` parses, measured on macOS 27.2: `v2-mac-step4`'s M11). Proved by
   `NodePinsAnchorTests/aSwitchToAPinnedBuildPassesAndToAnotherIsRefused`: with the job's program naming the next build
   while this build's server runs, the server passes (red on the old check). Unproven: a real in-place switch.
   **Row 10 (2026-11-26, `v2-mac-anchored-cli`; off with the rest; needs a review)**, as the design's "Rows 7 and 10"
   says. *Built:* the command line's server check takes the job's host from `MacAgent.runningHost` (launchd's whole word,
   the host by token and code), never from `print`'s text; a switch's Mac follow-up rewrites the plist for the build the
   host went to (`MacAgent.switched`: the host the target's by token and code first, the plist replaced by a new file
   renamed over it, `start`'s own checks with its descriptor held, launchd's word and the host again, the old bytes put
   back on a refusal after the rename, nothing loaded or unloaded); launchd's job may be another pinned build's than the
   plist's: for `status` and `start` only while the host is the plist's build and switched in place, and `status` and
   `start` refuse a host whose build isn't the plist's, naming the remedy; `stop` and the command line's server check
   also take a host that switched in place (the keeper's flags) whatever builds launchd's job and the plist are of, or
   that runs launchd's own job exactly under a plist another process replaced, so that `stop` and the remedy can run
   (the design's "Rows 7 and 10" has the rule). *The review's notes (2026-11-26, "ready with fixes"):* N1, the server
   check says why the host isn't known and what to do; N2, every remedy named runs from its state (a replaced plist:
   `vibeswitcher switch <build>`; a put-back that failed: remove what is there, `launchctl bootout` by hand, `start`);
   N3, a change in behaviour: `start` unloads a loaded, not-running job of another pinned build than the plist's, which
   before it refused and left loaded (`aStartOverAJobNotRunningOfAnotherBuildUnloadsItFirst`); N4, this line, and
   settle's refusal says the switch again finishes it. `program` is still read only by the grammar (a mismatch refuses) and the
   lenient reader in `start`'s wait (only to refuse sooner). *A real Mac proved:* an in-place switch of a scratch
   launchd job through a keeper (`MacAgentSwitchTests`, red with the change reverted): launchd's word stays the first
   build's job across it; the plist rewritten; `status` passes for the new build; after `stop`, the old build's `start`
   is refused and the new one's starts it; a print naming the pinned host while another image runs refused.
13. **(Owed, the review of 2026-11-21)** The Mac's checked node start (`HostImages.isCheckedMacNode`, false): until it
   exists no Mac host runs a `--server` child on the account's locks, none is a node host, and the record of the
   user's actions, its hooks and the vaultV2 capability stay off on the Mac (fixes `6e0798d9`, `a0a596d8`,
   `b45bb7b0`). It depends on item 10's anchor: a check against the user's own files proves nothing. **Still off
   (2026-11-25)**: item 10's record is built (`v2-mac-anchor`), so the checked start now waits on its own build and
   review: a `--node` host on the Mac that refuses to start unless its own running code is a pinned host
   (`HostImages.macServerPin` asks it, wired only behind `isCheckedMacNode`), the LaunchAgent wired (step 5, item 9's
   row), the server refusing a connector peer that runs no pinned host (the fake-host case above), and a real run of
   the administrator step by the user, and a switch that execs the checked file (not its path) or has the new image
   prove its code before the state is handed over. A record that can't be taken has no recovery short of the
   administrator step run by hand (`--fresh`) or a newer install: the install refuses an installed commit.
   **Built 2026-11-25 (`v2-mac-checked-start`, on `v2-mac-anchor`; off: `isCheckedMacNode` stays false; needs a
   review)**, as the design's "The checked node start" says. *Closed:* a `--node` host on the Mac starts only after
   `HostImages.macNodeStart` found, in order, the node root's own lock, the record, its own running code (the kernel's
   cdhash) as a row's host, and its `--server` (opened once, the node root's own file) as that row's server; only a host
   holding that result (`Config.checkedNode`) is a node host (a server child by the row's cdhash, `vaultV2`, the book's
   record and hooks), and a `--node` host without one runs no server child (`MacCheckedStartTests`, red on the seam
   `80358389`, green from `783e585d`). F6, narrowed and not closed (the fix round's re-check of the review's F1 pending;
   the design's "What it doesn't cover" says what a swapped file and a wrapper running the genuine image still do): a
   checked node host's switch goes through a keeper whose fresh token runs the
   pinned target's code, and the state, secrets and every descriptor cross the exec only to a new image whose fresh
   token runs the keeper's code; the server child is ended and reaped before the exec and started again by the new
   image (`MacKeeperHandoverTests`, scratch hosts with `--handover-test-keeper`); the keeper is proven against the cdhash
   the record was checked against, read once (`MacKeeperTargetTests`), and a switch gives the new image the target
   build's `--node-root` and `--server` (`aSwitchGivesTheNewImageItsOwnBuildsFolders`). *A real Mac proved:* all of it with
   this Mac's real hardened images, tokens and in-place exec. *The fix round (the review of 2026-11-25):* a checked node
   takes only its own arguments, each once, and none of this program's variables (F1, N5); the lock by its exact path,
   and `main` refuses a checked start it doesn't take for the user's host (F2); a checked node's parcel goes only to an
   image holding its own checked start, and a checked start takes state only from a keeper it proved (F1, N2); who the
   app is keys on the checked start, not on the server child (N1); the target's server is checked against its row
   before the keeper starts (N4); the keeper's wait has a limit (N6); the server child is told the build's folder (N3)
   (`MacCheckedFixRoundTests`). *Still open:* a file swapped between the keeper's proof and the exec runs at the job's
   pid with nothing, and the sessions end; a wrapper running the genuine pinned image with other arguments takes nothing
   and the sessions end, and one running it with the node's own arguments is the node, with the environment outside
   this program's variables of its choosing (superseded by the re-check below); a proven new image that can't restore exits
   (no unchecked fallback); F8 as above. *The re-check (2026-11-25, "not yet"; closed on this branch, needs its own
   re-check):* a checked node's command line is parsed once into a value (`HostImages.CheckedCommandLine`) and `main`
   builds the node from it alone, its raw arguments read by nothing else (I1); the keeper proves its parent (pinned host
   code, from the record, for a checked node's parcel), a checked start takes only a checked node's parcel holding the
   node's lock through its own descriptor, and only a checked node starts on the node's lock by file (I2); at its start
   a checked node takes its environment from a fixed list and closes the descriptors it was given (but the keeper's),
   umask 077, folder `/`, no core files; the handshake's flake (8 of 20 under load) found and fixed (the design's "The
   handshake"). *Round 2's last changes:* the node's lock known by the descriptor a host opened too (another letter case,
   a dangling link), every open descriptor closed at the start (not a range up to a lowered limit), the keeper's limit
   while it holds the state tested end to end, the new image's wait for its keeper limited. *Step 5 owes* (new): what
   the sessions on a checked node lose under the reset: `SSH_AUTH_SOCK`, the user's `PATH`, `LANG`, `LC_ALL`, `LC_CTYPE`,
   `__CF_USER_TEXT_ENCODING`, and they inherit umask 077 and a hard `RLIMIT_CORE` 0 (a plist's environment is a
   wrapper's to replace, so it is no answer); `NodeAgent` writes `SWIFT_BACKTRACE` into the plist, which the reset drops. *What step 5 (the LaunchAgent, next) can rely on:* the job's program, started
   as the unit's form, `<builds>/<commit>/bin/vibeswitcher-host --node --node-root <builds>/<commit> --server
   <builds>/<commit>/bin/vibeswitcher-server`, on the node's data root's lock (`<home>/.vibeswitcher/v2/node/host.lock`,
   its default), either refuses with one line on stderr (exit 1) or is the pinned host of its row with that row's server
   as its child, on the job's pid across every switch; a switch never changes the pid; and the job's stderr is where
   each refusal is said. Step 5 still owes the plist, `launchctl`, the command line's start and stop, and the switch-on
   review with the user's go-ahead. (Built since: item 15, with the sessions' environment and `SWIFT_BACKTRACE`.)

14. **(Answered, the re-review questions of 2026-11-22)**
   - *Is `HostImages.macServerRefusal`'s set of the account's locks complete?* It names the app's
     `~/.vibeswitcher/host.lock` and the node root's, from the user database's home, and refuses the user's host by
     `ownsLaunchers`, which compares with `VibePaths.hostLock`: the environment's root. So a root moved by
     `VIBESWITCHER_HOME` (a session's `launchctl setenv` before the app's next launch) is covered both ways: a host
     started with it takes its lock for the user's (`ownsLaunchers`) and is refused; a host started without it on that
     root's lock (`--lock /moved/host.lock`) is a scratch host, allowed, but it opens no vault from disk (only
     `ownsLaunchers` hosts read `lead/vault.sealed` with the Keychain key: its vault is in memory, empty). What remains
     is the app on the moved root connecting to that scratch host's socket and taking it for its own: the listed "The
     app trusts any host at the socket's path" below, not a server child's `.app`. Nothing to add to the set.
   - *Is the process-wide `LeadVaultV2.recordsOnThisHost` acceptable?* For `vibeswitcher-host` yes: one `HostServer` to a
     process. But it is one-way (never cleared) and the test bundles run many hosts in one process, so a test that made
     a Mac node host would leave it on for the rest. Nothing sets it today (`isCheckedMacNode` is false). When the
     checked node start lands (item 13), move it into the vault (`LeadVault.Book`, set by the host that owns it) and
     pass the book's own `on:` from the `.seal` and `.verify` hooks in `LeadVault.swift` (a one-line hook each).
     **Done 2026-11-25 (`v2-mac-checked-start`):** `LeadVault.Book.recordsActions` (Linux: every book; the Mac: set by
     the checked node host that owns it), passed by the `.seal` and `.verify` hooks and `VaultV2Handler`; the
     process-wide `recordsOnThisHost` is gone (`LeadVaultV2Tests/theRecordIsTheBooksNotTheProcesss`, red on the seam
     `056bd608`, green from `b0a2aa98`).
15. **(Row 9 of the measurement record's "What stands between this Mac and `vibeswitcher start`": step 5, the
   LaunchAgent; built 2026-11-26, `v2-mac-agent`, on `v2-mac-checked-start` with `v2-mac-web-port` joined; off: `start`
   for the user's node is still refused by `NodeSystem.macUnbuilt`; needs a review)**, as the node on the Mac's design's
   "The LaunchAgent: start, stop and status" says. *Built:* the plist as data (`NodeAgent.Job`, `Place`: label, plist
   folder, data root and lock injectable; `ProgramArguments` exactly a checked node's command line, `SWIFT_BACKTRACE` its
   only variable, `KeepAlive` false); `MacAgent`'s `start` (the build by the command line's own code in the record, its
   host and server files by cdhash; a plist on disk that isn't start's refused before any load and left alone; a job of
   the label running another program refused and left alone, one loaded and not running unloaded; `bootstrap` and
   `kickstart` in `gui/<uid>`; the host waited for on its socket and known by the connection's audit token, its pid
   launchd's, its running code the pinned host, hardened, then its welcome and its command line the job's; everything
   it loaded booted out on any refusal; since the review's round, a running job of the label is the node's only when loaded from the agent's own plist with launchd's word and its executable the job's), `stop` (the host checked, what ends said with
   the server's session count and the typed code asked, the server's stop, the host's children
   taken, `bootout`, then no job, no process of them and no socket within 30 s, else named) and `status` (from the host
   itself, its build the record's row its code is); the command line's Mac arm behind `usersNodeRefusal`
   (`MacAgentCommand`); a checked node's sessions given back launchd's `SSH_AUTH_SOCK` (a socket the user owns), the
   text encoding and the umask 022 on their spawn alone (`CheckedSessions`, the launcher's `--pty-umask`), the login
   shell building `PATH`, and its Swift children `SWIFT_BACKTRACE=enable=no`. *Measured first, on this Mac:* a
   scratch-path job's bootstrap and bootout put no Background Task Management item or notification in the unified log
   (a plist in `~/Library/LaunchAgents` not tried); `launchctl print`'s `state`, `runs`, `last exit code` and `last
   terminating signal`; `bootout` (and a killed job process) ends the job's process group and nothing outside it (a
   session-leader child runs on): AG-1's question, answered from an agent's session with a scratch job. *A real Mac
   proved* (`MacAgentTests`, `MacCheckedSessionsTests`, `MacSwitchedHostTokenTests`; which were red on the seams
   `01d34331` and which weren't, the design's "What a real Mac proved" says): start, status and stop of a scratch job leaving nothing; a changed plist and another program refused and
   left alone; the host by token and code and a look-alike with the host's path refused; a killed host not started
   again by launchd; a session's environment from the login shell and launchd, not the starter; a switched host's new
   connections' token running the new image. *Not reached while `macUnbuilt` and `isCheckedMacNode` are off:* a real
   `--node` job (the plist's checked command line is tested as data), the command line's Mac arm, the server's stop
   inside `stop`, a launchd job's own sessions, `--at-login`. *What the switch-on review can rely on:* the job's host is
   known by token and code, never by launchctl's text; nothing `start` loaded outlives a refusal; `stop` waits for the
   host and its children and says what it couldn't end; a crash is never restarted by launchd. *What the installer
   (step 7) can rely on:* `vibeswitcher agent-plist` prints exactly what `start` writes and checks (the same
   `NodeAgent.Job.node`), so an installed plist passes `start`'s check for that build, and any other is refused with the
   key that differs; the plist no longer holds `HOME` or `PATH`. *Owed:* a switch (or `start`) rewriting the plist for
   the build it goes to; the design's "What it doesn't cover" for step 5.
   *The review's round (2026-11-26, "ready with fixes"; `5dfbde9b` red, `ed1a053b` and `abab3abd` green):* I1, a
   plist swapped between start's read-back and launchd's read (`KeepAlive`, an extra variable, a file or its folder
   swapped away and back) is refused and unloaded: start holds the file it checked (inode, ctime, size, bytes) and its
   folder, and reads launchd's own word for the job (`path` by inode, `arguments`, the `environment` block, the output
   paths, `properties`). I2, a running job of the label loaded from another plist, or from other bytes at the agent's
   own path, or running a byte copy of the pinned host elsewhere, is refused by start, status and stop and left alone.
   N1, stop asks once by the server's rule and a refusal stops nothing; N2, it waits for the host's descendants and the
   sessions they lead; N3, the stale socket goes after a crash too; N4, the plist folder and the plist must be the
   user's and writable by no one else; N5, `status --json` checks the host; the test shape's lock by file. *What can't
   be bound:* an ancestor of the plist folder swapped and back with a key launchd's `print` doesn't show; a process that
   left its session and lost its parent before stop's look. *For the installer (step 7):* it must write exactly the
   plist `start` writes (`vibeswitcher agent-plist`, the same `NodeAgent.Job.node`), `0644`, in a `~/Library/LaunchAgents`
   of the user's that no one else can write; a plist an earlier install wrote (with `HOME` and `PATH`) is refused by
   `start`, which says to remove it and start again, so the installer's upgrade must replace it. *Owed:* a switch must
   rewrite the plist for the build it goes to (until then, the next `start` after a switch refuses the old build's).
   *The re-check's round (2026-11-26, "not yet"; `a290cb47` red, `5fe57dda` green):* launchd's `print` is read by one
   ordered grammar of macOS 27.2's format derived from the job start wrote (every line placed, nothing searched for, its
   path by `lstat` against the file start holds); the job is written in printable ASCII only; a newer macOS that prints
   otherwise refuses until someone looks (the canary `thisMacsLaunchdPrintsTheJobAsTheGrammarSays`). Notes: the keys
   `print` shows nothing of corrected (six then, seven with `JetsamProperties` since the final re-check); ACLs refused; a link at the lock refused and `HostServer` opens
   `--lock` with `O_NOFOLLOW` (the app's host too: shared code); only no listener is no server for `stop`; a failed
   bootout said as failed; session ids read at every look. What start still can't bind is the design's table. *Owed for
   a later step:* a host-side record of its sessions' ids, so `stop` can find an orphan whose session leader ended before
   its first look. *The final re-check (2026-11-26, "ready to offer for v2"):* the spec corrected to what it measured
   (the output-path stand-in is never spawned; a job found loaded binds the plist's bytes on disk, not only through a
   swap; the seven keys `print` shows nothing of, `JetsamProperties` among them, with their other values); and a
   `launchctl bootstrap` that didn't finish (no answer within its limit, or ended by a signal) is judged and start's own
   job booted out (`e7cd6467` red, `6f04d1e2` green).
   *A switch rewrites the plist (2026-11-26, `v2-mac-anchored-cli`; rows 7 and 10; item 12 above):* closed. After a
   switch the plist names the build the host runs, written by `start`'s code under its checks; a switch whose follow-up
   didn't run is refused by `status` (and the next `start` of the new build refuses the old plist, as before) with
   `vibeswitcher switch <build>` to finish it, while `stop` and the server check still take the node. *What can't be
   bound,* added to the design's table: the loaded job's keys `print` shows nothing of after a rewrite; the scratch
   test's `--handover` pair; a plist a process of the user's removes or renames over afterwards (it can make every
   command refuse the node, `stop` included, never pass). *For the installer (step 7):* an upgrade that switches the running node needn't write the plist: `vibeswitcher switch`
   rewrites it. *Owed:* a real `--node` job's switch, the command line's Mac arm end to end, the plist's row in the seal's
   Mac list (step 8: built since, item 16).
16. **(Row 13 of the measurement record's "What stands between this Mac and `vibeswitcher start`": step 8, the Mac seal
   list; built 2026-11-26, `v2-mac-seal-list`, on `v2-mac-anchored-cli`; off: only a checked Mac node host's book
   watches it, and `isCheckedMacNode` is false; needs a review)**, as the node on the Mac's design's "Built:
   `MacSealList`" says. *Built:* `MacSealList`, the rows as data in `LinuxSealList`'s shape (the LaunchAgents folder,
   the node's plist, Terminal's preferences, what the zsh files source, Homebrew's `bin` and `sbin`, the Xcode link, nvm,
   `~/bin`, `~/.local/bin`, Claude Code's versions, the shell snapshots), appended by `ConfigSeal.homeWatched(home:macList:)`
   only for a book with `watchesMacList` (set beside `recordsActions` by a checked node host) and held until accepted by
   the vault's own look and accept, Linux's path; the lead-approved `.preferences` kind (Terminal's keys but the measured
   churn: `LastTerminalStartTime`, `NSWindow Frame …`). *Measured first, on this Mac:* each row's owner, mode, parents,
   links and ACLs, and what writes it in use (the design's table). *Proven on scratch roots* (`MacSealListTests`,
   `MacSealVaultTests`, red on the seam, green with the rows): every row detects each change its kind reads (contents, a
   file renamed over, a link in its place; for folders a rewrite kept to size and mtime, an entry replaced, a link, a mode,
   an ACL); a change held, accepted, then the next held again; an accept seals only what its card showed; Terminal's start
   and window moves and a session's snapshot hold nothing; a row removed or unreadable is held; a book that isn't a
   checked node host's watches nothing of it, and the app's seal is today's. *What the switch-on review can rely on:* a
   change to any row holds the team until accepted, on the node's book alone. *Can't be sealed:* launchctl's user
   environment (memory, not a file; the node takes one name of it at its host's start, checked), what Homebrew's links
   point at, the user's own PATH folders, cfprefsd's cache before its write, a row's owner (not the user's to change).
   *Owed:* the node root's own folders (Linux's quiet rules key on Linux's names; the builds folder's row turns on the
   switch's refusals), `appWrite` around `start`'s and a switch's plist writes (until then each is a held change), a real
   checked node host, the Linux run of `theListIsEmptyOnLinux`.

## What `v2` found on the Mac and doesn't change

Found by [the security architecture document](../superpowers/specs/2026-11-13-v2-security-architecture.md#the-mac-and-linux)
and its [attack review](reviews/v2-security-review-2026-11-13.md), fixed on Linux, and left as they are on the Mac
(no behaviour change there on `v2`). Each is for main once a real Mac can check it.

- **The app trusts any host at the socket's path** (`HostConnection.answer`, `HostServer.enroll`): the app talks to
  whatever listens at `~/.vibeswitcher/host.sock`, shows the sessions it reports and sends it what the user types, and
  a host that answers with a keyless challenge is sent the app's key (`enrollApp`). So a same-user process that puts
  its own socket at the path while the host is down or restarting is the app's host, and holds the app's key. The key
  alone doesn't make that process the app to the real host, which also requires the app's code (`runsAppCode`). On
  Linux the app is the connections the host makes through its server child's connector, and no key is sent (S2).
  Check on a real Mac: with a scratch host stopped and a test's own listener at its path sending a keyless challenge,
  that the app sends `enrollApp` to it (expected today); then whether the app should check the host it connects to
  (the pid it launched, or the peer's code signature) before it shows anything or sends its key, and port that to main.
- **`BranchCode.runPrefix` doesn't put a verifier's commands in a POSIX session of their own**
  (`Worktrees.swift`, `runPrefix`: it execs the wrapper, no `setsid`). A command run under it that double-forks without
  `setsid` leaves the wrapper's ancestry but keeps the verifier's controlling terminal, and the host's terminal
  fallback (`HostServer.session(of:)`) then names it the verifier's. On Linux the branch's code runs as a new child in
  a session of its own, waited for (`BranchCodeSession`, `Platform.Tools.branchCodeGetsOwnSession`; S4). Check on a
  real Mac: whether a verifier's Bash commands under Claude Code have a controlling terminal at all (`tty`, `ps -o
  tty`); if they do, that `VerifierBranchCodeHostTests.anEscapedVerifierCommandWithoutSetsidIsNobodys`' scenario is
  the verifier's there, and whether to port `BranchCodeSession` to main.
- **The Mac's user's host honours `--handover-test-secret`**, and which host is the user's (stage 2 Task 9a):
  unchanged on the Mac, and wrong there as the security document found it on Linux. `ownsLaunchers` is still
  `lockPath == VibePaths.hostLock.path` (`vibeswitcher-host/main.swift`), a comparison of strings, so `--lock ~/.vibeswitcher//host.lock`, a `..` or a symlink
  to the user's lock takes the user's lock and yet makes a host that honours every test-only flag; and any host, the
  user's included, takes `--handover-test-secret` and carries it across a handover (`config.arguments`), the secret
  becoming the next image's vault. On Linux both are decided by `HostHardening` (the lock by its device and inode, a
  link refused; the flags a scratch host's only, and not carried). Check on a real Mac whether to port both to main.
  The plan's Mac test `HostHardeningTests.theMacsUsersHostKeepsTodaysTestSecret` was to start the user's host by
  `TestHosts.authorize`; as built it checks only the Mac's forms of `HostHardening`'s decisions (strings compared, every
  flag taken and carried, nothing hardened, no lock checked), because a user's host on the Mac reads its vault's key
  from the real Keychain (`VaultStorage.keychainKey()`), which `KeychainLintTests` forbids a test
  (`ServerChildHost(usersHost:)` throws there). A scratch host's test secret across a handover on the Mac stays
  `HostHandoverTests.secretsReachTheNewBuildAndNeverTheStateFile`'s. A process test of the Mac's user's host needs a
  Keychain stand-in first.
- **A `.user` seal never expires and is never retired on the Mac** (the security document's T41 and S11 item 29):
  delivery records (`<tty>.delivered`) are outside the seal and the inbox is a file any process of the user's can
  write, so a worker that copies a sealed line of the user's back into the lead's inbox has it delivered as the
  user's, there at any time later. On Linux `LeadVaultV2` (engine E6, EN-D11) limits it: a `.user` seal verifies false
  once the server retired it (it saw the lead take it, a lead start's handover withdrew it, or its line was out of
  the readable inbox at two looks) or 15 minutes after it was made or last renewed, renewed only
  while the line the server posted waits untaken and never two hours past its first making (`renewedLifeCap`); a
  replay still works inside that life (S11 item 29). On the Mac the vault's hooks do nothing (`LeadVaultV2.isOn` is
  `!Platform.CodeIdentity.isAvailable`; the host lists no `vaultV2`), as
  `LeadVaultV2Tests.theMacsVaultHooksDoNothing` pins: a day-old seal named retired verifies true. The candidate for
  main is that record (retire, the life, the renewal and its cap), with the app as the one that retires and renews.
  Check on a real Mac (a scratch host, the sandbox app): an answer the app sends a scratch lead, taken, then its line
  copied back into the inbox an hour later is delivered as the user's (expected today); then whether to port the
  record to main, and that an answer waiting through a long tool call is still the user's once it is.

## Owed on the Mac

Work `v2` leaves undone because it is shared with main (a change to the Mac's behaviour), or because only a Mac runs
it. Each is done once the Mac work begins.

- **`HostServer.watch(owner:)`'s data race, main's too**: main stores `ownerWatch` from the thread that starts the host
  while the watch of an owner already gone reports on the host's `queue`, where `ownerGone` reads it (the thread
  sanitizer's first run on Linux, 2026-11-23: a sanitized host whose owner was gone exited 66). Fixed on `v2` by making
  and storing the watch on `queue` (the port map's non-seam row for `HostServer.swift` `watch(owner:)`); main takes the
  same few lines at the next merge, and a Mac run of `TestHostsTests.aHostWhoseOwnerIsAlreadyGoneExits` under
  `swift test --sanitize=thread` checks it.
- **`TeamRowsTests.anAuditHeldBeforeItsVerifierStartsShowsTheResetInsteadOfWorkerProgress` (app), skipped on the
  runner** (`scripts/ci/macos-runner-skips.txt`): it pins main's Fable for a sensitive audit, and v2's
  `security_audit_model` defaults to mythos ([the port map's](v2-port-map.md) row for `securityAuditModel`), so the
  sensitive row reads "Waits for Mythos" (v2 macos run 44540219244). When main adopts the key, the test needs
  `team.workflow.securityAuditModel = "fable"` in `limitedTeam` (as `FableFallbackTests` sets
  `security_audit_model: fable`) or a Mythos expectation for that row; then it comes off the skip list.
- **Two waits on Foundation's `Process.waitUntilExit()` in VibeCore**: `Shell.run`'s, after a run is stopped or ends
  (`Sources/VibeCore/Worktrees.swift` ~337), and `PassageListener.stop(grace:)`'s (`Sources/VibeCore/PassageLink.swift`
  ~243). On the hosted Mac that wait never returned for a child that had ended and been collected (no zombie left,
  nothing else in the process collecting it), and the run sat at no CPU until vs-heavy's timeout (GitHub run
  43717393732, 2026-11-15; `ProcessesTests.Child`'s note). The tests no longer wait so (`ProcessesTests.Child`,
  VibeNodeTests' `run(_:_:environment:)`, `SpawnedHost`), but these two are product code shared with main. To do: start
  each child by `Platform.Spawn` and collect it by its pid with bounded `waitpid(WNOHANG)` waits, as those do; a change
  on main.
- **The Mac's `LeadController` handover** ([the port map's](v2-port-map.md) E4 row for `LeadController.swift`,
  starting): `LeadController` (1041-1052) still calls `LeadHandover.begin`, which empties whatever inbox the board
  names into the new lead, and reads `transcripts[old.uuidString]` for any session the board names, so a forged board
  hands another project's inbox and conversation to the new lead. The node checks first (`LeadEngine.replacedLead`,
  the security follow-ups' item 11): the session the board names is replaced only when the host lists it labelled as
  a lead, started in this root, on the board's terminal, and live, or ended and the session the vault binds this
  root's lead role to, its terminal taken by no live session since; the replaced lead's last turns are read only from
  a session started in this root; a board naming any other leaves that inbox where it is, its count said. The Mac's
  fix is the same check before `takeWaiting` and the transcript read, in `Sources/VibeSwitcher`, which `v2` doesn't
  edit. Check on a real Mac (a scratch host and scratch projects, the sandbox app): a project's board edited to name
  another project's running lead, with a message waiting in that lead's inbox; starting the first project's lead
  again in the app (replacing it) then empties that inbox into the new lead and puts the other lead's last turns in its first
  prompt (expected today); with the check ported to main, that inbox keeps its message, no turns are read, and a
  board naming this project's own lead on its terminal still hands over as before.
- **The Mac's `LeadController` delivery, wake and flush** ([the port map's](v2-port-map.md) E5 row for
  `LeadController.swift`, delivery): `deliver` (1225) takes the lead `LeadHandover.named(board)` gives and checks only
  that its pid runs an agent on the board's terminal (`leadRuns`, 593); the wake (1339, 1384) and the flush (1432)
  type into the session the board names. Nothing asks the vault who holds the lead role or the host which session runs
  on that terminal, so a `board.json` any session can write, naming a worker's own session or another project's
  running lead, gets this project's answers and reports, and the wakes are typed into it. The node checks first
  (`Delivery.target`: the session the vault binds to the root's lead role, live in the host's list, on the board's
  terminal; the security follow-ups' item 12, EN-D14); the Mac's fix is the same resolution (or at least
  `LeadHandover.current(board, holder:isRunning:)`) in those three paths, in `Sources/VibeSwitcher`, which `v2`
  doesn't edit. Check on a real Mac: a scratch board naming another project's running lead (or a worker's session)
  gets no delivery, wake or flush, and the message stays held.
- **The three Mac-only lints**: `AccessibilityLintTests`, `DebugAidsLintTests` and `ElapsedTimeLintTests` are in
  `Tests/VibeSwitcherTests` (the app's target), which Linux doesn't build, so `v2`'s lint runs on Linux never ran
  them. Run them on the Mac (`bash scripts/test.sh --filter 'AccessibilityLint|DebugAidsLint|ElapsedTimeLint'`) over
  the branch's shared code, and fix what they find there.
- **`LeadLaunch.userSettings`' three `Write(…)` deny rules** (`Write(~/.vibeswitcher/mac-limits.json)`,
  `Write(~/.vibeswitcher/boost.json)`, `Write(~/.vibeswitcher/policy.md)`; `Sources/VibeCore/LeadLaunch.swift` 82-84):
  Claude Code 2.1.325 says each "never matches · use Edit(…)", and its rule check names why (a `Write`, `MultiEdit` or
  `NotebookEdit` rule with a path "is not matched by file permission checks — only Edit(path) rules are … Edit rules
  cover all file-editing tools", read from the 2.1.325 binary's own validator). Each has its `Edit(…)` twin, so nothing
  is open; they are only redundant. Linux's five (`Platform.Tools.roleDenyRules`) are dropped on `v2`; these three are
  every role's on the Mac too (shared, a behaviour change there by the letter), so they go on main, with
  `LeadLaunchTests.noRoleMayWriteTheUsersMacWideSettings`' list. The same holds for the workers' and verifiers'
  `Write(~/.claude/**)` (`claudeHome`) and `Write(<records>/**)` (`deny`'s worker case), which the lead doesn't carry.

- **The app's own writes seal what changed between their reads** (the security document's S11 item 8; the start
  plan's ST-D17, the review of its S6; recorded 2026-11-16). `LeadVault.appWrite` (`Sources/VibeCore/ConfigSeal.swift`)
  fingerprints each watched thing before the write and after it, and the vault seals the chain to what it reads
  itself, so a change another process of the user's makes between those two reads is sealed with the app's write: on
  the Mac, `HookSetup`'s and `HookBinary`'s hook install and update; on the node, `hooks install`'s renames and config
  edits. What closes it: `appWrite` (or a variant) told each item's expected result, recording a line only when one
  read of the item both matches it and gives the fingerprint, and `HookInstaller.edit` refusing bytes that differ from
  the `before` fingerprint. A change to `appWrite`'s and `HookInstaller.edit`'s contracts, shared with main, so main's.
  Check on a real Mac (a scratch home and vault): a hook added to `settings.json` between the app's two reads (a test
  hook in `HookInstaller.replace`'s `beforeRename`, or in `appWrite`) is held at the next look, not sealed.
- **A `.folder` item doesn't see a folder's mode** (the security document's S11 item 8; the lead's call, 2026-11-16).
  `ConfigSeal.readFolder`'s walk hashes a subfolder as `d <path>` with no mode, so a mode changed in place is no change
  (a folder that can't be listed is held; a file's mode is read; Linux's `.entries` and `.listing` items read folder
  modes). Adding `st_mode & 0o7777` to the `d` line, as `LinuxSealList`'s walks do, changes every Mac seal's hash for
  each `.folder` item with a subfolder once, so each user's next look after the update holds them (one accept). A
  main-side change, with that one-time hold said in its release notes; then `v2`'s `.folder` items get it at the merge.

## Also to check

- **`Package.resolved`** pins swift-crypto 3.15.1 and swift-asn1 1.7.4 for the Mac too (`923a43b9`), though only Linux
  links them: the app's build resolves them and still links CryptoKit.
- **The Darwin costs** ([stage 1's R13](../superpowers/plans/2026-11-12-v2-stage-1-core-on-linux.md#r13-after-the-bootstrap-from-this-stage)):
  an own-process read for `ProcessUsage`, `StallWatch`, `SessionStrays` and `TestLock`; one `PROC_PIDTASKALLINFO` for
  `LoadRecorder`; terminal names looked up lazily; no kqueue in `FolderWatch(descriptor:)`. Measure each against
  main's.
- **`runPiped`'s pipes on the Mac aren't close-on-exec** (`PipeCommand+Darwin.swift:8-9`, as on main): its own
  spawn keeps only what it dups (`POSIX_SPAWN_CLOEXEC_DEFAULT`), but a spawn on another thread of the same process
  that doesn't use that flag inherits them while a status line runs. Left as it is on `v2` (no behaviour change on
  the Mac; `CloseOnExecLintTests` lists it). Check whether the status-line process spawns anything else meanwhile,
  and mark them close-on-exec on main if it does.
- **Each message's sender (stage 2 Task 7)**: `PeerPerMessageTests/aForkedWriterIsStillCaughtWhenTheHostBroadcasts`
  can't tell `checkPeer`'s re-read at `broadcast` from the check of each read's sender: the host's read source may
  read the child's bytes first, and either makes the connection no one's. Check on a real Mac, by hand, that with the
  host's queue held while a forked child writes on a lead's connection, a broadcast alone makes it `.unknown`. Also
  that the four session-based `PeerPerMessageTests` start their lead at all there: the helper runs through the
  session's `/bin/sh`, which SIP keeps DYLD_ variables from, so the test sets `DYLD_FRAMEWORK_PATH` and
  `DYLD_LIBRARY_PATH` on its command line (the hosted runner, SIP off, doesn't show this).
- **A listener's file mode through its path (stage 2, the host's socket)**: `UnixSocket.listen` on the Mac still binds
  and then chmods the path to 0600 (`Platform.Sockets.bindOwnerOnly`'s Darwin form, the old body), so a link a
  same-user process renames over the path between the two is followed, and the file the link names becomes 0600 (no
  more than that process could do itself), while the socket's file keeps the umask's mode. Linux sets the socket's
  mode before the bind (`fchmod`), which the Mac's `bind` may not honour: check on a real Mac, and
  `fchmodat(…, AT_SYMLINK_NOFOLLOW)` there otherwise.
- **`Platform.Processes.ignoredSignals` on the Mac (`779a8ac0`, unproven)**: new Darwin code, not an old body moved,
  written on Linux and never run on a Mac: it reads `kp_proc.p_sigignore` from `sysctl` `KERN_PROC_PID`
  (`Processes+Darwin.swift`). Only tests call it: `SessionEnvironmentTests.aSessionsProgramStartsWithSIGPIPEAtItsDefault`
  (which read the masks with `ps -o sigignore=`, a keyword Apple's `ps` doesn't have) and
  `ProcessesTests.theSignalsAChildIgnoresAreRead`. Its "Checked" note (`trap '' PIPE` makes the first fail) was made on
  Linux only. The Mac CI failure it fixes doesn't count as fixed until both tests pass on the hosted Mac. Check there
  too that a child that ignores SIGPIPE shows the bit in `p_sigignore`, and one that doesn't shows it clear.
- **The two replaced oracles**: the raw Darwin reads `IndexLockTests` and `ProcessTableTests` checked against, now
  platform calls; restore them under `#if canImport(Darwin)`.
- **The merge of main of 2026-11-17 (`4030c8af` and its four follow-ups), made and tested on Linux only**: nothing of
  it has been built or run on a Mac. To check on the hosted Mac at the first push, and by hand where said:
  - `83e7b934`: the Mac's code moved, not rewritten, but never compiled since. `Platform.Host.bootTime()`
    (`Host+Darwin.swift`, `RestartReopen.bootTime()`'s old body: `RestartOfferTests`, `RestartReopenTests`);
    `PromptAudit.isOn` and `intervalDays` on `any SettingsStore`, with `SettingsStore.integer(forKey:)` now a
    requirement `UserDefaults` meets by its own method (`PromptAuditReminderTests`, `Preferences`);
    `Sources/VibeCore/MacOnly/ImageDiff.swift` (`ImageDiffTests`), and by hand `scripts/ui-journeys.sh run smoke`:
    the script compiles the file by its new path, alone, with its `#if canImport(Darwin)` around it.
  - `329840cd`: `RoleModelsTests.theLeadsAPlainTasksAndAHardTasksCommandLinesArePinned` pins `--permission-mode auto`
    before `--name` (main's pin had none, and `v2` names the mode on the Mac too); `LeadLaunchTests.
    theMacsDenyRulesAreTodays`' four hashes were recorded from the Linux run with Linux's rules taken off the end.
    Any test of the app's own (`Tests/VibeSwitcherTests`, new on main) that pins a role's whole command line without
    the mode would fail the same way: none was found by reading (`LeadStartsHostTests`' reopen checks a suffix).
  - `648d7bb1`: `vs-heavy`'s `give_width` reads the Mac's load in an `else` arm now; its words are the same.
  - The ten conflicts' resolutions (the port map's [Merges](v2-port-map.md#the-merge-of-2026-11-17)): the Mac's side
    is main's text in each, with `v2`'s hook lines beside it.
- **The merge of main of 2026-11-19 (`66cf61ea` and its follow-ups), made and tested on Linux only**: to check on the
  hosted Mac at the first push:
  - `2a161663`, `891d3c47`: main's Mac code moved into `VibePlatform`, never compiled there since:
    `Platform.killAll(group:)` after `PipeCommand+Darwin.swift`'s loop (`StatusLineBinaryTests`), and
    `ExitWait+Darwin.swift`, main's `Shell.ExitWatch` kqueue (`ExitWaitTests`, `WorktreesTests`, any test running git).
  - `3eae240b`: `ConfigSeal.walkCode` reads an entry's name as a C string, not by `d_namlen`, and `linkDigest`
    through a `CChar` buffer (`ConfigSealModuleTests`).
  - `3ff4742e`, `016aa6f1`: `TestSupport.swift`'s Mac-only SIGPIPE catch and `EPipeProbe` are main's text inside
    `#if canImport(Darwin)` (`BrokenPipeProbeTests`, `BrokenPipeTests`); `StatusLineBinaryTests.left(in:)` lists a
    group through `Platform.Processes`, not `proc_listpids`; `HostedSessionTests`' late-reading shell test waits by
    `Platform.Processes.brief` (a zombie), not `waitid`; `ParserIsolationTests` prints
    `Platform.Clock.awakeClockName` (`CLOCK_UPTIME_RAW` there, as main's).

## The runner's skips

[`scripts/ci/macos-runner-skips.txt`](../../scripts/ci/macos-runner-skips.txt) as of `939ce080`: 10 entries, from 18
at `47636aaf` (`aa9eee06` removed the three `SignalsTests`, `939ce080` three `BoostTests` and two `LeadToolsetTests`).

| Skip | Cause |
| --- | --- |
| `BoostMarkTests/theMarkFollowsBoostOnAndOff` (app) | Found: expects the boosted limits of a Mac with more cores than the runner's. The fix is `939ce080`'s pattern |
| `BoostWatchTests/automaticFollowsPowerAndPresenceWithinOneHeartbeat` (app) | Found: the same |
| `ClaudeDictationTests` (app, the whole suite) | **Not found**: different tests time out on each run (12 of 58, then 3 others) |
| `EndingASessionTests/endingASessionEndsWhatItStartedOnly` (host) | Inferred, not seen: SIP off shows another process's environment, as seen in `SessionStraysTests` |
| `LeadRemoteTests/automaticFetchAsksTheVaultNothingBeforeItsNextFetchIsDue` (core) | **Not found**: the vault is asked once more than expected (16, not 15), in both runs |
| `LoadReportScriptTests/itPrintsTheProfileAndFreezesPerLoadBucketForTheDays` (core) | Found: the runner's `python3` refuses a date ending in Z (`fromisoformat`) |
| `MCPHandoverTests/anUnsignedBuildLeavesTheOldOneServing` (core) | Found: SIP off runs an unsigned build's probe, which a Mac kills |
| `SessionStraysTests/aProcessWhoseEnvironmentIsHiddenIsTheSessionsOnlyWhenItStartedIt` (core) | Found: SIP off shows another process's environment |
| `TestScriptWidthTests/aRunsSwiftTestGetsTheCoresFreeAtLeastItsSlotsShare` (core) | Found: expects a heavy slot's width on a Mac with more cores than the runner's |
| `Tests/SecurityAudit/library-injection.test.mjs` (web) | Found: SIP off lets an injected library into a Hardened Runtime binary |

On a real Mac every entry is run: the two not found are owed an answer, and a found one that fails there isn't the
runner's.

## Main's known flakes on the runner

Failures of main's own tests, in code `v2` leaves as main has it, seen on the hosted Mac. They aren't skipped: each is
re-run, and fixed on main.

- **`BrokenPipeProbeTests/aChildRunsSIGPIPENamesItsWriterAndTheFlakeLogKeepsIt` (core)**: the probe's child found "no
  thread of 5 in a write or a send" in its SIGPIPE snapshot, every block (run 45072995987, `e14045a0`); the next run
  (`5625a3f4`) passed it. The handler ran on the main thread, in its run loop (`mach_msg2_trap`): the signal for the
  writer's EPIPE was delivered to another thread, and by the time the handler took its snapshot the writer had moved
  on. Nothing signal-related changed between the last pass (`1c1c6f37`) and it. A race in which thread takes the
  signal: the probe's own (main's). Seen again at `cf861df6` (run 45101782742), 2 of 3 runs; fixed in the probe on
  `v2` (2026-11-23, the port map's `EPipeProbe.swift` row): the writer waits in the hook until the snapshot is taken.
- **`ComposerDeliveryTests/pastedImagesAndTheirTextArriveOnce` (app)**: a pasted image goes to the fake unbracketed,
  as its path. Seen twice in about 21 `v2 macos` app jobs, in different cases: run 43451992452 (`1fc49ad7`, "an image
  alone, the Send button": the input was the quoted `.png` path, `0 image(s)`, where `[Image #1] | 1 image(s)` was
  expected) and run 43724075229 (`0e6067e5`, "busy: an image then text, ⌥↩": queued `look at this  '….png'`, the
  message's `\n\n` turned into two spaces, `images` 0, `enters` 1). The cause, from the code: `FakeClaude` turns
  bracketed paste on once, as it starts (`ESC[?2004h`), and begins each redraw with `ESC[2J`; a view attaching is
  replayed only from the last screen wipe (`OutputRing.replay`), and `Harness.start` attaches after the spawn's
  reply. When the fake draws first (a loaded runner), the pane's terminal never sees `?2004h`,
  `TerminalPane.bracketedPaste` is false, and `ComposerText.writes(_, bracketed: false)` types the text as keys,
  newlines as spaces, so the fake never takes a paste. Nothing on that path differs from main (`OutputRing`,
  `ChatTimeline`, `HostInput`, `Sources/VibeSwitcher`, `Tests/VibeSwitcherTests`; `HostedSession` keeps spawn, reply,
  then attach and replay). The fix is main's: `Harness.start` waits for `h.pane.bracketedPaste(h.session.id)`, or
  `FakeClaude.draw()` sends `ESC[?2004h` before each `ESC[2J`. The real app has the same gap when its pane attaches
  to an agent after the agent's first screen; tracking DECSET 2004 in the host and putting it before a replay (as
  `FocusEvents` does for 1004) would close both, and is a decision for main.
- **`ShellDeskTests/declineStartsNothingAndUnansweredExpires` (app)**: seen once, in the app job of run 43864397210
  (attempt 1, on `4c50afbf`): `ShellDeskTests.swift:220`, the count of told texts with "expired after 30 minutes" and
  the ignored card's id wasn't 1, after the clock was moved 30 minutes and the desk refreshed. It passed on the rerun.
  The desk and its test are in `Sources/VibeSwitcher/Shell/ShellDesk.swift` and `Tests/VibeSwitcherTests`, which
  `v2` doesn't edit; the cause isn't found yet (what the desk shares with `VibeCore` wasn't checked against main), and
  the fix is main's.
