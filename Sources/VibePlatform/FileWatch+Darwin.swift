#if canImport(Darwin)
import Foundation

// The Mac's file watch: a dispatch source on the file's descriptor (EVFILT_VNODE), the way the app follows a transcript.
extension Platform.FileWatch {
    final class System: @unchecked Sendable {
        private let lock = NSLock()
        // Under `lock`. -1 once closed or handed to the dispatch source.
        private var file: Int32
        private var stopped = false
        private var source: DispatchSourceFileSystemObject?

        init?(path: String) {
            var facts = stat()
            guard stat(path, &facts) == 0, facts.st_mode & S_IFMT == S_IFREG else { return nil }
            let file = open(path, O_EVTONLY | O_CLOEXEC)
            guard file >= 0 else { return nil }
            self.file = file
        }

        func deliver(on queue: DispatchQueue, _ handler: @escaping @Sendable (Change) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, source == nil, file >= 0 else { return }
            // The source has the descriptor from here on, and closes it when it is cancelled.
            let descriptor = file
            file = -1
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
            source.setEventHandler {
                let data = source.data
                var change: Change = []
                if !data.intersection([.write, .extend]).isEmpty { change.insert(.written) }
                if !data.intersection([.delete, .rename, .revoke]).isEmpty { change.insert(.gone) }
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
            } else if file >= 0 {
                close(file)
                file = -1
            }
        }
    }
}
#endif
