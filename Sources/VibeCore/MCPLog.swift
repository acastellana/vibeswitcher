import Darwin
import Foundation

/// The tool server's own log (`vibeswitcher-mcp`): its start, its switches of builds, the tool calls that failed (with
/// the errno when there's one, and the descriptors open then), and why it stopped (its input's end, a read that failed,
/// a signal, a crash). Claude Code says only "connection closed" when a tool server ends: twice on 2026-10-27/28 nothing
/// said why (incident 4). One file per process, `~/.vibeswitcher/debug/mcp-<role>-<pid>.log`, kept through its switches
/// of builds (the pid stays). Names and numbers only, as app health keeps them: never a tool's arguments, a result's
/// text or a message.
///
/// It writes on a descriptor it opens once and keeps, so a process that's out of descriptors (EMFILE) still logs; a
/// file past `maxBytes` is moved to `.1` (the one before goes) and a new one started on the same descriptor number.
public final class MCPLog: @unchecked Sendable {
    /// This process's log, once `start` made it; nil elsewhere (the app, tests), where `note` does nothing.
    nonisolated(unsafe) public private(set) static var current: MCPLog?

    public let path: String
    private let maxBytes: Int
    private let lock = NSLock()
    /// Never another number once open: a new file goes onto it (dup2), so the crash handler's copy stays right.
    private let fd: Int32
    private var size: Int
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// The log at `path`, appended to; nil when it can't be opened.
    public init?(path: String, maxBytes: Int = 256 * 1024) {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        self.fd = fd
        self.path = path
        self.maxBytes = maxBytes
    }

    deinit { close(fd) }

    /// Where a tool server started as `role` (lead, worker, verifier) logs, under `root` (`~/.vibeswitcher`).
    public static func file(role: String, pid: Int32 = getpid(), root: URL = VibePaths.root) -> URL {
        let name = role.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) }) && !role.isEmpty ? role : "unknown"
        return root.appendingPathComponent("debug/mcp-\(name)-\(pid).log")
    }

    /// Makes this process's log (`current`) and watches for crashes: a fatal signal writes a line before the process
    /// ends as it would have. Logs of tool servers older than `keep` go first.
    @discardableResult
    public static func start(role: String, root: URL = VibePaths.root, keep: TimeInterval = 7 * 24 * 3600) -> MCPLog? {
        let file = file(role: role, root: root)
        try? VibePaths.ensurePrivate(file.deletingLastPathComponent())
        prune(folder: file.deletingLastPathComponent(), olderThan: keep)
        guard let log = MCPLog(path: file.path) else { return nil }
        current = log
        log.watchCrashes()
        return log
    }

    /// A line in this process's log, if it has one.
    public static func note(_ text: String) { current?.write(text) }

    public func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = Array("\(stamp.string(from: Date())) \(text)\n".utf8)
        if size > 0, size + line.count > maxBytes { rotate() }
        var sent = 0
        while sent < line.count {
            let count = line[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count > 0 { sent += count } else if count < 0 && errno == EINTR { continue } else { break }
        }
        size += sent
    }

    /// The file moves to `.1`, and a new one takes its descriptor's number. Out of descriptors, it goes on in the old.
    private func rotate() {
        let old = path + ".1"
        unlink(old)
        guard rename(path, old) == 0 else { return }
        let fresh = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fresh >= 0 else { return }
        if dup2(fresh, fd) >= 0 { size = 0 }
        close(fresh)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Removes the tool servers' logs not written to for `age` (each process has its own, so they add up).
    static func prune(folder: URL, olderThan age: TimeInterval, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("mcp-") && (name.hasSuffix(".log") || name.hasSuffix(".log.1")) {
            let path = folder.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) > age { unlink(path) }
        }
    }

    // MARK: Descriptors and errnos, in words

    /// The descriptors this process has open, and how many it may: "fds 14 of 138240". Asks the kernel (no descriptor
    /// needed, so it answers when they've run out).
    public static func descriptors() -> String {
        "fds \(openDescriptors().map(String.init) ?? "?") of \(descriptorLimit())"
    }

    public static func openDescriptors(pid: Int32 = getpid()) -> Int? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var room = max(Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)), 64 * stride)
        // It may have grown between the two asks: a full buffer is asked again with more room.
        for _ in 0..<3 {
            var buffer = [UInt8](repeating: 0, count: room)
            let got = buffer.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard got > 0 else { return nil }
            if Int(got) < room { return Int(got) / stride }
            room *= 2
        }
        return nil
    }

    /// The soft limit on open files, as the kernel applies it (never over kern.maxfilesperproc).
    public static func descriptorLimit() -> Int {
        var limit = rlimit()
        let soft = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? limit.rlim_cur : rlim_t(OPEN_MAX)
        var perProcess: Int32 = 0
        var length = MemoryLayout<Int32>.size
        let cap = sysctlbyname("kern.maxfilesperproc", &perProcess, &length, nil, 0) == 0 && perProcess > 0 ? rlim_t(perProcess) : soft
        return Int(min(soft, cap))
    }

    /// The errnos worth naming in a log line.
    static let errnoNames: [Int32: String] = [
        EPERM: "EPERM", ENOENT: "ENOENT", EINTR: "EINTR", EIO: "EIO", EBADF: "EBADF", ENOMEM: "ENOMEM", EACCES: "EACCES",
        EEXIST: "EEXIST", ENFILE: "ENFILE", EMFILE: "EMFILE", ENOSPC: "ENOSPC", EPIPE: "EPIPE", EAGAIN: "EAGAIN",
        ECONNREFUSED: "ECONNREFUSED", ECONNRESET: "ECONNRESET", ETIMEDOUT: "ETIMEDOUT",
    ]

    /// "errno 9 (EBADF)".
    public static func errnoText(_ code: Int32) -> String {
        "errno \(code)" + (errnoNames[code].map { " (\($0))" } ?? "")
    }

    /// The errno a tool's error text carries, if any: an NSPOSIXErrorDomain code, or one of `errnoNames`' messages
    /// (strerror's words). Only the number leaves the text.
    public static func errnoCode(in text: String) -> Int32? {
        if let match = text.firstMatch(of: #/NSPOSIXErrorDomain Code=(\d+)/#), let code = Int32(match.1) { return code }
        return errnoNames.keys.sorted().first { text.contains(String(cString: strerror($0))) }
    }

    // MARK: Crashes

    /// One line per fatal signal, written by the handler with nothing but write(2) (all it may call), then the signal
    /// again at its default: the process ends (and is reported) as it would have.
    private func watchCrashes() {
        MCPLog.crashFD = fd
        for number in MCPLog.fatalSignals {
            let line = "(time unknown) crashed: signal \(number) (\(String(cString: strsignal(number))))\n"
            MCPLog.crashLines[Int(number)] = strdup(line)
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { number in
                if MCPLog.crashFD >= 0, number > 0, number < 32, let line = MCPLog.crashLines[Int(number)] {
                    _ = Darwin.write(MCPLog.crashFD, line, strlen(line))
                }
                signal(number, SIG_DFL)
                raise(number)
            }
            action.sa_flags = SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(number, &action, nil)
        }
        NSSetUncaughtExceptionHandler { exception in MCPLog.note("crashing: uncaught exception \(exception.name.rawValue)") }
    }

    static let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGSYS]
    nonisolated(unsafe) private static var crashFD: Int32 = -1
    /// Made before any signal comes: the handler only reads them.
    nonisolated(unsafe) private static var crashLines = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 32).initialized()
}

private extension UnsafeMutablePointer where Pointee == UnsafeMutablePointer<CChar>? {
    func initialized() -> Self {
        initialize(repeating: nil, count: 32)
        return self
    }
}
