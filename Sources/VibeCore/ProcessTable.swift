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

    public init(pid: Int32, ppid: Int32, tty: String?, comm: String, startTime: Date, agent: Agent?) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.comm = comm
        self.startTime = startTime
        self.agent = agent
    }
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

    /// How long a snapshot may take. It takes about 10 ms for 1,500 processes on a Mac running several test suites
    /// (load 100+), where reading the whole table at once (sysctl KERN_PROC_ALL) stalled for 10 to 80 s.
    public static let snapshotLimit: TimeInterval = 2

    /// Every process, read whole within `limit`; nil when it couldn't be, not "no processes" and never part of the
    /// table: a process missing from a snapshot has ended (callers act on that, as a session's agent that quit).
    ///
    /// One process at a time (`proc_listallpids`, then each one's record), not KERN_PROC_ALL. A caller waits `limit`
    /// at most, whatever the kernel does: the read runs on another thread and is dropped when it's late; while a late
    /// one is still stuck in the kernel, the next callers are told at once.
    public static func trySnapshot(within limit: TimeInterval = snapshotLimit) -> [Int32: ProcInfo]? {
        reads.read(within: limit) { readTable(until: $0) }
    }

    static let reads = BoundedReads()

    /// The whole table, or nil: past `deadline`, or a process there that couldn't be read.

    /// The whole table, or nil: past `deadline`, or a process there that couldn't be read.
    static func readTable(until deadline: Date, arguments: ArgumentCache = argumentCache) -> [Int32: ProcInfo]? {
        guard let pids = allPids() else { return nil }
        var table: [Int32: ProcInfo] = [:]
        table.reserveCapacity(pids.count)
        for pid in pids {
            guard Date() < deadline else { return nil }
            switch record(pid, arguments: arguments) {
            case .gone: continue
            case .unreadable: return nil
            case .found(let info): table[pid] = info
            }
        }
        arguments.prune { table[$0] != nil }
        return table
    }

    /// Every pid but the kernel's; nil when the list couldn't be read.
    static func allPids() -> [pid_t]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        // Room for processes started meanwhile.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard listed > 0 else { return nil }
        return pids.prefix(Int(listed)).filter { $0 > 0 }
    }

    enum Record { case found(ProcInfo), gone, unreadable }

    /// A process's record: its parent, owner and state from its short record (any user's); name, terminal and start
    /// time from its full one (only the user's own processes give it), or else the kernel's record of that one process
    /// (sysctl KERN_PROC_PID); which agent it is from its name or argv. A zombie, or one on its way out, has ended.
    static func record(_ pid: pid_t, arguments: ArgumentCache) -> Record {
        var short = proc_bsdshortinfo()
        let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &short, shortSize) == shortSize else { return failure() }
        if short.pbsi_status == SZOMB || short.pbsi_flags & UInt32(PROC_FLAG_INEXIT) != 0 { return .gone }
        let comm: String
        let device: dev_t
        let start: timeval
        var full = proc_bsdinfo()
        let fullSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &full, fullSize) == fullSize {
            // Its records' `comm` are cut at 15 characters; the kernel's is its name (`p_name`, cut at 31) cut at 16.
            let name = text(full.pbi_name)
            comm = name.isEmpty ? String(decoding: text(full.pbi_comm), as: UTF8.self) : String(decoding: name.prefix(Int(MAXCOMLEN)), as: UTF8.self)
            device = dev_t(bitPattern: full.e_tdev)
            start = timeval(tv_sec: Int(full.pbi_start_tvsec), tv_usec: Int32(full.pbi_start_tvusec))
        } else if errno == ESRCH {
            return .gone
        } else {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var kinfo = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 else { return failure() }
            guard size > 0 else { return .gone }
            comm = String(decoding: text(kinfo.kp_proc.p_comm), as: UTF8.self)
            device = kinfo.kp_eproc.e_tdev
            start = kinfo.kp_proc.p_un.__p_starttime
        }
        let tty = ttyName(device)
        // Only the user's own processes' argv can be read (another user's isn't an agent of theirs unless named one).
        let readable = short.pbsi_uid == geteuid() ? arguments : nil
        var identity = Identity.unknown
        // A process being set up or exiting has no argv to read for a moment: once more, then it's that, or gone.
        for _ in 0..<2 where identity == .unknown {
            identity = identify(pid: pid, start: start.tv_sec, comm: comm, tty: tty, arguments: readable)
        }
        let agent: Agent?
        switch identity {
        case .agent(let found): agent = found
        case .none: agent = nil
        case .unknown:
            // One on its way out (its argv gone first) has ended; one still running that can't be told is no table.
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &short, shortSize) == shortSize else { return failure() }
            if short.pbsi_status == SZOMB || short.pbsi_flags & UInt32(PROC_FLAG_INEXIT) != 0 { return .gone }
            // Except a fork that hasn't exec'd (a shell's subshell, for the moment its argv can't be read, EIO): it runs
            // its parent's program, never a session of its own.
            guard short.pbsi_flags & UInt32(PROC_FLAG_EXEC) == 0 else { return .unreadable }
            agent = nil
        }
        return .found(ProcInfo(pid: pid, ppid: Int32(short.pbsi_ppid), tty: tty, comm: comm, startTime: date(start), agent: agent))
    }

    /// A fixed-size C string field's bytes, up to its NUL or its end.
    private static func text<Field>(_ field: Field) -> [UInt8] {
        withUnsafeBytes(of: field) { bytes in Array(bytes.prefix { $0 != 0 }) }
    }

    /// What a failed read of a process means: it has ended, or it couldn't be read.
    private static func failure() -> Record { errno == ESRCH ? .gone : .unreadable }

    private static func date(_ start: timeval) -> Date {
        Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// Every process's name (the kernel's `comm`, cut at 15 characters) by pid, and nothing else; nil when the list
    /// couldn't be read.
    public static func names() -> [Int32: String]? {
        guard let pids = allPids() else { return nil }
        var names: [Int32: String] = [:]
        for pid in pids {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            // Gone meanwhile.
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &info, size) == size else { continue }
            names[pid] = withUnsafePointer(to: &info.pbsi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
        }
        return names
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

    /// Every ancestor of `pid` up to launchd, nearest first, however deep; nil when the chain can't be followed
    /// there (a process in it ended, or it loops while pids are reused). For deciding who a caller is: a chain cut
    /// short could hide the session it runs in.
    public static func ancestry(of pid: Int32, info: (Int32) -> ProcInfo? = { info(pid: $0) }) -> [ProcInfo]? {
        var chain: [ProcInfo] = []
        var seen: Set<Int32> = [pid]
        guard var current = info(pid)?.ppid else { return nil }
        while current > 1 {
            guard seen.insert(current).inserted, let proc = info(current) else { return nil }
            chain.append(proc)
            current = proc.ppid
        }
        return current == 1 ? chain : nil
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
    /// An argv that couldn't be read leaves it as its name says.
    static func agent(pid: Int32, start: Int, comm: String, tty: String?, arguments: ArgumentCache) -> Agent? {
        switch identify(pid: pid, start: start, comm: comm, tty: tty, arguments: arguments) {
        case .agent(let agent): agent
        case .none: nil
        case .unknown: Agent(comm: comm)
        }
    }

    enum Identity: Equatable { case agent(Agent), none, unknown }

    /// Which agent a process is, as `agent` says; `unknown` when that takes its argv and it couldn't be read.
    /// `arguments` nil: its argv can't be read (another user's process), so it's an agent only by name.
    static func identify(pid: Int32, start: Int, comm: String, tty: String?, arguments: ArgumentCache?) -> Identity {
        // Only terminal-attached processes can be sessions; skipping the rest keeps snapshots cheap.
        guard tty != nil else { return .none }
        let named = Agent(comm: comm)
        guard let arguments else { return named.map(Identity.agent) ?? .none }
        if named == .claude { return .agent(.claude) }
        let argv = arguments.arguments(pid: pid, start: start, comm: comm)
        if argv.isEmpty { return .unknown }
        // Codex's app server (its background daemon, the daemon's pid-update-loop, a stdio server someone
        // started by hand) is the same `codex` binary but runs threads for sessions elsewhere: never one itself.
        if named == .codex { return isCodexAppServer(argv) ? .none : .agent(.codex) }
        return argv.first.map { ($0 as NSString).lastPathComponent }.flatMap(Agent.init(comm:)).map(Identity.agent) ?? .none
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

/// Reads given a time limit, each on another thread, so a caller waits the limit at most whatever the kernel does: past
/// it, it's told nil and the read is dropped. While a dropped read still runs (stuck in the kernel), the next callers
/// are told nil at once instead of starting more reads behind it.
final class BoundedReads: @unchecked Sendable {
    private let lock = NSLock()
    /// Reads whose callers stopped waiting for them, still running.
    private var late = 0

    /// `read` is given its deadline, to stop at itself.
    func read<Value: Sendable>(within limit: TimeInterval, _ read: @escaping @Sendable (Date) -> Value?) -> Value? {
        let deadline = Date().addingTimeInterval(limit)
        lock.lock()
        let blocked = late > 0
        lock.unlock()
        guard !blocked else { return nil }
        let run = Run<Value>()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let value = read(deadline)
            lock.lock(); defer { lock.unlock() }
            if run.abandoned { late -= 1 } else { run.value = value }
            run.done.signal()
        }
        _ = run.done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        lock.lock(); defer { lock.unlock() }
        guard let value = run.value else {
            if !run.finished { run.abandoned = true; late += 1 }
            return nil
        }
        return value
    }

    private final class Run<Value>: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var value: Value??
        var abandoned = false
        var finished: Bool { value != nil }
    }
}
