#if os(Linux)
import Foundation

// Linux's: a descriptor of the process (`pidfd_open`, through the shim as in ProcessExit+Linux.swift), which polls
// ready once the process has exited, whoever its parent is, and for good: it's closed once it has told, so that only
// one pause ends early, as the Mac's one-shot event.
extension Platform.ExitWait {
    /// A descriptor of `pid` (close-on-exec, as `pidfd_open` makes every one); -1 when it can't be had (no such
    /// process, a kernel before 5.3, none left).
    static func open(_ pid: pid_t) -> Int32 { vibe_pidfd_open(pid, 0) }

    static func wait(_ fd: Int32, upTo seconds: TimeInterval) -> Outcome {
        var polled = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let count = poll(&polled, 1, Int32((seconds * 1000).rounded(.up)))
        return count > 0 ? .exited : count == 0 ? .timedOut : .failed
    }

    /// The exit was told: the descriptor goes, and later pauses are plain sleeps.
    static func told(_ fd: inout Int32) {
        close(fd)
        fd = -1
    }
}
#endif
