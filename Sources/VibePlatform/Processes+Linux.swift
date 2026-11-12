#if os(Linux)
// Linux's reads of the process table, from /proc: a folder for each process, named by its number, whose files the
// kernel writes as they are read. Only libc, on glibc and on musl.
extension Platform.Processes {
    /// A process's line of /proc/<pid>/stat, the fields read here (proc_pid_stat(5) numbers them from 1).
    struct StatLine: Equatable {
        /// (1)
        var pid: Int32
        /// (2) The kernel's name for it, without the parentheses the line puts around it.
        var name: String
        /// (3) One letter: R, S, D, I, T, t, Z, X.
        var state: UInt8
        /// (4)
        var ppid: Int32
        /// (5)
        var pgrp: Int32
        /// (7) tty_nr: the controlling terminal's device number, 0 for none.
        var terminal: UInt32
        /// (8) tpgid: the terminal's foreground process group, -1 for none.
        var foreground: Int32
        /// (9) The kernel's PF_ flags of it.
        var flags: UInt32
        /// (14) and (15): CPU time in user and in kernel mode, in clock ticks.
        var userTicks: UInt64
        var systemTicks: UInt64
        /// (22) When it started, in clock ticks since the system booted.
        var startTicks: UInt64
        /// (38) The signal its parent gets when it ends; -1 for a thread that isn't its process's first, which has
        /// no parent to tell. nil: the line ends before it.
        var exitSignal: Int32?

        /// PF_EXITING: getting shut down.
        static let exitingFlag: UInt32 = 0x4
        /// PF_FORKNOEXEC: forked and not exec'd since.
        static let forkedFlag: UInt32 = 0x40

        /// Takes a line apart; nil when it isn't one. The name is everything between the first "(" and the last ")":
        /// it is a file's name cut at 15 bytes, or what a thread called itself, so it can hold spaces, parentheses
        /// and line ends, and the fields after it are counted from that last ")" only.
        init?(_ line: String) { self.init(bytes: Array(line.utf8)) }

        init?(bytes: [UInt8]) {
            guard let open = bytes.firstIndex(of: UInt8(ascii: "(")), let close = bytes.lastIndex(of: UInt8(ascii: ")")), open < close,
                  let pid = Self.number(bytes[..<open], as: Int32.self) else { return nil }
            // After the name: state (3) first, so field n is at n - 3.
            let fields = bytes[(close + 1)...].split(whereSeparator: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\n") })
            func field<Value: FixedWidthInteger>(_ number: Int, as type: Value.Type) -> Value? {
                let index = number - 3
                return index < fields.count ? Self.number(fields[index], as: type) : nil
            }
            guard fields.count >= 20, fields[0].count == 1, let state = fields[0].first,
                  let ppid = field(4, as: Int32.self), let pgrp = field(5, as: Int32.self),
                  // Printed as a signed number, and one with a large minor is negative.
                  let terminal = field(7, as: Int32.self), let foreground = field(8, as: Int32.self),
                  let flags = field(9, as: UInt32.self), let userTicks = field(14, as: UInt64.self),
                  let systemTicks = field(15, as: UInt64.self), let startTicks = field(22, as: UInt64.self) else { return nil }
            self.pid = pid
            self.name = String(decoding: bytes[(open + 1)..<close], as: UTF8.self)
            self.state = state
            self.ppid = ppid
            self.pgrp = pgrp
            self.terminal = UInt32(bitPattern: terminal)
            self.foreground = foreground
            self.flags = flags
            self.userTicks = userTicks
            self.systemTicks = systemTicks
            self.startTicks = startTicks
            self.exitSignal = field(38, as: Int32.self)
        }

        /// A decimal number with spaces around it, whole; nil for anything else.
        private static func number<Value: FixedWidthInteger>(_ text: ArraySlice<UInt8>, as type: Value.Type) -> Value? {
            var digits = text
            while digits.first == UInt8(ascii: " ") { digits.removeFirst() }
            while digits.last == UInt8(ascii: " ") { digits.removeLast() }
            let negative = digits.first == UInt8(ascii: "-")
            if negative { digits.removeFirst() }
            guard !digits.isEmpty, !negative || Value.isSigned else { return nil }
            var value: Value = 0
            for digit in digits {
                guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
                // Built below zero for a negative one, whose least value has no positive.
                let (scaled, overflowed) = value.multipliedReportingOverflow(by: 10)
                let unit = Value(digit - UInt8(ascii: "0"))
                let (next, overflowedToo) = negative ? scaled.subtractingReportingOverflow(unit) : scaled.addingReportingOverflow(unit)
                guard !overflowed, !overflowedToo else { return nil }
                value = next
            }
            return value
        }

        /// R running; S sleeping, D waiting where it can't be interrupted (on a disk), I an idle kernel thread: all
        /// asleep; T stopped by a signal, t by a debugger; Z a zombie; X dead and about to be gone, so a zombie too.
        var processState: State {
            switch state {
            case UInt8(ascii: "R"): return .running
            case UInt8(ascii: "S"), UInt8(ascii: "D"), UInt8(ascii: "I"): return .sleeping
            case UInt8(ascii: "T"), UInt8(ascii: "t"): return .stopped
            case UInt8(ascii: "Z"), UInt8(ascii: "X"), UInt8(ascii: "x"): return .zombie
            default: return .unknown
            }
        }

        /// A zombie has no memory, arguments, program or folder any more.
        var isZombie: Bool { processState == .zombie }

        /// Marked as shutting down (a zombie still is), or dead.
        var exiting: Bool { flags & Self.exitingFlag != 0 || state == UInt8(ascii: "X") || state == UInt8(ascii: "x") }

        /// Not a fork that still runs its parent's program.
        var execd: Bool { flags & Self.forkedFlag == 0 }

        /// The terminal's foreground group, when the process has a terminal and the terminal such a group.
        var foregroundGroup: Int32? { terminal != 0 && foreground > 0 ? foreground : nil }

        /// A thread that isn't its process's first: /proc answers for its number as for a process's, though it
        /// lists none and no signal or wait takes it for one.
        var isThread: Bool { exitSignal == -1 }

        /// When it started: `boot` (seconds since 1970) plus its ticks since then.
        func start(boot: Int, ticksPerSecond: Int) -> timeval {
            let rate = UInt64(max(1, ticksPerSecond))
            return timeval(tv_sec: boot + Int(startTicks / rate), tv_usec: Int(startTicks % rate * 1_000_000 / rate))
        }

        /// CPU time, user and system, in seconds.
        func cpuSeconds(ticksPerSecond: Int) -> Double {
            Double(userTicks + systemTicks) / Double(max(1, ticksPerSecond))
        }
    }

    enum System {
        /// Clock ticks a second (`sysconf(_SC_CLK_TCK)`: 100 everywhere today), the unit of the times in stat.
        static let ticksPerSecond: Int = {
            let rate = sysconf(Int32(_SC_CLK_TCK))
            return rate > 0 ? rate : 100
        }()

        static let pageSize: Int = {
            let size = sysconf(Int32(_SC_PAGESIZE))
            return size > 0 ? size : 4096
        }()

        /// When the system booted, in seconds since 1970 (`btime` in /proc/stat), read once and kept. The kernel
        /// works it out anew at each read from the wall clock, so it moves when the clock is set (WSL after the host
        /// slept) and can waver by a second between two reads: kept, a process's start is the same at every read
        /// made by this process. Where /proc/stat can't be read, the wall clock less the time since boot, once.
        static let bootTime: Int = {
            if case .success(let text) = contents("/proc/stat"), let boot = bootTime(in: text) { return boot }
            var now = timespec(), up = timespec()
            clock_gettime(CLOCK_REALTIME, &now)
            clock_gettime(CLOCK_BOOTTIME, &up)
            return Int(now.tv_sec) - Int(up.tv_sec)
        }()

        /// The number on /proc/stat's `btime` line.
        static func bootTime(in text: [UInt8]) -> Int? {
            let key = Array("btime ".utf8)
            for line in text.split(separator: UInt8(ascii: "\n")) where line.starts(with: key) {
                return Int(String(decoding: line.dropFirst(key.count), as: UTF8.self))
            }
            return nil
        }

        /// A file the kernel writes as it's read (its size says nothing), whole; or the error number of the open or
        /// read that failed.
        static func contents(_ path: String) -> Result<[UInt8], Platform.Errno> {
            let fd = open(path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { return .failure(Platform.Errno(code: errno)) }
            defer { close(fd) }
            var bytes: [UInt8] = []
            var failure: Int32 = 0
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4096) { chunk in
                while true {
                    let got = read(fd, chunk.baseAddress, chunk.count)
                    if got > 0 {
                        bytes.append(contentsOf: UnsafeMutableBufferPointer(rebasing: chunk[..<got]))
                    } else if got == 0 {
                        return
                    } else if errno != EINTR {
                        failure = errno
                        return
                    }
                }
            }
            return failure == 0 ? .success(bytes) : .failure(Platform.Errno(code: failure))
        }

        /// Whether a read of /proc failed because the process is no more: its folder is gone (ENOENT), or it ended
        /// with the file open (ESRCH).
        static func vanished(_ failure: Platform.Errno) -> Bool { failure.code == ENOENT || failure.code == ESRCH }

        enum Line { case line(StatLine), unreadable, gone }

        /// A process's line of stat. A thread's number answers there too, and is no process: gone.
        static func statLine(_ pid: pid_t) -> Line {
            switch contents("/proc/\(pid)/stat") {
            case .failure(let failure): return vanished(failure) ? .gone : .unreadable
            case .success(let bytes):
                // Nothing read: it ended as it was opened.
                if bytes.isEmpty { return .gone }
                guard let line = StatLine(bytes: bytes) else { return .unreadable }
                return line.isThread ? .gone : .line(line)
            }
        }

        /// Whose a process is: the owner of its folder in /proc, which is the process's effective user whoever asks.
        static func owner(_ pid: pid_t) -> Result<uid_t, Platform.Errno> {
            var node = stat()
            guard stat("/proc/\(pid)", &node) == 0 else { return .failure(Platform.Errno(code: errno)) }
            return .success(node.st_uid)
        }

        /// Every numbered folder of /proc: the processes (a thread has none there). nil when /proc can't be listed.
        static func allPids() -> [pid_t]? {
            var pids: [pid_t] = []
            pids.reserveCapacity(512)
            guard entries(of: "/proc", { name, _ in
                if let pid = number(name), pid > 0 { pids.append(pid) }
            }) else { return nil }
            return pids
        }

        /// Calls `body` with each entry's name in `folder` (not "." and "..") and the descriptor the folder is read
        /// through; false when the folder can't be opened.
        @discardableResult
        static func entries(of folder: String, _ body: (UnsafeBufferPointer<UInt8>, Int32) -> Void) -> Bool {
            guard let directory = opendir(folder) else { return false }
            defer { closedir(directory) }
            let descriptor = dirfd(directory)
            while let entry = readdir(directory) {
                withUnsafeBytes(of: &entry.pointee.d_name) { field in
                    let name = field.bindMemory(to: UInt8.self)
                    let length = name.firstIndex(of: 0) ?? name.count
                    if length == 1, name[0] == UInt8(ascii: ".") { return }
                    if length == 2, name[0] == UInt8(ascii: "."), name[1] == UInt8(ascii: ".") { return }
                    body(UnsafeBufferPointer(rebasing: name[..<length]), descriptor)
                }
            }
            return true
        }

        /// An entry's name as a number, when it is all digits.
        static func number(_ name: UnsafeBufferPointer<UInt8>) -> Int32? {
            guard !name.isEmpty, name.count <= 10 else { return nil }
            var value: Int64 = 0
            for digit in name {
                guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int64(digit - UInt8(ascii: "0"))
            }
            return Int32(exactly: value)
        }

        static func record(_ pid: pid_t) -> Read {
            switch statLine(pid) {
            case .gone: return .gone
            case .unreadable: return .unreadable
            case .line(let line):
                let uid: uid_t?
                switch owner(pid) {
                case .success(let found): uid = found
                case .failure(let failure):
                    if vanished(failure) { return .gone }
                    uid = nil
                }
                return .record(Record(pid: pid, ppid: line.ppid, pgid: line.pgrp, uid: uid, name: line.name, longName: line.name,
                                      terminal: Platform.Terminals.name(device: dev_t(line.terminal)),
                                      foregroundGroup: line.foregroundGroup,
                                      start: line.start(boot: bootTime, ticksPerSecond: ticksPerSecond),
                                      state: line.processState, exiting: line.exiting, execd: line.execd))
            }
        }

        static func kernelRecord(_ pid: pid_t) -> Record? {
            guard case .record(let record) = record(pid) else { return nil }
            return record
        }

        static func brief(_ pid: pid_t) -> BriefRead {
            switch statLine(pid) {
            case .gone: return .gone
            case .unreadable: return .unreadable
            case .line(let line):
                switch owner(pid) {
                case .failure(let failure): return vanished(failure) ? .gone : .unreadable
                case .success(let uid):
                    return .brief(Brief(pid: pid, ppid: line.ppid, pgid: line.pgrp, uid: uid, name: line.name,
                                        state: line.processState, exiting: line.exiting, execd: line.execd))
                }
            }
        }

        /// What a file of strings each ended by a NUL holds (cmdline, environ). A last one without its NUL counts.
        static func strings(_ bytes: [UInt8], keepingEmpty: Bool) -> [String] {
            var bytes = bytes[...]
            if bytes.last == 0 { bytes.removeLast() }
            guard !bytes.isEmpty else { return [] }
            return bytes.split(separator: 0, omittingEmptySubsequences: !keepingEmpty).map { String(decoding: $0, as: UTF8.self) }
        }

        /// cmdline: any user's is given. A zombie's and a kernel thread's are empty.
        static func arguments(_ pid: pid_t) -> [String] {
            guard case .success(let bytes) = contents("/proc/\(pid)/cmdline") else { return [] }
            return strings(bytes, keepingEmpty: true)
        }

        /// environ: the owner's alone. A zombie's opens and reads empty, as a process started with none does: only
        /// the second has an environment.
        static func environment(_ pid: pid_t) -> [String]? {
            guard case .success(let bytes) = contents("/proc/\(pid)/environ") else { return nil }
            if bytes.isEmpty {
                guard case .line(let line) = statLine(pid), !line.isZombie else { return nil }
            }
            return strings(bytes, keepingEmpty: false)
        }

        /// Where a link points, as the kernel spells it; nil when it can't be read.
        static func link(_ path: String) -> [UInt8]? {
            var room = 1024
            while room <= 64 * 1024 {
                var buffer = [CChar](repeating: 0, count: room)
                let length = readlink(path, &buffer, room)
                guard length >= 0 else { return nil }
                // Cut to fit, perhaps: asked again with more room.
                if length < room { return buffer.prefix(length).map { UInt8(bitPattern: $0) } }
                room *= 4
            }
            return nil
        }

        /// What the kernel puts after the path of a file or folder that has been removed.
        static let removedMark = Array(" (deleted)".utf8)

        /// The file or folder one of a process's links in /proc holds (cwd, exe, fd/<n>): its path, and whether it
        /// has been removed since (the path is then where it was). nil when the link can't be read.
        ///
        /// The kernel says "removed" by ending the path " (deleted)", which a name can end with too: it is the
        /// file's own name when the file at that whole path is the one the link holds.
        static func target(_ path: String) -> (path: String, removed: Bool)? {
            guard let bytes = link(path) else { return nil }
            let text = String(decoding: bytes, as: UTF8.self)
            guard bytes.count > removedMark.count, bytes.suffix(removedMark.count).elementsEqual(removedMark) else { return (text, false) }
            var named = stat(), held = stat()
            if stat(text, &named) == 0, stat(path, &held) == 0, named.st_dev == held.st_dev, named.st_ino == held.st_ino { return (text, false) }
            return (String(decoding: bytes.dropLast(removedMark.count), as: UTF8.self), true)
        }

        static func cwd(_ pid: pid_t) -> String? {
            guard let folder = target("/proc/\(pid)/cwd"), !folder.removed, !folder.path.isEmpty else { return nil }
            return folder.path
        }

        static func executable(_ pid: pid_t) -> String? {
            guard let program = target("/proc/\(pid)/exe"), !program.path.isEmpty else { return nil }
            return program.path
        }

        static func executableWasReplaced(_ pid: pid_t) -> Bool { target("/proc/\(pid)/exe")?.removed ?? false }

        /// Each descriptor's link in /proc/<pid>/fd that is a path: "/…" for a file, a folder or a device, where a
        /// socket's reads "socket:[1234]" and a pipe's "pipe:[5678]". Of this process, not the descriptor the list
        /// itself is read through.
        static func openFiles(_ pid: pid_t) -> [String] {
            let folder = "/proc/\(pid)/fd"
            let own = pid == getpid()
            var paths: [String] = []
            entries(of: folder) { name, listing in
                guard let descriptor = number(name), !(own && descriptor == listing),
                      let file = target("\(folder)/\(descriptor)"), !file.removed, file.path.hasPrefix("/") else { return }
                paths.append(file.path)
            }
            return paths
        }

        /// The entries of /proc/<pid>/fd, counted. From Linux 6.2 the folder's size is that count, and no descriptor
        /// is needed to ask; before, the folder is listed (of this process, less the descriptor that takes).
        static func openDescriptorCount(_ pid: pid_t) -> Int? {
            let folder = "/proc/\(pid)/fd"
            var node = stat()
            if stat(folder, &node) == 0, node.st_size > 0 { return Int(node.st_size) }
            let own = pid == getpid()
            var count = 0
            guard entries(of: folder, { name, listing in
                if let descriptor = number(name), !(own && descriptor == listing) { count += 1 }
            }) else { return nil }
            return count
        }

        /// Every process whose parent is `pid`: the table has no list of them by parent that can be trusted (the
        /// kernel's `children` file is exact only for a stopped process), so each process's line is read.
        static func children(_ pid: pid_t) -> [pid_t] {
            (allPids() ?? []).filter { child in
                guard child != pid, case .line(let line) = statLine(child) else { return false }
                return line.ppid == pid
            }
        }

        /// From stat, which anyone may read: any user's, and a zombie's (what it used while it ran).
        static func cpuSeconds(_ pid: pid_t) -> Double? {
            guard case .line(let line) = statLine(pid) else { return nil }
            return line.cpuSeconds(ticksPerSecond: ticksPerSecond)
        }

        /// statm's second number, in pages. Its first is the whole size: 0 for what has no memory of its own (a
        /// zombie, a kernel thread).
        static func residentBytes(_ pid: pid_t) -> Int64? {
            guard case .success(let bytes) = contents("/proc/\(pid)/statm") else { return nil }
            let fields = bytes.split(whereSeparator: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\n") })
            guard fields.count >= 2, let size = Int64(String(decoding: fields[0], as: UTF8.self)), size > 0,
                  let resident = Int64(String(decoding: fields[1], as: UTF8.self)) else { return nil }
            return resident * Int64(pageSize)
        }
    }
}
#endif
