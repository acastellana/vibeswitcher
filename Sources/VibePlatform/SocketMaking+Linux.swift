#if os(Linux)
// Linux's sockets, close-on-exec from the call that makes them: SOCK_CLOEXEC and accept4, through the shim (glibc
// shows accept4 only under _GNU_SOURCE, and SOCK_CLOEXEC is an enum to Swift there and a number on musl).
extension Platform.Sockets {
    /// `socket(AF_UNIX, type | SOCK_CLOEXEC, 0)`: -1 and errno, as the call.
    public static func makeSocket(type: Int32) -> Int32 {
        vibe_socket_cloexec(type)
    }

    /// `accept4(listener, nil, nil, SOCK_CLOEXEC)`: -1 and errno, as the call (EAGAIN when nothing waits on a
    /// listener that doesn't block).
    public static func accept(_ listener: Int32) -> Int32 {
        vibe_accept_cloexec(listener)
    }

    /// `socketpair(AF_UNIX, type | SOCK_CLOEXEC, 0)`; nil and errno when it fails.
    public static func pair(type: Int32) -> (Int32, Int32)? {
        var ends: [Int32] = [-1, -1]
        guard vibe_socketpair_cloexec(type, &ends) == 0 else { return nil }
        return (ends[0], ends[1])
    }
}
#endif
