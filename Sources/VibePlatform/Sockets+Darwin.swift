#if canImport(Darwin)
// The Mac's sockets: the calls VibeCore's UnixSocket and the pipes' writers made themselves, moved here unchanged.
extension Platform {
    /// The process at the other end of a socket, as the kernel names it: its audit token, which holds its pid and
    /// pidversion (an exec changes the version) and which Security's code checks take as the process's image.
    public typealias PeerToken = audit_token_t
}

extension audit_token_t {
    /// Fields as libbsm's `audit_token_to_pid` and `audit_token_to_pidversion` read them.
    public var pid: pid_t { pid_t(bitPattern: val.5) }
    public var pidVersion: Int32 { Int32(bitPattern: val.7) }

    /// The same process image: the same pid, not exec'd since (nor a pid reused).
    public func sameImage(as other: audit_token_t) -> Bool { pid == other.pid && pidVersion == other.pidVersion }
}

extension Platform.Sockets {
    /// A write to `fd` whose reader has gone fails with EPIPE and raises no SIGPIPE (`F_SETNOSIGPIPE`): for a pipe,
    /// or whatever a process was given as its output. A socket has its own switch, `noSigPipe(socket:)`.
    public static func noSigPipe(_ fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }

    /// The same for a socket, by the socket's own option (`SO_NOSIGPIPE`).
    public static func noSigPipe(socket fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes `count` bytes from `bytes` to the socket `fd`: write(2), as the Mac's code always wrote to its sockets.
    /// They carry `SO_NOSIGPIPE` (`noSigPipe(socket:)`, which UnixSocket gives each), so a peer gone is EPIPE.
    public static func send(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
        Sys.write(fd, bytes, count)
    }

    /// The user id of the process at the other end.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// The pid of the process at the other end, as it is when asked (see `peerToken`): for a log, not to tell who's
    /// calling.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 ? pid : nil
    }

    /// The audit token of the process at the other end, as it runs now: its pid and pidversion (an exec changes the
    /// version), which Security's code checks take as the process's image. Not fixed when the connection was made
    /// (nor is LOCAL_PEERPID): it's whichever process last sent or received on the peer's socket, so it moves to a
    /// forked child that writes, and names the new image after the connector's exec.
    public static func peerToken(_ fd: Int32) -> Platform.PeerToken? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 ? token : nil
    }

    /// Nothing on the Mac, whose `peerToken` already names whoever last used the peer's socket. (Linux: its socket's
    /// bytes then come with their sender.)
    public static func enableCredentials(_ fd: Int32) {}

    /// Reads from `fd` as read(2) does (`count` is what it returned; `errno` is as it left it), and with bytes read
    /// says whose they are: on the Mac, `peerToken` as it is after the read, the process that last used the peer's
    /// socket.
    public static func receive(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> (count: Int, sender: Platform.PeerToken?) {
        let count = read(fd, buffer.baseAddress, buffer.count)
        return (count, count > 0 ? peerToken(fd) : nil)
    }

    /// Binds the Unix socket `fd` to `address` (`path`'s, `unixAddress`), then sets the file's mode to `mode` through
    /// `path` (`chmod`), as UnixSocket always did on the Mac: a link renamed over the path between the two is followed
    /// (docs/process/v2-mac-tasks.md). Nil when bound; else the call that failed and its errno. `afterBind`: tests only,
    /// run just after a bind that succeeded, before the chmod.
    public static func bindOwnerOnly(_ fd: Int32, to address: sockaddr_un, path: String, mode: mode_t,
                                     afterBind: () -> Void = {}) -> (call: String, code: Int32)? {
        var address = address
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { return ("bind", errno) }
        afterBind()
        guard chmod(path, mode) == 0 else { return ("chmod", errno) }
        return nil
    }

    /// Nil on the Mac, which has no way to ask the kernel what file a socket is bound to (no unix_diag): a caller
    /// keeps its own check through the path. Nothing on the Mac asks today (the host watches its path on Linux only).
    public static func boundFile(of listener: Int32) -> (device: UInt64, inode: UInt64)? { nil }
}
#endif
