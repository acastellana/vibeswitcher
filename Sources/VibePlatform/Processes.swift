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
}
