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
    /// sender has gone since **and its pid wasn't given again**: the kernel names the sender by its pid alone, and its
    /// start is read here afterwards, so a sender that wrote and ended, its pid given to a new process before this
    /// read, comes as that new process (the security architecture document's S5; Linux 6.5's `SCM_PIDFD` closes
    /// that). Descriptors sent along are closed, never kept.
    public static func receive(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> (count: Int, sender: Platform.PeerToken?) {
        var sender = vibe_ucred()
        let count = vibe_receive_credentials(fd, buffer.baseAddress, buffer.count, &sender)
        guard count > 0 else { return (count, nil) }
        return (count, token(pid: sender.pid, uid: sender.uid))
    }

    /// The file the Unix socket `listener` is bound to, asked of the kernel (`NETLINK_SOCK_DIAG`'s unix_diag,
    /// `UDIAG_SHOW_VFS`): the file `bind` made, wherever it has been renamed since. Nothing goes through a path, so a
    /// file renamed over the socket's path can't answer in its place, at any moment. `device` is the device of the
    /// file system the file is on, its superblock's, in `stat`'s encoding: what `stat` gives as `st_dev` on most file
    /// systems, but not on btrfs (a subvolume's own device) or on an overlay over several file systems (a layer's), so
    /// a path is compared with it through `boundFile(of:at:)`, not through `lstat`. `inode` is the low 32 bits of the
    /// file's inode number, all the kernel reports. nil when the kernel can't say: `listener` isn't bound to a file
    /// (not bound, an abstract name), or the kernel has no unix_diag (`CONFIG_UNIX_DIAG`).
    public static func boundFile(of listener: Int32) -> (device: UInt64, inode: UInt64)? {
        var device: UInt64 = 0
        var inode: UInt64 = 0
        guard vibe_socket_bound_file(listener, &device, &inode) == 0 else { return nil }
        return (device, inode)
    }

    /// Whether `path` names (no link followed) the file the Unix socket `listener` is bound to (`boundFile(of:)`),
    /// compared as the kernel knows both: the device of the file system the path's file is on (its superblock's, from
    /// /proc's view of the mount, not `st_dev`, which differs on btrfs and on an overlay over several file systems)
    /// and the low 32 bits of its inode number (the kernel's own, /proc/self/fdinfo's from Linux 5.14; `st_ino`
    /// before), each read from one descriptor opened on the path (`O_PATH`: nothing goes through the path after, and
    /// no rename meanwhile mixes two files). A file on a file system whose inode numbers pass 32 bits can share those
    /// bits with the listener's. `.cantSay` when unix_diag (`boundFile(of:)`) or /proc can't say.
    public static func boundFile(of listener: Int32, at path: String) -> BoundFileAtPath {
        guard let bound = boundFile(of: listener) else { return .cantSay }
        var statDevice: UInt64 = 0
        var statInode: UInt64 = 0
        var mode: UInt32 = 0
        var device: UInt64 = 0
        var inode: UInt64 = 0
        switch vibe_path_file(path, &statDevice, &statInode, &mode, &device, &inode) {
        case 0: break
        case -1: return .another
        default: return .cantSay
        }
        guard mode & UInt32(S_IFMT) == UInt32(S_IFSOCK), device == bound.device,
              UInt32(truncatingIfNeeded: inode) == UInt32(truncatingIfNeeded: bound.inode) else { return .another }
        return .bound(device: statDevice, inode: statInode)
    }
}

extension Platform.Sockets {
    /// Binds the Unix socket `fd` to `address` (`path`'s, `unixAddress`) with the file `bind` makes no wider than
    /// `mode`: the socket's own mode is set first (`fchmod`), and `bind` makes the file with it, less the umask (Linux
    /// gives a socket file its socket's mode; measured here, docs/process/v2-linux-inventory.md). Nothing goes through
    /// `path` after the bind, so a link renamed over it then is never followed. Nil when bound; else the call that
    /// failed and its errno. `afterBind`: tests only, run just after a bind that succeeded.
    public static func bindOwnerOnly(_ fd: Int32, to address: sockaddr_un, path: String, mode: mode_t,
                                     afterBind: () -> Void = {}) -> (call: String, code: Int32)? {
        guard fchmod(fd, mode) == 0 else { return ("fchmod", errno) }
        var address = address
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { return ("bind", errno) }
        afterBind()
        return nil
    }
}

// The C library's send(2), under a name `Platform.Sockets` doesn't have: inside it a bare `send` is its own.
@inline(__always) private func socketSend(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
    send(fd, bytes, count, Int32(MSG_NOSIGNAL))
}
#endif
