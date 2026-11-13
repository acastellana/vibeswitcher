#if canImport(Darwin)
// The Mac's sockets, marked close-on-exec right after the call that makes them, as UnixSocket, the host's accept and
// its parsers' pair always did: the Mac has no SOCK_CLOEXEC and no accept4.
extension Platform.Sockets {
    /// `socket(AF_UNIX, type, 0)`, then `FD_CLOEXEC`: -1 and errno, as the call.
    public static func makeSocket(type: Int32) -> Int32 {
        let fd = socket(AF_UNIX, type, 0)
        if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return fd
    }

    /// `accept(listener, nil, nil)`, then `FD_CLOEXEC`: -1 and errno, as the call.
    public static func accept(_ listener: Int32) -> Int32 {
        let fd = Darwin.accept(listener, nil, nil)
        if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return fd
    }

    /// `socketpair(AF_UNIX, type, 0)`, then `FD_CLOEXEC` on both ends; nil and errno when it fails.
    public static func pair(type: Int32) -> (Int32, Int32)? {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, type, 0, &ends) == 0 else { return nil }
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        return (ends[0], ends[1])
    }
}
#endif
