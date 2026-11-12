#if os(Linux)
// Linux's sockets: who is at the other end is `SO_PEERCRED` (fixed when the connection was made) and, for bytes as
// they are read, `SCM_CREDENTIALS` (who sent them). Only libc and the shim, on glibc and on musl.
extension Platform {
    /// The process at the other end of a socket: its pid, its user, and when it started in clock ticks since boot
    /// (/proc/<pid>/stat, read once as the token is made), which tells it from a later process given the same pid.
    ///
    /// Unlike the Mac's token it says nothing of an exec: a process that replaces its program keeps its pid and its
    /// start, and its token.
    public struct PeerToken: Equatable, Sendable {
        public var pid: pid_t
        public var uid: uid_t
        public var startTicks: UInt64

        public init(pid: pid_t, uid: uid_t, startTicks: UInt64) {
            self.pid = pid
            self.uid = uid
            self.startTicks = startTicks
        }

        /// The same process: the same pid, started at the same tick (not a pid reused).
        public func sameImage(as other: PeerToken) -> Bool { pid == other.pid && startTicks == other.startTicks }
    }
}

extension Platform.Sockets {
    /// Nothing: Linux has no switch per descriptor. A process there settles SIGPIPE as a whole (the host, the hook
    /// and the keeper ignore it, the tool server catches it, the test bundles ignore it as they load), and a write
    /// whose reader has gone is then EPIPE.
    public static func noSigPipe(_ fd: Int32) {}

    /// Nothing, as `noSigPipe(_:)`.
    public static func noSigPipe(socket fd: Int32) {}

    /// Writes `count` bytes from `bytes` to the socket `fd`, as write(2) does (what it returns; with -1, `errno` as it
    /// left it), with no SIGPIPE when the peer has gone (`MSG_NOSIGNAL`): EPIPE, whatever the process does with the
    /// signal. A process that writes to the session host before it has settled SIGPIPE (the hook) lives through a
    /// host that went mid-write (a handover, a restart).
    public static func send(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
        socketSend(fd, bytes, count)
    }

    /// What the kernel kept of the process that connected (or made the pair) when it did: `SO_PEERCRED`. A socket
    /// that isn't connected answers too, with pid 0 and user -1.
    static func peerCredentials(_ fd: Int32) -> vibe_ucred? {
        var peer = vibe_ucred()
        var length = socklen_t(MemoryLayout<vibe_ucred>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &length) == 0, Int(length) == MemoryLayout<vibe_ucred>.size else { return nil }
        return peer
    }

    /// A token for the process `pid` of `uid` as it is now; nil when its start can't be read: it has gone (and was
    /// reaped), or /proc doesn't show it. Should the process have gone and its pid been given again since the kernel
    /// named it, the token is the new one's: nothing short of a descriptor on the process (Linux 6.5's SO_PEERPIDFD)
    /// closes that.
    static func token(pid: pid_t, uid: uid_t) -> Platform.PeerToken? {
        guard pid > 0, case .line(let line) = Platform.Processes.System.statLine(pid) else { return nil }
        return Platform.PeerToken(pid: pid, uid: uid, startTicks: line.startTicks)
    }

    /// The user id of the process at the other end, as it was when the connection was made.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        guard let peer = peerCredentials(fd), peer.uid != uid_t.max else { return nil }
        return peer.uid
    }

    /// The pid of the process that connected (or that made the pair), which stays what it was whoever uses the
    /// socket since: for a log, not to tell who's calling.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        guard let peer = peerCredentials(fd), peer.pid > 0 else { return nil }
        return peer.pid
    }

    /// The process that connected (or that made the pair), with its start read now. Fixed at the connection: a
    /// forked child that writes on the peer's socket, or a process handed it, doesn't show here. Who sent which
    /// bytes is `receive(_:into:)`'s to say.
    public static func peerToken(_ fd: Int32) -> Platform.PeerToken? {
        guard let peer = peerCredentials(fd), peer.uid != uid_t.max else { return nil }
        return token(pid: peer.pid, uid: peer.uid)
    }

    /// From now on what is sent to `fd` comes with its sender (`SO_PASSCRED`), which `receive(_:into:)` reads. Bytes
    /// sent before have none. A connection accepted from a listener that had this set has it from its first byte.
    public static func enableCredentials(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_PASSCRED, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads from the socket `fd` as recvmsg(2) does (`count` is what it returned; with -1, `errno` is as it left
    /// it), and with bytes read says who sent them: the process that made the write, were it a child of the one
    /// that connected (`SCM_CREDENTIALS`). One read never holds bytes of two senders: it stops where the sender
    /// changes. nil when the bytes came with no sender (`enableCredentials` wasn't in force as they were sent) or the
    /// sender has gone since. Descriptors sent along are closed, never kept.
    public static func receive(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> (count: Int, sender: Platform.PeerToken?) {
        var sender = vibe_ucred()
        let count = vibe_receive_credentials(fd, buffer.baseAddress, buffer.count, &sender)
        guard count > 0 else { return (count, nil) }
        return (count, token(pid: sender.pid, uid: sender.uid))
    }
}

// The C library's send(2), under a name `Platform.Sockets` doesn't have: inside it a bare `send` is its own.
@inline(__always) private func socketSend(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
    send(fd, bytes, count, Int32(MSG_NOSIGNAL))
}
#endif
