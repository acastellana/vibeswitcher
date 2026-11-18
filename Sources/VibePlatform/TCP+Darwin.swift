#if canImport(Darwin)
// The Mac's TCP socket, marked close-on-exec right after the call that makes it, as its Unix sockets are
// (SocketMaking+Darwin.swift): the Mac has no SOCK_CLOEXEC.
extension Platform.TCP {
    /// `socket(family, SOCK_STREAM, 0)`, then `FD_CLOEXEC`: -1 and errno, as the call.
    static func makeSocket(_ family: Family) -> Int32 {
        let fd = socket(family.domain, SOCK_STREAM, 0)
        if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return fd
    }

    // The egress proxy's forms: none. The Mac has no session sandbox, so no proxy runs there (the session sandbox
    // plan's "The Mac"); each fails with ENOTSUP and makes nothing.

    public static func resolve(_ name: String) -> Result<[[UInt8]], Platform.Errno> { .failure(Platform.Errno(code: ENOTSUP)) }

    public static func connect(to address: [UInt8], port: UInt16, timeout: Double) -> Result<Int32, Platform.Errno> {
        .failure(Platform.Errno(code: ENOTSUP))
    }
}
#endif
