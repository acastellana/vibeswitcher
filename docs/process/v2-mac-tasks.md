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
