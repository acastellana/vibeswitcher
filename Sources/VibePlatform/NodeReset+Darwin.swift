#if canImport(Darwin)
import Darwin

// The Mac's forms of `Platform.NodeReset`.
extension Platform.NodeReset {
    enum System {
        static func processState(keeping: Set<Int32>) -> String? {
            umask(0o077)
            guard chdir("/") == 0 else { return "its working folder couldn't be made / (errno \(errno))" }
            var none = rlimit(rlim_cur: 0, rlim_max: 0)
            guard setrlimit(RLIMIT_CORE, &none) == 0 else { return "its core limit couldn't be made 0 (errno \(errno))" }
            // Only what crossed the exec: what this process opened itself is close-on-exec from its making.
            let top = Int32(min(getdtablesize(), 65_536))
            for fd in Int32(3)..<max(3, top) where !keeping.contains(fd) {
                let flags = fcntl(fd, F_GETFD)
                if flags >= 0, flags & FD_CLOEXEC == 0 { close(fd) }
            }
            return nil
        }

        static var userTemporaryFolder: String? {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
            guard length > 0, length <= buffer.count else { return nil }
            let path = String(cString: buffer)
            return path.hasPrefix("/") ? path : nil
        }
    }
}
#endif
