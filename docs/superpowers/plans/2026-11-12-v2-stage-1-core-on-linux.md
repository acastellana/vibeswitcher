# VibeSwitcher 2, Stage 1 (The Core on Linux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `VibeCore`, the hook and the tool server build on Ubuntu and pass their tests there through
`scripts/test.sh`, and `vibeswitcher status` shows a real agent session's status, with the Mac build and suite still
green.

**Architecture:** A new module, `VibePlatform`, holds every system call the shared code makes, as static functions
with one implementation per system; it compiles and is tested on Linux from the first task. `VibeCore`'s call sites
are switched to it one service at a time, each a mechanical edit checked by the Mac suite on the hosted runner, until
`VibeCore` compiles on Linux. Then its tests are brought over. Code that only the Mac can have moves, file by file,
into `Sources/VibeCore/MacOnly/`.

**Tech Stack:** Swift 6.4.2 (language mode 5), SwiftPM with `--build-system native`, swift-crypto 3.15.1 on Linux, a
C header shim for Linux, glibc and musl, bash.

**Spec:** `docs/superpowers/specs/2026-11-12-vibeswitcher-2-design.md` (The platform layer; Strict isolation; The
bootstrap; Stage 1). **Signatures and call sites:** `docs/process/v2-stage1-recon.md`, cited below as "recon §n";
where this plan and the recon differ, this plan is right.

## Global Constraints

- All work is on `v2`. Never commit to, push or open a pull request against `main`.
- Nothing under `Sources/VibeSwitcher`, `Tests/VibeSwitcherTests` or `Web/` is edited.
- An edit to a file under `Sources/VibeCore`, `Sources/VibeHost` or an executable's folder is one of: a call
  switched to `VibePlatform`; an import line removed; a whole file moved with `git mv`; a block moved into
  `VibePlatform` or `MacOnly/`. No behaviour changes on the Mac, no renames of existing names, no reformatting.
- Outside `Sources/VibePlatform` and `Sources/VibeCore/MacOnly`, no file in the portable targets has `import Darwin`,
  `import Glibc`, an Apple-only framework import, `#if os(` or `#if canImport(`. `PlatformLint` (Task 1) enforces it.
- Inside `VibePlatform`, libc is imported only as `#if canImport(Darwin) … #elseif canImport(Glibc) … #elseif
  canImport(Musl) … #endif`. Never a bare `import Glibc`.
- Tests run only through `scripts/test.sh` (`AGENTS.md`). Agents install nothing. A fix's test is shown failing
  without the fix.
- Swift on this machine: `. ~/.local/share/swiftly/env.sh` first.
- Nothing is pushed while a `v2 macos` run is in progress that someone is waiting on; both workflows are green before
  the next task's first push.
- New dependencies, pinned exact: `apple/swift-crypto` 3.15.1 (Linux only). No others in this stage.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Decisions this plan makes

Each is the author's call and can be overruled before its task starts.

1. **A module, not a folder.** The design said `Platform/` inside each target. A module of its own compiles and is
   tested on Linux before `VibeCore` does, serves `VibeHost` too, and makes the boundary the compiler's. `VibeCore`
   re-exports it from one file, so call sites need no import.
2. **A C shim on Linux** (`CVibePlatform`, headers only, `_GNU_SOURCE`) for what Swift can't reach through Glibc's
   module: `renameat2`, `statx`, `struct ucred`, `pidfd_open`, `ptsname_r`, `POSIX_SPAWN_SETSID`. Imported only inside
   `VibePlatform`.
3. **A terminal's name has no slash.** Linux's `/dev/pts/3` is named `ttypts3`, so `state/<tty>.json` and the steer
   inbox's name rule hold unchanged (recon §0).
4. **`CryptoKit` is exported once** from `VibeCore` (`CryptoKit` on the Mac, `Crypto` on Linux) and the 18 import
   lines go. If one exported import doesn't serve the whole module, the fallback is a Linux-only target named
   `CryptoKit` that re-exports `Crypto`, with no edits.
5. **Mac-only files move whole** (`git mv` into `MacOnly/`, wrapped in `#if canImport(Darwin)`), so git's rename
   detection keeps carrying main's edits into them.
6. **One binary or several** for a release is not decided here; Task 13 measures what the decision needs.

## Review Focus

1. A process whose record can't be fully read (another user's, a zombie, one that exits mid-read, a name with spaces
   or `)` in it): the table still lists what it can and never crashes or misnames a session (Task 8).
2. A path on a filesystem that lacks what the fast path needs (tmpfs, 9p under `/mnt/c`): exclusive rename and file
   watching fall back or fail with the existing error, never silently succeed (Tasks 6 and 9).
3. A child started with more descriptors open than it should see: after `Spawn.start()` with `keep: []`, the child
   has only 0, 1 and 2, on glibc and on musl (Task 7).
4. A wall clock stepped while processes run (WSL after the host sleeps): two reads of one process's start time are
   equal within a process, and "is this the process I recorded" tolerates the step (Task 8).
5. A write to a socket or pipe whose reader has gone: the process gets an error, not SIGPIPE's death, in the test
   bundle and in each executable (Tasks 6 and 12).

---

### Task 1: The module, the manifest on Linux, the lint

**Files:**
- Create: `Sources/VibePlatform/Platform.swift`, `Sources/VibePlatform/Libc.swift`
- Create: `Sources/CVibePlatform/include/CVibePlatform.h`, `Sources/CVibePlatform/shim.c`
- Create: `Sources/VibeCore/PlatformExport.swift`
- Create: `Tests/VibePlatformTests/TestSupport.swift`, `PlatformLintTests.swift`, `PlatformLintPending.txt`
- Modify: `Package.swift`

**Interfaces:**
- Produces: `public enum Platform {}`; `Platform.Errno` (`struct Errno: Error, Equatable { public var code: Int32 }`);
  the manifest's `portableTargets` list, which later tasks add `VibeCore` and the others to.
- Produces: `PlatformLintPending.txt`, one path a line, the files still breaking the lint's rule. Every later task
  removes the files it cleans.

- [ ] **Step 1: The manifest.** `Package.swift` keeps today's targets on macOS and adds `VibePlatform` (depended on by
  `VibeCore`) and `VibePlatformTests`. Under `#if os(Linux)` the package's targets are only the portable ones that
  compile so far: `CVibePlatform`, `VibePlatform`, `VibePlatformTests`; swift-crypto is a dependency there. The list
  is one array, `portableTargets`, with a comment saying which task adds what.

- [ ] **Step 2: The lint, failing first.** `PlatformLintTests.noSystemCodeOutsideThePlatform`: for every `.swift`
  under `Sources/VibeCore` (not `MacOnly/`), `Sources/VibeHost`, `Sources/vibeswitcher-host`, `-hook`, `-mcp`, a line
  matching `^\s*(@_exported\s+)?import\s+(Darwin|Glibc|Musl|CryptoKit|Security|Network|CoreGraphics|ImageIO|UniformTypeIdentifiers|AppKit|SwiftUI|Combine|IOKit)\b`
  or `^\s*#(if|elseif)\s+.*\b(os|canImport)\(` is a violation unless the file is in `PlatformLintPending.txt`
  (`PlatformExport.swift` is exempt for its one exported import). Second test,
  `thePendingListHoldsOnlyFilesThatStillBreakTheRule`: a listed file with no violation fails, naming it. Generate the
  list from the tree as it is. Run on Linux: `bash scripts/test.sh --filter PlatformLintTests` is not possible yet
  (Task 2), so this once: `VIBESWITCHER_HOME=$(mktemp -d) swift test --build-system native --filter PlatformLintTests`.
  Expected: both pass; delete a line from the list and the first fails naming that file.

- [ ] **Step 3: The shim and `Libc.swift`.** The header declares, under `#define _GNU_SOURCE`, what Decision 2 lists
  and nothing else. `Libc.swift` is the one place with the three-way libc import, `@_exported` inside the module only.

- [ ] **Step 4: The test target's home guard.** `Tests/VibePlatformTests/TestSupport.swift` carries the same
  `refuseTheAccountRoot` guard as `Tests/VibeCoreTests/TestSupport.swift`, with the section name chosen by system:
  `__DATA,__mod_init_func` on the Mac, `.init_array` on Linux, and on Linux it also ignores SIGPIPE. Test
  `TestHomeGuardTests.theGuardRan` asserts `homeGuardRan == true`. Shown failing: with the Mach-O name on Linux the
  test fails.

- [ ] **Step 5: `PlatformExport.swift`** in `VibeCore`: `@_exported import VibePlatform`.

- [ ] **Step 6: Both systems.** Linux: `swift build --build-system native` and the two test classes pass. Push; `v2
  macos` builds and its suite is as green as before; `v2 linux` gains a step `swift build --build-system native
  --force-resolved-versions` in place of the SwiftTerm-only build.

- [ ] **Step 7: Commit** ("v2: VibePlatform, the Linux manifest, PlatformLint").

---

### Task 2: The scripts on Linux

**Files:**
- Modify: `scripts/lib/processes.sh`, `scripts/test.sh`, `Resources/bin/vs-heavy`
- Test: `Tests/VibePlatformTests/TestScriptLinuxTests.swift`

**Interfaces:**
- Produces: `bash scripts/test.sh [swift test options]` works on Linux: scratch home, build, tests, web tests,
  leftover check. Every later task's test commands use it.

- [ ] **Step 1: Failing tests** (Linux only, skipped on the Mac with `.enabled(if:)`):
  `theLeftoverCheckFindsAProcessOfTheRun` starts `sleep 300` with a mark in its environment, runs `scripts/test.sh
  --leftovers MARK`, expects exit 1, the process named and ended; `vsHeavyRunsACommandInASlot` runs
  `Resources/bin/vs-heavy --as test true` with a scratch `TMPDIR`, expects exit 0 inside 10 s;
  `vsHeavyGivesItsShareOfTheCores` runs `vs-heavy bash -c 'echo $VS_HEAVY_CORES'`, expects a whole number from 1 to
  the machine's cores.

- [ ] **Step 2: `processes()`** on Linux: `ps axwwe -o pid=,ppid=,stat=,command=` (procps), the same four columns.
  The libproc fallback stays the Mac's.

- [ ] **Step 3: `vs-heavy`**, each Mac command given a Linux form chosen by `uname`: cores from `nproc`; the load from
  `/proc/loadavg`; the two `ps` reads with procps' columns (`lstart` has the same format in procps; `etime` too); the
  lock folder under `/tmp` where there is no `/private/tmp`. Nothing else in it changes.

- [ ] **Step 4: `scripts/test.sh`** on Linux: `real_preferences` is empty and both preference checks are skipped with
  one line saying so; `CFFIXED_USER_HOME` is still exported; the security audit's tests are skipped until Task 12 adds
  the host ("no host on Linux yet"), the web tests run.

- [ ] **Step 5: Run.** `bash scripts/test.sh` on Linux: `VibePlatformTests` pass, `web tests: 7 of 7 passed`, the
  leftover check runs (no "skipped" line). `v2 linux` runs `bash scripts/test.sh` in place of its web-only step. The
  Mac run is unchanged: `scripts/test.sh`'s Mac path differs by no line that runs there (review the diff for it).

- [ ] **Step 6: Commit** ("v2: scripts/test.sh, vs-heavy and the leftover check on Linux").

---

### Task 3: Libc names, imports, crypto

**Files:**
- Create: `Sources/VibePlatform/Sys.swift`; Test: `Tests/VibePlatformTests/SysTests.swift`
- Modify: the 13 files with `Darwin.`-qualified calls, the 21 with `import Darwin`, the 18 with `import CryptoKit`
  (lists: recon §0 and §1.1); `Sources/VibeCore/PlatformExport.swift`; `Package.swift` (crypto for `VibeCore` on Linux)

**Interfaces:**
- Produces: `public enum Sys` exactly as recon §1.1 (`read`, `write`, `close`, `pipe`, `kill`, `open`, `connect`,
  `listen`, `truncate`).

- [ ] **Step 1: Failing test** `SysTests.aPipeCarriesBytesAndClosesTwice`: `Sys.pipe`, `Sys.write` 3 bytes,
  `Sys.read` returns the same 3, `Sys.close` returns 0 and then −1.
- [ ] **Step 2: Implement `Sys`**, each a one-line forward to libc.
- [ ] **Step 3: Switch the 51 call sites** (`Darwin.x(` to `Sys.x(`), delete the 21 `import Darwin` lines, add the
  exported crypto import to `PlatformExport.swift` and delete the 18 `import CryptoKit` lines. If Decision 4's first
  form doesn't compile on the Mac runner, use its fallback and restore the 18 lines.
- [ ] **Step 4: Measure.** `scripts/ci/linux-core-errors.sh` (create it: builds `VibeCore` on Linux with
  `VIBE_LINUX_ALL=1`, which the manifest reads to include every portable target, with
  `-Xswiftc -continue-building-after-errors`; prints the error count and the count per file). Expected: no "no such
  module" and no "cannot find 'Darwin'" left. Record the count in the commit message.
- [ ] **Step 5: Lint list.** Remove from `PlatformLintPending.txt` every file this cleaned; the lint passes.
- [ ] **Step 6: Push; both workflows green; commit** ("v2: libc through Sys, one crypto import").

---

### Task 4: `stat` fields and the small ones

**Files:**
- Create: `Sources/VibePlatform/Stat.swift`, `Small.swift`, `Signals.swift`; Test: `StatTests.swift`, `SmallTests.swift`
- Modify: the 12 files of recon §1.6; `CodexUsage.swift`, `SetupStats.swift`, `ActivityFeed.swift`, `WebPush.swift`,
  `Redaction.swift`, `MCPLog.swift` (recon §1.10, §1.11)

**Interfaces:**
- Produces: `Platform.Files.modified(_:)`, `changed(_:)` (a `stat`'s `timespec`s), `inode(_:)`, `byteSize(_:)`. Not an
  `extension stat`: on Linux each C module reads glibc's headers into itself, a file can meet CoreFoundation's copy of
  `stat` first, and an extension recorded under Glibc's copy is then not found (found when the call sites were switched);
  `Platform.Files.birthTime(_:) -> Double?`; `Platform.isBoolean(_:)`; `Platform.plainInline(_:)`;
  `Platform.Signals.onFatal(_:_:)`, `onUncaughtException(_:)`.

- [ ] **Step 1: Failing tests.** `StatTests.modifiedFollowsAWrite` (write a file, `stat`, `modified.tv_sec` within 2 s
  of now; `byteSize` equals the bytes written; two files have different `inode`). `birthTimeIsNilOrNotLaterThanNow`.
  `SmallTests.aJSONTrueIsABooleanAndAOneIsNot` (through `JSONSerialization`, on both systems).
  `plainInlineDropsEmphasisAndLinks`: `"**a** [b](http://x) `c`"` gives `"a b c"`.
- [ ] **Step 2: Implement.** On Linux `birthTime` uses `statx` through the shim and returns nil where the filesystem
  doesn't record it. `plainInline` on the Mac is the existing `AttributedString(markdown:)` call moved; on Linux a
  small stripper for emphasis, code spans and links, returning nil for anything it doesn't recognise as inline.
- [ ] **Step 3: Switch the call sites**, including the three the compiler hid (recon §0): `ConfigSeal.swift:771`,
  `TestLock.swift:433`, `DiskSpace.swift:303`. `WebPush`'s random bytes become `SystemRandomNumberGenerator` on both.
- [ ] **Step 4: Measure, lint list, push, both green, commit** ("v2: stat fields, signals and the small ones").

---

### Task 5: Clocks and the host

**Files:**
- Create: `Sources/VibePlatform/Clock.swift`, `Host.swift`; Test: `ClockTests.swift`, `HostTests.swift`
- Modify: `MacTime.swift`, `LoadRecorder.swift`, `MacMemory.swift`, `DiskSpace.swift`, `MCPLog.swift`

**Interfaces:**
- Produces: `Platform.Clock.awakeSeconds()`, `threadCPUNanoseconds()`; `Platform.Host.memoryPressureLevel()`,
  `memoryFreePercent()`, `swapUsage()`, `swapOuts()`, `volumeFree(at:)`, `descriptorLimit()` (recon §1.4, §1.5).

- [ ] **Step 1: Failing tests.** `awakeSecondsNeverGoesBack` (1,000 reads, non-decreasing, positive).
  `threadCPUGrowsWithWork`. `volumeFreeOfTheScratchFolderIsPositive`. `descriptorLimitIsAtLeast256`.
  `swapUsageIsNilOrUsedNotOverTotal`. `memoryPressureIsNilOrOneTwoOrFour`.
- [ ] **Step 2: Implement.** The Mac's are the existing bodies moved. Linux: `CLOCK_MONOTONIC`,
  `CLOCK_THREAD_CPUTIME_ID`, `/proc/meminfo`, `/proc/vmstat`, `/proc/pressure/memory` (nil where the file is absent,
  as on this machine), `statvfs`, `getrlimit`.
- [ ] **Step 3: Switch the call sites** (recon §1.4, §1.5).
- [ ] **Step 4: Measure, lint list, push, both green, commit** ("v2: clocks and host statistics").

---

### Task 6: Sockets and files

**Files:**
- Create: `Sources/VibePlatform/Sockets.swift`, `Files.swift`; Test: `SocketsTests.swift`, `FilesTests.swift`
- Modify: `UnixSocket.swift`, `AccountUsage.swift`, `MCPKeeper.swift`, `MCPServer.swift`,
  `Sources/vibeswitcher-mcp/main.swift`, `LeadLaunch.swift`, `WalletLocalLink.swift`, `TestLock.swift`,
  `LoadRecorder.swift`, `DiskSpace.swift`

**Interfaces:**
- Produces: `Platform.Sockets` and `Platform.PeerToken` as recon §1.7; `Platform.Files.renameExclusive(in:from:to:)`,
  `createLocked(_:mode:)`, `eventsOnly`, `sharedTemporaryRoot` as recon §1.8.

- [ ] **Step 1: Failing tests.** `SocketsTests`: `aPeersUIDAndPIDAreThisProcesss` (a connected Unix pair);
  `aPathOverTheLimitIsRefused` (104 bytes on the Mac, 108 on Linux, measured from `sun_path`);
  `writingToAClosedPeerReturnsAnErrorNotASignal` (after `noSigPipe`, a write returns −1 with `EPIPE`; the test
  process is still alive to say so). `FilesTests`: `renameExclusiveRefusesAnExistingTarget` (−1, `EEXIST`, the source
  still there), for a file and for a folder; `createLockedIsNeverSeenUnlocked`: 8 threads loop "open the ticket name,
  try `flock` non-blocking" for 2 s while the main thread creates 200 tickets with `createLocked`; no thread ever
  gets the lock on a live ticket. `sharedTemporaryRootExistsAndIsWritable`.
- [ ] **Step 2: Implement.** Linux `createLocked`: create under a name that doesn't start `ticket-`, `flock` it,
  `link` it to the wanted name, unlink the first (recon §1.8). `renameExclusive`: `renameat2(RENAME_NOREPLACE)`; on
  `EINVAL` (a filesystem without it) `link` then `unlink` for a file, and for a folder the existing error.
  `noSigPipe` does nothing on Linux, which has no switch per descriptor: there a process ignores SIGPIPE as a whole.
  The test bundle does (Task 1), the host, hook and keeper already do and the tool server catches it; a second test,
  `everyExecutableSettlesSIGPIPEBeforeItsFirstWrite`, reads each executable's `main.swift` and fails when none of
  `signal(SIGPIPE`, `Platform.Signals` or `MCPLog.install` comes before its first socket or pipe use.
  `peerToken` on Linux: pid, uid and the pid's start ticks read once at accept.
- [ ] **Step 3: Switch the call sites** (recon §1.7, §1.8), the five `/private/tmp` lines included.
- [ ] **Step 4: Measure, lint list, push, both green, commit** ("v2: sockets, peers, exclusive files").

---

### Task 7: Spawning

**Files:**
- Create: `Sources/VibePlatform/Spawn.swift`; Test: `SpawnTests.swift`
- Modify: `AccountUsage.swift`, `MCPKeeper.swift`, `MCPServer.swift` (two sites), `Worktrees.swift`

**Interfaces:**
- Produces: `Platform.Spawn` exactly as recon §1.2 (`Stdio`, `Group`, `SignalDefaults`, `start()`,
  `replaceProcess()`). `VibeHost`'s four sites use it in stage 2.

- [ ] **Step 1: Failing tests**, each run on both systems, the child being `/bin/sh -c` with a short script:
  `aChildSeesOnlyTheDescriptorsItWasGiven` (the parent opens 5 extra descriptors; with `keep: []` the child's
  `ls /proc/self/fd` or `/dev/fd` lists 0, 1, 2 and the listing's own; with `keep: [n]` also `n`);
  `stdoutAndStderrGoWhereTheyWereSent` (pipe, path, `/dev/null`, `sameAsStdin`);
  `ownSessionMakesTheChildItsOwnSessionLeader` (`ps -o sid=` of the child equals its pid);
  `ownGroupMakesItsOwnGroup`; `theDirectoryIsTheChilds` (`pwd`);
  `theEnvironmentIsExactlyTheOneGiven` (`env` prints the two given, sorted);
  `aMissingExecutableIsENOENT`; `signalDefaultsOnlyLeavesTheOthersAsInherited` (the parent ignores SIGUSR1; with
  `.only([SIGTERM])` the child still ignores SIGUSR1, with `.all` it dies of it);
  `replaceProcessKeepsOnlyWhatItWasTold` (a helper mode of the test binary execs `/bin/sh` and reports its
  descriptors).
- [ ] **Step 2: Implement.** The Mac's is the existing calls moved behind the struct. Linux: non-optional attribute
  and action types, `sigfillset`, `POSIX_SPAWN_SETSID` from the shim, `addchdir_np`, and for "nothing else open"
  `posix_spawn_file_actions_addclosefrom_np(3)` where the libc has it, else a close for each entry of `/proc/self/fd`
  not kept. `replaceProcess` on Linux: reset handlers and mask, mark what isn't kept close-on-exec, `execve`, undo
  all of it on failure.
- [ ] **Step 3: Switch the five `VibeCore` sites** per the table in recon §1.2. `AccountUsage.runCommand`'s body waits
  for Task 9.
- [ ] **Step 4: Measure** (the 74 `posix_spawn` errors are gone), **lint list, push, both green, commit** ("v2: one
  spawn for every site").

---

### Task 8: Processes and terminals

**Files:**
- Create: `Sources/VibePlatform/Processes.swift`, `Processes+Darwin.swift`, `Processes+Linux.swift`, `Terminals.swift`
- Test: `Tests/VibePlatformTests/ProcessesTests.swift`, `ProcStatParseTests.swift`
- Modify: `ProcessTable.swift` and the ten other files of recon §1.3

**Interfaces:**
- Produces: `Platform.Processes` (`State`, `Record`, `Read`, `allPids`, `record`, `arguments`, `environment`, `cwd`,
  `executable`, `openFiles`, `openDescriptorCount`, `children`, `cpuSeconds`, `residentBytes`) and
  `Platform.Terminals.name(devicePath:)` as recon §1.3.
- `ProcessTable` keeps every name its tests call (`record`, `info`, `cwd`, `names`, `holdsForeground`,
  `residentBytes`, `readArguments`, `environment`), each now a short map of the platform's answer.

- [ ] **Step 1: Failing tests.** `ProcStatParseTests` (Linux), on fixture lines:
  `aNameWithSpacesAndParenthesesIsParsedFromTheLastParenthesis` (`1234 (a b) c)) S 1 1234 …` gives name `a b) c)`,
  state sleeping, ppid 1); `aZombieIsAZombie`; `startIsBootPlusTicks`. `ProcessesTests` (both systems):
  `thisProcessIsInTheTable`; `itsRecordNamesItsParentAndOwner` (`ppid == getppid()`, `uid == getuid()`);
  `itsArgumentsStartWithItsExecutable`; `aChildsCwdIsWhereItWasStarted` (a `Spawn` with `directory`);
  `aChildsEnvironmentIsReadable`; `aChildIsAmongThisProcesssChildren`;
  `aProcessThatExitedIsGone` (reap it, then `record` is `.gone`);
  `twoReadsOfOneProcesssStartAreEqual`; `cpuSecondsGrowForABusyChild`;
  `openFilesNamesAFileTheChildHolds`. `TerminalsTests`: `/dev/ttys009` is `ttys009`, `/dev/pts/3` is `ttypts3`,
  `/dev/tty` is `tty`.
- [ ] **Step 2: Move the Mac's reads** from `ProcessTable.swift` and `TerminalNames` into `Processes+Darwin.swift`,
  unchanged in body, and make `ProcessTable`'s kept names forward to them. Push here: the Mac suite's
  `ProcessTableTests` and `SessionDetectionTests` green is this step's proof.
- [ ] **Step 3: The Linux reads** from `/proc` (recon §1.3): `btime` read once a process; a `(deleted)` suffix on
  `exe` stripped and reported by a second function, `executableWasReplaced(_:) -> Bool`.
- [ ] **Step 4: Switch the other ten files' blocks** to the one call each.
- [ ] **Step 5: Measure** (the 177 process-inspection errors are gone), **lint list, push, both green, commit** ("v2:
  the process table through the platform").

---

### Task 9: Watching

**Files:**
- Create: `Sources/VibePlatform/FolderWatch.swift`, `PipeCommand.swift`; Test: `FolderWatchTests.swift`,
  `PipeCommandTests.swift`
- Modify: `LeadAdvance.swift`, `WalletLocalLink.swift`, `AccountUsage.swift`

**Interfaces:**
- Produces: `Platform.FolderWatch` (`init?(path:)`, `init?(descriptor:)`, `wait()`, `deliver(on:_:)`, `stop()`,
  `Change`), `Platform.pipeCommand(_:input:patience:stopSignals:) -> Data` as recon §1.9. `ProcessExit` is stage 2's.

- [ ] **Step 1: Failing tests.** `aNewFileInTheFolderIsAnEntriesChange`; `aRenameIntoTheFolderIsOne`;
  `aWriteInsideAnExistingFileIsNotOne` (no change within 300 ms, waited on a semaphore with that timeout);
  `removingTheFolderIsFolderGone`; `stopEndsAWaitInProgress` (`wait()` returns nil);
  `aBurstOfTwentyCreationsIsAtLeastOneChangeAndThenQuiet`. `pipeCommandReturnsWhatTheCommandPrinted` (`cat` with
  input); `aCommandThatIgnoresItsInputAndExitsIsNotAHang`; `aCommandOverItsPatienceIsStoppedAndGivesNothing`.
- [ ] **Step 2: Implement.** The Mac's are the kqueue code and `runCommand`'s body, moved. Linux: inotify with the
  masks in recon §1.9, drained before answering; `init?(path:)` returns nil when `inotify_add_watch` fails (9p),
  which callers already treat as "can't be watched". `pipeCommand` with `poll` on the pipes and the child's exit.
- [ ] **Step 3: Switch the call sites.**
- [ ] **Step 4: Measure, lint list, push, both green, commit** ("v2: folder watching and piped commands").

---

### Task 10: Settings and tools

**Files:**
- Create: `Sources/VibePlatform/Settings.swift`, `Tools.swift`; Test: `SettingsTests.swift`, `ToolsTests.swift`
- Modify: `Pausing.swift`, `LeadMail.swift`, `Sources/vibeswitcher-mcp/main.swift`, `Git.swift`, `LeadRemote.swift`,
  `LaunchPreflight.swift`, `Worktrees.swift`, `TeamSummaries.swift`, `LoginShell.swift`,
  `Sources/vibeswitcher-host/main.swift`

**Interfaces:**
- Produces: `protocol SettingsStore` and `Platform.settings(domain:)` as recon §1.12; `Platform.Tools.git`,
  `branchShell`, `loginShell`, `find(_:path:)`, `missing()` as recon §1.13.

- [ ] **Step 1: Failing tests.** `SettingsTests` (against a store at a scratch path): a string, a bool, a date inside a
  dictionary and a removal each survive a second store opened on the same file; the file's mode is 0600; a write is
  atomic (the file is never seen half-written by a reader looping during 200 writes).
  `ToolsTests`: `gitIsAnAbsolutePathToAnExecutable`; `branchShellStartsAShellThatReadsNoStartupFile` (run it with
  `-c 'echo ok'` under a HOME whose startup files print "polluted": the output is `ok`);
  `findReturnsNilForAToolThatIsNowhere`; `theRunnerCheckAndTheWrapperAgree` (`BranchCode.isRunner` on the argv
  `BranchCode.wrapper` builds is true).
- [ ] **Step 2: Implement.** On the Mac: `UserDefaults` conforms; `git` is `/usr/bin/git`; `branchShell` is
  `["/bin/zsh", "-f"]`: today's values. On Linux: a property list at `VibePaths`' folder `/settings.plist`, written
  whole and renamed into place; `git` the first on PATH, found once; `branchShell` `["/bin/bash", "--noprofile",
  "--norc"]`; `loginShell` `/bin/bash`.
- [ ] **Step 3: Switch the sites** (recon §1.12, §1.13). The Mac-only tool checks (`xcode-select`, `xcrun`, `pkgutil`:
  `ToolchainWatch`, `ToolInstall`, `LaunchPreflight`) answer "not applicable" on Linux through one
  `Platform.Tools.hasDeveloperTools() -> Bool?` (nil on Linux), and their callers skip on nil.
- [ ] **Step 4: Measure, lint list, push, both green, commit** ("v2: the settings store and tools on PATH").

---

### Task 11: What only the Mac has

**Files:**
- Move (`git mv`): `Sources/VibeCore/PreviewProxy.swift` to `Sources/VibeCore/MacOnly/PreviewProxy.swift`
- Create: `Sources/VibeCore/MacOnly/AppProof+Keychain.swift`, `StatusMark+Paths.swift`, `KeptImages+ImageIO.swift`
- Create: `Sources/VibePlatform/Images.swift`; Test: `ImagesTests.swift`
- Modify: `LeadVaultAppProof.swift`, `MenuBarDots.swift`, `LeadImages.swift`, `SessionOrdering.swift`, `Package.swift`

**Interfaces:**
- Produces: `Platform.Images.pixelSize(of:) -> (width: Int, height: Int)?`, `pngThumbnail(of:maxSide:) -> Data?`.
- Produces: `VibeCore` in the Linux manifest's `portableTargets`.

- [ ] **Step 1: Failing tests.** `ImagesTests.pixelSizeReadsPNGJPEGGIFAndWebPHeaders` (four fixtures a few hundred
  bytes each, written by the test); `aTruncatedFileIsNil`; on Linux `pngThumbnail` is nil.
- [ ] **Step 2: Move.** Each `MacOnly` file is wrapped whole in `#if canImport(Darwin)`. The Keychain types,
  `StatusMark.body(in:)` and `glyph(in:)`, and the ImageIO thumbnail leave their files as blocks and nothing else in
  those files changes.
- [ ] **Step 3: `VibeCore` builds on Linux.** `swift build --build-system native --target VibeCore` exits 0 with no
  error. Add it to `portableTargets`; `scripts/ci/linux-core-errors.sh` is deleted, and `PlatformLintPending.txt` is
  empty for `Sources/VibeCore`.
- [ ] **Step 4: Push; both green** (`v2 linux` now builds the core); **commit** ("v2: VibeCore builds on Linux").

---

### Task 12: The core's tests on Linux

**Files:**
- Modify: `Tests/VibeCoreTests/TestSupport.swift` (the guard's Linux form), `Package.swift` (the test target on Linux)
- Modify: test files, as found; Create: `docs/process/platform-parity.md`
- Create: `Tests/VibeCoreTests/MacOnlyTests.txt`

**Interfaces:**
- Produces: `bash scripts/test.sh` green on Linux for `VibeCoreTests`.
- `MacOnlyTests.txt`: one test file a line, two spaces, the reason. A file listed is compiled only on the Mac
  (wrapped whole in `#if canImport(Darwin)`); a lint test fails when a wrapped file isn't listed or a listed one
  isn't wrapped.

- [ ] **Step 1: Compile.** Add `VibeCoreTests` to the Linux manifest. The 29 test files with Darwin-only code (recon
  §4) each get the smallest change that compiles: a call through `VibePlatform` where one exists (`Clock`, `stat`,
  `Sys`), or the file listed Mac-only when what it tests is Mac-only (`KeychainLiveTests`, `DevPreview*Tests`,
  `StatusAccessibilityTests`, `PreferenceLedger`).
- [ ] **Step 2: The guard.** `TestSupport.swift`'s two initializers in `.init_array` on Linux, SIGPIPE ignored there,
  `Scratch.defaults` on a file-backed store. `HomeIsolationTests` passes on Linux; shown failing with the Mach-O
  section name.
- [ ] **Step 3: Run and sort.** `bash scripts/test.sh` on Linux. Every failing test is one of three, decided in this
  order: the platform's Linux form is wrong (fix it, with a `VibePlatformTests` test that fails first); the test
  assumes the Mac where the code doesn't (a path under `/private`, `zsh`, a `ttysNNN` name, "Killed: 9"): the test
  takes the value from the platform; the thing tested is the Mac's: listed Mac-only with its reason. Work by suite,
  largest first. Stop and report if more than a tenth of the 236 files would be listed, or if a failure shows a
  change in the Mac's behaviour.
- [ ] **Step 4: Foundation's differences**, tested first because sizes and pruning depend on them (recon §6):
  `totalFileAllocatedSize` and `creationDate` on Linux. Where one is nil, the code asks `stat` through the platform.
- [ ] **Step 5: `platform-parity.md`**: the count of test files that run on both, and each Mac-only one with its
  reason.
- [ ] **Step 6: Push; both green; commit** in slices of one suite group each.

---

### Task 13: The hook, the tool server, `vibeswitcher status`

**Files:**
- Create: `Sources/vibeswitcher/main.swift`, `Sources/vibeswitcher/Status.swift`
- Modify: `Package.swift` (the three executables on Linux), `HookInstaller.swift` call sites if any remain
- Test: `Tests/VibeCoreTests/StatusCommandTests.swift`

**Interfaces:**
- Produces: the executable `vibeswitcher` with `status [--json]`: one line a session (terminal, agent, project
  folder, status word, since when), from `ProcessTable`, the hook state files and `StatusRules`; exit 0.
  `--json` prints an array of `{terminal, agent, cwd, status, since}`.

- [ ] **Step 1: Failing test** `StatusCommandTests.aFakeSessionIsListedWithItsStatus`: with a scratch home, a fake
  agent process (`FakeClaude`'s approach: a script named `claude` on a pty) and a hook state file written for its
  terminal saying "needs you", `status --json` lists one session with that status and that folder.
- [ ] **Step 2: Build the three executables on Linux**; fix what is left (`F_SETNOSIGPIPE` in `vibeswitcher-mcp`, the
  `sigaction` line in `vibeswitcher-host` through `Platform.Signals`). `vibeswitcher-host` itself only has to compile
  here; it runs in stage 2.
- [ ] **Step 3: Implement `status`.**
- [ ] **Step 4: A real session.** In a scratch home (`VIBESWITCHER_HOME`), install the hook for a throwaway Claude
  Code config folder (`CLAUDE_CONFIG_DIR`), start `claude --model sonnet -p "say hi"` there, and watch `vibeswitcher
  status` go from working to done. Never against the user's own `~/.claude`. Record what the hook wrote.
- [ ] **Step 5: Measure for Decision 6.** Time to run the hook once (`vibeswitcher-hook` given one event on stdin),
  median of 200 runs: the glibc build, the static build, and a static build that is one multi-call binary. Record
  the three numbers and sizes in `docs/process/v2-linux-inventory.md`.
- [ ] **Step 6: Push; both green; commit** ("v2: vibeswitcher status, the hook and tool server on Linux").

---

## Done when

On Ubuntu, `bash scripts/test.sh` is green for `VibePlatformTests` and `VibeCoreTests` with the Mac-only tests listed
and counted; `vibeswitcher status` showed a real session going from working to done; `PlatformLint` holds with an
empty pending list for `VibeCore`; and both workflows are green on the same commit.

## After the bootstrap, from this stage

Not tasks here; the lead's early work (design, The bootstrap): dev previews' proxy on sockets, image thumbnails on
Linux, power and keep-awake, `vibeswitcher doctor`, the agent adapters' version ranges and nightly run, resources
embedded in the binaries, a format version in every file the core writes.
