#if os(Linux)
// Linux's forms of `Platform.ProcessSelf`: prctl(2) through the shim (it is variadic, which Swift can't call),
// setrlimit(2), and this process's /proc/self/status. Only libc and the shim, on glibc and on musl.
extension Platform.ProcessSelf {
    enum System {
        /// `PR_SET_DUMPABLE 0`, then `RLIMIT_CORE` 0 soft and hard (lowering a limit needs no privilege; nothing
        /// raises it again).
        static func harden() -> Bool {
            let undumpable = vibe_set_dumpable(0) == 0
            var none = rlimit(rlim_cur: 0, rlim_max: 0)
            #if canImport(Glibc)
            let noCore = setrlimit(__rlimit_resource_t(RLIMIT_CORE.rawValue), &none) == 0
            #else
            let noCore = setrlimit(RLIMIT_CORE, &none) == 0
            #endif
            return undumpable && noCore
        }

        static func makeDumpable() -> Bool { vibe_set_dumpable(1) == 0 }

        /// 1 is dumpable by the process's own user. 0 is not; 2 (after a set-user-id program, with
        /// `fs.suid_dumpable` 2) is by root alone, which to another process of the user is the same.
        static func isDumpable() -> Bool? {
            let state = vibe_get_dumpable()
            return state < 0 ? nil : state == 1
        }

        static func tracer() -> pid_t? {
            guard case .success(let bytes) = Platform.Processes.System.contents("/proc/self/status") else { return nil }
            return Platform.ProcessSelf.tracer(fromStatus: String(decoding: bytes, as: UTF8.self))
        }
    }
}
#endif
