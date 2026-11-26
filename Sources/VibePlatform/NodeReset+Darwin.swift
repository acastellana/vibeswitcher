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
            // Only what crossed the exec: what this process opened itself is close-on-exec from its making. Every open
            // descriptor, as the kernel lists them (`PROC_PIDLISTFDS`), not a range up to a limit the starter could
            // have lowered (the re-check's round 2, note 2).
            guard let open = openDescriptors() else { return "its open descriptors can't be listed (errno \(errno))" }
            for fd in open where fd > STDERR_FILENO && !keeping.contains(fd) {
                let flags = fcntl(fd, F_GETFD)
                if flags >= 0, flags & FD_CLOEXEC == 0 { close(fd) }
            }
            return nil
        }

        /// This process's open descriptors, as the kernel lists them; nil when it can't.
        static func openDescriptors() -> [Int32]? {
            let stride = MemoryLayout<proc_fdinfo>.stride
            let needed = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { return nil }
            // Room for some opened meanwhile.
            var infos = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
            let got = infos.withUnsafeMutableBytes { proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard got > 0 else { return nil }
            return infos.prefix(Int(got) / stride).map(\.proc_fd)
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
