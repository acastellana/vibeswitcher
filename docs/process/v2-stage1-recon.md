# Stage 1 recon: VibeCore's platform layer

Read-only research on branch `v2`. Marks: **[V]** verified by reading the code, the spike's error list, or this machine; **[I]** inferred, to be checked when built.

## 0. What the plan should know first

Superseded where it names `Platform/Darwin/` and `Platform/Linux/`: the code is one module, `Sources/VibePlatform`.

- **The 34 files are not the whole edit set [V].** 21 files `import Darwin` (7 outside the 34: `ConfigSealCommands`, `HostConnection`, `Steer`, `LeadVault`, `LeadMail`, `LeadBoard`, `LeadBoardArchive`); 51 `Darwin.`-qualified calls sit in 13 files (5 outside the 34: `LeadToolset` ×4, `HostConnection` ×3, `LeadBoardArchive` ×2, `FlakeLedger`, `PassageLink`); 18 files `import CryptoKit`; `SessionOrdering.swift` imports CoreGraphics. About 45 files get at least an import-line edit.
- **The error list hides errors [V].** The compiler stops at the first error in an expression or closure: `ConfigSeal.swift:771` also uses `st_ctimespec` (×2), `TestLock.swift:433` uses `st_mtimespec` inside the closure that failed at 420, and `DiskSpace.swift:303` ("unable to type-check") is a `st_mtimespec`.
- **Terminal names break two path rules on Linux [V].** `VibePaths.stateFile(tty:)` (`Paths.swift:146`) makes `state/<tty>.json`, and `SteerInbox.file` (`Steer.swift:74`) refuses any name that isn't `tty` + letters and digits. Linux's `pts/3` fails both. Proposed: the platform gives a slash-free name (`ttypts3`); a decision for you.
- **`/private/tmp` is hard-coded on the lead's path [V]**: `TestLock.swift:146`, `LoadRecorder.swift:514`, `DiskSpace.swift:81,136,287`. On Linux the folder can't be made, so the heavy-slot lock fails.
- **Swift cannot call `syscall()` (variadic), and glibc hides `renameat2`, `statx`, `struct ucred`, `ptsname_r`, `POSIX_SPAWN_SETSID` behind `_GNU_SOURCE` [V for SETSID and ptsname_r by the spike's errors; I for the rest].** Either a small C shim target imported only inside `Platform/`, or constants by value plus `@_silgen_name`. The shim is the safer one for musl. A decision for you.
- **For Mac-only files, move the whole file** (`git mv` into `Platform/Darwin/`, wrapped in `#if`): git's rename detection then carries main's daily edits into it. Splitting a file makes every later edit from main to a moved block a hand merge.

## 1. Proposed services

Superseded where it names `Platform/Darwin/` and `Platform/Linux/`: the code is one module, `Sources/VibePlatform`.

Layout: `Platform/Platform.swift` (`public enum Platform {}` and neutral types), `Platform/Darwin/<Service>+Darwin.swift` (existing code moved), `Platform/Linux/<Service>+Linux.swift` (`#if canImport(Glibc) import Glibc #elseif canImport(Musl) import Musl`). Static functions, not protocol objects: the process table is read 1,500 times a poll, and the existing closure seams already serve the tests. No type named `Platform` or `Sys` exists today [V].

### 1.1 Libc names (`Sys`) and imports

```swift
public enum Sys {
    public static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int
    public static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int
    @discardableResult public static func close(_ fd: Int32) -> Int32
    public static func pipe(_ fds: UnsafeMutablePointer<Int32>) -> Int32
    @discardableResult public static func kill(_ pid: pid_t, _ signal: Int32) -> Int32
    public static func open(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32
    public static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32
    public static func listen(_ fd: Int32, _ backlog: Int32) -> Int32
    public static func truncate(_ path: String, _ length: off_t) -> Int32
}
```

- Call sites: `Darwin.x(` becomes `Sys.x(`, 51 sites in 13 files (close 17, write 12, read 8, pipe 6, kill 4, one each of truncate, open, listen, connect) [V]. `import Darwin` is deleted in 21 files; Foundation re-exports libc on both systems [I].
- CryptoKit (18 files, 6 test files): either one `@_exported import CryptoKit`/`Crypto` in `Platform/` and the 18 lines deleted [I: that an exported import in one file serves the whole module], or a Linux-only target *named* `CryptoKit` that re-exports `Crypto`, with no edits at all.

### 1.2 Spawn: one wrapper for the 9 sites

```swift
extension Platform {
    public struct Spawn {
        public enum Stdio { case inherit                      // the parent's descriptor of that number
                            case descriptor(Int32)            // dup2
                            case path(String, flags: Int32, mode: mode_t = 0)
                            case sameAsStdin }                // dup2(0, n) in the child
        public enum Group { case inherit, ownGroup, ownSession }
        public enum SignalDefaults { case all, only([Int32]) }
        public var executable: String
        public var arguments: [String]                 // argv, argv[0] included
        public var environment: [String]? = nil        // "K=V"; nil: this process's
        public var directory: String? = nil
        public var stdin = Stdio.inherit, stdout = Stdio.inherit, stderr = Stdio.inherit
        public var keep: [Int32]? = []                 // other descriptors kept; nil: all not close-on-exec
        public var group = Group.inherit
        public var defaults = SignalDefaults.all       // always with an empty signal mask
        public init(executable: String, arguments: [String])
        public func start() -> Result<pid_t, Platform.Errno>   // posix_spawn's code; ENOENT stays ENOENT
        public func replaceProcess() -> Int32                   // returns an errno only when it failed
    }
    public struct Errno: Error, Equatable { public var code: Int32 }
}
```

Actions apply in the order stdin, stdout, stderr, chdir (the PTY site needs 0 opened before it is duplicated).

| Site [V] | stdin | stdout | stderr | keep | group | signals | chdir, env |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `AccountUsage.swift:387-417` `runCommand` (`/bin/sh -c`) | pipe | pipe | `/dev/null` O_WRONLY | none | own group | defaults only TERM, HUP, INT, PIPE | environ |
| `MCPKeeper.swift:209-227` `spawn` | pipe | pipe | inherit | none | inherit | all | environ |
| `MCPServer.swift:297-314` `probe` | state fd | pipe | inherit | none | inherit | all | environ |
| `MCPServer.swift:354-378` `exec` (SETEXEC) | inherit | inherit | inherit | `[stateFD]`, unmarked close-on-exec first, re-marked on failure | inherit | all | own envp |
| `Worktrees.swift:400-422` `Shell.Spawned` | `/dev/null` | pipe | pipe | none | own session, or own group | all | chdir, dictionary env |
| `VibeHost/HostHandover.swift:165-180` `probe` | `/dev/null` | pipe | inherit | none | inherit | all | environ |
| `VibeHost/HostHandover.swift:221-243` `exec` (SETEXEC) | inherit | inherit | inherit | list, or nil (then no CLOEXEC_DEFAULT) | inherit | all | environ |
| `VibeHost/PTYSpawn.swift:59-82` | the pty's path O_RDWR (becomes the controlling terminal) | same as stdin | same as stdin | none | own session | all | chdir, own env |
| `VibeHost/SessionParser.swift:260-279` | socket | `/dev/null` O_WRONLY | inherit | none | own group | all | env `PATH=/usr/bin:/bin` |

The Mac app's tenth site (`VibeSwitcher/HostClient.swift:301-321`) fits the same struct and is left alone.

- **macOS**: the existing calls moved (optional attribute types, `POSIX_SPAWN_CLOEXEC_DEFAULT`, `addinherit_np`, `SETEXEC`).
- **Linux**: attribute and action types aren't optional. `sigset_t = ~0` doesn't compile; `sigfillset` does. `POSIX_SPAWN_SETSID` is 0x80 by value. `addchdir_np` resolves on glibc [V: the spike's error at `Worktrees:417` is only the pointer type]. "Nothing else open": `posix_spawn_file_actions_addclosefrom_np(3)` on glibc 2.34+ [I]; on musl list `/proc/self/fd` and add a close for each [I]. `.inherit` is `adddup2(n, n)`, which clears close-on-exec [I].
- **`replaceProcess` differs semantically**: Linux has no `SETEXEC`. It resets handlers and the mask, marks every descriptor outside `keep` close-on-exec, calls `execve`, and undoes all of it on failure. Not atomic: other threads run during the window.

### 1.3 Processes

```swift
extension Platform {
    public enum Processes {
        public enum State: Sendable { case starting, running, sleeping, stopped, zombie, unknown }
        public struct Record: Sendable {
            public var pid, ppid, pgid: Int32
            public var uid: uid_t?                // nil: owner not readable (macOS's kernel-record fallback)
            public var name: String               // kernel name
            public var terminal: String?          // slash-free; see Terminals
            public var foregroundGroup: Int32?
            public var start: timeval
            public var state: State
            public var exiting: Bool              // PROC_FLAG_INEXIT, P_WEXIT | PF_EXITING, state X
            public var execd: Bool                // PROC_FLAG_EXEC | not PF_FORKNOEXEC
        }
        public enum Read: Sendable { case record(Record), partial(ppid: Int32, name: String), unreadable, gone }
        public static func allPids() -> [pid_t]?
        public static func record(_ pid: pid_t) -> Read
        public static func arguments(_ pid: pid_t) -> [String]      // empty: unreadable
        public static func environment(_ pid: pid_t) -> [String]?
        public static func cwd(_ pid: pid_t) -> String?
        public static func executable(_ pid: pid_t) -> String?
        public static func openFiles(_ pid: pid_t) -> [String]
        public static func openDescriptorCount(_ pid: pid_t) -> Int?
        public static func children(_ pid: pid_t) -> [pid_t]
        public static func cpuSeconds(_ pid: pid_t) -> Double?
        public static func residentBytes(_ pid: pid_t) -> Int64?
    }
    public enum Terminals {
        public static func name(devicePath: String) -> String       // "/dev/ttys009" -> "ttys009"; "/dev/pts/3" -> "ttypts3"
    }
}
```

- Used by 11 files [V]: `ProcessTable` (all of it), `ProcessUsage:65,68,81`, `DiskSpace:343-364`, `Worktrees:2217-2232`, `MCPLog:109-119`, `StallWatch:166-199`, `LoadRecorder:532-549`, `TestLock:219-221,473-476`, `SessionStrays:35,85,106-109,163-166`, `WalletCourier:449-452`, `WalletLocalLink:182-184`. Each outside block of 3 to 6 lines becomes one call. There are three copies of "cwd of a pid" and three fd-list readers today; all become one call each.
- **macOS**: `proc_listallpids`, `proc_pidinfo` (full record, then short record plus `sysctl KERN_PROC_PID`, then the kernel record alone), `KERN_PROCARGS2` with `parse(procargs:)`, `proc_pidpath`, `PROC_PIDLISTFDS`, `proc_listchildpids`, `TerminalNames` (`devname`). All moved.
- **Linux**: numeric entries of `/proc`; `/proc/<pid>/stat` parsed from the last `)` (the name may hold spaces and brackets): state, ppid, pgrp, tty_nr, tpgid, flags, utime, stime, starttime. Owner from `stat("/proc/<pid>")`. `cmdline`, `environ`, `readlink` of `cwd`, `exe` and each `fd/*` (keep those starting with `/`). Children by scanning ppid.
- **Differences**:
  - Start time: ticks since boot (10 ms) added to `/proc/stat`'s `btime`, against microseconds on macOS. `btime` moves when the wall clock is stepped (WSL2 after the host sleeps), so read it once per process. Equality within a process holds (`Shell.signalFamily`, `SessionStrays.isRunning`); values kept in files and compared later can drift (`WalletCourier.ListenRecord`, `TestLock.isGone`, which allows 3 s).
  - CPU time is in 10 ms ticks (`sysconf(_SC_CLK_TCK)`), not Mach units; `StallWatch.cpuShare` of 1 % over 30 s still resolves.
  - A zombie is state `Z` with an empty `cmdline` and no `exe`.
  - Another user's `cmdline` is readable on Linux (not on macOS), unless `/proc` is mounted `hidepid`; `environ`, `cwd`, `exe`, `fd` are the owner's only on both. So `identify`'s "another user's is an agent only by name" rule stays in `ProcessTable`, not in the platform.
  - The exec window (`identityUnknown`, the retry pause) hardly occurs on Linux: `cmdline` reads the old or the new argv.
  - The kernel name is 15 characters (16 on macOS) and a thread can rename it.
  - `/proc/<pid>/exe` reads `… (deleted)` after the binary is replaced: `SessionStrays.runs(_:executable:)` compares for equality and would miss a process running a replaced build.

### 1.4 Clocks

```swift
extension Platform { public enum Clock {
    public static func awakeSeconds() -> TimeInterval      // CLOCK_UPTIME_RAW | CLOCK_MONOTONIC
    public static func threadCPUNanoseconds() -> UInt64    // CLOCK_THREAD_CPUTIME_ID
} }
```

Sites: `MacTime.swift:13`, `LoadRecorder.swift:396,416` [V]. Linux's `CLOCK_MONOTONIC` doesn't count suspend (matching `CLOCK_UPTIME_RAW`); macOS's own `CLOCK_MONOTONIC` does, so the names must not be unified. The four `mach_timebase_info` sites (`ProcessUsage:56`, `StallWatch:180`, `TestLock:214`, `LoadRecorder:521`) disappear into `Processes.cpuSeconds`.

### 1.5 Host: memory, load, cores, disk, limits

```swift
extension Platform { public enum Host {
    public static func memoryPressureLevel() -> Int32?            // 1, 2, 4 as macOS; nil: unknown
    public static func memoryFreePercent() -> Int?
    public static func swapUsage() -> (used: UInt64, total: UInt64)?
    public static func swapOuts() -> UInt64?                       // pages since boot
    public static func volumeFree(at path: String) -> Int64?
    public static func descriptorLimit() -> Int
} }
```

- Sites: `MacMemory.swift:98-123` (three functions become forwards), `LoadRecorder.swift:493-508`, `DiskSpace.swift:46-48`, `MCPLog.swift:124-131` [V].
- macOS: `sysctlbyname`, `host_statistics64`, `statfs`, `getrlimit` capped by `kern.maxfilesperproc`.
- Linux: `/proc/meminfo` (SwapTotal, SwapFree, MemAvailable), `/proc/vmstat` `pswpout`, `statvfs` (`statfs` isn't in Swift's Glibc module [V]), `getrlimit`. Pressure from `/proc/pressure/memory` where it exists: **it does not on this machine** (WSL2 5.15) [V], so it reads nil, which `MacMemory.shortage` already treats as "no hold". `pswpout` is here [V].
- `getloadavg` and `ProcessInfo.activeProcessorCount` (`MacLoad.swift:48,55`) compile unchanged [V]. Linux's load average also counts tasks waiting on I/O.

### 1.6 `stat` fields

**Superseded (2026-11-12):** the `extension stat` below can't be used from another module on Linux (each C module
holds its own copy of glibc's `stat`, and a file may see CoreFoundation's first). The functions are
`Platform.Files.modified(_:)`, `changed(_:)`, `inode(_:)`, `byteSize(_:)`, taking the `stat`.

```swift
extension stat {                                   // in Platform/
    public var modified: timespec { get }          // st_mtimespec | st_mtim
    public var changed: timespec { get }           // st_ctimespec | st_ctim
    public var inode: UInt64 { get }
    public var byteSize: Int64 { get }
}
extension Platform.Files { public static func birthTime(_ path: String) -> Double? }
```

22 uses in 12 files [V]: `ConfigSeal:771` (×4), `:844`; `ConfigSealDetails:252`; `DiskSpace:303`; `HookInstaller:238-241`; `LeadTokenLedger:206`; `MCPLog:97`; `MCPServer:154`; `Paths:260`; `SetupStats:527`; `TestLock:433`; `TranscriptReader:1025-1028`. Each is a rename (`info.st_mtimespec.tv_sec` to `info.modified.tv_sec`). Birth time on Linux needs `statx`; ext4 and btrfs record it, tmpfs and 9p don't. `LeadTokenLedger.born` already returns nil for "not known", so nil is a correct first form.

### 1.7 Sockets and peers

```swift
extension Platform {
    public enum Sockets {
        public static func unixAddress(_ path: String) -> sockaddr_un?   // nil: too long; sets sun_len on macOS only
        public static var stream: Int32 { get }                           // SOCK_STREAM (an enum in glibc)
        public static func noSigPipe(_ fd: Int32)                         // SO_NOSIGPIPE, F_SETNOSIGPIPE | nothing
        public static func peerUID(_ fd: Int32) -> uid_t?
        public static func peerPID(_ fd: Int32) -> pid_t?
        public static func peerToken(_ fd: Int32) -> PeerToken?
    }
    // macOS: typealias PeerToken = audit_token_t (its pid, pidVersion, sameImage extension moves here)
    // Linux: struct PeerToken { pid; uid; startTicks; func sameImage(as:) }
}
```

- Sites: `UnixSocket.swift:24,55,78,103,110,118,128` and its `audit_token_t` extension; `F_SETNOSIGPIPE` at `AccountUsage:428`, `MCPKeeper:239,287`, `MCPServer:677`, `vibeswitcher-mcp/main.swift:53`; VibeHost names the type at `ClientConnection:14`, `HostServer:665`, `AppCode:11` [V].
- Linux: `SO_PEERCRED` read into three `Int32` (pid, uid, gid).
- **Differences**: the macOS token names whichever process last used the socket and changes at exec; `SO_PEERCRED` is fixed at `connect()` and never changes, and "same pid and start time" doesn't notice an exec. `HostServer.swift:646` relies on the macOS meaning: stage 2's question.
- **SIGPIPE**: Linux has no per-descriptor switch. The host, hook and keeper ignore it and the tool server catches it [V], but a **test process** writing to a closed socket or pipe would be killed. The test bundle's load hook must ignore SIGPIPE on Linux, or socket writes go through `send(MSG_NOSIGNAL)`.
- Path limit: 104 bytes on macOS, 108 on Linux; the code measures `sun_path` [V].

### 1.8 Files: exclusive rename, locked create, temporary root

```swift
extension Platform { public enum Files {
    public static func renameExclusive(in directory: Int32, from: String, to: String) -> Int32  // -1 and EEXIST when `to` exists
    public static func createLocked(_ path: String, mode: mode_t) -> Int32                       // made and flocked at once
    public static var eventsOnly: Int32 { get }                                                  // O_EVTONLY | O_RDONLY
    public static var sharedTemporaryRoot: String { get }                                        // "/private/tmp" | "/tmp"
} }
```

- Sites: `LeadLaunch:297` (a folder), `WalletLocalLink:252` (a file); `TestLock:407`; `WalletLocalLink:123`; the five `/private/tmp` lines [V].
- `renameat2(RENAME_NOREPLACE)` has the same meaning as `renameatx_np(RENAME_EXCL)`; some filesystems (9p, WSL's `/mnt/c`) refuse it with EINVAL [I]; `link` then `unlink` covers files only.
- **`O_EXLOCK` is a real race on Linux**: `TestLock.waiters()` (`:415-424`) unlinks any ticket it can flock. With create-then-flock, a live ticket can be removed in the gap. Linux form: create under a name that doesn't start `ticket-`, flock it, `link` it to the ticket's name, unlink the first name (the lock stays with the open file).
- `flock` itself (25 sites) is unchanged [V]. `MAXPATHLEN` at `WalletLocalLink:279` can become `PATH_MAX` with no platform code [I].

### 1.9 Watching

```swift
extension Platform {
    public final class FolderWatch: @unchecked Sendable {
        public struct Change: OptionSet, Sendable { public static let entries, folderGone: Change }
        public init?(path: String)
        public init?(descriptor: Int32)                 // takes over an open folder
        public func wait() -> Change?                   // blocks; nil once stopped
        public func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void)
        public func stop()
    }
    public enum ProcessExit {                           // VibeHost ×3: HostServer:199, HostedSession:348, SessionParser:59
        public static func watch(_ pid: pid_t, queue: DispatchQueue, _ ended: @escaping @Sendable () -> Void) -> any Platform.Cancellable
    }
    /// AccountUsage.runCommand's whole body.
    public static func pipeCommand(_ command: String, input: Data, patience: TimeInterval, stopSignals: [Int32]) -> Data
}
```

- `LeadAdvance.swift:177-209` (a kqueue on the board folder, on its own thread, stopped through a pipe at `:224`) becomes `FolderWatch(path:)` and a `wait()` loop: about 25 lines change. `WalletLocalLink.swift:346-400` uses `deliver(on:)`.
- macOS: the kqueue and the dispatch source, moved.
- Linux: inotify with `IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO` for entries and `IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT` for the folder; a descriptor is watched through `/proc/self/fd/<n>` [I].
- **Differences**: kqueue with `EV_CLEAR` merges changes into one event; inotify queues every one, so drain before answering. A folder's `NOTE_WRITE` doesn't fire for a write inside an existing file, so don't add `IN_MODIFY`. inotify doesn't work on 9p.
- Process exit on Linux: `pidfd_open` and a read source (kernel 5.3+; needs the shim or glibc 2.36's wrapper).
- `pipeCommand` on Linux: `poll` on the pipes and a pidfd, with SIGPIPE and the stop signals blocked on that thread and read by `sigtimedwait` [I].

### 1.10 Signals, limits, crash notes

```swift
extension Platform { public enum Signals {
    public static func onFatal(_ signals: [Int32], _ handler: @escaping @convention(c) (Int32) -> Void)   // SA_RESETHAND
    public static func onUncaughtException(_ note: @escaping @Sendable (String) -> Void)                  // nothing on Linux
} }
```

`MCPLog.swift:161-173` (the `__sigaction_u` union, `sa_flags`' type, `NSSetUncaughtExceptionHandler`); `vibeswitcher-host/main.swift:153-159` needs the three-argument form. `strsignal` says "Killed: 9" on macOS and "Killed" on Linux: `MCPKeeperTests:64,155,186` expect the Mac's words [V].

### 1.11 Small ones

```swift
extension Platform {
    public static func isBoolean(_ number: NSNumber) -> Bool      // CodexUsage:137, SetupStats:814, 1004
    public static func plainInline(_ markdown: String) -> String? // ActivityFeed:111-112
}
```

- Randomness needs no service: `WebPush.swift:94-96` becomes `SystemRandomNumberGenerator` on both systems (used by `RemoteAccess:42,60` for pairing tokens).
- `Redaction.swift:1037`: unwrap `baseAddress` portably; no platform code.
- Linux `isBoolean`: `objCType` is `c` [I; what `JSONSerialization` yields for `true` on Linux must be tested].

### 1.12 Settings

```swift
public protocol SettingsStore: AnyObject {
    func object(forKey: String) -> Any?
    func string(forKey: String) -> String?
    func bool(forKey: String) -> Bool
    func dictionary(forKey: String) -> [String: Any]?
    func set(_ value: Any?, forKey: String)
}
extension Platform { public static func settings(domain: String = "dev.vibeswitcher.VibeSwitcher") -> (any SettingsStore)? }
// macOS: extension UserDefaults: SettingsStore {}; Linux: a property list at ~/.vibeswitcher/settings.plist
```

Seven lines [V]: `Pausing.swift:13,18`; `LeadMail.swift:82`; `vibeswitcher-mcp/main.swift:76,94,238,453`. Line 238 reads `claudeCommand` and `codexCommand`, the command workers start with: on the lead's path. `UserDefaults` compiles on Linux today, so this isn't needed for a green build. `PauseStore` keeps dates, so the file must be a property list, not JSON.

### 1.13 Tools

```swift
extension Platform { public enum Tools {
    public static var git: String { get }                 // "/usr/bin/git" | first on PATH, found once
    public static var branchShell: [String] { get }       // ["/bin/zsh", "-f"] | ["/bin/bash", "--noprofile", "--norc"]
    public static var loginShell: String { get }          // fallback when $SHELL is unset: "/bin/zsh" | "/bin/bash"
    public static func find(_ name: String, path: String?) -> String?
    public static func missing() -> [String]              // checked at start
} }
```

All sites [V]:
- git: `Git.swift:39,257,278,401`; `LeadRemote.swift:114,122,133,367`; `LaunchPreflight.swift:53` (and the texts at `:232,240`).
- zsh: `Worktrees.swift:126` (`BranchCode.wrapper`), `:183`, `:1385`, `:1410` (`-lc`); `TeamSummaries.swift:209`; `LoginShell.swift:25`; `vibeswitcher-host/main.swift:29`.
- Left as they are: `/bin/sh` (`AccountUsage:406,417`), `/usr/bin/tar` and `/bin/bash` (`ProductInventory:55-56`), `/usr/bin/printenv` (`LoginShell:22`): all present on Ubuntu [V here].
- Mac-only: `xcode-select`, `xcrun`, `pkgutil` (`ToolchainWatch:51-59`, `ToolInstall:12`, `LaunchPreflight:53`).
- This machine has `/usr/bin/git` and no `/bin/zsh` [V]. `BranchCode.isRunner` compares argv with `wrapper`, so both must come from the one value. `bash -lc` reads `.profile`, not `.bashrc`, where nvm usually puts PATH.

### 1.14 Mac-only services

- **Keychain** (`LeadVaultAppProof.swift:35-62,84-125,153-166`): `KeychainStore`, `KeychainSecret`, `appOnlyAccess` move as an extension of `AppProof` to `Platform/Darwin/`. Only the Mac app makes them (`KeychainLintTests` asserts it; its expected path changes). Linux has none; the app's key there is stage 2's.
- **Images**: `Platform.Images.pixelSize(of: URL) -> (width: Int, height: Int)?` and `pngThumbnail(of: URL, maxSide: Int) -> Data?` (`LeadImages.swift:124-150`). Linux reads PNG, JPEG, GIF and WebP headers and returns nil for a thumbnail.
- **MenuBarDots**: only `StatusMark.body(in:)` and `glyph(in:)` (`:145-205`, `CGPath`) fail; they move to `Platform/Darwin/`. The geometry compiles on Linux (Foundation has `CGRect`).
- **PreviewProxy**: the whole file is Network.framework and only the Mac app makes one (`VibeSwitcher/DevPreviews.swift:176`). `git mv` it.

## 2. The 34 files

| File | Services | Kind | What stays |
| --- | --- | --- | --- |
| ProcessTable | Processes, Terminals | **structural** | `ProcInfo`, `snapshot`, `trySnapshot`, `readTable`, `Record`, `retry`, `identify`, `agent`, `ArgumentCache`, `BoundedReads`, `ancestors`, `ancestry`, `agentRuns`, `shells`; `record`, `info`, `cwd`, `names`, `holdsForeground`, `residentBytes`, `readArguments`, `environment` as short maps of `Platform.Processes` (tests call them by name). `parse(procargs:)`, `TerminalNames` and the kernel reads move |
| LeadVaultAppProof | Keychain | **structural** | challenge, answer, `MemoryStore`, `MemorySecret`, both protocols |
| PreviewProxy | (Network) | **structural**: whole file moves | nothing |
| MCPServer | Spawn ×2, stat, noSigPipe, Sys | mechanical: two blocks of 15 lines become struct literals | probe's wait loop, the handover |
| AccountUsage | pipeCommand, Sys | **structural** for `runCommand` (lines 386-490) | a one-line forward; the other 550 lines |
| Worktrees | Spawn, Processes.openFiles, Tools, Sys | mechanical | `Spawned`'s reaping and status |
| DiskSpace | Host.volumeFree, stat, Processes, temporary root | mechanical | everything else |
| LeadImages | Images | mechanical: two guards and the loop's inner call | the downscale loop, pruning |
| ProcessUsage | Processes | mechanical: three blocks | `ProcUsage`, the bounded read |
| MCPKeeper | Spawn, noSigPipe, Sys ×16 | mechanical | the relay |
| StallWatch | Processes | mechanical: `tree`'s two reads; `state(_:)` maps the platform's enum | the judge |
| LoadRecorder | Clock, Host, Processes, temporary root | mechanical: five blocks | the recorder |
| LeadAdvance | FolderWatch, Sys | small structural: `start()` and the stop pipe | the loop |
| WalletLocalLink | Processes, Files, FolderWatch | mechanical | the folder checks, `WalletFolderWatch`'s debounce |
| UnixSocket | Sockets | **structural** but small: nearly every body becomes a forward | `Failure`, the connect retry, `listen`'s order |
| MacMemory | Host | mechanical: three bodies | all the logic and `SwapSamples` |
| MCPLog | Processes, Host, Signals, stat | mechanical: five places | the log |
| TestLock | Processes, Files.createLocked, stat, temporary root | mechanical | all else |
| SessionStrays | Processes | mechanical: four places | all else |
| MenuBarDots | (CoreGraphics) | **structural**: two functions move | layout, hit-testing, palette |
| SetupStats, CodexUsage | isBoolean, stat | mechanical | |
| WalletCourier | Processes | mechanical: one block | |
| ActivityFeed | plainInline | mechanical: two lines | |
| MacTime | Clock | mechanical: one line | |
| TranscriptReader, HookInstaller, ConfigSeal, ConfigSealDetails, Paths, LeadTokenLedger | stat | mechanical | |
| LeadLaunch | Files.renameExclusive | mechanical: one line | |
| WebPush, Redaction | none: portable edits | mechanical | |

## 3. Needed for the bootstrap, or stubbed first

**Needed, real**: Sys and imports; Spawn; Processes (with Terminals); Clock; Host (load, cores, disk; memory may read nil); stat; Sockets with `peerUID` and `peerPID`; Files (all four); FolderWatch by path; Signals; Settings; Tools; the small ones.

**Stubbed first**, and what callers then do [V unless marked]:

| Stub | Callers |
| --- | --- |
| PreviewProxy absent | None in the portable targets; `DevPreviewTests`, `DevPreviewHardeningTests` and `CookieJarTests` (an extension of `PreviewProxyTests`) marked Mac-only |
| `Images.pngThumbnail` nil | `KeptImages.keep` throws its existing refusal for an image over 5 MB ("doesn't downscale under …: crop it or send a smaller one") |
| `StatusMark` paths absent | Only `VibeSwitcher/StatusStyle.swift` draws them |
| Wallet watch (`FolderWatch(descriptor:)` nil) | `WalletLocalLink.watch` throws its "can't be watched" failure; only the app makes a `WalletLocalLink` |
| Keychain absent | Nothing portable makes one |
| `pipeCommand` returns no data | `runCommand` documents "empty when it couldn't be started": the user's own status line isn't shown |
| Memory pressure nil | `MacMemory.shortage` holds on nothing; the text reads "memory pressure unknown" |
| `birthTime` nil | `LeadTokenLedger.born` returns nil, as documented |
| `peerToken` nil | `HostServer.swift:646` skips its same-image check: stage 2 |
| Web push | Needs no stub once `randomBytes` is portable |
| Power | No code in VibeCore (no IOKit import); a new service later |

## 4. Tests

Of 236 files in `Tests/VibeCoreTests`, **29 hold Darwin-only imports or calls** [V]:
- 16 `import Darwin`: `EndedSessions`, `HookBounds`, `MCPKeeper`, `HeavyJobs`, `FailFastSessions`, `StallWatch`, `HeavySlots`, `IndexLock`, `ZombieWatch` (helper), `LeftoverCheck`, `MacSleepLimits`, `TestLock`, `MCPHandover`, `MCPLog`, `ProcessTable`, `ZombieWatchTests`.
- Frameworks: Network (`DevPreviewTests`, `DevPreviewHardeningTests`), Security (`KeychainLiveTests`), ImageIO and UTType (`KeptImagesTests`), CoreGraphics (`StatusAccessibilityTests`), ObjectiveC (`PreferenceLedger`).
- Darwin calls through Foundation: `WorktreesTests:1087-1113` (its own kqueue), `AppHealthTests:476`, `RedactionLeakTests:191`, `HookBoundsTests:102` (`clock_gettime_nsec_np`), `ConfigSealPluginTests:485-489` (`st_*timespec`), `TestScriptWidthTests:56` (`sysctlbyname`), `LeadRecordsTests:235` (`Darwin.read`), `IndexLockTests:149` and `ZombieWatch.swift:61` (`kinfo_proc`).
- Beyond those: 6 files import CryptoKit, 19 mention zsh, 76 name a tool by absolute path (mostly ones Ubuntu has), 80 run git.

| Service | Tests on the moved code |
| --- | --- |
| Processes | `ProcessTableTests` (16 tests; reaches `record`, `readTable`, `readArguments`, `parse`, `TerminalNames`: the last two Mac-only), `SessionDetectionTests` (34; fixtures, portable), `HeavyJobsTests`, `SessionStraysTests`, `HookBoundsTests`, `IndexLockTests`, `SecurityTests`, `VibeCoreTests`. **`OpenPaths` and `StallWatch.tree` have no direct test** |
| Spawn | `Shell.run` in 16 files (41 calls), `MCPKeeperTests`, `MCPHandoverTests`, `AccountUsageTests`, `VerifierIsolationTests` |
| Clock | `MacTime` in 7 files and `TestSupport` |
| Host | `MacMemoryTests`, `LoadRecorderTests`, `DiskSpaceTests`, `MCPLogTests` |
| stat | `UnchangedFilesTests`, `HookInstallerTests`, `LeadTokenLedgerTests`, `ConfigSeal*Tests`, `MCPServerTests` |
| Sockets | Only `LaunchPreflightTests` names `UnixSocket` here; the real cover is in `VibeHostTests` |
| Files | `TestLockTests` (42), `HeavySlotsTests`, `VerifierIsolationTests`, `WalletLocalLinkTests` |
| FolderWatch | `LeadAdvanceTests`, `WalletLocalLinkTests` |
| Settings | `PreferenceLedger`, `PreferencesLintTests`, `TestSupport.Scratch.defaults` |
| Tools | `LaunchPreflightTests`, `LoginShellVariableTests`, `GitGuardTests`, `TeamSummariesTests` |
| Images, dots, proxy, Keychain | `KeptImagesTests`, `LeadDoneEvidenceTests`; `StatusAccessibilityTests`; `DevPreview*Tests`; `AppProofTests`, `KeychainLintTests`, `KeychainLiveTests` |

**`TestSupport.swift` [V].** Two `@_used @_section("__DATA,__mod_init_func")` constants of type `@convention(c) () -> Void`, run as the bundle loads, before any test:
1. `refuseTheAccountRoot` sets `homeGuardRan = true`, asks `VibePaths.testRefusal()`, and when the VibeSwitcher folder resolves to the account's own `~/.vibeswitcher` writes the refusal to stderr and calls `exit(78)`. Checked by `HomeIsolationTests.swift:103` and by `TestHomeGuardTests` in the other two targets.
2. `fakeTheDisk` sets `DiskSpace.testRun` so every volume read answers 1 TB and records an issue.

The Linux form must:
- put the same two closures in `.init_array` (the Mach-O name compiles on Linux and never runs; an ELF name won't compile on macOS, so the attribute needs an `#if` in each of the three `TestSupport.swift` files, which are outside the lint's scope);
- keep `homeGuardRan` and the exit code;
- ignore SIGPIPE there (1.7);
- use a file-backed settings store in `Scratch.defaults`.

Risk [I]: the closures call Foundation before `main`; the spike showed only that such an initializer runs. `VibePaths.home` relies on `NSHomeDirectory()` honouring `CFFIXED_USER_HOME` on Linux [I].

## 5. Order of slices

To a green `swift build --target VibeCore`, smallest risk first; each slice moves the Mac code, adds the Linux form (real where trivial), switches the call sites, and has a test on both systems:

1. **Scaffold**: `Platform`, `Sys`, the import lines, the CryptoKit decision, `PlatformLint` with a shrinking list of files still to do, the test guard's Linux form.
2. **stat and the small ones** (stat, `isBoolean`, `plainInline`, random, `memchr`, Signals): about 45 errors, 14 files clean, all real on Linux.
3. **Clock and Host** (about 35 errors), real except pressure.
4. **Sockets and Files** (about 20), real except `peerToken`.
5. **Spawn** (74 here, 62 more in VibeHost later), real on both: the most widely tested piece.
6. **Processes** (177): the API, the Mac code moved, `ProcessTable` reshaped; the Linux form may first answer nil from `allPids` (every caller handles "table unread").
7. **Watching** (about 40): `FolderWatch`, `pipeCommand`; Linux may first be a stub.
8. **Mac-only moves** (about 120): PreviewProxy, Keychain, Images, `StatusMark`. The build is green here.

Then real, one at a time: Tools and the temporary root (they unlock the 80 test files that run git) → Processes on `/proc` → `FolderWatch` on inotify → Settings file → Host memory → `pipeCommand` → `createLocked` and `renameExclusive` checked on tmpfs and 9p → birth time.

## 6. Hard or surprising on Linux

- **Terminal names**: `Paths.swift:146`, `Steer.swift:74`, `ProcessTable.swift:428`, `VibeHost/HostedSession.swift:162`.
- **`/private/tmp`**: `TestLock:146,586`; `LoadRecorder:514`; `DiskSpace:81` (Claude Code's scratch is `/tmp/claude-<uid>` on Linux [V: this session's own path]), `:136`, `:287`; `Steer:378` and `TrustPrompt:17` strip `/private` (harmless); `DebugOutput:11`.
- **`Resources/bin/vs-heavy`**: `:109` `/private/tmp`, `:114` `sysctl -n hw.ncpu`, `:312` `ps -o etime=`, `:384` `/usr/sbin/sysctl -n vm.loadavg`, `:404` `/bin/ps -x -o pid=,ppid=,pgid=,time=,lstart=` (BSD's `lstart`).
- **Shells**: `Worktrees:126,183,1385,1410`; `TeamSummaries:209`; `LoginShell:25`. `$SHELL -l -i -c` under bash prints job-control warnings without a terminal [I].
- **The `O_EXLOCK` gap** (`TestLock:407` against `:422`) and **the `(deleted)` suffix** (`SessionStrays:85-88`), both in section 1.
- **Stored start times** against a stepped clock: `WalletCourier:443-452`, `TestLock:465-476`.
- **Foundation on Linux [I]**: `DiskSpace.size(of:)` (`:57-64`) reads `totalFileAllocatedSize` and `KeptImages.prune` (`LeadImages:165`) reads `creationDate`; if they come back nil, sizes read 0 and pruning order is lost. Test both first.
- **Mac-only checks that must be skipped, not failed**: `LaunchPreflight:53,229-240` (`xcode-select`, "Apple's stub"), `ToolchainWatch:51-59`, `ToolInstall:12`, `AppHealth:658` (`~/Library/Logs/DiagnosticReports`), `SetupScorecard:133` (`/Applications/`), `PassageCommand:23-29`, `PassageLink:19`, `Paths.swift:84` (`Library/Application Support/wallet-manager`).
- **Not found in the portable targets [V by search]**: `open`, `pbcopy`, `sw_vers`, `pmset`, `codesign`, `defaults`, `launchctl` and `/usr/libexec` as commands run. `osascript`, `caffeinate`, `security` appear only as words in command classifiers (`ConfigSealCommands:141,166`, `RunnableCommand:227`, `LeadLaunch:44`).
- **Case**: no case-insensitive path comparison on the lead's path; `LeadMail:277` compares project names without case on purpose.
- **Errno numbers differ** (EAGAIN 35 and 11, ECONNREFUSED 61 and 111); the code uses the constants [V], no test expects a number [V by search].
