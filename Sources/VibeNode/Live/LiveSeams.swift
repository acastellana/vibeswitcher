import Foundation

// The live protocol's seams on the hub's side (the live plan's "The seams", W0): what every lane builds against, so
// lanes A (the listener), B (the hub) and F (tokens) never wait on each other. The integrator's file: a lane that needs
// a change here asks the lead.

/// What the hub writes to: one connection, whatever carries it (the server's Unix socket, a WebSocket). `send` takes
/// one message as compact JSON (no newline); `writable` is false while the carrier's buffer is full, and `onWritable`
/// is called when it drains.
public protocol LiveTransport: AnyObject, Sendable {
    func send(_ message: Data)
    var writable: Bool { get }
    var onWritable: (() -> Void)? { get set }
    /// `bye` with `code` and `reason` (`NodeWire.Bye`), then the close.
    func close(code: String, reason: String)
}

/// What a connection may ask of the hub. A Unix socket's peer of the uid reads; a web token reads and drafts, and is
/// never the user's voice (LW-D6).
public struct LiveRights: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The node, the sessions, the leads, the cards and the chats.
    public static let read = LiveRights(rawValue: 1 << 0)
    /// A draft answer on a card, which does nothing until the user confirms it on the command line.
    public static let draft = LiveRights(rawValue: 1 << 1)
    /// Acting as the user (acting from the page, the web UI design's step 2): `web_acts` on, a page on this machine's
    /// loopback, its token paired while it is (the vault keeps it: `ActingPages`). Never a tailnet page's.
    public static let act = LiveRights(rawValue: 1 << 2)
}
