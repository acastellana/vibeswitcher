import Darwin
import Foundation

public struct ProcInfo: Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// Controlling terminal, e.g. "ttys009"; nil for daemons and GUI apps.
    public let tty: String?
    /// Executable name from the kernel (max 16 chars), e.g. "zsh".
    public let comm: String
    public let startTime: Date
    /// Set for terminal-attached `claude` / `codex` processes.
    public let agent: Agent?
}

/// Reads the kernel process table directly via sysctl (no `ps` subprocess, so it is cheap to poll).
public enum ProcessTable {
    // Both lookups below are slow enough to dominate a snapshot of ~750 processes if repeated every
    // poll: devname() scans /dev on every call, and argv needs a sysctl per process. Their answers
    // never change for a given device / process, so they're cached.
    private static let cacheLock = NSLock()
    private static var ttyNames: [dev_t: String?] = [:]
    static let argumentCache = ArgumentCache(read: readArguments)

    static func ttyName(_ device: dev_t) -> String? {
        guard device != -1 else { return nil }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = ttyNames[device] { return cached }
        var name: String?
        if let raw = devname(device, S_IFCHR) {
            let value = String(cString: raw)
            if value != "??" { name = value }
        }
        ttyNames[device] = name
        return name
    }

    public static func snapshot() -> [Int32: ProcInfo] { trySnapshot() ?? [:] }

    /// Every process; nil when the table couldn't be read (not "no processes": callers mustn't act on that as if
    /// every session had ended).
    public static func trySnapshot() -> [Int32: ProcInfo]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer: [kinfo_proc] = []
        var size = 0
        var read = false
        // The table can grow between asking its size and reading it (a build forking hard): ask again, with more room.
        for attempt in 0..<5 where !read {
            var needed = 0
            guard sysctl(&mib, 4, nil, &needed, nil, 0) == 0 else { return nil }
            buffer = [kinfo_proc](repeating: kinfo_proc(), count: needed / stride + 64 << attempt)
            size = buffer.count * stride
            if sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 { read = true } else if errno != ENOMEM { return nil }
        }
        guard read, size > 0 else { return nil }
        var result: [Int32: ProcInfo] = [:]
        for index in 0..<(size / stride) {
            let info = makeInfo(buffer[index])
            result[info.pid] = info
        }
        argumentCache.prune { result[$0] != nil }
        return result
    }

    public static func info(pid: Int32) -> ProcInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        return makeInfo(proc)
    }

    /// Current working directory of a process we own.
    public static func cwd(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Ancestors of `pid`, nearest first (excluding pid itself and launchd).
    public static func ancestors(of pid: Int32, limit: Int = 32) -> [ProcInfo] {
        var chain: [ProcInfo] = []
        var current = info(pid: pid)?.ppid ?? 0
        while current > 1, chain.count < limit, let proc = info(pid: current) {
            chain.append(proc)
            current = proc.ppid
        }
        return chain
    }

    static func makeInfo(_ kinfo: kinfo_proc) -> ProcInfo {
        var proc = kinfo.kp_proc
        let comm = withUnsafePointer(to: &proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let tty = ttyName(kinfo.kp_eproc.e_tdev)
        let start = proc.p_un.__p_starttime
        let startTime = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        return ProcInfo(pid: proc.p_pid, ppid: kinfo.kp_eproc.e_ppid, tty: tty, comm: comm, startTime: startTime,
                        agent: agent(pid: proc.p_pid, start: start.tv_sec, comm: comm, tty: tty, arguments: argumentCache))
    }

    /// Which agent a process is. Claude Code runs as a versioned binary (`~/.local/share/claude/versions/2.1.282`),
    /// so the kernel's `comm` is "2.1.282", not "claude"; argv[0] tells them apart.
    static func agent(pid: Int32, start: Int, comm: String, tty: String?, arguments: ArgumentCache) -> Agent? {
        // Only terminal-attached processes can be sessions; skipping the rest keeps snapshots cheap.
        guard tty != nil else { return nil }
        if let agent = Agent(comm: comm) {
            // Codex's app server (its background daemon, the daemon's pid-update-loop, a stdio server someone
            // started by hand) is the same `codex` binary but runs threads for sessions elsewhere: never one itself.
            return agent == .codex && isCodexAppServer(arguments.arguments(pid: pid, start: start, comm: comm)) ? nil : agent
        }
        return arguments.arguments(pid: pid, start: start, comm: comm).first
            .map { ($0 as NSString).lastPathComponent }.flatMap(Agent.init(comm:))
    }

    /// `codex [options] app-server …`: `--listen unix:// --managed-daemon`, `daemon pid-update-loop`, plain stdio.
    /// (A prompt is one argument, so a session's argv never holds a bare "app-server".)
    public static func isCodexAppServer(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains("app-server")
    }

    /// A process's argv (see `ArgumentCache`).
    public static func arguments(pid: Int32, start: Int, comm: String) -> [String] {
        argumentCache.arguments(pid: pid, start: start, comm: comm)
    }

    static func readArguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // Layout: argc (int32), exec path, NUL padding, argv[0] … argv[argc-1], environment…
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let begin = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[begin..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

/// argv per process, read once: it needs a sysctl per process, too slow to repeat for every process on every poll.
///
/// Keyed on (pid, start time, comm). `exec` keeps the pid and the start time but replaces argv and comm, and window
/// sessions start as `vibeswitcher-host --pty-exec claude …`: a scan in the moment before that exec reads the
/// launcher's argv, and keyed on pid and start alone that answer would hide the session for its whole life.
final class ArgumentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Int32: (start: Int, comm: String, arguments: [String])] = [:]
    private let read: (Int32) -> [String]

    init(read: @escaping (Int32) -> [String]) { self.read = read }

    func arguments(pid: Int32, start: Int, comm: String) -> [String] {
        lock.lock()
        if let cached = entries[pid], cached.start == start, cached.comm == comm {
            lock.unlock()
            return cached.arguments
        }
        lock.unlock()
        let arguments = read(pid)
        // Unreadable (the process is still being set up, or just exited): ask again next time.
        guard !arguments.isEmpty else { return arguments }
        lock.lock()
        entries[pid] = (start, comm, arguments)
        lock.unlock()
        return arguments
    }

    /// Forgets processes that are gone.
    func prune(keeping isLive: (Int32) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { isLive($0.key) }
    }
}
