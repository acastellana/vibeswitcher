extension Platform {
    /// The system's table of processes, one process a read and never a `ps`: cheap enough to walk the whole table
    /// (about 1,500 processes) every poll. Each read has one implementation per system: the Mac's is libproc and
    /// sysctl (Processes+Darwin.swift), Linux's is /proc (Processes+Linux.swift).
    ///
    /// A process can end between any two reads, and its number be given to another: every read answers for the
    /// moment it was made, "gone" or "can't be read" included, and none of them fails.
    ///
    /// What differs between the systems, beyond the words of each read below:
    /// - A zombie (ended, not yet collected by its parent) reads `.gone` from `record` on the Mac for the user's own
    ///   processes and as a record in state `.zombie` on Linux. Either way it has ended: ask `state` and `exiting`.
    /// - Another user's process gives its arguments, CPU time and memory on Linux, and none of them on the Mac. Its
    ///   environment, folder, program and open files are its owner's alone on both. A caller that means "the user's
    ///   own" compares `uid`, and doesn't rely on a read failing.
    /// - A start time is exact to the microsecond on the Mac and to a clock tick (10 ms) on Linux, where it is the
    ///   boot time plus ticks: the boot time is read once in this process's life, so two reads of one process's start
    ///   are always equal here, but may differ by a second or more from what another process read (or this program
    ///   in an earlier run) when the wall clock was set meanwhile.
    /// - A kernel name is 16 bytes at most on the Mac and 15 on Linux, where a thread can also rename it.
    public enum Processes {
        public enum State: Sendable {
            case starting, running, sleeping, stopped, zombie, unknown
        }

        /// One process as the kernel records it.
        ///
        /// Of a zombie or an exiting process, only `pid`, `ppid`, `pgid`, `uid`, `name`, `state`, `exiting` and
        /// `execd` are sure: the Mac doesn't read another user's further (its `terminal` and `foregroundGroup` are
        /// then nil and its `start` zero).
        public struct Record: Sendable {
            public var pid: Int32
            public var ppid: Int32
            public var pgid: Int32
            /// Its effective owner. nil: not readable (only the Mac's last fallback, the kernel's record alone, and
            /// `kernelRecord`, which doesn't ask).
            public var uid: uid_t?
            /// The kernel's name for it, usually its program's file name, cut short: at 16 bytes on the Mac and 15 on
            /// Linux.
            public var name: String
            /// The kernel's whole name for it where it keeps a longer one (the Mac, up to 31 bytes, for the user's own
            /// processes); else `name`.
            public var longName: String
            /// Its controlling terminal, by a name with no slash in it (`Terminals`): "ttys009" on the Mac, "ttypts3"
            /// on Linux. nil: it has none, or the terminal is closed and has no name any more.
            public var terminal: String?
            /// The process group in the foreground of its controlling terminal; nil when it has no terminal or the
            /// terminal has no such group.
            public var foregroundGroup: Int32?
            /// When it started, in seconds and microseconds since 1970 (see `Processes` for how exact).
            public var start: timeval
            public var state: State
            /// On its way out: it can't be signalled or read much longer. A zombie is past that (`state`); on Linux
            /// it is also still marked so.
            public var exiting: Bool
            /// It has replaced its program since it was made (exec): false for a fork that still runs its parent's
            /// program, as a shell's subshell does.
            public var execd: Bool

            public init(pid: Int32, ppid: Int32, pgid: Int32, uid: uid_t?, name: String, longName: String, terminal: String?,
                        foregroundGroup: Int32?, start: timeval, state: State, exiting: Bool, execd: Bool) {
                self.pid = pid
                self.ppid = ppid
                self.pgid = pgid
                self.uid = uid
                self.name = name
                self.longName = longName
                self.terminal = terminal
                self.foregroundGroup = foregroundGroup
                self.start = start
                self.state = state
                self.exiting = exiting
                self.execd = execd
            }
        }

        /// What `record` could read of a process.
        public enum Read: Sendable {
            case record(Record)
            /// It is there, and only its parent and name could be read (the Mac: its short record, when the kernel's
            /// own record of it couldn't be). Never on Linux.
            case partial(ppid: Int32, name: String)
            /// It is there and nothing of it could be read.
            case unreadable
            /// No such process (on Linux also: the number is a thread's, not a process's).
            case gone
        }

        /// What any user's process says of itself in one cheap read: no terminal and no start time.
        public struct Brief: Sendable {
            public var pid: Int32
            public var ppid: Int32
            public var pgid: Int32
            public var uid: uid_t
            /// The kernel's short name for it: 15 bytes at most on both systems.
            public var name: String
            public var state: State
            public var exiting: Bool
            public var execd: Bool

            public init(pid: Int32, ppid: Int32, pgid: Int32, uid: uid_t, name: String, state: State, exiting: Bool, execd: Bool) {
                self.pid = pid
                self.ppid = ppid
                self.pgid = pgid
                self.uid = uid
                self.name = name
                self.state = state
                self.exiting = exiting
                self.execd = execd
            }
        }

        /// What `brief` could read of a process.
        public enum BriefRead: Sendable {
            case brief(Brief)
            /// It is there and couldn't be read.
            case unreadable
            /// No such process.
            case gone
        }

        /// Every process's number; nil when the list couldn't be read (never "no processes"). The Mac leaves out the
        /// kernel's own (0); Linux lists its kernel threads, which are processes there.
        public static func allPids() -> [pid_t]? { System.allPids() }

        /// A process's record, as much of it as can be read.
        ///
        /// The Mac: its full record (one call; only the user's own processes give it), else its short record (any
        /// user's) with the kernel's own record of that one process for its name, terminal and start, else the
        /// kernel's record alone (`uid` nil). A zombie of the user's own is `.gone` there.
        /// Linux: its line of /proc/<pid>/stat and the owner of /proc/<pid>; any user's, zombies too.
        public static func record(_ pid: pid_t) -> Read { System.record(pid) }

        /// The kernel's own record of a process in one read, zombies included; nil when there's no such process or
        /// it couldn't be read. The Mac (sysctl KERN_PROC_PID) doesn't read its owner (`uid` is nil) and gives it for
        /// any user's process; on Linux it is `record`'s.
        public static func kernelRecord(_ pid: pid_t) -> Record? { System.kernelRecord(pid) }

        /// A process's short record, any user's, zombies included (the Mac: one call that never asks for more than
        /// anyone may know; Linux: `record`'s two reads without its terminal's name).
        public static func brief(_ pid: pid_t) -> BriefRead { System.brief(pid) }

        /// Whether every program this system starts is first a copy of the process that starts it. Linux: a child is
        /// made by fork and only then execs, so each new process reads for a moment as its parent in its name,
        /// arguments and program, with `execd` false, and a reader of the table tells nothing from those until
        /// `execd`. The Mac starts a program in one step (posix_spawn); only a process that forks by itself has
        /// such a copy there, read as it always was.
        public static var childrenStartAsCopies: Bool { System.childrenStartAsCopies }

        /// The arguments a process was started with, its program's name first. Empty: they can't be read (gone, a
        /// zombie, a process being set up; on the Mac another user's; on Linux a kernel thread).
        public static func arguments(_ pid: pid_t) -> [String] { System.arguments(pid) }

        /// The environment a process was started with, each "NAME=value" (what it set later isn't there); nil when it
        /// can't be read (another user's, a zombie, gone).
        public static func environment(_ pid: pid_t) -> [String]? { System.environment(pid) }

        /// The folder a process works in, as the kernel names it (symlinks resolved); nil when it can't be read
        /// (another user's, a zombie, gone) or the folder has been removed.
        public static func cwd(_ pid: pid_t) -> String? { System.cwd(pid) }

        /// The file a process's program was started from, as the kernel names it (symlinks resolved); nil when it
        /// can't be read (a zombie, gone; on Linux another user's). When that file has been removed or replaced since
        /// (a new build written over it), Linux still gives where it was, and `executableWasReplaced` says so.
        public static func executable(_ pid: pid_t) -> String? { System.executable(pid) }

        /// Whether the file a process runs is no longer the one at `executable`'s path: removed, or another written
        /// in its place. Always false on the Mac, which doesn't tell; false too when the program can't be read.
        public static func executableWasReplaced(_ pid: pid_t) -> Bool { System.executableWasReplaced(pid) }

        /// The files, folders and devices a process has open, by path, one for each descriptor (so a path can be
        /// there twice); not its sockets or pipes, nor a file removed since. Empty: none, or they can't be read
        /// (another user's, gone).
        public static func openFiles(_ pid: pid_t) -> [String] { System.openFiles(pid) }

        /// How many descriptors a process has open; nil when that can't be read. Of this process, the Mac answers
        /// with none to spare; Linux before 6.2 needs one descriptor to count them, and says nil without.
        public static func openDescriptorCount(_ pid: pid_t) -> Int? { System.openDescriptorCount(pid) }

        /// The processes `pid` started that are there now (its children; zombies among them), any user's.
        public static func children(_ pid: pid_t) -> [pid_t] { System.children(pid) }

        /// The CPU time a process has used so far, user and system, in seconds; nil when it can't be read (gone; on
        /// the Mac another user's or a zombie). Exact to a clock tick (10 ms) on Linux.
        public static func cpuSeconds(_ pid: pid_t) -> Double? { System.cpuSeconds(pid) }

        /// The memory a process holds in RAM now, in bytes; nil when it can't be read (gone, a zombie; on the Mac
        /// another user's; on Linux a kernel thread, which has none of its own).
        public static func residentBytes(_ pid: pid_t) -> Int64? { System.residentBytes(pid) }

        /// The signals a process ignores now (its disposition `SIG_IGN`), any user's, one bit each: signal `n` is bit
        /// `n - 1`, as `sigmask` and Linux's status give them. nil when it can't be read (gone). The Mac: the kernel's
        /// record of it (sysctl KERN_PROC_PID, `p_sigignore`); Linux: `SigIgn` in /proc/<pid>/status, which anyone
        /// may read, a non-dumpable process's too. A reader that isn't `ps`, whose Mac form has no such column.
        public static func ignoredSignals(_ pid: pid_t) -> UInt64? { pid > 0 ? System.ignoredSignals(pid) : nil }

        /// The `SigIgn` of a /proc/<pid>/status text (hex, one bit a signal); nil when it has no such field or it
        /// isn't hex.
        public static func ignoredSignals(fromStatus status: String) -> UInt64? {
            guard let fields = Platform.ProcessSelf.statusFields("SigIgn", in: status), fields.count == 1,
                  fields[0].allSatisfy(\.isHexDigit) else { return nil }
            return UInt64(fields[0], radix: 16)
        }
    }
}

extension Platform.Processes {
    /// A token for the process `pid` as it runs now, made as `Platform.Sockets.peerToken` makes one for the process at
    /// the other end of a connection, and compared with it by `sameImage(as:)`: for a process this one knows by its
    /// pid alone (a child, a server it started, a pid recorded in a file). Linux: its pid, its effective user and when
    /// it started (/proc/<pid>/stat and status, read through one descriptor on its folder, so both are of the same
    /// process); nil when it has gone, or the number is a thread's. The Mac: nil, since an audit token can't be had
    /// for another process without privileges.
    ///
    /// The process's owner is read from its status, its `Uid` line. The folder /proc/<pid> itself (mode 0555) would
    /// say the same, as it stays the effective user's whatever the process does; its other entries don't: while the
    /// process is non-dumpable, and once it has no memory (ending, or a zombie), the kernel gives them to root. Its
    /// status and stat are among them, and being mode 0444 stay readable to anyone: a hardened process's token is
    /// its peer token too.
    public static func token(_ pid: pid_t) -> Platform.PeerToken? { System.token(pid) }

    /// Whether the process `pid` is dumpable, as another process of its user can tell: Linux, true when its
    /// /proc/<pid>/fd is its own effective user's, false when that is root's while its user isn't root (the kernel
    /// gives a non-dumpable process's entries but the folder itself to root); nil when it can't be told: gone, a
    /// thread's number, ending or a zombie (whose entries are root's whether or not it hardened, its memory gone),
    /// or a process of root's (whose entries are root's either way). The Mac: nil.
    ///
    /// Any process may make itself non-dumpable, so an unreadable process is no one in particular: only its pid and
    /// start (`token`) tell it is the session host, a parser or the server (the security architecture document's S6).
    public static func isDumpable(_ pid: pid_t) -> Bool? { System.isDumpable(pid) }

    /// One link of a process's ancestry, as one read gives it: its parent, when it started and its controlling
    /// terminal, all of the same process (the session host's check of who a caller is, the security architecture
    /// document's S4).
    public struct Link: Equatable, Sendable {
        public var pid: pid_t
        public var parent: pid_t
        /// When it started, in the system's clock ticks since boot: a process started later has no fewer.
        public var startTicks: UInt64
        /// Its controlling terminal's name (`Terminals`), nil for none.
        public var terminal: String?

        public init(pid: pid_t, parent: pid_t, startTicks: UInt64, terminal: String?) {
            self.pid = pid
            self.parent = parent
            self.startTicks = startTicks
            self.terminal = terminal
        }

        /// Whether `token` names this process: the same pid, started at the same tick, not the pid given again.
        /// The Mac's tokens carry no start ticks: false (the Mac reads no links).
        public func isProcess(of token: Platform.PeerToken) -> Bool { System.names(token, self) }
    }

    /// The process `pid` as one read gives it (`Link`). Linux: its line of /proc/<pid>/stat; nil when it has gone,
    /// or the number is a thread's. The Mac: nil (its records carry no start ticks; the host there matches a process by
    /// its pid, `ProcessTable.ancestry`).
    public static func link(_ pid: pid_t) -> Link? { System.link(pid) }
}

extension Platform.Processes {
    /// The process holding a lock on the file at `path` (a `flock` or a POSIX lock, as `/proc/locks` lists it), found
    /// by the file's device and inode as the kernel holds them (its file system's device, which `stat`'s isn't on btrfs
    /// or an overlay), never by its name: a file renamed over `path` is another file, and its holder another process;
    /// a link at `path` is not followed. Linux: the first holder `/proc/locks` names with a pid (an open file description's lock, which
    /// names none, and a waiter, are passed over); nil when nothing holds one, the file isn't there, or the list can't
    /// be read. The Mac: nil (it has no such list). The engine plan's EN-D8: the command line's check of a scratch
    /// node, whose server must be the child of the host holding `<root>/scratch-host.lock`.
    public static func lockHolder(path: String) -> pid_t? { System.lockHolder(path: path) }

    /// `lockHolder`'s reading of a `/proc/locks` text: the pid of the first lock (not a waiter, `->`) on the file of
    /// device `major:minor` and inode `inode`, whose pid is a number above 0. Each line is
    /// `N: KIND ADVISORY|MANDATORY READ|WRITE PID MAJOR:MINOR:INODE START END`, the device's two numbers in hex.
    public static func lockHolder(locks: String, major: UInt64, minor: UInt64, inode: UInt64) -> pid_t? {
        for line in locks.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard words.count >= 6, words[1] != "->" else { continue }
            let file = words[5].split(separator: ":").map(String.init)
            guard file.count == 3, UInt64(file[0], radix: 16) == major, UInt64(file[1], radix: 16) == minor,
                  UInt64(file[2]) == inode, let pid = pid_t(words[4]), pid > 0 else { continue }
            return pid
        }
        return nil
    }

    /// The cgroup lines of the process `pid` (`/proc/<pid>/cgroup`, mode 0444, readable for a non-dumpable process
    /// too): `0::/init.scope` on the unified hierarchy, and on a hybrid one also each v1 line such as
    /// `1:name=systemd:/init.scope`. nil when they can't be read (gone, a thread's number, no such file), and on the
    /// Mac, which has no cgroups. The engine plan's voice rule (E1) reads them; a process of the user can't move
    /// itself out of the user's manager's tree.
    public static func cgroup(_ pid: pid_t) -> [String]? { pid > 0 ? System.cgroup(pid) : nil }

    /// Whether this system has cgroups: Linux does, the Mac doesn't (`cgroup` is nil there for every process).
    public static var hasCgroups: Bool { System.hasCgroups }
}
