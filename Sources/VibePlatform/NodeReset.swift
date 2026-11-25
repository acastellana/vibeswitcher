extension Platform {
    /// What a checked Mac node host resets of what it was started with, before it reads its record (the node on the
    /// Mac's design, "What a checked node resets at its start"): the process state a wrapper that runs its genuine image
    /// chooses. Linux's forms do nothing (no checked Mac node runs there); the Mac's are in NodeReset+Darwin.swift.
    public enum NodeReset {
        /// `umask` 077, the working folder `/`, no core files (`RLIMIT_CORE` 0, soft and hard), and every descriptor
        /// above 2 that isn't close-on-exec (one it was given across its exec) closed but `keeping`. Why not, or nil.
        public static func processState(keeping: Set<Int32>) -> String? { System.processState(keeping: keeping) }

        /// The system's own temporary folder for this user (`confstr(_CS_DARWIN_USER_TEMP_DIR)`), nil where there is none.
        public static var userTemporaryFolder: String? { System.userTemporaryFolder }
    }
}
