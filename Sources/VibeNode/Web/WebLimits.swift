import Foundation

/// What a web listener allows of each connection and of all of them: every size and every wait has a limit, so that
/// nothing a client sends, withholds or doesn't read grows the server's memory or holds a connection without end.
public struct WebLimits: Sendable, Equatable {
    /// What happens to a message sent to a client whose outbound queue is full (`maxQueuedBytes`).
    public enum Overflow: Sendable, Equatable {
        /// The message is dropped, and so is every one after it until the caller says otherwise
        /// (`WebSocketConnection.resume`): the client gets what was queued, then whatever the caller sends to bring
        /// it up to date, and nothing in between.
        case drop
        /// The connection is closed at once, with no close frame (the client isn't reading): it connects again.
        case close
    }

    /// The connections open at once, whatever their state; one more is answered 503 and closed.
    public var maxConnections = 64
    /// The connections waiting to be accepted (`listen`'s backlog).
    public var backlog: Int32 = 128

    /// The longest request line ("GET /path HTTP/1.1"), without its line end; over it, 414.
    public var maxRequestLineBytes = 4_096
    /// The longest request head, from its first byte to the empty line that ends it; over it, 431.
    public var maxHeaderBytes = 16 * 1_024
    /// The most header fields; over it, 431.
    public var maxHeaderCount = 64
    /// Seconds from a connection's accept to the end of its request head, however the bytes come; past it, 408.
    public var headSeconds = 10
    /// Seconds a response may take to leave, however slowly the client reads; past it the connection is closed.
    public var responseSeconds = 30
    /// Seconds a connection that has been told the end (a response sent whole, a close frame queued) may take to
    /// close its side; past it the connection is closed.
    public var closeSeconds = 5

    /// The largest message a client may send, all its fragments together; over it, close 1009. A connection holds
    /// at most about twice this of what its client sent.
    public var maxMessageBytes = 1 << 20
    /// The most bytes of messages waiting to be written to one client; a message that would pass it isn't queued
    /// (`overflow`). No single message larger than this can be sent.
    public var maxQueuedBytes = 4 << 20
    public var overflow = Overflow.drop
    /// Seconds between the server's pings. 0: no pings.
    public var pingSeconds = 30
    /// A client that has been pinged this many times in a row and has sent nothing in between (no pong, no frame of
    /// any kind) is closed, at the ping after.
    public var maxMissedPings = 2

    public init() {}
}

/// The close codes of RFC 6455 this transport sends or reports.
public enum WebSocketClose {
    public static let normal: UInt16 = 1000
    /// The server is going: what a client is told when the listener stops.
    public static let goingAway: UInt16 = 1001
    public static let protocolError: UInt16 = 1002
    /// Reported, never sent: the client's close frame carried no code.
    public static let noStatus: UInt16 = 1005
    /// Reported, never sent: the connection ended with no close frame (the client went, answered no ping, or fell
    /// behind under `WebLimits.Overflow.close`).
    public static let abnormal: UInt16 = 1006
    /// A text message that isn't UTF-8.
    public static let invalidData: UInt16 = 1007
    public static let policyViolation: UInt16 = 1008
    /// A message over `WebLimits.maxMessageBytes`.
    public static let tooBig: UInt16 = 1009
    public static let internalError: UInt16 = 1011

    /// Whether `code` may travel in a close frame: RFC 6455's own (but 1004, 1005, 1006), IANA's 1012 to 1014, and
    /// 3000 to 4999 (registered and private).
    public static func isSendable(_ code: UInt16) -> Bool {
        switch code {
        case 1000...1003, 1007...1014, 3000...4999: return true
        default: return false
        }
    }
}
