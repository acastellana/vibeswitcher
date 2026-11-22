extension Platform.ProcessSelf {
    /// This process's limit on open descriptors (`RLIMIT_NOFILE`), soft and hard; nil when it can't be read.
    public static func descriptorLimits() -> (soft: UInt64, hard: UInt64)? {
        var limit = rlimit()
        guard getrlimit(nofile, &limit) == 0 else { return nil }
        return (UInt64(limit.rlim_cur), UInt64(limit.rlim_max))
    }

    /// The soft limit on open descriptors raised to the hard one (the Mac: at most `OPEN_MAX`, which its kernel takes
    /// for this limit): for a long-running process that holds a descriptor per session and per client (the session
    /// host, whose server child inherits it), where the soft limit's usual 1,024 is reached long before the hard one.
    /// The soft limit it had before, when it was raised; nil when it was already there or couldn't be raised.
    @discardableResult public static func raiseDescriptorLimit() -> UInt64? {
        var limit = rlimit()
        guard getrlimit(nofile, &limit) == 0 else { return nil }
        let before = limit.rlim_cur
        #if canImport(Darwin)
        let target = min(limit.rlim_max, rlim_t(OPEN_MAX))
        #else
        let target = limit.rlim_max
        #endif
        guard target > before else { return nil }
        limit.rlim_cur = target
        return setrlimit(nofile, &limit) == 0 ? UInt64(before) : nil
    }

    /// The soft limit on open descriptors set to `soft` (at most the hard one): what a program a raised process starts
    /// gets back (a session's, which may use `select`). Whether it held.
    @discardableResult public static func setDescriptorSoftLimit(_ soft: UInt64) -> Bool {
        var limit = rlimit()
        guard getrlimit(nofile, &limit) == 0 else { return false }
        limit.rlim_cur = min(rlim_t(soft), limit.rlim_max)
        return setrlimit(nofile, &limit) == 0
    }

    #if canImport(Glibc)
    private static var nofile: __rlimit_resource_t { __rlimit_resource_t(RLIMIT_NOFILE.rawValue) }
    #else
    private static var nofile: Int32 { RLIMIT_NOFILE }
    #endif
}
