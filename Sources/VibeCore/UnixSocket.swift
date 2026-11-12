import Foundation

/// Unix-domain socket plumbing shared by the session host and the app.
public enum UnixSocket {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case pathTooLong
        case system(String, Int32)

        /// Said in words, not as `system("connect", 2)`: a socket that isn't there is a session host that isn't running.
        public var description: String {
            switch self {
            case .pathTooLong: return "the socket's path is too long"
            case .system("connect", ENOENT):
                return "the session host (vibeswitcher-host) isn't running: its socket isn't there (connect: No such file or directory)"
            case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        guard let address = Platform.Sockets.unixAddress(path) else { throw Failure.pathTooLong }
        return address
    }

    /// A connected, nonblocking socket. `patience`: how long to keep retrying a connect the host refused
    /// (ECONNREFUSED: its backlog was full, or no one listens on a socket file left behind; EAGAIN), pausing longer
    /// each time; then it fails as it would at once. 0 (the default) fails at once. `pause`: waits between attempts
    /// (a test's records them instead).
    public static func connect(path: String, patience: TimeInterval = 0,
                               pause: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) }) throws -> Int32 {
        var waited: TimeInterval = 0
        var next: TimeInterval = 0.01
        while true {
            do {
                return try connectOnce(path: path)
            } catch Failure.system("connect", let code) where (code == ECONNREFUSED || code == EAGAIN) && waited < patience {
                let wait = min(next, patience - waited)
                pause(wait)
                waited += wait
                next = min(next * 2, 0.2)
            }
        }
    }

    private static func connectOnce(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, Platform.Sockets.stream, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        do {
            var address = try address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Sys.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw Failure.system("connect", errno) }
        } catch {
            Sys.close(fd)
            throw error
        }
        configure(fd)
        return fd
    }

    /// Listens on `path`, replacing a stale socket file; only the owner may connect (0600). The backlog is the most
    /// the system takes (SOMAXCONN): a burst of callers (leads' tool servers, the app, hooks) each connecting at once
    /// would otherwise be refused once a short queue fills, before the host's next accept.
    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, Platform.Sockets.stream, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        do {
            var address = try address(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw Failure.system("bind", errno) }
            guard chmod(path, 0o600) == 0 else { throw Failure.system("chmod", errno) }
            guard Sys.listen(fd, SOMAXCONN) == 0 else { throw Failure.system("listen", errno) }
        } catch {
            Sys.close(fd)
            throw error
        }
        configure(fd)
        return fd
    }

    /// Nonblocking, no SIGPIPE on writes to a closed peer, not inherited by programs the host starts.
    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        Platform.Sockets.noSigPipe(socket: fd)
    }

    /// The user id of the process at the other end.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        Platform.Sockets.peerUID(fd)
    }

    /// The pid of the process at the other end, as it is when asked (see `peerToken`): for the host's log, not to
    /// tell who's calling.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        Platform.Sockets.peerPID(fd)
    }

    /// The audit token of the process at the other end, as it runs now: its pid and pidversion (an exec changes the
    /// version), which Security's code checks take as the process's image. Not fixed when the connection was made
    /// (nor is LOCAL_PEERPID): it's whichever process last sent or received on the peer's socket, so it moves to a
    /// forked child that writes, and names the new image after the connector's exec.
    public static func peerToken(_ fd: Int32) -> Platform.PeerToken? {
        Platform.Sockets.peerToken(fd)
    }
}
