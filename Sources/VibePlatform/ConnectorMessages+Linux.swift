#if os(Linux)
// A connector's messages on Linux: its pair is `SOCK_SEQPACKET`, which keeps each message's edges, so each call here is
// the socket's own call, as the host and its server child made it before the Mac's form (ConnectorMessages+Darwin.swift).
extension Platform.Sockets {
    /// `send(_:with:over:)`: one message, `fds` riding on it.
    public static func sendConnectorMessage(_ bytes: [UInt8], with fds: [Int32], over socket: Int32) -> Int {
        send(bytes, with: fds, over: socket)
    }

    /// `receive(over:count:room:)`: the next message and what rides on it.
    public static func receiveConnectorMessage(over socket: Int32, count: Int, room: Int) -> Received? {
        receive(over: socket, count: count, room: room)
    }

    /// `receive(_:into:)`: the host's end reading its child's next request, one message, with its sender.
    public static func receiveConnectorRequest(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> (count: Int, sender: Platform.PeerToken?) {
        receive(fd, into: buffer)
    }
}
#endif
