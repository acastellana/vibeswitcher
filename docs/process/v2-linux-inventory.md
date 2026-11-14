# How far the code is from compiling on Linux

Measured 2026-11-12 in a scratch copy (main at `f2ebe92b`, Swift 6.4.2, Ubuntu 24.04 on WSL2), for
[version 2's design](../superpowers/specs/2026-11-12-vibeswitcher-2-design.md). The copy was thrown away; nothing here
is a port. The numbers are a floor: see "What the numbers don't cover".

## VibeCore: 505 errors in 34 of 171 files

The other 137 files type-check unchanged.

| Kind | Errors | Files | On Linux |
| --- | --- | --- | --- |
| Process inspection (`proc_pidinfo`, `sysctl` KERN_PROC, `kinfo_proc`, `proc_pidpath`, fd lists) | 177 | 11 | `/proc/<pid>/{stat,status,cmdline,exe,cwd,fd}`. `ProcessTable.swift` alone is 70 |
| `posix_spawn` | 74 | 4 | In glibc the attributes and file actions aren't optionals; `POSIX_SPAWN_CLOEXEC_DEFAULT`, `SETEXEC` and `addinherit_np` have no direct equivalent |
| Keychain (`SecItem*`, `SecAccess`, `SecTrustedApplication`) | 48 | 1 | No equivalent of the per-app access list: the security architecture's question |
| kqueue, `kevent`, `O_EVTONLY`, file-system sources | 38 | 3 | epoll, `pidfd_open`, inotify |
| Network.framework (`PreviewProxy.swift`) | 38 | 1 | Sockets. Understated: about 55 lines use it |
| Mach clocks and host statistics, `sysctlbyname`, `statfs` | 34 | 8 | `clock_gettime(CLOCK_MONOTONIC)`, `/proc/meminfo`, `statvfs` |
| CoreGraphics, ImageIO, UTType (`MenuBarDots`, `LeadImages`) | 33 | 2 | The dots are the Mac's; image sizes from headers |
| Darwin `stat` fields (`st_mtimespec`, `st_birthtimespec`, widths) | 19 | 9 | `st_mtim`; `statx` for the birth time |
| Peer credentials and socket options (`audit_token_t`, `LOCAL_PEERPID`, `getpeereid`, `SO_NOSIGPIPE`, `sun_len`) | 18 | 4 | `SO_PEERCRED`, `SCM_CREDENTIALS`, `MSG_NOSIGNAL` |
| Other libc (`O_EXLOCK`, `renameatx_np`, the `sigaction` union, `rlimit` types, `OPEN_MAX`) | 11 | 5 | `flock`, `renameat2`, `sa_handler` |
| CoreFoundation's boolean test | 6 | 2 | An `NSNumber` type test |
| Foundation gaps (`AttributedString(markdown:)` once, `NSSetUncaughtExceptionHandler`) | 6 | 2 | Own inline-markdown stripper; no handler |
| `SecRandomCopyBytes` | 3 | 1 | `SystemRandomNumberGenerator` |
| CryptoKit | 0 | 0 | swift-crypto 3.15.1 is a drop-in for the 20 files that use it |
| Objective-C runtime | 0 | 0 | Not used |

## VibeHost: 142 errors in 8 of 13 files

| Kind | Errors | Files |
| --- | --- | --- |
| `posix_spawn` | 62 | 3 |
| Code signing and Mach-O (`AppCode.swift`) | 29 | 1 |
| Keychain (`VaultStorage.swift`) | 25 | 1 |
| Process inspection | 12 | 2 |
| `DispatchSource.makeProcessSource` (pidfd on Linux) | 5 | 3 |
| Peer credentials | 5 | 4 |
| Other (`ptsname_r`, `ioctl`'s request type, a Dispatch block convention) | 4 | 2 |

The executables, type-checked against stubs: `vibeswitcher-hook` 0, `vibeswitcher-mcp` 1 (`F_SETNOSIGPIPE`),
`vibeswitcher-host` 4 (one `sigaction` line).

## What changes the plan

- **One construct is 103 of the errors**: optional `posix_spawnattr_t` and `posix_spawn_file_actions_t` at 9 spawn
  sites in 7 files, across both targets. One shared spawn wrapper removes them.
- **The trust chain is the design problem, not the count**: audit token, then the code-signature check, then the
  Keychain's access list.
- **SwiftTerm 1.19.0 builds on Linux unchanged.**
- **OpenCombine 0.14.0 builds** (three products) and lacks `combineLatest` and `merge`, which the app calls 10 times.
  Version 2's stores don't use Combine, so this matters only if a Mac model is ever compiled here.
- **The tests' home guard is inert on Linux.** `@_section("__DATA,__mod_init_func")` compiles and never runs;
  `@_section(".init_array")` runs at load. Until the Linux form exists, a bare `swift test` here is not refused.
- **`--build-system native`** is needed to see every error (the default build system stops at the first failing
  batch) and is deprecated in Swift 6.4.

## What the numbers don't cover

- How it was measured: `import CryptoKit` to `Crypto`, `import Darwin` to `Glibc`, the five framework imports behind
  `#if canImport`, and 89 `Darwin.`-qualified calls rewritten. `VibeHost` and the executables were checked against a
  `VibeCore` module emitted with errors allowed, so their numbers are softer.
- Closure bodies that failed inference were never checked.
- Checks that come after type-checking never ran on the 34 files with errors.
- Mac dependencies that only show at run time, counted by search and not compiled: `osascript` (4 lines), `Library/`
  paths (12), `/Applications` (7), `UserDefaults` (7), `/usr/bin/git` and `/bin/zsh` (16).

## A fully static build works

Tried 2026-11-12 with Swift's static Linux SDK 0.1.0 for 6.4.2 (musl), on a probe that prints a version, hashes with
swift-crypto 3.15.1, starts a child with `posix_spawn` and feeds a headless SwiftTerm 1.19.0 terminal:

| Build | Result | Size |
| --- | --- | --- |
| `--swift-sdk x86_64-swift-linux-musl -c release` | builds; "statically linked"; runs here, all four lines right | 152 MB, 58 MB stripped |
| `--swift-sdk aarch64-swift-linux-musl -c release` | builds; "statically linked"; not run (no ARM machine here) | 152 MB |
| the same probe against glibc, for comparison | builds and runs | 14.5 MB, plus the Swift runtime it needs installed |

So a node can ship as binaries with nothing to install beside them, for both architectures, from this machine or a
hosted runner. What it asks of the code:

- The platform layer has to compile against musl as well as glibc: `#if canImport(Glibc)` … `#elseif
  canImport(Musl)`, never a bare `import Glibc`. The spike's 89 `Darwin.`-qualified calls become unqualified or go
  through `Platform/`.
- Most of the size is Foundation and its Unicode data, and each static binary carries its own copy. Four binaries
  that size is 230 MB stripped, so the release is one binary that acts by the name it's called under (`vibeswitcher`,
  `-host`, `-hook`, `-mcp`, `-server`), or the small ones (the hook runs on every agent event) avoid Foundation.
  Decided in stage 1's plan, with the hook's start-up time measured both ways.
- SwiftPM puts cross-built products in `.build/out/Products/Release-staticlinux-<arch>/`.

## The hosted runners

- **macOS**: the `xcode-27` image (macOS 27.0.1, arm64) has Xcode 27.2 and Swift 6.4.2, the Xcode the Mac that builds
  main uses. `macos-26` stops at Xcode 26.6. The whole package builds there in about 3 minutes.
- **Ubuntu 24.04**: the image's own Swift is used when it is `.swift-version`'s, else swiftly installs that version.
- The Mac suite on the runner: how long it takes and what it can't run are in
  [the skip list](../../scripts/ci/macos-runner-skips.txt) and below, once the first runs are in.

## State at the end of stage 1 (2026-11-13)

- **Builds on Linux:** `VibePlatform`, `VibeCore`, `VibeNode`, the hook (`vibeswitcher-hook`), the tool server
  (`vibeswitcher-mcp`) and the command line (`vibeswitcher-cli`, installed as `vibeswitcher`).
- **The Linux suite** (`bash scripts/test.sh`, on this 24-core machine): 2,801 tests in 345 suites passed, with 1
  known issue.
- **`VibeHost` still doesn't build on Linux**, nor `vibeswitcher-host`: it is stage 2's
  ([its plan](../superpowers/plans/2026-11-13-v2-stage-2-session-host.md)). `scripts/ci/linux-core-errors.sh` counts
  its errors (142 in 8 files at `dbbeecbe`).
- **What remains of stage 1** ([its plan](../superpowers/plans/2026-11-12-v2-stage-1-core-on-linux.md#remaining-work-revised-2026-11-13)):
  nothing. R3 was met at `4485b65a`, the first commit with every `v2 linux` and `v2 macos` job green
  ([the plan's done-when](../superpowers/plans/2026-11-12-v2-stage-1-core-on-linux.md#done-when-revised-2026-11-13)),
  and R10, a real Claude Code session from working to needs-you to done, passed here on 2026-11-13 (below).

## A real Claude Code session on Linux (2026-11-13)

Stage 1's R10, on this machine (Ubuntu 24.04 under WSL2): `RealClaudeStatusTests.aRealSessionGoesFromWorkingToNeedsYouToDone`
in `Tests/VibeNodeTests/RealClaudeStatusTests.swift`, run by
`VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<config> bash scripts/test.sh --filter RealClaudeStatusTests`, `<config>` being
a throwaway Claude Code config folder the user logged in once. Claude Code **2.1.323** (the native build, run as
`~/.local/bin/claude`, a link to `~/.local/share/claude/versions/2.1.323`), model sonnet (Sonnet 5.5 on the screen).
Without the variable the test is skipped, saying why.

The test installs the hooks into `<config>` (`vibeswitcher hooks install --agent claude`, a scratch
`VIBESWITCHER_HOME`), writes the scratch project's trust entry into `<config>/.claude.json`, and starts
`claude --model sonnet --permission-mode manual '<prompt>'` on a pty of its own (util-linux `script`), the prompt
asking it to run `touch made-by-claude` with Bash. It polls `vibeswitcher status --json` every 0.5 s, presses Enter
on the permission question, and quits with Ctrl-C twice.

**What `status` said, in order**, the same in each of the three passing runs:
`unknown -> working -> needs-you -> working -> done`. Unknown is the first poll, before the first hook wrote. The
session was found on its terminal (`ttypts4`) although the native `claude`'s process name is `2.1.323`: argv[0]
tells it apart, in the hook's lineage and in the status scan. The whole turn took about 2.3 s from the prompt to
Stop; the test, about 4 s.

**The state files** (`state/ttypts4.json`) a poll saw, without the prompt, transcript, folder and session id that
each also carried:

| `lastEvent` | Also there | `status` |
| --- | --- | --- |
| `UserPromptSubmit` | `agentPid` | working |
| `PermissionRequest` | `toolName` Bash, `request` "Run: touch made-by-claude", `notice` "Wants permission to use Bash", `toolDetail` "Create empty file" | needs-you |
| `PostToolUse` | the same tool, its notice kept | working |
| `Stop` | `lastMessage` "finished" | done |

After Ctrl-C twice the session ended and its `SessionEnd` hook removed the state file. In the second run the quit,
as first written, looked for "again to exit" on a screen whose spaces are cursor moves, waited its 2 s out and sent
the second Ctrl-C after Claude Code's window: the session was still running 15 s later and was killed (that run took
31 s, the others 4), and the file stayed, saying Stop. No hook runs on SIGKILL; `status`'s sweep of state files with
no agent on their terminal, 15 s after their last write, is what clears it then.

**Found on the way:**

- **2.1.323's default permission mode is auto mode** ("auto mode on" on the screen): the first run's Bash command ran
  unasked and the session went from working to done with no needs-you. The test starts it with
  `--permission-mode manual` (2.1.323's choices: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`,
  `plan`; there is no `default` any more).
- **No product change was needed on Linux**: the hook, the status scan and `ProcessTable` worked as they were.

**What each run leaves in `<config>`:** the hooks are taken out again (`hooks remove`; `settings.json` keeps its own
settings, and `HookInstaller` leaves `settings.json.vibeswitcher-backup` beside it), and the project's trust entry is
taken out of `.claude.json` again after Claude Code has ended. Claude Code's own files for the session stay, as for
any session: its transcript under `projects/<the scratch project's name>/`, a folder in `session-env/` and in
`shell-snapshots/`, and the prompt in `history.jsonl`.

## A real Claude Code under a scratch host (2026-11-14, Linux 5.15.167.4-microsoft-standard-WSL2)

Stage 2's Task 12a, on this machine (Ubuntu 24.04 under WSL2, 24 cores):
`RealClaudeHostTests.aClaudeSessionSurvivesItsClientAHandoverAndAKilledParser` in
`Tests/VibeHostTests/RealClaudeHostTests.swift`, run by
`VIBESWITCHER_REAL_CLAUDE_CONFIG_DIR=<config> bash scripts/test.sh --filter RealClaudeHostTests`, `<config>` the
throwaway Claude Code config folder of R10. Claude Code **2.1.323** (`~/.local/bin/claude`, the native build), model
sonnet (Sonnet 5.5 on the screen). Without the variable the test is skipped, saying why.

A scratch host (`ScratchHostProcess`: its own home, socket and lock, the test its app through the connector stand-in)
spawns `exec claude --model sonnet --permission-mode manual` in a scratch repository whose trust entry the run writes
into `<config>/.claude.json` (and takes out at its end), `CLAUDE_CONFIG_DIR` coming through the spawn request's
`env`. No prompt is sent. Each step's time, from the step before, in the passing run (the same within 0.1 s in the
two runs before it, which failed only at step 6):

| Step | Time | From the spawn |
| --- | --- | --- |
| 1. A client reads the screen until the prompt shows (Claude Code's box, `⏸ manual mode on · ? for shortcuts`), its screen the same a second later; it disconnects | 1.4 s | 1.4 s |
| 2. A new client attaches: the same screen | 0.1 s | 1.5 s |
| 3. A handover to the same code's build (`newBinary`, through sealed memory): listed with the same id and terminal (`ttypts4`), still running, the same screen | 0.2 s | 1.8 s |
| 4. The parser killed (`SIGKILL`): the watchdog starts another from the replay, and its screen is the same | 0.1 s | 1.9 s |
| 5. `/exit` sent as an `inputUnit` (the text, Enter 0.06 s later): the session's exit recorded, "exited 0" | 0.4 s | 2.3 s |

**Step 6, no parser reply dropped (Task 9e), found two replies Claude Code's start draws from the headless terminal
that 9e's table didn't answer:**

- **The focus report.** Claude Code turns focus events on as it starts (`CSI ? 1004 h`), and SwiftTerm 1.19.0, as
  xterm does, says at once that it has focus (`CSI I`, `sendFocusReport`). 9e's table took that responder for a
  view's only, so on Linux the report was dropped and logged, and Claude Code never heard it had focus while no view
  was attached (the Mac types it). Fixed in `ParserReplies`: DECSET 1004 is a query whose reply is `CSI I` or
  `CSI O`, one per 1004 the setting names (`ParserReplyTests.aProgramTurningFocusEventsOnIsToldItHasFocus`, and
  `everyQueryIsAnsweredInItsGrammar`'s cases).
- **The kitty graphics probe** (`APC G i=31,…,a=q;… ST`), which the headless terminal answers `APC G i=31;OK ST`.
  9e leaves kitty graphics out on purpose, so the reply is dropped and logged ("it is no reply"), once per session
  start: Claude Code then takes the terminal for one without kitty graphics, which a headless parser is in effect.
  The test allows that drop and no other. Whether to answer the probe (a query only, its `OK` reply only) is the
  lead's call.

**The 12a review (2026-11-14): a drop was hiding behind the log's once-a-second line.** The host logged a dropped
reply a line a second at most; a drop within that second was only counted, and the count reached the log only with
the next logged drop, so a drop held back when the parser stopped was never logged (the passing run above could not
see one). `ParserReplies.flushDropped` now logs what was held back when a session's parser stops (the session ending,
a handover's exec, the host quitting), and step 6 waits for the parser to stop and allows a line only if every drop it
counts is named and is a kitty graphics reply. The run after that fix (16:25, Claude Code 2.1.323, steps 1 to 5 in
1.5, 0.1, 0.2, 0.1 and 0.4 s) **failed step 6**: the first host image logged, as its parser stopped for the handover,
"1 more dropped since the last line", 1.2 s after the kitty probe's drop. That build counted without naming, so which
reply it was is not known; the flush line now names it, and the next gated run will say. Claude Code's binary holds a
second kitty graphics probe (`s=1,v=1,a=q,t=f,f=32`) beside the `t=d,f=24` one whose reply was logged: a likely
candidate, not confirmed. The slice's four gated runs are spent.

## Sealed copies: the measurement (2026-11-13)

Stage 2's Task 3b, on this machine: kernel 5.15.167.4-microsoft-standard-WSL2, Ubuntu 24.04 under WSL2, 24 cores,
three other builds running beside it. `SealedCopyTests` in `Tests/VibePlatformTests/SealedCopyTests.swift`, run by
`bash scripts/test.sh --filter SealedCopyTests`, and three times more under `scripts/test-under-load.sh --load 24`.

**The measurement holds.** A helper of the test binary, non-dumpable from its first statement, made a sealed copy of
`/bin/sleep` (a memfd, all four seals, `0111`) and started it as a child from `/proc/self/fd/<n>`. From the moment
the child's pid was known until 2 s later the test tried, every 2 ms, `pidfd_getfd` of the child's descriptor 0 and
an open of `/proc/<child>/mem`: 942 of each, every one refused (`EPERM`, `EACCES`), none let through. The same child
started from the readable `/bin/sleep` was taken on the first try of each (955 of 955 when the copy was left
readable, the failing form). So the exec windows of the security document's S6 are closed on this kernel: the
measurement decision 6 rests on passes here.

Also measured there:

- A copy held by a non-dumpable process can't be opened for writing (`EACCES`), `chmod`ded (`EACCES`) or taken
  (`pidfd_getfd`: `EPERM`) by another process of the user; its holder's own `write` and `ftruncate` fail `EPERM`
  (the seals). A copy held by a dumpable process is `chmod`ded and taken, which is why only a hardened process
  makes them.
- A copy runs as it was read after its file is rewritten in place (no process runs the file, so no `ETXTBSY`), and
  the bytes `withBytes` gives are those, not the file's new ones.
- A script's copy left `0555` runs; made `0111` it can't (`/bin/sh` exits 2, refused the read).

**What copies cost** (`VIBE_SEALED_COPY_COST=1 bash scripts/test.sh --filter SealedCopyTests/whatCopiesCost`):

| Copy | Size | Time | `Shmem` |
| --- | --- | --- | --- |
| `vibeswitcher-mcp` (debug) | 56.2 MB | 21 ms | +53.3 MB |
| the test binary (debug, `VibeSwitcherPackageTests.xctest`) | 202.3 MB | 66 ms | +192.5 MB |
| ten copies of the test binary at once | 2,023 MB | 123 ms | +2,100 MB |
| `vibeswitcher-host` (debug) | not built on Linux yet (Task 4); measured once it is | | |

Ten at once take 2.1 GB, under a quarter of a GitHub Ubuntu runner's 16 GB (4 GB): the suites that start hosts as
processes (`ServerChildTests` and the others) needn't run `.serialized` on Linux for the copies' sake. A copy's
memory is gone when its last descriptor closes.

## The session host's tests on Linux: what differed (2026-11-13)

Measured while sorting `VibeHostTests` on this machine (kernel 5.15.167.4-microsoft-standard-WSL2, Ubuntu 24.04, Swift
6.4.2), the stage 2 plan's Task 5b. None of these is the Mac's behaviour changing; each is a thing the tests or the
host took from the Mac:

- **Foundation's file copy doesn't keep the modification date** (swift-corelibs-foundation's `copyItem`: the copy is
  dated when it was made). The host names its launcher copy by that date (`HostBuild.id`), so a host that went back
  after a failed handover said it was the newer build. `Platform.Files.copyKeepingModificationDate` sets the date on
  Linux; the Mac's copy keeps it by itself.
- **`components(separatedBy: "\n")` doesn't split `"\r\n"`** on Linux's Foundation (one `Character`); the Mac's, through
  `NSString`, does. A test reading a terminal's lines drops the carriage returns first.
- **`/bin/sh` is dash**: no function name with a hyphen, no `\x` in `printf`; run with `-i` it doesn't exec a lone
  command (a session's program stays `sh` over `sleep`; `exec sleep` makes it `sleep`); and a background job's
  redirections keep a copy of its stdout (fd 10) until they are all made, so a pipe read to its end waits for the
  job's FIFO to open.
- **Ubuntu's `nc` (OpenBSD's with Debian's patches) keeps the connection after its input ends** until the far end
  closes it; the host doesn't close a client that hasn't hung up. The tests pass `-N` there.
- **Foundation's `Process` didn't see a child end while a process the child started still held what it had inherited**
  (a starter `sh` a zombie with `isRunning` true for 300 s, its background job holding a socket of the test process's).
  Tests that start a process which leaves another behind use `Platform.Spawn` and `waitpid`.
- **No `plutil`**: the fake `claude` of `WorkerToolsTests` reads its config with `python3` where `plutil` is missing.

## A Unix socket's file, from the kernel (2026-11-14, Linux 5.15.167.4-microsoft-standard-WSL2)

- **unix_diag answers here** (`CONFIG_UNIX_DIAG=y`): a `NETLINK_SOCK_DIAG` request (`SOCK_DIAG_BY_FAMILY`) for one
  `AF_UNIX` socket by its sockfs inode number and its cookie (`SO_COOKIE`, which this kernel gives), with
  `UDIAG_SHOW_VFS`, returns `UNIX_DIAG_VFS`: the device and inode of the file the socket is bound to, the same after
  the file is renamed. `Platform.Sockets.boundFile` (`SocketsTests.boundFileIsTheFileTheSocketIsBoundTo`).
- **Its device is the kernel's own `dev_t`** (the file system's `s_dev`: major from bit 20), not `stat`'s: the root
  file system here, 8:32, is 0x800020 to unix_diag and 0x820 in `st_dev`. The shim converts with `makedev`.
- **Its device is the superblock's, which `stat` doesn't always give**: on ext4 and tmpfs here `st_dev` is the same
  device, but on an overlay whose lower and upper layers are two tmpfs mounts (made in an unprivileged user and mount
  namespace) unix_diag gave 0:110 (the overlay's) and `st_dev` 0:111 (the upper layer's); btrfs gives a subvolume's
  own device in `st_dev` (`btrfs_getattr`, not measured here). `/proc/self/mountinfo` gives the superblock's device
  for each mount, and `/proc/self/fdinfo/N` the mount (`mnt_id`) and, from Linux 5.14, the inode number (`ino`) of an
  `O_PATH` descriptor on a socket file (opening it otherwise is `ENXIO`): `Platform.Sockets.boundFile(of:at:)`
  compares those (`HostPathDeviceTests.aSocketOnAFileSystemWhoseStatDeviceIsNotItsOwnIsTheHosts`).
- **Its inode is 32 bits** (`udiag_vfs_ino` is a `__u32`): compared with the low 32 bits of the kernel's (`fdinfo`'s
  `ino`; `st_ino` before 5.14). ext4 here (`/`, which holds the home and `/tmp`), whose inode numbers fit them. A
  path's file whose number passes 32 bits matches on the low bits only, and the host's watch then checks by a
  connection too (`Platform.Sockets.kernelMatch`, `SocketsTests.aKernelMatchOnTheLowBitsOfAnInodePast32BitsIsNotConclusive`).
- **The listener is found by its sockfs inode number** (32 bits) **and its cookie** (`SO_COOKIE`, Linux 4.12): a
  kernel before 4.12 is asked by the number alone, which comes round after 2^32 sockets.
- **`fchmod` of a Unix socket before its `bind` sets the mode of the file `bind` makes** (the kernel takes the socket
  inode's mode, less the umask): `fchmod(fd, 0600)` then `bind` gave a 0600 file under umask 0, 022 and 077; without
  it, 0777 under umask 0. `glibc`'s `fchmodat(…, AT_SYMLINK_NOFOLLOW)` refuses a link (`EOPNOTSUPP`; this kernel has no
  `fchmodat2`, ENOSYS, so glibc 2.39 goes through `O_PATH`).
