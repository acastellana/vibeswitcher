import Foundation

extension Platform {
    /// What the process's file watches (`FolderWatch`, `FileWatch`) couldn't get from the system. A watch whose `init?`
    /// is nil for want of a kernel resource (on Linux: no inotify instance left for this user, fs.inotify.
    /// max_user_instances; no watch left, max_user_watches; no memory) is counted here, and the first such is told once
    /// (`whenFirstUnmade`, the standard error by default), so none fails silently: its owner sees changes at its next
    /// housekeeping look instead, and the node says how many in `status --health`. A path that isn't there, isn't a
    /// folder (or a file) or is on a file system that doesn't tell isn't counted: that is the path's answer, not the
    /// system's. The Mac's watches count nothing.
    public enum Watches {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var count = 0
        nonisolated(unsafe) private static var told: (@Sendable (String) -> Void)?

        /// How many watches couldn't be made for want of a kernel resource since the process started.
        public static var unmade: Int { lock.withLock { count } }

        /// Called once, with what happened, at the first watch that couldn't be made (set by the process before its
        /// first watch: the server's and the host's logs). Unset, the line goes to the standard error.
        public static var whenFirstUnmade: (@Sendable (String) -> Void)? {
            get { lock.withLock { told } }
            set { lock.withLock { told = newValue } }
        }

        /// A scratch host's or server's test flags (`--test-no-inotify`, `--test-inotify-census`), set before its first
        /// watch: `testNoInstance`, no inotify instance is made (as when the user has none left: every watch is unmade);
        /// `testCensus`, a folder where the process writes a file named by its pid when it makes its instance (how a test
        /// counts the instances of processes it can't look into). Never set on the user's node, whose host and server
        /// refuse the flags.
        public static var testNoInstance: Bool {
            get { lock.withLock { noInstance } }
            set { lock.withLock { noInstance = newValue } }
        }
        public static var testCensus: String? {
            get { lock.withLock { census } }
            set { lock.withLock { census = newValue } }
        }
        nonisolated(unsafe) private static var noInstance = false
        nonisolated(unsafe) private static var census: String?

        /// The process made its instance: said in the census folder, when there is one.
        static func noteInstance() {
            guard let folder = testCensus else { return }
            let name = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "?"
            let line = "\(name) \(CommandLine.arguments.dropFirst().prefix(6).joined(separator: " "))\n"
            let file = open(folder + "/\(getpid())", O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o600)
            guard file >= 0 else { return }
            _ = line.withCString { write(file, $0, strlen($0)) }
            close(file)
        }

        /// The count back to none, so the next is the process's first again. For the tests.
        static func resetForTests() { lock.withLock { count = 0 } }

        /// A watch of `path` couldn't be made: `why`, the system's answer.
        static func noteUnmade(_ path: String, _ why: String) {
            let (first, tell) = lock.withLock { () -> (Bool, (@Sendable (String) -> Void)?) in
                count += 1
                return (count == 1, told)
            }
            guard first else { return }
            let line = "a file watch couldn't be made (\(path): \(why)): changes it would have told are seen at the next housekeeping look; `status --health` counts every such watch"
            if let tell { tell(line) } else { Stdio.error("vibeswitcher: " + line + "\n") }
        }
    }
}
