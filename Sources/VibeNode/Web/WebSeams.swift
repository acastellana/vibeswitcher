import Foundation

// The web listener's seams (the live plan's "The seams", W0): what lane A's listener consumes from lane C (the files),
// lane F (who may connect) and lane B (the hub), wired together by the integrator (I1). The integrator's file: a lane
// that needs a change here asks the lead.

/// The web listener's fixed place (LW-D3, LW-D5): one port, one origin, `http://127.0.0.1:<port>`. A constant until
/// stage 5's Settings store makes it a node's setting. No test binds it: a scratch server takes `--test-web-port=`.
public enum NodeWeb {
    /// The Mac's phone server is 47823.
    public static let port: UInt16 = 47830
}

/// One file the listener may serve, with its headers ready (lane C makes them; lane A writes them).
public struct WebAsset: Sendable {
    public var body: Data
    /// In the order they are written; a name may repeat.
    public var headers: [(String, String)]

    public init(body: Data, headers: [(String, String)]) {
        self.body = body
        self.headers = headers
    }
}

/// The files the listener serves, by exact path (`/` is `index.html`); nil: 404.
public protocol WebAssetSource: Sendable {
    func asset(path: String) -> WebAsset?
}

/// Who may connect (lane F): a first frame's `args` judged, and the `hello` additions for it.
public protocol WebGate: AnyObject, Sendable {
    /// The `auth` request's `args` (`pair` or `token`, `client`, `assets`); nil: refused, never saying why.
    func admit(_ args: [String: NodeWire.Value]) -> WebAdmission?
    /// A pairing code or a token is alive: the listener stays up.
    var wanted: Bool { get }
}

/// An admitted connection: what it may do, `hello`'s `auth`, and the token it came in under (to close it on revoke).
public struct WebAdmission: Sendable {
    public var rights: LiveRights
    public var auth: NodeWire.Value
    public var token: String

    public init(rights: LiveRights, auth: NodeWire.Value, token: String) {
        self.rights = rights
        self.auth = auth
        self.token = token
    }
}

/// What the listener hands an authenticated socket to (lane B's hub, wired by I1).
public protocol WebSocketHandler: AnyObject, Sendable {
    func opened(_ transport: LiveTransport, rights: LiveRights)
    /// One whole text message (reassembled from its fragments): one JSON object.
    func text(_ message: Data, on transport: LiveTransport)
    /// One whole binary message: the terminal's only (the contract's §9).
    func binary(_ message: Data, on transport: LiveTransport)
    func closed(_ transport: LiveTransport)
}
