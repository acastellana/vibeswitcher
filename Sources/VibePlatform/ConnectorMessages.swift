import Foundation

// The bytes that frame a message on a stream connector (the Mac's, ConnectorMessages+Darwin.swift). Linux's connector
// is `SOCK_SEQPACKET`, whose messages keep their edges, and frames nothing (ConnectorMessages+Linux.swift).
extension Platform.Sockets {
    /// The first byte of a framed message: `w`, as every web message's (`HostWebListen.word`) starts. Any other byte is a
    /// message of one byte (a connection's request or answer).
    public static let framedStart = UInt8(ascii: "w")
    /// The byte that ends a framed message, not part of it.
    public static let framedEnd = UInt8(ascii: "\n")
}
