#if canImport(Darwin)
import Foundation

// The Mac's folder watch, each half as VibeCore had it before this layer. `wait()` is LeadAdvance's: a kqueue on the
// folder (EVFILT_VNODE, EV_CLEAR: the changes since the last read are one event), read on the caller's own thread and
// stopped through a pipe; it hears the folder change even while every pooled thread is busy. `deliver` is
// WalletLocalLink's: a dispatch source on the folder's descriptor.
extension Platform.FolderWatch {
    final class System: @unchecked Sendable {
        private let lock = NSLock()
        // Under `lock`. Each descriptor is -1 once closed or handed to the dispatch source.
        private var folder: Int32
        private var kernelQueue: Int32
        /// A pipe the kqueue also reads: `stop()` writes to it.
        private var stopRead: Int32
        private var stopWrite: Int32
        private var stopped = false
        /// The threads inside `wait()` now: what they wait on is closed only when there are none.
        private var waiting = 0
        private var source: DispatchSourceFileSystemObject?

        convenience init?(path: String) {
            let folder = open(path, O_EVTONLY)
            guard folder >= 0 else { return nil }
            _ = fcntl(folder, F_SETFD, FD_CLOEXEC)
            self.init(descriptor: folder)
        }

        /// Takes `descriptor` over: closed when the watch stops, or here when it can't be watched.
        init?(descriptor: Int32) {
            let queue = descriptor >= 0 ? kqueue() : -1
            var pipes: [Int32] = [-1, -1]
            var watched = false
            if descriptor >= 0, queue >= 0, pipe(&pipes) == 0 {
                for end in pipes { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
                _ = fcntl(queue, F_SETFD, FD_CLOEXEC)
                var changes = [kevent(ident: UInt(descriptor), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                                      fflags: UInt32(NOTE_WRITE | NOTE_RENAME | NOTE_DELETE), data: 0, udata: nil),
                               kevent(ident: UInt(pipes[0]), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)]
                watched = kevent(queue, &changes, Int32(changes.count), nil, 0, nil) == 0
            }
            guard watched else {
                for held in [descriptor, queue] + pipes where held >= 0 { close(held) }
                return nil
            }
            folder = descriptor
            kernelQueue = queue
            stopRead = pipes[0]
            stopWrite = pipes[1]
        }

        /// Whether a thread is inside `wait()` now. For the tests.
        var isWaitedOn: Bool {
            lock.lock()
            defer { lock.unlock() }
            return waiting > 0
        }

        func wait() -> Change? {
            lock.lock()
            guard !stopped, source == nil, kernelQueue >= 0 else {
                lock.unlock()
                return nil
            }
            waiting += 1
            let queue = kernelQueue
            lock.unlock()
            defer {
                lock.lock()
                waiting -= 1
                if stopped && waiting == 0 { closeAll() }
                lock.unlock()
            }
            var event = kevent()
            while true {
                let count = kevent(queue, nil, 0, &event, 1, nil)
                if count < 0 && errno == EINTR { continue }
                // The pipe is never read: every wait, now and later, sees the stop.
                if count < 0 || event.filter == Int16(EVFILT_READ) { return nil }
                var change: Change = []
                if event.fflags & UInt32(NOTE_WRITE) != 0 { change.insert(.entries) }
                if event.fflags & UInt32(NOTE_RENAME | NOTE_DELETE) != 0 { change.insert(.folderGone) }
                if !change.isEmpty { return change }
            }
        }

        func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, source == nil, waiting == 0, folder >= 0 else { return }
            // The source has the folder's descriptor from here on, and closes it when it is cancelled. No wait: no
            // kqueue and no pipe.
            let descriptor = folder
            folder = -1
            closeAll()
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
            // The source in its own handler, as it was in WalletLocalLink: let go when the source is cancelled.
            source.setEventHandler {
                let data = source.data
                var change: Change = []
                if data.contains(.write) { change.insert(.entries) }
                // The folder itself gone or moved.
                if !data.intersection([.rename, .delete, .revoke]).isEmpty { change.insert(.folderGone) }
                if !change.isEmpty { handler(change) }
            }
            source.setCancelHandler { close(descriptor) }
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
                _ = Sys.write(stopWrite, [UInt8(1)], 1)
            }
        }

        /// Closes what the watch itself still holds. Under `lock`.
        private func closeAll() {
            for held in [kernelQueue, folder, stopRead, stopWrite] where held >= 0 { close(held) }
            kernelQueue = -1
            folder = -1
            stopRead = -1
            stopWrite = -1
        }
    }
}
#endif
