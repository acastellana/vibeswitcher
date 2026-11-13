#if os(Linux)
// Linux's descriptors passed over a Unix socket: one byte carrying one descriptor (SCM_RIGHTS), through the shim, whose
// C walks a message's control data with the macros Swift doesn't see. The host's connector rests on it: the server
// child inherits one end of a pair, asks over it for a connection to the host, and the host hands one end of a new
// pair back. The Mac has no connector, and its forms (SocketDescriptors+Darwin.swift) pass nothing.
extension Platform.Sockets {
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
}
#endif
