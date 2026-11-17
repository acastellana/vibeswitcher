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
}
#endif
