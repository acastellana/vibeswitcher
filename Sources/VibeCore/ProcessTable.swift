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
    private static var argumentCache: [Int32: (start: Int, arguments: [String])] = [:]

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

    public static func snapshot() -> [Int32: ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between the two calls; leave headroom.
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
        size = buffer.count * stride
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [:] }
        var result: [Int32: ProcInfo] = [:]
        for index in 0..<(size / stride) {
            let info = makeInfo(buffer[index])
            result[info.pid] = info
        }
        cacheLock.lock()
        argumentCache = argumentCache.filter { result[$0.key] != nil }
        cacheLock.unlock()
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
        // Only terminal-attached processes can be sessions; skipping the rest keeps snapshots cheap.
        let agent = tty == nil ? nil
            : (Agent(comm: comm) ?? arguments(pid: proc.p_pid, start: start.tv_sec).first
                .map { ($0 as NSString).lastPathComponent }.flatMap(Agent.init(comm:)))
        return ProcInfo(pid: proc.p_pid, ppid: kinfo.kp_eproc.e_ppid, tty: tty, comm: comm, startTime: startTime,
                        agent: agent)
    }

    /// A process's argv, cached per (pid, start time). Claude Code runs as a versioned binary
    /// (`~/.local/share/claude/versions/2.1.282`), so the kernel's `comm` is "2.1.282", not "claude";
    /// argv[0] tells them apart.
    public static func arguments(pid: Int32, start: Int) -> [String] {
        cacheLock.lock()
        if let cached = argumentCache[pid], cached.start == start {
            cacheLock.unlock()
            return cached.arguments
        }
        cacheLock.unlock()
        let arguments = readArguments(pid: pid)
        cacheLock.lock()
        argumentCache[pid] = (start, arguments)
        cacheLock.unlock()
        return arguments
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
