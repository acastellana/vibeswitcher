extension Platform {
    /// A program to start, and what it starts with: its descriptors, its directory and environment, its session or
    /// group, its signals. `start()` runs it as a child; `replaceProcess()` runs it in place of this process.
    ///
    /// The child's descriptors are set in the order stdin, stdout, stderr, then the directory: a terminal opened as
    /// its stdin is there when stdout and stderr are made the same. It always starts with no signal blocked,
    /// whatever the thread that starts it blocks (libdispatch's threads block most signals, and a child that
    /// inherited that would never hear SIGTERM).
    ///
    /// The systems' own calls are in Spawn+Darwin.swift and Spawn+Linux.swift.
    public struct Spawn {
        /// What the child has as its stdin, stdout or stderr.
        public enum Stdio {
            /// This process's descriptor of that number, even one marked close-on-exec here.
            case inherit
            /// A copy of this descriptor of this process.
            case descriptor(Int32)
            /// The file at a path, opened in the child with open(2)'s `flags` and `mode`.
            case path(String, flags: Int32, mode: mode_t = 0)
            /// A copy of the child's stdin, as set just before (for stdin itself: `inherit`).
            case sameAsStdin
        }

        public enum Group {
            /// This process's group and session.
            case inherit
            /// A process group of its own, in this process's session: its group's id is its pid.
            case ownGroup
            /// A session of its own, with no controlling terminal until it opens one.
            case ownSession
        }

        /// The signals whose handling is the default in the child; the others stay ignored where this process
        /// ignores them. (A signal this process catches is at its default in any new program.)
        public enum SignalDefaults {
            case all
            case only([Int32])
        }

        /// The program's path: not looked up on PATH.
        public var executable: String
        /// Its argv, argv[0] included.
        public var arguments: [String]
        /// "NAME=value" each; nil: this process's.
        public var environment: [String]? = nil
        /// The directory it starts in; nil: this process's.
        public var directory: String? = nil
        public var stdin = Stdio.inherit, stdout = Stdio.inherit, stderr = Stdio.inherit
        /// The other descriptors of this process it keeps, under the same numbers, even ones marked close-on-exec
        /// here: it has nothing else open. nil: it keeps every descriptor that isn't marked close-on-exec.
        public var keep: [Int32]? = []
        public var group = Group.inherit
        public var defaults = SignalDefaults.all

        public init(executable: String, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }

        /// `strings` as C's argv and envp want them: a copy of each, then nil. `release` frees them.
        static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
            strings.map { strdup($0) } + [nil]
        }

        static func release(_ strings: [UnsafeMutablePointer<CChar>?]) {
            strings.forEach { free($0) }
        }
    }
}
