import Foundation

extension Platform {
    /// Something under way that its starter can call off.
    public protocol Cancellable: AnyObject, Sendable {
        /// Calls it off: nothing it would have told is told from here on (what is being told at this moment, on
        /// another thread, may still finish). Safe to call again, and from any thread.
        func cancel()
        /// Whether `cancel()` was called. Having told what it was there to tell doesn't make it so.
        var isCancelled: Bool { get }
    }

    /// The end of a process that needn't be this one's child, told when it comes: nothing is polled.
    ///
    /// The Mac's is a dispatch source on the process (ProcessExit+Darwin.swift); Linux's reads a descriptor of the
    /// process, `pidfd_open` (ProcessExit+Linux.swift).
    public enum ProcessExit {
        /// Calls `ended` on `queue`, once, when the process `pid` has ended: when it exits, not when its parent
        /// collects it, so a caller watching its own child still has to collect it (`waitpid`), as before. Also
        /// once, right away, when there is no such process as the watch begins: it ended earlier, and whoever asks
        /// can't have learned of that from this watch.
        ///
        /// Keep what it returns for as long as the end is wanted: `cancel()` on it, or letting go of it, ends the
        /// watch, and `ended` is then never called.
        ///
        /// A process that has ended and isn't collected yet as the watch begins (a zombie) is told on Linux; the
        /// Mac leaves it to its dispatch source, which the callers there back up with a look of their own.
        public static func watch(_ pid: pid_t, queue: DispatchQueue, _ ended: @escaping @Sendable () -> Void) -> any Platform.Cancellable {
            System.watch(pid, queue: queue, ended)
        }

        /// What `watch` returns on both systems: the system's source, and `ended` until it has been called.
        final class Watch: Platform.Cancellable, @unchecked Sendable {
            private let lock = NSLock()
            private var ended: (@Sendable () -> Void)?
            private var source: (any DispatchSourceProtocol)?
            private var cancelled = false

            init(_ ended: @escaping @Sendable () -> Void) {
                self.ended = ended
            }

            /// The source that tells of the end: cancelled when the watch is, or once it has told. Before it is
            /// resumed.
            func hold(_ source: any DispatchSourceProtocol) {
                lock.lock()
                self.source = source
                lock.unlock()
            }

            var isCancelled: Bool {
                lock.lock()
                defer { lock.unlock() }
                return cancelled
            }

            func cancel() {
                lock.lock()
                cancelled = true
                ended = nil
                let source = self.source
                self.source = nil
                lock.unlock()
                source?.cancel()
            }

            /// The process has ended: `ended` is called, the first time and unless the watch was called off. On the
            /// watch's queue.
            func report() {
                lock.lock()
                let ended = self.ended
                self.ended = nil
                let source = self.source
                self.source = nil
                lock.unlock()
                source?.cancel()
                ended?()
            }

            deinit { source?.cancel() }
        }
    }
}
