#if canImport(Darwin)
import Foundation

// The Mac's: a kqueue with the process's NOTE_EXIT on it, one-shot (main's `Shell.ExitWatch`, 2026-11-18).
extension Platform.ExitWait {
    /// A kqueue watching `pid`'s exit; -1 when it can't be had or the process can't be watched.
    static func open(_ pid: pid_t) -> Int32 {
        let queue = kqueue()
        guard queue >= 0 else { return -1 }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
            close(queue)
            return -1
        }
        return queue
    }

    static func wait(_ queue: Int32, upTo seconds: TimeInterval) -> Outcome {
        var event = kevent()
        var timeout = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1_000_000_000))
        let count = kevent(queue, nil, 0, &event, 1, &timeout)
        return count > 0 ? .exited : count == 0 ? .timedOut : .failed
    }

    /// The exit was told: the one-shot event is gone with it, and the kqueue stays (later waits time out).
    static func told(_ queue: inout Int32) {}
}
#endif
