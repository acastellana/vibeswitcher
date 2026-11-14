import Foundation

extension Platform {
    /// Unix-domain sockets, where the systems differ: an address's layout and the longest path it holds, a stream
    /// socket's type, what a write to a peer that has gone does, and who is at the other end.
    ///
    /// Each system's answers to the last two are in a file of its own (Sockets+Darwin.swift, Sockets+Linux.swift),
    /// under the same names:
    ///
    /// - `noSigPipe(_:)` and `noSigPipe(socket:)`: a write to this descriptor whose reader has gone is an error
    ///   (EPIPE), not SIGPIPE. The Mac asks it of each descriptor, a socket by its own option and anything else by
    ///   fcntl. Linux has no switch per descriptor and both do nothing there: a process settles SIGPIPE as a whole.
    /// - `send(_:_:_:) -> Int`: a write to a socket that raises no SIGPIPE when the peer has gone, whatever the process
    ///   has settled: EPIPE. Linux says so on each write (`MSG_NOSIGNAL`); the Mac's sockets carry `SO_NOSIGPIPE`
    ///   (`noSigPipe(socket:)`), so its write is write(2).
    /// - `peerUID(_:) -> uid_t?`, `peerPID(_:) -> pid_t?`: the user and the process at the other end.
    /// - `peerToken(_:) -> PeerToken?`: the process at the other end, in a form that tells it from a later one of the
    ///   same pid (`Platform.PeerToken`, each system's own).
    /// - `enableCredentials(_:)` and `receive(_:into:)`: bytes read with the process that sent them.
    /// - `bindOwnerOnly(_:to:path:mode:afterBind:) -> (call: String, code: Int32)?`: a bind whose file is no wider
    ///   than `mode`. Linux sets the socket's mode before the bind and touches the path no more; the Mac chmods the
    ///   path after it, as it always did.
    /// - `boundFile(of:) -> (device: UInt64, inode: UInt64)?`: the file a listener is bound to, as the kernel knows it
    ///   (Linux's unix_diag); nil on the Mac, which can't say.
    public enum Sockets {
        /// The address of the socket at `path`; nil when the path is too long for one: with the 0 that ends it, it
        /// must fit `sun_path`, 104 bytes on the Mac and 108 on Linux. The Mac's address also holds its own length.
        public static func unixAddress(_ path: String) -> sockaddr_un? {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            #if canImport(Darwin)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            #endif
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            return address
        }

        /// Whether `info`, a `stat` of a path, is of the file `bound` (`boundFile(of:)`): the same device, and the
        /// same low 32 bits of the inode number, all the kernel reports of it. On a file system whose inode numbers
        /// go past 32 bits, two files on it can share those bits.
        public static func boundFile(_ bound: (device: UInt64, inode: UInt64), is info: stat) -> Bool {
            UInt64(truncatingIfNeeded: info.st_dev) == bound.device
                && UInt32(truncatingIfNeeded: info.st_ino) == UInt32(truncatingIfNeeded: bound.inode)
        }

        /// `SOCK_STREAM` as the number `socket` and `socketpair` take: glibc's is an enum to Swift, the Mac's and
        /// musl's a number.
        public static var stream: Int32 {
            #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
            #else
            SOCK_STREAM
            #endif
        }
    }
}
