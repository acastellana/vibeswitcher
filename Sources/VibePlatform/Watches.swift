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
