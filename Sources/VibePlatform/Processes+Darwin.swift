#if canImport(Darwin)
// The Mac's reads of the process table: libproc (`proc_listallpids`, `proc_pidinfo`, `proc_pidfdinfo`, `proc_pidpath`,
// `proc_listchildpids`) and sysctl (`KERN_PROC_PID`, `KERN_PROCARGS2`), each as VibeCore made it before this layer
// (ProcessTable.swift and its smaller copies in ProcessUsage, DiskSpace, MCPLog, SessionStrays, StallWatch): the same
// calls, in the same order, with the same fallbacks and buffer sizes. Swift's Darwin module has all of them and their
// constants; nothing is declared here by value.
extension Platform.Processes {
    enum System {
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

        /// A process's record: from its full record (only the user's own processes give it: most of the table, one
        /// call each), else its parent, owner and state from its short record (any user's) and its name, terminal and
        /// start time from the kernel's record of that one process (sysctl KERN_PROC_PID), else that record alone.
        /// A zombie, or one on its way out, is told as such by the short record without the kernel's being read.
        static func record(_ pid: pid_t) -> Read {
            var full = proc_bsdinfo()
            let fullSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &full, fullSize) == fullSize {
                // Its records' `comm` are cut at 15 characters; the kernel's is its name (`p_name`, cut at 31) cut at 16.
                let name = text(full.pbi_name)
                let comm = name.isEmpty ? String(decoding: text(full.pbi_comm), as: UTF8.self) : String(decoding: name.prefix(Int(MAXCOMLEN)), as: UTF8.self)
                let device = dev_t(bitPattern: full.e_tdev)
                return .record(Record(
                    pid: pid, ppid: Int32(full.pbi_ppid), pgid: Int32(full.pbi_pgid), uid: full.pbi_uid, name: comm,
                    longName: name.isEmpty ? comm : String(decoding: name, as: UTF8.self),
                    terminal: Platform.Terminals.name(device: device),
                    foregroundGroup: foregroundGroup(device: device, group: Int32(truncatingIfNeeded: full.e_tpgid)),
                    start: timeval(tv_sec: Int(full.pbi_start_tvsec), tv_usec: Int32(full.pbi_start_tvusec)),
                    state: state(full.pbi_status), exiting: full.pbi_flags & UInt32(PROC_FLAG_INEXIT) != 0,
                    execd: full.pbi_flags & UInt32(PROC_FLAG_EXEC) != 0))
            } else if errno == ESRCH {
                return .gone
            } else {
                var short = proc_bsdshortinfo()
                let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &short, shortSize) == shortSize else {
                    return errno == ESRCH ? .gone : kernelAlone(pid)
                }
                let exiting = short.pbsi_flags & UInt32(PROC_FLAG_INEXIT) != 0
                let execd = short.pbsi_flags & UInt32(PROC_FLAG_EXEC) != 0
                // Ended: not read further (see `Record`).
                if short.pbsi_status == SZOMB || exiting {
                    let comm = String(decoding: text(short.pbsi_comm), as: UTF8.self)
                    return .record(Record(pid: pid, ppid: Int32(short.pbsi_ppid), pgid: Int32(short.pbsi_pgid), uid: short.pbsi_uid,
                                          name: comm, longName: comm, terminal: nil, foregroundGroup: nil, start: timeval(),
                                          state: state(short.pbsi_status), exiting: exiting, execd: execd))
                }
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
                var kinfo = kinfo_proc()
                var size = MemoryLayout<kinfo_proc>.stride
                guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 else {
                    return errno == ESRCH ? .gone : .partial(ppid: Int32(short.pbsi_ppid), name: String(decoding: text(short.pbsi_comm), as: UTF8.self))
                }
                guard size > 0 else { return .gone }
                let comm = String(decoding: text(kinfo.kp_proc.p_comm), as: UTF8.self)
                let device = kinfo.kp_eproc.e_tdev
                return .record(Record(
                    pid: pid, ppid: Int32(short.pbsi_ppid), pgid: Int32(short.pbsi_pgid), uid: short.pbsi_uid, name: comm,
                    longName: comm, terminal: Platform.Terminals.name(device: device),
                    foregroundGroup: foregroundGroup(device: device, group: kinfo.kp_eproc.e_tpgid),
                    start: kinfo.kp_proc.p_un.__p_starttime, state: state(short.pbsi_status), exiting: exiting, execd: execd))
            }
        }

        /// A process whose short record couldn't be read, from the kernel's record of it (sysctl KERN_PROC_PID): its
        /// owner isn't read; nothing read, it's there and nothing more is known.
        private static func kernelAlone(_ pid: pid_t) -> Read {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var kinfo = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 else { return errno == ESRCH ? .gone : .unreadable }
            guard size > 0 else { return .gone }
            return .record(record(of: kinfo))
        }

        /// The kernel's record of one process (sysctl KERN_PROC_PID), any user's, zombies too.
        static func kernelRecord(_ pid: pid_t) -> Record? {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var proc = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0 else { return nil }
            return record(of: proc)
        }

        /// What the kernel's record says (`ProcessTable.makeInfo`, and `kernelRecord`'s and `holdsForeground`'s
        /// checks of it): no owner.
        private static func record(of kinfo: kinfo_proc) -> Record {
            var proc = kinfo.kp_proc
            let comm = withUnsafePointer(to: &proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            let device = kinfo.kp_eproc.e_tdev
            return Record(pid: proc.p_pid, ppid: kinfo.kp_eproc.e_ppid, pgid: kinfo.kp_eproc.e_pgid, uid: nil, name: comm,
                          longName: comm, terminal: Platform.Terminals.name(device: device),
                          foregroundGroup: foregroundGroup(device: device, group: kinfo.kp_eproc.e_tpgid),
                          start: proc.p_un.__p_starttime, state: state(UInt32(truncatingIfNeeded: proc.p_stat)),
                          exiting: proc.p_flag & P_WEXIT != 0, execd: proc.p_flag & P_EXEC != 0)
        }

        /// A process's short record, any user's, zombies too (the 1: a zombie's is given).
        static func brief(_ pid: pid_t) -> BriefRead {
            var short = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 1, &short, size) == size else { return errno == ESRCH ? .gone : .unreadable }
            return .brief(Brief(pid: pid, ppid: Int32(short.pbsi_ppid), pgid: Int32(short.pbsi_pgid), uid: short.pbsi_uid,
                                name: String(decoding: text(short.pbsi_comm), as: UTF8.self), state: state(short.pbsi_status),
                                exiting: short.pbsi_flags & UInt32(PROC_FLAG_INEXIT) != 0,
                                execd: short.pbsi_flags & UInt32(PROC_FLAG_EXEC) != 0))
        }

        /// A program is started in one step (posix_spawn), never seen as a copy of the process that started it.
        static let childrenStartAsCopies = false

        /// The terminal's foreground group, when the process has a terminal (its device isn't -1) and the terminal
        /// such a group.
        private static func foregroundGroup(device: dev_t, group: Int32) -> Int32? {
            device != -1 && group > 0 ? group : nil
        }

        private static func state(_ status: UInt32) -> State {
            switch Int32(truncatingIfNeeded: status) {
            case SIDL: return .starting
            case SRUN: return .running
            case SSLEEP: return .sleeping
            case SSTOP: return .stopped
            case SZOMB: return .zombie
            default: return .unknown
            }
        }

        /// A fixed-size C string field's bytes, up to its NUL or its end.
        private static func text<Field>(_ field: Field) -> [UInt8] {
            withUnsafeBytes(of: field) { bytes in Array(bytes.prefix { $0 != 0 }) }
        }

        /// A process's argv as it is now: empty when it can't be read.
        static func arguments(_ pid: pid_t) -> [String] { procargs(pid: pid).map { Platform.Processes.parse(procargs: $0).arguments } ?? [] }

        /// The environment a process was started with (what it set later isn't there): nil when it can't be read
        /// (another user's, a zombie).
        static func environment(_ pid: pid_t) -> [String]? { procargs(pid: pid).map { Platform.Processes.parse(procargs: $0).environment } }

        /// The kernel's record of a process's argv and environment (KERN_PROCARGS2): only the user's own processes give it.
        static func procargs(pid: Int32) -> [UInt8]? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
            return Array(buffer.prefix(size))
        }

        /// Current working directory of a process we own.
        static func cwd(_ pid: pid_t) -> String? {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return path.isEmpty ? nil : path
        }

        /// The program a process runs, by path (its symlinks resolved, as the kernel names it).
        static func executable(_ pid: pid_t) -> String? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
        }

        /// The kernel names a program's file wherever it is now, and says nothing of one removed.
        static func executableWasReplaced(_ pid: pid_t) -> Bool { false }

        /// The files and folders `pid` has open.
        static func openFiles(_ pid: pid_t) -> [String] {
            let stride = MemoryLayout<proc_fdinfo>.stride
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return [] }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 8)
            let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard got > 0 else { return [] }
            return fds.prefix(Int(got) / stride).compactMap { fd in
                guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
                let path = withUnsafePointer(to: &info.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                return path.isEmpty ? nil : path
            }
        }

        /// The descriptors a process has open. Asks the kernel (no descriptor needed, so it answers when they've run
        /// out).
        static func openDescriptorCount(_ pid: pid_t) -> Int? {
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

        /// The processes `pid` started that run now.
        static func children(_ pid: pid_t) -> [pid_t] {
            let count = proc_listchildpids(pid, nil, 0)
            guard count > 0 else { return [] }
            var pids = [pid_t](repeating: 0, count: Int(count) + 16)
            let listed = pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
            return Array(pids.prefix(Int(max(0, listed)))).filter { $0 > 0 }
        }

        /// Seconds per tick of `proc_taskinfo`'s CPU times (mach absolute time).
        static let cpuTick: Double = {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            return Double(timebase.numer) / Double(max(1, timebase.denom)) / 1e9
        }()

        /// CPU seconds (user and system) of a process we own.
        static func cpuSeconds(_ pid: pid_t) -> Double? {
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { return nil }
            return Double(task.pti_total_user + task.pti_total_system) * cpuTick
        }

        /// Resident memory of a process we own, in bytes.
        static func residentBytes(_ pid: pid_t) -> Int64? {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
            return Int64(info.pti_resident_size)
        }
    }

    /// What `KERN_PROCARGS2` gives of a process, taken apart (public for VibeCore's tests of it, which give it
    /// buffers of their own). Layout: argc (int32), exec path, NUL padding, argv[0] … argv[argc-1], the environment
    /// up to an empty string, then the kernel's own (`ptr_munge=`, `executable_file=`…).
    public static func parse(procargs buffer: [UInt8]) -> (arguments: [String], environment: [String]) {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return ([], []) }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        func next() -> String {
            let begin = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[begin..<index], as: UTF8.self)
        }
        var arguments: [String] = []
        while arguments.count < argc, index < size { arguments.append(next()) }
        var environment: [String] = []
        while index < size {
            let entry = next()
            if entry.isEmpty { break }
            environment.append(entry)
        }
        return (arguments, environment)
    }
}
#endif

#if canImport(Darwin)
extension Platform.Processes.System {
    /// nil: an audit token is had only for the process at the other end of a connection (`LOCAL_PEERTOKEN`), not for
    /// another pid without privileges (`task_name_for_pid` needs root).
    static func token(_ pid: pid_t) -> Platform.PeerToken? { nil }

    /// nil: the Mac has no dumpable state another process can read.
    static func isDumpable(_ pid: pid_t) -> Bool? { nil }
}
#endif
