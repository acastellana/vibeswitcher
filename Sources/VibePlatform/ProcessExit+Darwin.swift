#if canImport(Darwin)
import Foundation

// The Mac's: a dispatch source on the process, as VibeHost's three watches made it (HostServer's on its owner,
// HostedSession's on its program, SessionParser's on its host).
extension Platform.ProcessExit {
    enum System {
        /// The Mac has no descriptor of a process: nothing is held, and nothing held runs.
        static func hold(_ pid: pid_t) -> Int32? { nil }
        static func stillRuns(_ held: Int32, pid: pid_t) -> Bool { false }

        static func watch(_ pid: pid_t, queue: DispatchQueue, _ ended: @escaping @Sendable () -> Void) -> Watch {
            let watch = Watch(ended)
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak watch] in watch?.report() }
            watch.hold(source)
            source.resume()
            // Gone before the watch began: no exit comes (HostServer's own look, made here for every caller).
            queue.async { [weak watch] in
                if kill(pid, 0) != 0, errno == ESRCH { watch?.report() }
            }
            return watch
        }
    }
}
#endif
