import Foundation

extension Platform {
    /// The clocks the wall clock isn't: time awake, and a thread's own CPU time.
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
    }
}
