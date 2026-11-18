#if os(Linux)
import Foundation

// Linux's: a descriptor of the process (`pidfd_open`, Linux 5.3; through the shim, as glibc has it only from 2.36 and
// musl not at all), which reads as ready once the process has ended, whoever its parent is, and a dispatch source
// on it. The descriptor doesn't collect the process: its parent still does.
extension Platform.ProcessExit {
    enum System {
        /// How often a process is asked about where it can't be opened (`watch`'s last case).
        static let askEvery: TimeInterval = 0.5

        static func watch(_ pid: pid_t, queue: DispatchQueue, _ ended: @escaping @Sendable () -> Void) -> Watch {
            watch(pid, queue: queue, opening: { vibe_pidfd_open($0, 0) }, ended)
        }

        /// `open`: `pidfd_open`, or what stands in for it in a test.
        static func watch(_ pid: pid_t, queue: DispatchQueue, opening open: (pid_t) -> Int32,
                          _ ended: @escaping @Sendable () -> Void) -> Watch {
            let watch = Watch(ended)
            let descriptor = open(pid)
            let refusal = errno
            if descriptor >= 0 {
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                // Ready from the process's end on, for good: `report` cancels the source, so it is told once.
                source.setEventHandler { [weak watch] in watch?.report() }
                source.setCancelHandler { close(descriptor) }
                watch.hold(source)
                source.resume()
            } else if refusal == ESRCH {
                // No such process: it ended before the watch began, and was collected.
                queue.async { [weak watch] in watch?.report() }
            } else {
                // No descriptor to be had (a kernel before 5.3: ENOSYS; none left: EMFILE). Never a watch that
                // stays silent: the process is asked about instead.
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: askEvery, leeway: .milliseconds(50))
                timer.setEventHandler { [weak watch] in
                    if hasEnded(pid) { watch?.report() }
                }
                watch.hold(timer)
                timer.resume()
            }
            return watch
        }

        static func hold(_ pid: pid_t) -> Int32? {
            let descriptor = vibe_pidfd_open(pid, 0)
            return descriptor >= 0 ? descriptor : nil
        }

        /// A pidfd names its process in /proc/self/fdinfo (`Pid:`, -1 once it is collected) and reads as ready once it
        /// has exited, never before; anything else isn't one of `hold`'s.
        static func stillRuns(_ held: Int32, pid: pid_t) -> Bool {
            guard held >= 0, pid > 0, case .success(let bytes) = Platform.Processes.System.contents("/proc/self/fdinfo/\(held)") else { return false }
            let named = String(decoding: bytes, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("Pid:") }
                .flatMap { pid_t($0.dropFirst(4).trimmingCharacters(in: .whitespaces)) }
            guard named == pid else { return false }
            var waiting = pollfd(fd: held, events: Int16(POLLIN), revents: 0)
            var ready: Int32
            repeat { ready = poll(&waiting, 1, 0) } while ready < 0 && errno == EINTR
            return ready == 0
        }

        /// Whether `pid` is no process any more, or one that has exited and waits to be collected.
        static func hasEnded(_ pid: pid_t) -> Bool {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            if case .brief(let brief) = Platform.Processes.brief(pid) { return brief.state == .zombie }
            return false
        }
    }
}
#endif
