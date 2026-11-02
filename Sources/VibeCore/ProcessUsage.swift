import Darwin
import Foundation

/// A process's CPU use, as `ps -o pid=,ppid=,pgid=,uid=,time=,etime=` gives it, read from the kernel (no `ps`
/// subprocess): what the heavy-job witness (`HeavyJobs`) and the load recorder measure by. Its command is only its name
/// (`ProcessTable.commandName`), never its arguments: an argument may hold a secret, and what's read here goes into
/// leads' messages and records.
public struct ProcUsage: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// Its process group (`ps -o pgid`): a job's processes share one (a shell's job, `vs-heavy`'s command).
    public let pgid: Int32
    public let uid: uid_t
    /// CPU seconds it has used so far, user and system (`ps -o time`).
    public let cpu: Double
    /// When it started (`ps -o etime` is the time since).
    public let started: Date
    /// The kernel's name for it (`ps -o comm`'s last path component, cut at 16 characters).
    public let name: String

    public init(pid: Int32, ppid: Int32, pgid: Int32, uid: uid_t = getuid(), cpu: Double, started: Date, name: String) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.uid = uid
        self.cpu = cpu
        self.started = started
        self.name = name
    }

    /// How long it has run (`ps -o etime`).
    public func elapsed(now: Date = Date()) -> TimeInterval { max(0, now.timeIntervalSince(started)) }
}

extension ProcessTable {
    /// The user's own processes' CPU use, read whole within `limit`; nil when it couldn't be (past `limit`, or the pid
    /// list unread). Another user's process (root's daemons) gives no CPU time to read, and isn't in it.
    public static func usage(within limit: TimeInterval = snapshotLimit) -> [ProcUsage]? {
        usageReads.read(within: limit) { deadline in
            guard let pids = allPids() else { return nil }
            var list: [ProcUsage] = []
            list.reserveCapacity(pids.count)
            for pid in pids {
                guard Date() < deadline else { return nil }
                if let usage = usage(of: pid) { list.append(usage) }
            }
            return list
        }
    }

    /// Its own reads (not the table's): a late table read doesn't hold this one up, nor the other way round.
    static let usageReads = BoundedReads()

    /// Seconds per tick of `proc_taskinfo`'s CPU times (mach absolute time).
    static let cpuTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(max(1, timebase.denom)) / 1e9
    }()

    /// One process's CPU use; nil when it's gone, a zombie, or not the user's.
    public static func usage(of pid: Int32) -> ProcUsage? {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize, info.pbi_status != SZOMB else { return nil }
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { Array($0.prefix { $0 != 0 }) }
        let comm = withUnsafeBytes(of: info.pbi_comm) { Array($0.prefix { $0 != 0 }) }
        return ProcUsage(pid: pid, ppid: Int32(info.pbi_ppid), pgid: Int32(info.pbi_pgid), uid: info.pbi_uid,
                         cpu: Double(task.pti_total_user + task.pti_total_system) * cpuTick,
                         started: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000),
                         name: String(decoding: (name.isEmpty ? comm : Array(name.prefix(Int(MAXCOMLEN)))), as: UTF8.self))
    }

    /// The folder a process works in (its current directory); nil when it can't be read (gone, or another user's).
    public static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// What a process was started as, by name: its argv[0]'s last path component ("node", "qemu-system-aarch64"), never
    /// its arguments; nil when its argv can't be read (gone, or another user's), or when its argv[0] was rewritten into
    /// a title with spaces in it ("postgres: user db 10.0.0.1"), which may carry what an argument would.
    public static func commandName(of pid: Int32) -> String? {
        guard let first = readArguments(pid: pid).first else { return nil }
        return commandName(argv0: first)
    }

    /// argv[0]'s last path component, as `commandName(of:)` says it.
    static func commandName(argv0: String) -> String? {
        let name = (argv0 as NSString).lastPathComponent
        return name.isEmpty || name.contains(where: \.isWhitespace) ? nil : String(name.prefix(64))
    }
}
