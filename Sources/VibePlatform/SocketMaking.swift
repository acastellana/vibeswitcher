extension Platform.Sockets {
    /// `SOCK_SEQPACKET` as the number `socket` and `socketpair` take (as `stream`): a connected socket that keeps each
    /// send one message, read whole and alone, as the server child's connector needs.
    public static var seqpacket: Int32 {
        #if canImport(Glibc)
        Int32(SOCK_SEQPACKET.rawValue)
        #else
        SOCK_SEQPACKET
        #endif
    }
}

// Sockets made close-on-exec: each system's calls are in SocketMaking+Darwin.swift and SocketMaking+Linux.swift,
// under the same names.
//
// - `makeSocket(type:) -> Int32`: a new Unix-domain socket of `type` (`stream`, `seqpacket`); -1 and errno.
// - `accept(_:) -> Int32`: the next connection waiting on a listener, as accept(2) answers; -1 and errno.
// - `pair(type:) -> (Int32, Int32)?`: two sockets of `type` connected to each other; nil and errno.
//
// Each is close-on-exec, so no program the process starts holds it unless the spawn keeps it: on Linux from the call
// that makes it (`SOCK_CLOEXEC`, `accept4`), so no program another thread starts in between holds it either; on the
// Mac, which has no such flag, right after it (`fcntl`), as the Mac's code always did.
