import Foundation

extension Platform {
    /// A watch on a folder: it tells when an entry of the folder is made, removed or renamed (in, out or within),
    /// and when the folder itself is removed or renamed. A write inside a file that is already there is no change of
    /// the folder, and isn't told. Nothing is polled and no process is started.
    ///
    /// A watch is read one of two ways, never both: `wait()` on a thread of the caller's own, or `deliver(on:_:)` on
    /// a queue. Changes that come close together are told as one. `stop()` ends either, from any thread, and so does
    /// letting go of the watch.
    ///
    /// The Mac's is a kqueue for `wait()` and a dispatch source for `deliver` (FolderWatch+Darwin.swift); Linux's is
    /// inotify for both (FolderWatch+Linux.swift). What differs:
    /// - `folderGone` for a folder that was removed comes at once on the Mac. On Linux it comes when the last
    ///   descriptor open on the folder is closed (some process's working directory counts): while one is, the
    ///   kernel keeps the folder and says nothing. A rename is told at once on both.
    /// - On Linux a folder of a 9p file system (a Windows drive under WSL) can't be watched: `init?` is nil. The
    ///   kernel would take the watch and never tell of what the other side changes.
    /// - The Mac watches whatever `path` names, Linux only a folder.
    public final class FolderWatch: @unchecked Sendable {
        public struct Change: OptionSet, Sendable {
            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }

            /// An entry of the folder was made, removed or renamed.
            public static let entries = Change(rawValue: 1 << 0)
            /// The folder itself was removed or renamed (or its volume taken away): what is watched is no longer
            /// what the path names, and no further change of it is told.
            public static let folderGone = Change(rawValue: 1 << 1)
        }

        /// The system's own watch. Not private: the tests ask it what it holds.
        let system: System

        /// Watches the folder at `path` from now on; nil when it can't be watched (it isn't there, it isn't a
        /// folder, its file system doesn't tell, no descriptor is left).
        public init?(path: String) {
            guard let system = System(path: path) else { return nil }
            self.system = system
        }

        /// Watches the folder `descriptor` is open on, and takes the descriptor over, whatever the result: the
        /// caller no longer closes it, and must not use it. (The Mac keeps it until the watch stops; Linux closes it
        /// at once, as a descriptor held on a folder would keep its removal from being told.)
        public init?(descriptor: Int32) {
            guard let system = System(descriptor: descriptor) else { return nil }
            self.system = system
        }

        /// Blocks until the folder changes, and says how: every change since the last answer, as one. nil once the
        /// watch is stopped (a `stop()` from another thread ends a wait under way), and for a watch given to
        /// `deliver`. After a `folderGone` nothing more comes: the next wait lasts until `stop()`.
        public func wait() -> Change? {
            system.wait()
        }

        /// From now on `handler` is called on `queue` for each change (those close together as one), until
        /// `stop()`; one already running then may still finish. Once: a second call, and one on a watch that is
        /// stopped or waited on, does nothing.
        public func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void) {
            system.deliver(on: queue, handler)
        }

        /// Ends the watch and closes what it holds (at once; when a wait or a handler is under way, as that ends).
        /// Safe to call again, and from any thread, a handler's own included.
        public func stop() {
            system.stop()
        }

        deinit { system.stop() }
    }
}
