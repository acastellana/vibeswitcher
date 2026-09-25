import Darwin
import Foundation

public struct ProcInfo: Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// Controlling terminal, e.g. "ttys009"; nil for daemons and GUI apps.
    public let tty: String?
    public let startTime: Date
    /// Set for terminal-attached `claude` / `codex` processes.
    public let agent: Agent?
}

/// Reads the kernel process table directly via sysctl (no `ps` subprocess, so it is cheap to poll).
public enum ProcessTable {
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
        let tdev = kinfo.kp_eproc.e_tdev
        var tty: String?
        if tdev != -1, let name = devname(tdev, S_IFCHR) {
            let value = String(cString: name)
            if value != "??" { tty = value }
        }
        let start = proc.p_un.__p_starttime
        let startTime = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        // Only terminal-attached processes can be sessions; skipping the rest keeps snapshots cheap.
        let agent = tty == nil ? nil : (Agent(comm: comm) ?? argv0(pid: proc.p_pid).flatMap(Agent.init(comm:)))
        return ProcInfo(pid: proc.p_pid, ppid: kinfo.kp_eproc.e_ppid, tty: tty, startTime: startTime,
                        agent: agent)
    }

    /// Basename of argv[0]. Needed because Claude Code runs as a versioned binary
    /// (`~/.local/share/claude/versions/2.1.282`), so the kernel's `comm` is "2.1.282", not "claude".
    static func argv0(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (int32), exec path, NUL padding, argv[0], argv[1], …
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // skip exec path
        while index < size, buffer[index] == 0 { index += 1 }   // skip padding
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        let arg = String(decoding: buffer[start..<index], as: UTF8.self)
        return (arg as NSString).lastPathComponent
    }
}
