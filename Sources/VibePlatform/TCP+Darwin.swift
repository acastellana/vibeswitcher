#if canImport(Darwin)
// The Mac's TCP socket, marked close-on-exec right after the call that makes it, as its Unix sockets are
// (SocketMaking+Darwin.swift): the Mac has no SOCK_CLOEXEC.
extension Platform.TCP {
    /// Whether the socket `fd` listens: this process's own descriptor as `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` gives
    /// it, its `soi_options` (`so_options`, where listen(2) sets `SO_ACCEPTCONN`). Not `getsockopt(SO_ACCEPTCONN)`:
    /// xnu doesn't read that option back as Linux does (H1's tests failed on it on the v2 macos run of 350ced4d).
    static func acceptsConnections(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return false }
        return Int32(info.psi.soi_options) & SO_ACCEPTCONN != 0
    }

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
