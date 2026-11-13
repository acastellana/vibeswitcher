#if canImport(Darwin)
// The Mac's forms of `Platform.ProcessSelf`: nothing. The Mac's processes are kept from one another by the system
// (`task_for_pid` needs an entitlement or root), and the Mac's host and app keep today's behaviour, which never
// hardened anything (the plan's Global Constraints: no behaviour change on the Mac).
extension Platform.ProcessSelf {
    enum System {
        /// Nothing, and false: the Mac has no `PR_SET_DUMPABLE`, and its `RLIMIT_CORE` is left as it is.
        static func harden() -> Bool { false }

        /// nil: the Mac has no such state to ask.
        static func isDumpable() -> Bool? { nil }

        /// nil: the Mac has no /proc/self/status to read it from.
        static func tracer() -> pid_t? { nil }
    }
}
#endif
