#if os(Linux)
import Foundation

// Linux's file watch: inotify on the file. A burst of writes queues an event each; the queue is read to its end before
// the handler is told, so a burst is one `Change`.
extension Platform.FileWatch {
    final class System: @unchecked Sendable {
        /// Written to, or closed after a write (IN_CLOSE_WRITE also tells of a rewrite that kept the size).
        static let writeEvents = UInt32(IN_MODIFY) | UInt32(IN_CLOSE_WRITE)
        /// The file removed (told when the last descriptor open on it closes) or renamed, or its file system unmounted.
        static let goneEvents = UInt32(IN_DELETE_SELF) | UInt32(IN_MOVE_SELF) | UInt32(IN_UNMOUNT)

        private let lock = NSLock()
        // Under `lock`. -1 once closed or handed to the dispatch source.
        private var inotify: Int32
        private var stopped = false
        private var source: DispatchSourceRead?

        init?(path: String) {
            // 9p (a Windows drive under WSL): the kernel takes the watch and tells only of what this system's own
            // processes change there. Refused rather than half heard.
            var kind: UInt = 0
            guard vibe_filesystem_type(path, &kind) == 0, kind != UInt(VIBE_9P_MAGIC) else { return nil }
            var facts = stat()
            guard stat(path, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG else { return nil }
            let inotify = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
            guard inotify >= 0 else { return nil }
            guard inotify_add_watch(inotify, path, Self.writeEvents | Self.goneEvents) >= 0 else {
                close(inotify)
                return nil
            }
            self.inotify = inotify
        }

        func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, source == nil, inotify >= 0 else { return }
            // The source has the descriptor from here on, and closes it when it is cancelled.
            let inotify = self.inotify
            self.inotify = -1
            let source = DispatchSource.makeReadSource(fileDescriptor: inotify, queue: queue)
            source.setEventHandler {
                let change = Self.change(Platform.FolderWatch.System.drained(inotify))
                if !change.isEmpty { handler(change) }
            }
            source.setCancelHandler { close(inotify) }
            self.source = source
            source.resume()
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            stopped = true
            if let source {
                self.source = nil
                source.cancel()
            } else if inotify >= 0 {
                close(inotify)
                inotify = -1
            }
        }

        /// What a read's events say. The kernel dropping events (IN_Q_OVERFLOW) is a write, which the caller then reads
        /// for itself; the watch's own end (IN_IGNORED) is nothing.
        static func change(_ mask: UInt32) -> Change {
            var change: Change = []
            if mask & (writeEvents | UInt32(IN_Q_OVERFLOW)) != 0 { change.insert(.written) }
            if mask & goneEvents != 0 { change.insert(.gone) }
            return change
        }
    }
}
#endif
