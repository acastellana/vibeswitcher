import Foundation

extension Platform {
    /// A watch on one file: it tells when the file is written to (appended, rewritten in place, truncated) and when the
    /// file itself is removed or renamed. A folder's watch (`FolderWatch`) never tells of a write inside a file; a
    /// transcript an agent appends to is followed by this one (the live chat, `ChatStore`). Nothing is polled and no
    /// process is started.
    ///
    /// It is read on a queue (`deliver(on:_:)`): changes that come close together are told as one. `stop()` ends it,
    /// from any thread, and so does letting go of the watch.
    ///
    /// The Mac's is a dispatch source on the file's descriptor (FileWatch+Darwin.swift); Linux's is a watch on the
    /// process's one inotify instance (FileWatch+Linux.swift, `InotifyHub`). What differs:
    /// - On Linux a file of a 9p file system (a Windows drive under WSL) can't be watched: `init?` is nil. The kernel
    ///   would take the watch and never tell of what the other side writes.
    /// - On Linux `gone` for a removed file comes when the last descriptor open on it is closed; a rename is told at
    ///   once on both.
    public final class FileWatch: @unchecked Sendable {
        public struct Change: OptionSet, Sendable {
            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }

            /// The file was written to: its bytes or its size changed.
            public static let written = Change(rawValue: 1 << 0)
            /// The file itself was removed or renamed (or its volume taken away): what is watched is no longer what the
            /// path names, and no further change of it is told.
            public static let gone = Change(rawValue: 1 << 1)
        }

        let system: System

        /// Watches the regular file at `path` from now on; nil when it can't be watched (it isn't there, it isn't a
        /// file, its file system doesn't tell, the system has no watch left: that last counted, `Platform.Watches`).
        public init?(path: String) {
            guard let system = System(path: path) else { return nil }
            self.system = system
        }

        /// From now on `handler` is called on `queue` for each change (those close together as one), until `stop()`;
        /// one already running then may still finish. Once: a second call, and one on a watch that is stopped, does
        /// nothing.
        public func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void) {
            system.deliver(on: queue, handler)
        }

        /// Ends the watch and closes what it holds. Safe to call again, and from any thread, a handler's own included.
        public func stop() {
            system.stop()
        }

        deinit { system.stop() }
    }
}
