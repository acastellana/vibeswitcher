#if canImport(Darwin)
// The Mac's descriptors passed over a socket: none. A descriptor passed this way is the connector's (the server child's
// way to a connection the host makes for it, Linux only); the Mac has no connector, and its app connects to the host's
// socket as it always has, checked by its code signature.
extension Platform.Sockets {
    /// Nothing is sent, and false: the Mac has no connector.
    public static func sendDescriptor(_ fd: Int32, over socket: Int32) -> Bool { false }

    /// Nothing is read, and nil: the Mac has no connector.
    public static func receiveDescriptor(over socket: Int32) -> Int32? { nil }

    /// Whether `socket` reports a hang-up or an error (`POLLHUP`, `POLLERR`, `POLLNVAL`): a poll that doesn't wait; a
    /// failed poll says gone. Only the connector asks it, and the Mac has none.
    public static func peerHasGone(_ socket: Int32) -> Bool {
        var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat { ready = poll(&waiting, 1, 0) } while ready < 0 && errno == EINTR
        return ready < 0 || (ready > 0 && waiting.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0)
    }
}
#endif
