import Foundation

extension Platform {
    /// The clocks the wall clock isn't: time awake, and a thread's own CPU time; and work run later on a queue.
    public enum Clock {
        /// Seconds this machine has been awake, from a start that doesn't matter: it never goes back, and it stands
        /// still while the machine sleeps. The Mac's `CLOCK_UPTIME_RAW` (mach_absolute_time); Linux's
        /// `CLOCK_MONOTONIC`, which doesn't count a suspend either. The Mac's own `CLOCK_MONOTONIC` does count sleep,
        /// so the two systems' names can't be one.
        public static func awakeSeconds() -> TimeInterval {
            #if canImport(Darwin)
            return TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
            #else
            var now = timespec()
            clock_gettime(CLOCK_MONOTONIC, &now)
            return TimeInterval(now.tv_sec) + TimeInterval(now.tv_nsec) / 1e9
            #endif
        }

        /// The CPU time the calling thread has used so far, in nanoseconds (`CLOCK_THREAD_CPUTIME_ID`).
        public static func threadCPUNanoseconds() -> UInt64 {
            #if canImport(Darwin)
            return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            #else
            var used = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &used)
            return UInt64(used.tv_sec) * 1_000_000_000 + UInt64(used.tv_nsec)
            #endif
        }

        /// Runs `work` on `queue` once `wait` seconds have passed (`asyncAfter`). The Mac's form is the call the
        /// session host's resize log made itself. Linux's Dispatch takes only `@Sendable` work, and the work here is
        /// whatever the caller has (the host's work runs on the queue that owns what it touches), so it goes over in a
        /// box the compiler is told is safe to send.
        public static func later(_ wait: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) {
            #if canImport(Darwin)
            queue.asyncAfter(deadline: .now() + wait, execute: work)
            #else
            let sent = Sent(work)
            queue.asyncAfter(deadline: .now() + wait) { sent.work() }
            #endif
        }

        #if !canImport(Darwin)
        private final class Sent: @unchecked Sendable {
            let work: () -> Void
            init(_ work: @escaping () -> Void) { self.work = work }
        }
        #endif
    }
}
