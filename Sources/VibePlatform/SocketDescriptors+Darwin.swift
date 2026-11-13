#if canImport(Darwin)
// The Mac's descriptors passed over a socket: none. A descriptor passed this way is the connector's (the server child's
// way to a connection the host makes for it, Linux only); the Mac has no connector, and its app connects to the host's
// socket as it always has, checked by its code signature.
extension Platform.Sockets {
    /// Nothing is sent, and false: the Mac has no connector.
    public static func sendDescriptor(_ fd: Int32, over socket: Int32) -> Bool { false }

    /// Nothing is read, and nil: the Mac has no connector.
    public static func receiveDescriptor(over socket: Int32) -> Int32? { nil }
}
#endif
