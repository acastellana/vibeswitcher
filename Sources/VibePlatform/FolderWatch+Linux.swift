#if os(Linux)
import Foundation

// Linux's folder watch: inotify. Unlike a kqueue with EV_CLEAR, which folds the changes since the last read into one
// event, inotify queues an event for each: the queue is read to its end before an answer is given, so a burst of
// changes is one `Change` here too. Closing an inotify descriptor takes the kernel tens of milliseconds (it waits
// for every reader of its marks): `stop()` takes that long when no wait is under way to do the closing.
extension Platform.FolderWatch {
    final class System: @unchecked Sendable {
        /// An entry made, removed, renamed out or renamed in. Not IN_MODIFY: a write inside a file that is there
        /// isn't a change of the folder (the Mac's NOTE_WRITE on a folder doesn't fire for it, and callers count on
        /// that).
        static let entryEvents = UInt32(IN_CREATE) | UInt32(IN_DELETE) | UInt32(IN_MOVED_FROM) | UInt32(IN_MOVED_TO)
        /// The folder itself removed or renamed, or its file system unmounted.
        static let folderEvents = UInt32(IN_DELETE_SELF) | UInt32(IN_MOVE_SELF) | UInt32(IN_UNMOUNT)

        private let lock = NSLock()
        // Under `lock`. Each descriptor is -1 once closed or handed to the dispatch source.
        private var inotify: Int32
        /// A pipe that `stop()` writes to: a wait polls its reading end beside `inotify`.
        private var wakeRead: Int32
        private var wakeWrite: Int32
        private var stopped = false
        /// The threads inside `wait()` now: what they poll is closed only when there are none.
        private var waiting = 0
        private var source: DispatchSourceRead?
        /// Entered while the watch holds a descriptor, left when the last is closed: the tests wait on it.
        let released = DispatchGroup()

        convenience init?(path: String) {
            self.init(watching: path)
        }

        /// The folder is watched by the name /proc gives the descriptor, and the descriptor closed: while one is
        /// open on a folder the kernel doesn't say the folder was removed (IN_DELETE_SELF comes when the last
        /// reference to it goes), and the watch itself needs none.
        convenience init?(descriptor: Int32) {
            defer { if descriptor >= 0 { close(descriptor) } }
            self.init(watching: "/proc/self/fd/\(descriptor)")
        }

        private init?(watching path: String) {
            // 9p (a Windows drive under WSL): the kernel takes the watch and tells only of what this system's own
            // processes change there, never of what the other side does. Refused rather than half heard.
            var kind: UInt = 0
            guard vibe_filesystem_type(path, &kind) == 0, kind != UInt(VIBE_9P_MAGIC) else { return nil }
            let inotify = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
            guard inotify >= 0 else { return nil }
            var ends: [Int32] = [-1, -1]
            // IN_ONLYDIR: a file's watch would never tell of anything asked for here.
            guard inotify_add_watch(inotify, path, Self.entryEvents | Self.folderEvents | UInt32(IN_ONLYDIR)) >= 0,
                  Sys.pipeClosedOnExec(&ends) == 0 else {
                close(inotify)
                return nil
            }
            for end in ends { _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK) }
            self.inotify = inotify
            wakeRead = ends[0]
            wakeWrite = ends[1]
            released.enter()
        }

        /// Whether a thread is inside `wait()` now. For the tests.
        var isWaitedOn: Bool {
            lock.lock()
            defer { lock.unlock() }
            return waiting > 0
        }

        func wait() -> Change? {
            lock.lock()
            guard !stopped, source == nil, inotify >= 0 else {
                lock.unlock()
                return nil
            }
            waiting += 1
            let inotify = self.inotify, wake = wakeRead
            lock.unlock()
            defer {
                lock.lock()
                waiting -= 1
                if stopped && waiting == 0 { closeAll() }
                lock.unlock()
            }
            while true {
                var polled = [pollfd(fd: inotify, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
                let count = poll(&polled, 2, -1)
                if count < 0 && errno == EINTR { continue }
                // The wake pipe is never read: every wait, now and later, sees the stop.
                if count < 0 || polled[1].revents != 0 { return nil }
                if polled[0].revents == 0 { continue }
                guard polled[0].revents & Int16(POLLIN) != 0 else { return nil }
                let change = Self.change(Self.drained(inotify))
                if !change.isEmpty { return change }
            }
        }

        func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, source == nil, waiting == 0, inotify >= 0 else { return }
            // The source has the inotify descriptor from here on, and closes it when it is cancelled (a descriptor
            // closed under a source that still polls it is the next file to get its number). No wait: no pipe.
            let inotify = self.inotify
            self.inotify = -1
            closeWake()
            let source = DispatchSource.makeReadSource(fileDescriptor: inotify, queue: queue)
            source.setEventHandler {
                let change = Self.change(Self.drained(inotify))
                if !change.isEmpty { handler(change) }
            }
            source.setCancelHandler { [released] in
                close(inotify)
                released.leave()
            }
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
            } else if waiting == 0 {
                closeAll()
            } else {
                var one: UInt8 = 1
                _ = write(wakeWrite, &one, 1)
            }
        }

        /// Closes what the watch itself still holds. Under `lock`.
        private func closeAll() {
            closeWake()
            guard inotify >= 0 else { return }
            close(inotify)
            inotify = -1
            released.leave()
        }

        private func closeWake() {
            for end in [wakeRead, wakeWrite] where end >= 0 { close(end) }
            wakeRead = -1
            wakeWrite = -1
        }

        /// Reads every event queued on `inotify` (not blocking): their masks, together. 0 for none.
        static func drained(_ inotify: Int32) -> UInt32 {
            // An event is 16 bytes and its entry's name, 256 at most.
            let header = MemoryLayout<inotify_event>.size
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var mask: UInt32 = 0
            while true {
                let count = read(inotify, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                // EAGAIN: the queue is empty.
                guard count > 0 else { break }
                var offset = 0
                while offset + header <= count {
                    let event = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: inotify_event.self) }
                    mask |= event.mask
                    offset += header + Int(event.len)
                }
            }
            return mask
        }

        /// What a read's events say. The kernel dropping events (its queue was full: IN_Q_OVERFLOW) is a change of
        /// the entries, which the caller then reads for itself; the watch's own end (IN_IGNORED) is nothing.
        static func change(_ mask: UInt32) -> Change {
            var change: Change = []
            if mask & (entryEvents | UInt32(IN_Q_OVERFLOW)) != 0 { change.insert(.entries) }
            if mask & folderEvents != 0 { change.insert(.folderGone) }
            return change
        }
    }
}
#endif
