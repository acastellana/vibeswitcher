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
  R10, a real Claude Code session from working to needs-you to done, which waits for the user's Claude Code config
  folder; and R3's confirmation that every `v2 linux` and `v2 macos` job is green on one commit.
