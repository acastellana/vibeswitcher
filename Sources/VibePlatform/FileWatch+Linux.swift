#if os(Linux)
import Foundation

// Linux's file watch: a client of the process's one inotify instance (`InotifyHub`, Watches+Linux.swift). A burst of
// writes is one `Change`: the watch takes every event told to it, the kernel's queue read first, when it answers.
extension Platform.FileWatch {
    final class System: @unchecked Sendable {
        /// Written to, or closed after a write (IN_CLOSE_WRITE also tells of a rewrite that kept the size).
        static let writeEvents = UInt32(IN_MODIFY) | UInt32(IN_CLOSE_WRITE)
        /// The file removed (told when the last descriptor open on it closes) or renamed, or its file system unmounted.
        static let goneEvents = UInt32(IN_DELETE_SELF) | UInt32(IN_MOVE_SELF) | UInt32(IN_UNMOUNT)

        /// The watch's share of the instance. Not private: the tests ask it what it holds.
        let client: InotifyClient

        init?(path: String) {
            // 9p (a Windows drive under WSL): the kernel takes the watch and tells only of what this system's own
            // processes change there. Refused rather than half heard.
            var kind: UInt = 0
            guard vibe_filesystem_type(path, &kind) == 0, kind != UInt(VIBE_9P_MAGIC) else { return nil }
            var facts = stat()
            guard stat(path, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG else { return nil }
            guard let client = InotifyHub.shared.watch(path, mask: Self.writeEvents | Self.goneEvents, folder: false) else { return nil }
            self.client = client
        }

        func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void) {
            client.deliver(on: queue) { events in
                let change = Self.change(events)
                if !change.isEmpty { handler(change) }
            }
        }

        func stop() {
            client.stop()
        }

        /// What a read's events say. The kernel dropping events (IN_Q_OVERFLOW) is a write, which the caller then reads
        /// for itself; the kernel ending the watch (IN_IGNORED: the file gone) is gone, as nothing more will be told.
        static func change(_ mask: UInt32) -> Change {
            var change: Change = []
            if mask & (writeEvents | UInt32(IN_Q_OVERFLOW)) != 0 { change.insert(.written) }
            if mask & (goneEvents | UInt32(IN_IGNORED)) != 0 { change.insert(.gone) }
            return change
        }
    }
}
#endif
