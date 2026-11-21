#if canImport(Darwin)
// The Mac's sockets, marked close-on-exec right after the call that makes them, as UnixSocket, the host's accept and
// its parsers' pair always did: the Mac has no SOCK_CLOEXEC and no accept4. Each gets `SO_NOSIGPIPE` there too, while
// it is still whole: the Mac refuses any socket option (EINVAL) on a socket shut both ways, which a stream's end is
// once its peer has closed, so a switch set later, just before a write, is lost exactly when it's needed (a connector
// whose host had gone: SIGPIPE in HostConnector.connect, run 44801844163).
extension Platform.Sockets {
    /// `socket(AF_UNIX, type, 0)`, then `FD_CLOEXEC` and `SO_NOSIGPIPE`: -1 and errno, as the call.
    public static func makeSocket(type: Int32) -> Int32 {
        let fd = socket(AF_UNIX, type, 0)
        if fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            noSigPipe(socket: fd)
        }
        return fd
    }

    /// `accept(listener, nil, nil)`, then `FD_CLOEXEC` and `SO_NOSIGPIPE` (which takes only while the peer is still
    /// there; XNU's accepted socket also inherits its listener's, `makeSocket`'s, to be confirmed on the Mac): -1 and
    /// errno, as the call.
    public static func accept(_ listener: Int32) -> Int32 {
        let fd = Darwin.accept(listener, nil, nil)
        if fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            noSigPipe(socket: fd)
        }
        return fd
    }

    /// `socketpair(AF_UNIX, type, 0)`, then `FD_CLOEXEC` and `SO_NOSIGPIPE` on both ends, before either can close;
    /// nil and errno when it fails. The switch is the socket's, so an end handed to a child keeps it across the exec.
    public static func pair(type: Int32) -> (Int32, Int32)? {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, type, 0, &ends) == 0 else { return nil }
        for end in ends {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            noSigPipe(socket: end)
        }
        return (ends[0], ends[1])
    }
}
#endif
