import Darwin
import Foundation

/// Unix-domain socket plumbing shared by the session host and the app.
public enum UnixSocket {
    public enum Failure: Error, Equatable {
        case pathTooLong
        case system(String, Int32)
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// A connected, nonblocking socket.
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        do {
            var address = try address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw Failure.system("connect", errno) }
        } catch {
            Darwin.close(fd)
            throw error
        }
        configure(fd)
        return fd
    }

    /// Listens on `path`, replacing a stale socket file; only the owner may connect (0600).
    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
            guard Darwin.listen(fd, 16) == 0 else { throw Failure.system("listen", errno) }
        } catch {
            Darwin.close(fd)
            throw error
        }
        configure(fd)
        return fd
    }

    /// Nonblocking, no SIGPIPE on writes to a closed peer, not inherited by programs the host starts.
    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The user id of the process at the other end.
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// The pid of the process at the other end, as it is when asked (see `peerToken`): for the host's log, not to
    /// tell who's calling.
    public static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 ? pid : nil
    }

    /// The audit token of the process at the other end, as it runs now: its pid and pidversion (an exec changes the
    /// version), which Security's code checks take as the process's image. Not fixed when the connection was made
    /// (nor is LOCAL_PEERPID): it's whichever process last sent or received on the peer's socket, so it moves to a
    /// forked child that writes, and names the new image after the connector's exec.
    public static func peerToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 ? token : nil
    }
}

extension audit_token_t {
    /// Fields as libbsm's `audit_token_to_pid` and `audit_token_to_pidversion` read them.
    public var pid: pid_t { pid_t(bitPattern: val.5) }
    public var pidVersion: Int32 { Int32(bitPattern: val.7) }

    /// The same process image: the same pid, not exec'd since (nor a pid reused).
    public func sameImage(as other: audit_token_t) -> Bool { pid == other.pid && pidVersion == other.pidVersion }
}
