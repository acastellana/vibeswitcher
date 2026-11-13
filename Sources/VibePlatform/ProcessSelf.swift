extension Platform {
    /// What this process does to itself: makes itself non-dumpable, and asks whether it is and who traces it.
    ///
    /// On Linux a process of the user is open to every other process of the same user while it is dumpable: with no
    /// Yama (WSL's kernel has none), any of them may ptrace it, read its memory (`process_vm_readv`,
    /// `/proc/<pid>/mem`) and take its descriptors (`pidfd_getfd`). Non-dumpable closes all of that to anyone without
    /// `CAP_SYS_PTRACE`, and keeps it out of a core dump. The entries of its /proc/<pid> become root's, all but the
    /// folder itself (mode 0555, which stays its effective user's): those of mode 0444 (`stat`, `status`, `limits`)
    /// stay readable to anyone, the others (`fd`, `mem`, `environ`) to root alone. It is the one lock the session
    /// host, its parsers and its server have against another program of the user (the security architecture
    /// document's S6). An exec of a file the process can read makes it dumpable again: what a new image keeps is the
    /// business of the sealed copies it is started from (S9), not of this.
    ///
    /// The Mac's forms do nothing and say nothing (`harden()` false, the reads nil): its processes are kept from each
    /// other by the system's own rules (no `task_for_pid` without an entitlement), and the Mac's path keeps today's
    /// behaviour. The systems' own calls are in ProcessSelf+Linux.swift and ProcessSelf+Darwin.swift. The images it
    /// starts, sealed in-memory copies, are in SealedCopy.swift.
    public enum ProcessSelf {
        /// Makes this process non-dumpable (`PR_SET_DUMPABLE 0`) and gives it no core file (`RLIMIT_CORE 0`, soft and
        /// hard); true when both held. For the first statements of a program that holds what no other process of the
        /// user may read, never for a test process (other tests read its /proc entries). Doing it twice is harmless.
        /// On this kernel `RLIMIT_CORE` limits nothing (`core_pattern` is a pipe, which core(5) doesn't limit by it):
        /// it is set for kernels where a core is a file. The Mac: nothing, and false.
        public static func harden() -> Bool { System.harden() }

        /// Whether this process is dumpable now (`PR_GET_DUMPABLE` is 1: by its own user, not root alone); nil when
        /// that can't be asked. The Mac: nil.
        public static func isDumpable() -> Bool? { System.isDumpable() }

        /// The pid of the process that traces this one (`TracerPid` in /proc/self/status), 0 when none does; nil
        /// when the status can't be read. The Mac: nil. A tracer attached since is seen at the next call, not before.
        public static func tracer() -> pid_t? { System.tracer() }

        /// The `TracerPid` of a /proc/<pid>/status text: 0 when nothing traces the process; nil when the text has
        /// no such field or it isn't a number.
        public static func tracer(fromStatus status: String) -> pid_t? {
            guard let fields = statusFields("TracerPid", in: status), fields.count == 1 else { return nil }
            return number(fields[0])
        }

        /// The effective user of a /proc/<pid>/status text: the second of its `Uid` line's four (real, effective,
        /// saved, file system); nil without one. The user `SO_PEERCRED` names, the owner of the process's /proc/<pid>
        /// folder, and of its other entries while it is dumpable and has its memory (root's otherwise).
        static func effectiveUser(fromStatus status: String) -> uid_t? {
            guard let fields = statusFields("Uid", in: status), fields.count == 4 else { return nil }
            return number(fields[1])
        }

        /// The values of the field `name` of a /proc/<pid>/status text ("Name:\tvalue\tvalue"), split at tabs and
        /// spaces; nil when it has no such field.
        static func statusFields(_ name: String, in status: String) -> [Substring]? {
            let key = name + ":"
            for line in status.split(separator: "\n") where line.hasPrefix(key) {
                return line.dropFirst(key.count).split(whereSeparator: { $0 == "\t" || $0 == " " })
            }
            return nil
        }

        /// A number of digits alone; nil for anything else, a sign included.
        private static func number<Value: FixedWidthInteger>(_ text: Substring) -> Value? {
            guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
            return Value(text)
        }
    }
}
