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

---

## Remaining work (revised 2026-11-13)

Everything above is the plan as written on 2026-11-12 and stays as history. This section is what is left, read
against `47636aaf`, which is also `origin/v2`: everything is pushed. The runs on that commit: `v2 linux` 43275652307
failed after 18 minutes (its one job runs the whole of `VibeCoreTests` inside `timeout-minutes: 30`, and the suite has
the failures below); `v2 macos` 43275652285 was still running when this was written. On this machine the fourth full
Linux run of the core's tests passed 2,707 of 2,774 in 12.5 minutes, and its failures were sorted by cause, A to P.

It was written from a planner's draft, five reviews and three critiques of that draft; each correction below says
what it corrects. The bootstrap's order across stages is in
[the bootstrap path](2026-11-13-v2-bootstrap-path.md), and stage 2 has [its own plan](2026-11-13-v2-stage-2-session-host.md).

### Where each task stands

| Task | State | Commits | Left |
| --- | --- | --- | --- |
| 1 | done | 9fc9c6eb | |
| 2 | done | b445bf0a, 438b1270 | Step 4's "until Task 12 adds the host" reads "until stage 2's host builds" |
| 3 | done | 923a43b9 | |
| 4 | done | c23a5c3a, 865e57ef, 7f958a95 | |
| 5 | done | in the Task 4 and 6 commits (`Clock.swift`, `Host+Linux.swift`) | |
| 6 | done but one test | 915893ee, ad2036c4, 30c182bf | R5 |
| 7 | done | 37e9ec75, ffd4068d | |
| 8 | done | b22f4b8d, 71e8aed5 | the cross-process start time: after the bootstrap (R13) |
| 9 | done, and built `ProcessExit` early | d013c359, 9aef7377 | |
| 10 | mostly done | 0bfdfc38, 9fd05f05 | the developer-tools callers and three hard-coded tools: after the bootstrap (R13) |
| 11 | done | dbbeecbe | |
| 12 | partly done | b37f0ef5, a599becd, 676cc112, 31e109f8, 2e2d3c83, 3485345f, f48cc714, 47636aaf | Step 3: covered by the core-test fixes (2026-11-13), then R1. Step 4: covered by the core-test fixes (2026-11-13). Step 5: after the bootstrap (R13) |
| 13 | not started | | R8a, R8b, R9, R10. The binary decision: after the bootstrap (R13) |

### Changes to the plan's text

- **The command line's target is `vibeswitcher-cli`**, in `Sources/vibeswitcher-cli`, and is installed as
  `vibeswitcher` on Linux. `Sources/vibeswitcher` would differ from the app's `Sources/VibeSwitcher` only in case: on
  the Mac's case-insensitive file system the two folders are one, both hold a `main.swift`, and the products
  `.build/<config>/vibeswitcher` and `VibeSwitcher` collide. Task 13's file lines read accordingly.
- **Task 13 Step 2 doesn't build `vibeswitcher-host` on Linux.** It stays in `notYetPortableTargets` (as
  `Package.swift` already says) and is stage 2's.
- **The real session goes from working to needs-you to done**, as the design's stage 1 says (R10). `claude -p` never
  reaches needs-you.
- **Decision 6 is called "the binary decision"** from here on (stage 2 numbers its own decisions S2-D1 and up), and it
  is taken after the bootstrap together with the static build (R13).
- **The tool server's full check moves to stage 2.** It learns its role from the session host, so with no host it
  lists no tools (R9).
- **Out of stage 1, into R13 with reasons:** the cross-process start time (R6 of the draft), the static build and hook
  timing (R11 of the draft), `platform-parity.md` and its lint, format versions beyond the settings file, resources
  inside the binaries, the adapters, `doctor`, LinuxAPILint (the Linux build and test jobs are the check).

### Covered by the core-test fixes (2026-11-13)

A workflow is fixing the Linux run's failures by cause as this is written, in Task 12 Step 3's order. These are its
work and are not repeated here; each is marked "covered by the core-test fixes (2026-11-13)" where it would otherwise
appear:

- A: BSD-only commands in the scripts under test (`stat -f`, `cp -c`, the Xcode lookup, `ps` columns), with their
  Linux forms.
- B: dash as `/bin/sh` (`command -v` of a missing program exits 127, read as "unknown").
- C: the Mac's developer-tools check asked of Linux.
- D: tests that run `/bin/zsh` where the code gives the platform's shell.
- E: creation dates Foundation can't set on Linux (Task 12 Step 4's `creationDate`).
- F: `components(separatedBy: "\n")` and CRLF.
- G: `totalFileAllocatedSize` on Linux (Task 12 Step 4's allocated size). The fix's review checks that its fallback is
  an allocated size (`st_blocks` × 512), not `Platform.Files.byteSize`, which is `st_size`.
- H: more cores than the boost's load threshold allows for.
- I: "Killed: 9" against "Killed".
- J: `/private` spelled in tests.
- K: memory pressure, the Mac's alone.
- L: the process table's pid 1 and readable environments.
- M: BSD-only flags in tests' own commands.
- N: signals and threads on Linux (`raise` and the main actor).
- O: ctime's tick on Linux.
- P: the temporary-folder lint's allow entries.
- The JSON-order flake, and the `WorktreesTests` exit wait moved onto `Platform.ProcessExit` (its own kqueue gone and
  its line out of `MacOnlyTests.txt`).

If that workflow ends with one of these unfixed, it comes back here as part of R1.

---

### R1: What the core-test fixes leave (Task 12 Step 3)

**Files:** test files as found; `Tests/VibeCoreTests/MacOnlyTests.txt`; `Tests/VibePlatformTests/MacOnlyTestsLintTests.swift`;
`ConfigSealPluginTests.swift`, `HomeIsolationTests.swift`, `RedactionReference.swift`, `TestScriptWidthTests.swift`.

- [ ] **Step 1: One run after the fixes land.** `bash scripts/test.sh --filter VibeCoreTests` on Linux. Every failure
  that isn't one of A to P is sorted in the plan's order (the platform's Linux form wrong, with a failing
  `VibePlatformTests` test first; the test assumes the Mac; the thing tested is the Mac's, listed with its reason). A
  run that ends on a signal with no failing test named is R2's collision: R2 first, and that run isn't a baseline.
- [ ] **Step 2: The stop rule as a fraction.** `MacOnlyTestsLintTests.fewerThanATenthOfATargetsFilesAreMacOnly`
  counts the target's `.swift` files and the list's lines, so the threshold doesn't go stale (236 files today, not
  237).
- [ ] **Step 3: Values from the platform.** The four files that branch on `#if os(Linux)` inside a test body take the
  `Platform` value where one exists (`Platform.Tools.loginShell`, `Platform.Terminals.name(devicePath:)`,
  `Platform.Files.sharedTemporaryRoot`). A branch stays only where no platform value can exist, with a comment saying
  why. Skip any file the core-test fixes already changed this way.

**Done when:** every `VibeCoreTests` file runs green on Linux or is listed with its reason, and the lint holds.

### R2: Signal tests that step on each other (both systems)

**Files:** `Tests/VibePlatformTests/TestSupport.swift`, `Tests/VibeCoreTests/TestSupport.swift` (a `SignalTestLock`
each), `SignalsTests.swift`, `PipeCommandTests.swift`, `Tests/VibeCoreTests/MCPLogTests.swift`,
`scripts/ci/macos-runner-skips.txt`.

The cause, read from the code: three suites change the dispositions of the same signals in one process.
`SignalsTests` uses SIGUSR2 (lines 63-77, no delivery), SIGURG (79-97) and SIGWINCH (99-124).
`MCPLogTests.itSaysWhyServingEndedAndAToolsErrnoButNoneOfItsText` (line 61) stops a server on SIGUSR2:
`MCPServer.stop(on:)` (MCPServer.swift 567-580) sets a handler it never restores, and the test raises SIGUSR2
repeatedly. `PipeCommandTests.aStopSignalStopsTheCommandAndItsGroup` (127-140) sends SIGWINCH to the test process and
then sets it to `SIG_DFL`; on Linux `aSignalThatIsNotAStopSignalStopsNothing` sends SIGWINCH too, and several of its
tests install and restore SIGURG. On Linux every test target runs in one process. On the Mac, `PipeCommandTests` and
`SignalsTests` still share the platform job's process, which fits the three "CAUSE NOT FOUND" skips.

Corrected from the draft: the tests keep signals whose default is to be ignored. `SignalsTests` says why (lines
10-12), and `aFatalHandlerRunsAndTheDefaultIsBack` delivers its signal a second time after `SA_RESETHAND` has put the
default back (lines 93-96): a real-time signal, SIGXCPU or SIGXFSZ there would end the whole test process. There are
too few default-ignored signals on Linux (SIGURG, SIGWINCH, SIGCHLD, SIGCONT, and SIGCHLD arrives from every child) to
give each suite its own, so the suites are serialized against each other instead.

- [ ] **Step 1: Show it.** Run `bash scripts/test.sh --filter 'SignalsTests|PipeCommandTests|MCPLogTests'` twenty
  times on Linux and record the failures and any run that ends on a signal. This is the "without the fix" evidence.
- [ ] **Step 2: The lock.** `SignalTestLock.held(_ body: () async throws -> T) async rethrows -> T` in each target's
  `TestSupport.swift`: `flock(LOCK_EX)` on `<scratch home>/signal-tests.lock`, opened anew for each use. A flock
  belongs to the open file description, so two opens in one process exclude each other, and the two test targets
  need no shared module. **The wait is off the cooperative pool:** `held` takes the flock on a dispatch thread and
  resumes through a continuation, because Swift Testing runs even synchronous tests on the pool (4 threads on a
  hosted runner), and a dozen tests blocked in `flock` there would hold every thread while the holder's body needs
  one (`MCPServer`'s `serve`, anything that awaits). Each of the three suites is also `.serialized`, so at most one
  test per suite waits. Every `SignalsTests` test, every `PipeCommandTests` test that passes a non-empty
  `stopSignals` or sends a signal to the test process, and `MCPLogTests`' SIGUSR2 test take it for their whole body
  (they become `async`).
- [ ] **Step 3: MCPLogTests puts SIGUSR2 back.** That test is cause N of the core-test fixes (`raise` reaching a
  thread libdispatch doesn't watch), which the core-test workflow is changing: this step starts from its fix once it
  has landed, and re-reads the test before editing it. It saves the disposition before `serve` and restores it in a
  `defer` once `serve` has returned (its signal source stays registered; nothing sends SIGUSR2 after it).
- [ ] **Step 4: A lint, narrow.** `SignalsTests.everyTestThatHandlesTheseSignalsHoldsTheLock`: in `Tests/**/*.swift`,
  a file that changes a disposition (`signal(`, `sigaction(`, `onFatal`, `onSignal`, `stop(on:`, a non-empty
  `stopSignals:`) or sends a signal to its own process (`raise(`, `pthread_kill`, `kill -… $PPID`) for SIGURG,
  SIGWINCH or SIGUSR2 must mention `SignalTestLock`. `Sources/` and `Tests/Tools/*.py` aren't read: the host's
  SIGWINCH goes to its sessions, never to its own process. Shown failing by removing the lock from one test.
- [ ] **Step 5: The same twenty runs**, with no failure and no run ending on a signal.
- [ ] **Step 6: The Mac.** The next push runs the platform job with the lock. Each of the three SignalsTests skips
  that passes there is removed from `macos-runner-skips.txt`; one that still fails keeps its line with what the run
  showed. At most two pushes go to this (R3's time box).

**Done when:** twenty Linux runs of the three suites together pass, and on the Mac the three skips are gone or each
says what was seen.

### R3: CI that fits, then everything green on one commit

**Files:** `.github/workflows/v2-linux.yml`, `scripts/ci/macos-runner-skips.txt`, `docs/process/v2-branch.md`,
`docs/process/v2-mac-tasks.md`.

Corrected from the draft: nothing is left to push (the draft read `origin/v2` as `9fd05f05`), and the current evidence
is the runs on `47636aaf`.

- [ ] **Step 1: Split the Linux workflow** as `47636aaf` split the Mac's: jobs `platform`
  (`bash scripts/test.sh --filter VibePlatformTests`) and `core` (`--filter VibeCoreTests`), each with
  `timeout-minutes: 90` and the workflow check first; `scripts/ci/check-workflows.sh` passes. This is the first commit
  of this list, pushed only when no run someone is waiting on is in progress. (The suite took 12.5 minutes on this
  24-core machine; the hosted runner has 4.)
- [ ] **Step 2: Read the Mac.** Once 43275652285 ends, download `macos-test-log-core`, `-platform`, `-host` and
  `-app` into a scratch folder and compare them with 43260865049. `LoadHarnessTests.itsBuildRunsOnItsSlotsShareOfTheCores`:
  its Linux side is cause A; for the Mac, read `b445bf0a` and `438b1270` for any line that runs there. A test that
  starts and never ends in the platform job is a bug to fix with a hang guard that names it, not a skip.
- [ ] **Step 3: The time box.** A Mac-only failure in new platform code gets at most two pushes of investigation. Then
  it is listed in `macos-runner-skips.txt` with the experiment that will find its cause, and in
  `docs/process/v2-mac-tasks.md`, and Linux work goes on. Write this rule into `v2-branch.md`. This step **creates**
  `docs/process/v2-mac-tasks.md` (a heading and its first lines), since R2 and this step write into it before R12;
  R12 fills it in.

**Done when:** both `v2 linux` jobs are green, and `v2 macos`'s platform, host and app jobs are green and its core job
is green apart from listed skips, each with its cause or its experiment, on one commit.

### R5: No process dies of SIGPIPE before it settles it (Task 6's missing test, and a bug it hides)

**Files:** `Sources/VibePlatform/Sockets.swift`, `Sockets+Linux.swift`, `Sockets+Darwin.swift`;
`Sources/VibeCore/HostConnection.swift` (the writes at lines 71 and 411), `Sources/VibeCore/UnixSocket.swift`;
`Sources/vibeswitcher-hook/main.swift`, `Sources/vibeswitcher-mcp/main.swift`; Test:
`Tests/VibePlatformTests/SocketsTests.swift`, `PlatformLintTests.swift`; `docs/process/v2-port-map.md`.

The bug: the hook's first write to the host's socket is `LeadVault.standard.record` at `main.swift:87`, a round trip
to the host; SIGPIPE is ignored only at lines 91 and 99. On Linux `Platform.Sockets.noSigPipe(socket:)` does nothing
(`Sockets+Linux.swift:30-33`) and `HostConnection` writes with `write(2)`, so a host that closes mid-write (a handover,
a restart) kills the hook. The tool server's `--read-only-permission` branch writes stdout at line 41, before its
SIGPIPE settings at lines 51 and 153. Corrected from the draft: a lint that compares where words appear in
`main.swift` misses the hook's write (no pattern matches `LeadVault.standard.record`) and matches `case .write(` by
accident, so the fix is made where the write is.

- [ ] **Step 1: Failing test.** `SocketsTests.aSocketWriteToAGonePeerFailsWithEPIPEAndTheProcessLives`: a helper mode
  of the test binary writes through `Platform.Sockets.send(_:_:_:)` to a peer that has closed, and exits 0 having
  seen `EPIPE`. Both test targets ignore SIGPIPE from `.init_array` as they load
  (`Tests/VibePlatformTests/TestSupport.swift:50`, `Tests/VibeCoreTests/TestSupport.swift:38`), and a helper mode runs
  after that, so the helper's first act is `signal(SIGPIPE, SIG_DFL)`, and it asserts the disposition before writing.
  On the Mac the socket gets `noSigPipe(socket:)` first, as the code's sockets do. Shown failing on Linux with
  `Sys.write` in its place: the record says the helper died of SIGPIPE (status 141 or signal 13).
- [ ] **Step 2: `Platform.Sockets.send(fd, bytes, count) -> Int`**: `send(…, MSG_NOSIGNAL)` on Linux; `write(2)` on
  the Mac, whose sockets carry `SO_NOSIGPIPE`. Switch `HostConnection`'s two writes and `UnixSocket`'s socket writes
  to it (calls switched to `VibePlatform`; the Mac's behaviour is the same).
- [ ] **Step 3: The executables settle it after their mode dispatch, before their first write.** Corrected from an
  earlier draft of this step, which asked for `signal(SIGPIPE, …)` as the first statement: `vibeswitcher-host` runs
  three mode dispatches first (`PTYSpawn.execIfLaunched`, `SessionParser.runIfAsked`, `HostHandover.probeIfAsked`,
  lines 9-13) and settles SIGPIPE at line 15, and it must: the launcher execs the session's program, and an ignored
  SIGPIPE survives `execve`, so moving line 15 up would start every session's shell and agent with SIGPIPE ignored.
  The tool server's first statement must stay the `BranchCode` prefix check, which runs a branch's code.
  `PlatformLintTests.everyExecutableSettlesSIGPIPEBeforeItWrites`: in each `Sources/vibeswitcher*/main.swift`, the
  first top-level statement that isn't a mode dispatch is `signal(SIGPIPE, …)`. A mode dispatch is an `if` whose
  every path ends in `exit`, `_exit` or an exec, or one of the host's three named calls; a dispatch branch that
  writes (the tool server's read-only hook answer, line 41) ignores SIGPIPE itself before writing, and starts no
  program. Move the hook's `signal(SIGPIPE, SIG_IGN)` above its `SIGALRM` line (check that the hook starts no
  program; one it starts would inherit the ignore, so it would be started with `SignalDefaults.all`), and the tool
  server's caught handler from line 153 to just after its dispatches (its status-line branch still ignores SIGPIPE
  itself). Each move is a line in the port map's Non-seam edits. The lint covers `vibeswitcher-cli` and
  `vibeswitcher-server` when they exist. That a session's program starts with SIGPIPE at its default is held by stage
  2's `SessionEnvironmentTests.aSessionsProgramStartsWithSIGPIPEAtItsDefault`.

**Done when:** both tests pass on Linux and on the Mac.

### R7: The settings file's folder is the core's, and the file says its format

**Files:** `Sources/VibePlatform/Settings+Linux.swift` (it copies `VibePaths.root`'s rules by hand, lines 270-283).
Tests: `Tests/VibePlatformTests/SettingsTests.swift`, `Tests/VibeCoreTests/SettingsRootTests.swift`.

- [ ] **Step 1: Failing tests.** `SettingsRootTests.thePlatformsRootIsTheCoresRoot`: over injected environments
  (with `VIBESWITCHER_HOME`, with `CFFIXED_USER_HOME`, and with `HOME` only), `VibePaths.root(environment:fallbackHome:)`
  (`Paths.swift:19`) equals VibePlatform's `Settings` `root(variable:fallbackHome:)` (`Settings+Linux.swift:275`,
  internal, so through `@testable import VibePlatform`). The process environment is never changed: tests run in
  parallel, and every other test's `VibePaths.root` would move with it, possibly out of the scratch home.
  `SettingsTests.aSettingsFileCarriesItsFormat` (the written file has `"format": 1`) and
  `aNewerFormatIsRefusedAndLeftAsItIs` (a file with `"format": 2` reads as empty, and a write leaves it as it was, with
  a log line; rule 11).
- [ ] **Step 2: Implement.** Nothing changes on the Mac, where `UserDefaults` is the store.

The file has no users yet, so its format costs nothing now and a migration later. Its scope (rule 9: this node's
setting or the user's everywhere) comes with `VibeNode`'s settings catalog after the bootstrap.

**Done when:** the three pass on Linux; the Mac runs the root test.

### R8a: The node's first module, and `vibeswitcher status`

**Files:**
- Create: `Sources/VibeNode/LocalSessions.swift`: the one session list the status command, and later the engine,
  read. `ProcessTable`'s agents joined with `HookState` by terminal name and resolved with `StatusRules`. Plain Swift,
  no Combine.
- Create: `Sources/vibeswitcher-cli/main.swift`, `Status.swift`.
- Create: `Tests/VibeNodeTests/TestSupport.swift` (the home guard, as in the other targets), `StatusCommandTests.swift`.
- Modify: `Package.swift`, both halves (`VibeNode`, the executable target `vibeswitcher-cli`, `VibeNodeTests`);
  `Tests/VibePlatformTests/PlatformLintTests.swift` (its folders gain `Sources/VibeNode` and `Sources/vibeswitcher-cli`);
  `.github/workflows/v2-macos.yml` (the core job runs `scripts/ci/macos-tests.sh 'VibeCoreTests|VibeNodeTests'`) and
  `.github/workflows/v2-linux.yml` (the core job's filter `'VibeCoreTests|VibeNodeTests'`, after R3's split), checked
  with `scripts/ci/check-workflows.sh`. Without this, no job on either system runs `VibeNodeTests`.

**Interfaces:**
- `vibeswitcher status [--json]` (built as `vibeswitcher-cli`): one line per session: terminal, agent, project folder,
  status word, since when. `--json` prints `{"format":1,"node":"local","sessions":[{"id","terminal","agent","cwd","status","since"}]}`,
  `id` being `local:<terminal>`. It reads files directly, as a local probe; stage 3's protocol client replaces it, and
  its output may change until then (rule 1's `id` and `node` are there from the start).

- [ ] **Step 1: Failing tests.** `FakeClaude` is the app's, so the fake is built here: a script named `claude` started
  on a pty with `script` (util-linux's form on Linux, BSD's on the Mac, as `3485345f` does).
  `StatusCommandTests.aFakeSessionIsListedWithItsStatus` (with a scratch home and a hook state file for its terminal
  saying needs-you, `status --json` lists exactly that session, with that status, that `cwd`, and on Linux a terminal
  starting `ttypts`); `aSessionWithNoStateFileIsListedByTheTableAlone`; `theJSONCarriesFormatNodeAndId`. Tests find
  the binary under its build name, `vibeswitcher-cli`.
- [ ] **Step 2: A guard against the collision.** `PlatformLintTests.noTwoTrackedPathsDifferOnlyInCase`: every path
  prefix of every `git ls-files` path (each folder as well as each file), lowercased, has no duplicate among the
  distinct prefixes. Comparing whole file paths alone would miss `Sources/vibeswitcher/Run.swift` beside
  `Sources/VibeSwitcher/main.swift`, whose folders are still one on the Mac. Shown failing on a scratch tree holding
  `Sources/vibeswitcher/Run.swift`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: The Mac.** The app job builds from a clean checkout on the commit, which shows the new targets don't
  touch the app's build.

**Done when:** `bash scripts/test.sh --filter VibeNodeTests` passes on Linux, the Mac's core job builds and runs it,
and PlatformLint covers the two new folders.

### R8b: `vibeswitcher hooks install|remove`

**Files:** Create `Sources/vibeswitcher-cli/Hooks.swift`; Test: `Tests/VibeNodeTests/HooksCommandTests.swift`.

**Interfaces:** `vibeswitcher hooks install|remove [--agent claude|codex]`:
1. copies `vibeswitcher-hook` and `vibeswitcher-mcp` from beside its own executable into `VibePaths.binDir` (0755,
   written whole and renamed into place);
2. calls `HookInstaller.install(agent:at:)`, with `at:` set to `$CLAUDE_CONFIG_DIR/settings.json` when that variable
   is set (the installer reads only `VibePaths.home` and stays as it is).

It doesn't seal the write through the vault: there is no host on Linux yet. Through the install step, the engine
seals it (the bootstrap path, milestone 7). This replaces the app's `HookSetup` and `HookBinary` (port map).

- [ ] **Step 1: Failing tests.** `installWritesOurHandlersIntoTheConfigFolderGiven` (with `CLAUDE_CONFIG_DIR` set to a
  scratch folder, its `settings.json` has the nine Claude events pointing at `<scratch home>/bin/vibeswitcher-hook`,
  and the scratch `HOME/.claude` is untouched); `installCopiesBothBinariesExecutable`; `removeLeavesTheUsersOwnHandlers`.
- [ ] **Step 2: Implement.**

**Done when:** the three pass on Linux and on the Mac.

### R9: The tool server answers on Linux, without a host

**Files:** `Tests/VibeNodeTests/ToolServerSmokeTests.swift`.

Corrected from the draft: the tool server learns its role by asking the session host (`vibeswitcher-mcp/main.swift`
430-470, `MCPHostedToolset`), and `LeadToolset.tools` is empty for no role (`LeadToolset.swift` 634-636). With no
host, `tools/list` is empty for up to two minutes, so the lead's tools can't be listed here. Nor is `auto_advance` a
tool: it is a setting of `add_task`, `update_task` and `configure`.

- [ ] `theToolServerAnswersWithNoHost`: start the built `vibeswitcher-mcp` (found as `676cc112`'s helpers find the
  build's products) with a scratch home. Over stdio, `initialize` answers within 10 s; `tools/list` answers, with an
  empty list; its stderr has "the session host can't be asked yet, or its session holds no role yet; asking again".
  Shown failing by pointing it at a missing binary.

The full check, the lead's tools listed and one call served, is stage 2's
`ToolServerUnderAHostTests.theLeadsToolServerListsItsToolsAndServesStatus`, once a host runs on Linux.

**Done when:** it passes on Linux and on the Mac.

### R10: A real Claude Code session goes from working to needs-you to done

**Files:** `Tests/VibeNodeTests/RealClaudeStatusTests.swift`, `docs/process/v2-linux-inventory.md`.

- [ ] **Step 1: The user prepares a config folder.** A throwaway Claude Code config folder, logged in once by the user
  (`CLAUDE_CONFIG_DIR=<folder> claude`, then `/login`). An agent never logs in or copies credentials (`AGENTS.md`).
  The test runs only when `VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR` names that folder, as `CodexRealRunTests` is gated by
  `VIBESWITCHER_REAL_CODEX_HOME`. This is asked of the user at the start, with the other questions (the bootstrap path),
  and doesn't hold up other work: until the folder exists the test is skipped, saying why, and the item stays open.
- [ ] **Step 2: The test.** `aRealSessionGoesFromWorkingToNeedsYouToDone`, in a scratch `VIBESWITCHER_HOME` and a
  scratch project folder:
  1. `vibeswitcher hooks install` against that config folder.
  2. The project's trust entry written into `$CLAUDE_CONFIG_DIR/.claude.json` (`projects[<path>]` with
     `hasTrustDialogAccepted` and `hasCompletedProjectOnboarding`, as `Tests/Tools/capture-claude-status-rows.py:124`
     does): otherwise Claude Code shows its trust dialog first and no hook runs. This is not a credential.
  3. `claude --model sonnet` on a pty the test owns, made with util-linux `script` as R8a's fake is (stage 2's
     `Platform.Terminals.open` doesn't exist yet), the test writing to `script`'s stdin, with a first prompt asking it to run `touch made-by-claude`
     through Bash, which the scratch settings leave unapproved.
  4. Poll `status --json` every 0.5 s: `working`, then `needs-you` (the permission prompt), within 120 s.
  5. Approve the prompt (Enter on "Yes"). Expect `done` within 60 s, and `made-by-claude` in the folder.
  6. Record the sequence of `state/ttypts<N>.json` contents the hook wrote, then `hooks remove`, so the folder is left
     with its own settings (each run adds a project entry to its `.claude.json`; the record says so).

  Corrected from the draft: it doesn't press Escape and wait for done. Claude Code fires no Stop hook on Esc
  (`StatusRules.swift:66-67`); only the title glyph catches it, and `status` reads no title, so the state would stay
  at needs-you. What Esc does may be recorded as a separate observation, never asserted.

  This also checks that the hook finds its session from the agent's terminal on Linux (`vibeswitcher-hook/main.swift`
  35-60), where the native `claude`'s process name is its version number and argv[0] tells it apart
  (`ProcessTable.swift:262`).
- [ ] **Step 3:** write the observed states, the state files and the Claude Code version (2.1.322 here) into
  `v2-linux-inventory.md`.

**Done when:** the gated test passed once here with the user's folder, and the record is committed. Without the
variable, `bash scripts/test.sh` skips it, saying why.

### R12: Records

**Files:** fill in `docs/process/v2-mac-tasks.md` (created in R3); modify this plan, `docs/process/v2-stage1-recon.md`,
`docs/process/v2-branch.md`.

- [ ] **`v2-mac-tasks.md`**: each change to the Mac's behaviour made on `v2`, with its commit and what to check on a
  real Mac: `ffd4068d` (no `setpgroup(0)` in `Shell.Spawned`); `71e8aed5` (`ProcessTable.record` for any user, the uid
  checks in its five callers, `LoadRecorder` leaving out zombies with two calls per process); `9aef7377`
  (`LeadAdvance` gets no thread when kevent fails; `WalletFolderWatch` fails at creation when descriptors run out);
  `0bfdfc38` (`LaunchPreflight` split); `865e57ef` (`WebPush`'s random bytes from `SystemRandomNumberGenerator`, with no
  failure path: accepted, both are a CSPRNG); `47636aaf` (`createLocked` makes, flocks and links on the Mac too, no
  `O_EXLOCK`; a crash between making and linking leaves a file under its making name). Also: the 18 runner skips;
  `Package.resolved` pinning swift-crypto and swift-asn1 for the Mac; the three Darwin costs and the two replaced
  oracles (R13); the runner's limits (SIP off, 3 cores, no Keychain prompts); and the benches the design's anti-goal
  measures by (`--perf`, the UI bench, the freeze count), none of which a hosted runner runs.
- [ ] **This plan:** tick the done steps; a "Commits:" line under each task; correct the Files lines of Task 6
  (`FilesExclusive.swift`, `+Linux`, `+Link`), Task 9 (`ProcessExit*.swift` built here), Task 11 (`Images+Darwin.swift`;
  `ProcessTable+Procargs.swift` in `MacOnly`; `linux-core-errors.sh` kept, for `VibeHost`) and Task 13
  (`vibeswitcher-cli`).
- [ ] **The recon:** a line at the top of §0 and §1: "Superseded where it names `Platform/Darwin/` and
  `Platform/Linux/`: the code is one module, `Sources/VibePlatform`."
- [ ] **`v2-branch.md`:** at each merge, a target main adds is mirrored into `Package.swift`'s Linux list; push only
  with every `v2` job green, under R3's time box; the jobs' new names; the port map's merge step
  (`docs/process/v2-port-map.md`).

**Done when:** `bash scripts/test.sh --filter DocLinksLintTests` passes.

### R13: After the bootstrap, from this stage

Not tasks here; they go to the lead's backlog, or to `v2-mac-tasks.md` where only a Mac can check them.

- **The cross-process start time** (Review Focus 4). Only `WalletCourier.Saved` (lines 445-472) writes a start for
  another process to read, and the wallet desk is after the bootstrap. The other comparisons
  (`SessionStrays.swift:129`, `SessionScanner.swift:113`, `Worktrees.swift:479`) compare starts read in one process,
  where boot time is read once. The fix, when it comes: persist the start ticks and `/proc/sys/kernel/random/boot_id`
  beside the start, compare those exactly, and keep `==` on the Mac. A tolerance of seconds would be wrong: WSL steps
  the clock by as long as Windows slept.
- **The static build, the hook's start-up time and the binary decision** (the draft's R11): a pinned
  `swift sdk install <url> --checksum <sha256>` step in CI first, since the musl SDK is only on this machine; no
  multi-call variant (it would turn the executables' top-level code into functions); the static hook's numbers stand
  in for it. Whatever the decision, the host never trusts its server by the executable's identity.
- **`platform-parity.md`** with the design's meaning (features per client) and a section of test counts checked by a
  lint against the `MacOnlyTests.txt` lists.
- **Format versions beyond the settings file, resources inside the binaries, the adapters, `doctor`, dev previews'
  proxy, thumbnails, power and keep-awake.**
- **Task 10's leftovers:** `ToolchainWatch` and `ToolInstall` through `Platform.Tools.hasDeveloperTools()`,
  `LaunchPreflight`'s Linux wording, and `/usr/bin/printenv` (`LoginShell.swift:22`), `/usr/bin/tar`
  (`ProductInventory.swift:55`) and `/usr/bin/perl` (`Git.swift:396`) through `Platform.Tools.find`. All three exist on
  Ubuntu, so the lead's path doesn't break.
- **The Darwin costs:** an own-process read for `ProcessUsage`, `StallWatch`, `SessionStrays` and `TestLock`; one
  `PROC_PIDTASKALLINFO` for `LoadRecorder`; terminal names looked up lazily; no kqueue in `FolderWatch(descriptor:)`.
  The raw Darwin oracles restored in `IndexLockTests` and `ProcessTableTests` under `#if canImport(Darwin)`.
- **`SessionStrays.processes(user:)`** compares with `user` again.

## Done when (revised 2026-11-13)

On Ubuntu, `bash scripts/test.sh` is green for `VibePlatformTests`, `VibeCoreTests` and `VibeNodeTests`, with the
Mac-only tests listed under a tenth of each target. `vibeswitcher status` showed a real Claude Code session go from
working to needs-you to done, and that run is recorded (or, until the user's config folder exists, the test is
skipped and the item is open). `PlatformLint` holds with an empty pending list for `VibeCore`. Both `v2 linux` jobs are
green, and `v2 macos` is green as R3 defines it, on one commit.
