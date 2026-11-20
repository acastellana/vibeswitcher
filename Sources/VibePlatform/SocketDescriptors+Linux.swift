#if os(Linux)
// Linux's descriptors passed over a Unix socket: one byte carrying one descriptor (SCM_RIGHTS), through the shim, whose
// C walks a message's control data with the macros Swift doesn't see. The host's connector rests on it: the server
// child inherits one end of a pair, asks over it for a connection to the host, and the host hands one end of a new
// pair back. The Mac's forms (SocketDescriptors+Darwin.swift) pass one descriptor the same way, over a stream.
extension Platform.Sockets {
    /// The type of a connector's pair: `SOCK_SEQPACKET` on Linux (`seqpacket`), each request and answer a message of
    /// its own. The Mac's is a stream (SocketDescriptors+Darwin.swift).
    public static var connectorType: Int32 { seqpacket }

    /// Sends `fd` over the Unix socket `socket`: one byte carrying it (`SCM_RIGHTS`), with no SIGPIPE when the peer has
    /// gone. True when the byte went; false and `errno` otherwise. `fd` stays open here, and the caller closes it when
    /// the peer's copy is the only one it means to leave.
    public static func sendDescriptor(_ fd: Int32, over socket: Int32) -> Bool {
        vibe_send_descriptor(socket, fd) == 0
    }

    /// The descriptor the next message on `socket` carries, close-on-exec from its arrival (`MSG_CMSG_CLOEXEC`), so no
    /// program started meanwhile inherits it. Exactly one is taken: a message carrying none or more than one gives nil
    /// (`errno` EBADMSG), and every descriptor it carried is closed. nil too at the end of the stream (EPIPE: the peer
    /// has closed or shut its end) and when the read fails (its `errno`). On a `SOCK_SEQPACKET` socket an empty message
    /// from a peer still there reads as 0 bytes, as the end does, and is told apart: EBADMSG, the connection still
    /// open. Waits for a message as the socket's reads do.
    public static func receiveDescriptor(over socket: Int32) -> Int32? {
        let fd = vibe_receive_descriptor(socket)
        return fd >= 0 ? fd : nil
    }

    /// `receiveDescriptor(over:)`, with the process that sent the message: its pid as the kernel put it on the message
    /// when it was sent (`SCM_CREDENTIALS`, while `socket` has `enableCredentials`), numbered as this process numbers
    /// it whatever pid namespace the sender is in; 0 when the message came with none. The session sandbox's porter
    /// reads its door line so: the sender is the box's init.
    public static func receiveDescriptorAndSender(over socket: Int32) -> (descriptor: Int32, sender: pid_t)? {
        var sender: pid_t = 0
        let fd = vibe_receive_descriptor_from(socket, &sender)
        return fd >= 0 ? (fd, sender) : nil
    }

    /// Whether `socket`'s peer can send nothing more: it has closed its end (every process that held it) or shut it
    /// for writing (`shutdown(SHUT_WR)`), so the socket is shut for reading (`POLLRDHUP`), or it reports a hang-up or an
    /// error. A poll that doesn't wait; a failed poll says gone. On a `SOCK_SEQPACKET` socket a message of no bytes
    /// reads as 0, as the end does: this tells the two apart, and a socket shut for writing at the far end, which
    /// reports no hang-up and reads as 0 for good, is gone too.
    public static func peerHasGone(_ socket: Int32) -> Bool {
        vibe_peer_has_gone(socket) != 0
    }

    /// Sends `bytes` over the Unix socket `socket` with the descriptors `fds` (at most 8; `SCM_RIGHTS`) riding on the
    /// first byte, with no SIGPIPE when the peer has gone: the session sandbox's door, where a relay sends its one line
    /// with its stdin, stdout and stderr. What sendmsg returns: the bytes that went (a stream may take fewer: the
    /// descriptors went with the first), or -1 and `errno`. Each of `fds` stays open here.
    public static func send(_ bytes: [UInt8], with fds: [Int32], over socket: Int32) -> Int {
        bytes.withUnsafeBytes { raw in
            fds.withUnsafeBufferPointer { numbers in
                vibe_send_with_descriptors(socket, raw.baseAddress, raw.count, numbers.baseAddress, numbers.count)
            }
        }
    }

    /// What one read of a Unix socket brought: its bytes (none at the end of a stream), the descriptors that rode on
    /// them, each close-on-exec and the caller's to close, and whether more came than there was room for (`cut`: the
    /// kernel closed those itself).
    public struct Received: Sendable {
        public var bytes: [UInt8]
        public var descriptors: [Int32]
        public var cut: Bool
    }

    /// One read of at most `count` bytes from the Unix socket `socket`, with room for `room` descriptors (at most 8),
    /// each close-on-exec from its arrival. nil and `errno` when the read fails (EAGAIN on a socket that doesn't block
    /// and has nothing), with no descriptor left open.
    public static func receive(over socket: Int32, count: Int, room: Int) -> Received? {
        var bytes = [UInt8](repeating: 0, count: max(count, 1))
        var fds = [Int32](repeating: -1, count: 8)
        var taken = 0
        var cut: Int32 = 0
        let got = bytes.withUnsafeMutableBytes { raw in
            fds.withUnsafeMutableBufferPointer { numbers in
                vibe_receive_with_descriptors(socket, raw.baseAddress, count, numbers.baseAddress, room, &taken, &cut)
            }
        }
        guard got >= 0 else { return nil }
        return Received(bytes: Array(bytes[0..<got]), descriptors: Array(fds[0..<taken]), cut: cut != 0)
    }
}
#endif
