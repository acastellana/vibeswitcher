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
- **Which host is the user's, and its test-only flags (stage 2 Task 9a)**: unchanged on the Mac, and wrong there as
  the security document found it on Linux. `ownsLaunchers` is still `lockPath == VibePaths.hostLock.path`
  (`vibeswitcher-host/main.swift`), a comparison of strings, so `--lock ~/.vibeswitcher//host.lock`, a `..` or a symlink
  to the user's lock takes the user's lock and yet makes a host that honours every test-only flag; and any host, the
  user's included, takes `--handover-test-secret` and carries it across a handover (`config.arguments`), the secret
  becoming the next image's vault. On Linux both are decided by `HostHardening` (the lock by its device and inode, a
  link refused; the flags a scratch host's only, and not carried). Check on a real Mac whether to port both to main.
- **The two replaced oracles**: the raw Darwin reads `IndexLockTests` and `ProcessTableTests` checked against, now
  platform calls; restore them under `#if canImport(Darwin)`.

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
| `TestScriptWidthTests/aRunsSwiftTestGetsItsSlotsShare` (core) | Found: expects a heavy slot's width on a Mac with more cores than the runner's |
| `Tests/SecurityAudit/library-injection.test.mjs` (web) | Found: SIP off lets an injected library into a Hardened Runtime binary |

On a real Mac every entry is run: the two not found are owed an answer, and a found one that fails there isn't the
runner's.
