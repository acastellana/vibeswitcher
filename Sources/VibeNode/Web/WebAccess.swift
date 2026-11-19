import Foundation
import VibeCore

/// Who may use the web listener (the live plan's F1, LW-D4; the live wire contract's §2): the one-time pairing codes
/// `vibeswitcher web` asks for, the tokens they are exchanged for (`WebTokens`), and what an admitted connection may
/// send (`refusal(for:rights:)`, `WebRequestScreen`).
///
/// - A pairing code is 16 random bytes in base64url, alive `codeLife`, taken once. Only its SHA-256 is kept, in memory.
///   It travels in the URL's fragment (`url(port:code:)`), which a browser never sends in a request nor a `Referer`.
/// - `admit` takes an `auth` request's `args`: a `pair` taken once inside its life issues a token (sent back once, in
///   `hello`'s `auth`); a `token` is checked. Anything else is nil, and nil never says why (a wrong, a used and a late
///   code are refused alike), nor is the code or the token ever in a note.
/// - A token reads and drafts (`rights`) and is never the user's voice (LW-D6).
///
/// The integrator (I1) wires the listener to it: `listen` binds it (or says why the port can't be had), `onChange` is
/// called when a code or a token comes or goes (the listener stops once `wanted` is false), `onRevoke` when every token
/// is dropped (the listener closes its connections with `revoked`, 4403). From any thread.
public final class WebAccess: WebGate, @unchecked Sendable {
    /// How long a pairing code is taken.
    public static let codeLife: TimeInterval = 120
    /// The bytes of randomness in a pairing code.
    public static let codeBytes = 16
    /// The most codes alive at once (`vibeswitcher web` run again and again): the oldest dropped.
    public static let codesKept = 8
    /// What a token may do.
    public static let rights: LiveRights = [.read, .draft]
    /// What a refused `auth` is told, whatever the reason: the `bye`'s `reason`.
    public static let refusedReason = "not admitted: run `vibeswitcher web` in a terminal for a new address"
    /// `hello`'s `peer.why` on a web connection.
    public static let peerWhy = "a web client: it reads and drafts, and is never the user's voice"

    /// The listener's port, or why it can't be bound.
    public typealias Listen = @Sendable () -> Result<UInt16, WebTokens.Refusal>

    /// What `open` made: the address the command line prints.
    public struct Opened: Equatable, Sendable {
        public var url: String
        public var port: UInt16
        public var expiresIn: Int
    }

    public let tokens: WebTokens
    private let now: @Sendable () -> Date
    private let note: @Sendable (String) -> Void
    private let lock = NSLock()
    /// Each live code's digest and when it runs out, the oldest first.
    private var codes: [(digest: [UInt8], expiresAt: Date)] = []
    /// Bumped by each `revoke`, with the codes dropped, under `lock`: an `admit` that saw another number before it took
    /// its code than after it issued its token raced a revoke, and the token it issued is dropped (a revoke means no page
    /// until `vibeswitcher web` again, whatever was under way).
    private var revocations = 0
    private var listenHook: Listen = { .failure(WebTokens.Refusal("this server has no web listener")) }
    private var changeHook: (@Sendable () -> Void)?
    private var revokeHook: (@Sendable () -> Void)?
    private var takenHook: (@Sendable () -> Void)?
    private var admittedHook: (@Sendable () -> Void)?

    /// `now` is the clock codes and tokens are judged on (a test's own); `note` the server's log, which never gets a
    /// code or a token.
    public init(tokens: WebTokens, now: @escaping @Sendable () -> Date = { Date() }, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.tokens = tokens
        self.now = now
        self.note = note
    }

    /// Binds the listener when it isn't, and says its port (I1's wiring); by default there is none.
    public var listen: Listen {
        get { lock.withLock { listenHook } }
        set { lock.withLock { listenHook = newValue } }
    }

    /// Called after a code or a token came or went (`wanted` may have changed).
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHook } }
        set { lock.withLock { changeHook = newValue } }
    }

    /// Called after every token was dropped: each connection admitted under one is closed.
    public var onRevoke: (@Sendable () -> Void)? {
        get { lock.withLock { revokeHook } }
        set { lock.withLock { revokeHook = newValue } }
    }

    /// Tests: called in `admit` once a code is taken and before its token is issued (where a revoke can land).
    var betweenTakeAndIssue: (@Sendable () -> Void)? {
        get { lock.withLock { takenHook } }
        set { lock.withLock { takenHook = newValue } }
    }

    /// Tests: called in `admit` once it has admitted, before it returns (where a revoke can land before `hello`).
    var afterAdmit: (@Sendable () -> Void)? {
        get { lock.withLock { admittedHook } }
        set { lock.withLock { admittedHook = newValue } }
    }

    /// `http://127.0.0.1:<port>/#pair=<code>`: the one origin (LW-D5), the code in the fragment.
    public static func url(port: UInt16, code: String) -> String { "http://127.0.0.1:\(port)/#pair=\(code)" }

    // MARK: Codes

    /// A new pairing code, alive `codeLife` from `now`.
    public func openCode(now: Date) -> String {
        let code = WebTokens.randomText(bytes: Self.codeBytes)
        lock.withLock {
            codes = codes.filter { $0.expiresAt > now }
            codes.append((WebTokens.digest(code), now.addingTimeInterval(Self.codeLife)))
            if codes.count > Self.codesKept { codes.removeFirst(codes.count - Self.codesKept) }
        }
        return code
    }

    /// `web.open`: the listener bound (`listen`), then a code made, and the address to print. Refused, with no code
    /// made, when the port can't be had or the tokens' file is a newer build's.
    public func open() -> Result<Opened, WebTokens.Refusal> {
        if let refusal = tokens.refusal { return .failure(refusal) }
        switch listen() {
        case .failure(let refusal):
            note("web.open refused: \(refusal.description)")
            return .failure(refusal)
        case .success(let port):
            let code = openCode(now: now())
            note("web.open: a pairing code made, taken once in the next \(Int(Self.codeLife)) s; the web listens on 127.0.0.1:\(port)")
            onChange?()
            return .success(Opened(url: Self.url(port: port, code: code), port: port, expiresIn: Int(Self.codeLife)))
        }
    }

    /// `web.revoke`: every code and token dropped, then `onRevoke` and `onChange`. Returns how many tokens were alive.
    public func revoke() -> Result<Int, WebTokens.Refusal> {
        lock.withLock {
            codes = []
            revocations += 1
        }
        let dropped: Int
        do { dropped = try tokens.revokeAll(now: now()) } catch let refusal as WebTokens.Refusal {
            return .failure(refusal)
        } catch {
            return .failure(WebTokens.Refusal("\(error)"))
        }
        note("web.revoke: \(dropped) tokens dropped; their connections are closed")
        onRevoke?()
        onChange?()
        return .success(dropped)
    }

    // MARK: WebGate

    /// A code or a token is alive.
    public var wanted: Bool {
        let at = now()
        return lock.withLock { codes.contains { $0.expiresAt > at } } || tokens.live(now: at) > 0
    }

    /// Late codes dropped; then whether anything is still `wanted` (I1 asks it on the clock and stops the listener).
    @discardableResult
    public func sweep() -> Bool {
        let at = now()
        lock.withLock { codes = codes.filter { $0.expiresAt > at } }
        return wanted
    }

    /// Whether `token` is still taken (a connection admitted under it is closed once it isn't: it ran out, or every
    /// token was revoked).
    public func holds(_ token: String) -> Bool { tokens.check(token, now: now()) }

    public func admit(_ args: [String: NodeWire.Value]) -> WebAdmission? {
        let pair = args["pair"]?.string, token = args["token"]?.string
        let at = now()
        switch (pair, token) {
        case (let pair?, nil):
            // The revocations seen before the code is taken, and again once its token is issued: a revoke between the
            // two (it dropped every token, but not this one, issued after it) leaves this one dropped and the page out.
            let before = lock.withLock { revocations }
            guard pair.utf8.count <= 64, take(pair, now: at) else { return refused() }
            betweenTakeAndIssue?()
            guard let issued = try? tokens.issue(now: at) else { return refused() }
            guard lock.withLock({ revocations }) == before else {
                try? tokens.drop(issued.token)
                onChange?()
                return refused()
            }
            note("a pairing code was taken: a web token issued")
            onChange?()
            afterAdmit?()
            return WebAdmission(rights: Self.rights, auth: Self.auth(token: issued.token, expiresAt: issued.expiresAt), token: issued.token)
        case (nil, let token?):
            guard let expiresAt = tokens.expiry(of: token, now: at) else { return refused() }
            afterAdmit?()
            return WebAdmission(rights: Self.rights, auth: Self.auth(token: nil, expiresAt: expiresAt), token: token)
        default:
            return refused()
        }
    }

    /// One note for every refusal, saying nothing of why.
    private func refused() -> WebAdmission? {
        note("a web connection's auth was refused")
        return nil
    }

    /// Whether `code` is a live code's; it is taken (dropped) when it is. Every live code compared, none skipped.
    private func take(_ code: String, now: Date) -> Bool {
        let candidate = WebTokens.digest(code)
        return lock.withLock {
            codes = codes.filter { $0.expiresAt > now }
            var found: Int?
            for (index, live) in codes.enumerated() where WebTokens.same(live.digest, candidate) && found == nil { found = index }
            guard let found else { return false }
            codes.remove(at: found)
            return true
        }
    }

    /// `hello`'s `auth`: the rights, the token (only in answer to a code) and when it runs out.
    static func auth(token: String?, expiresAt: Date) -> NodeWire.Value {
        var fields: [String: NodeWire.Value] = ["rights": .array(names(rights).map(NodeWire.Value.string)), "expiresAt": .date(expiresAt)]
        if let token { fields["token"] = .string(token) }
        return .object(fields)
    }

    /// The rights' names on the wire, in order.
    public static func names(_ rights: LiveRights) -> [String] {
        [(LiveRights.read, "read"), (LiveRights.draft, "draft")].filter { rights.contains($0.0) }.map(\.1)
    }

    // MARK: What a web connection may send

    /// Why a web connection with `rights` may not send `request` (nil: it may): a kind no server names is
    /// `unknown-kind`; a read kind needs `read` and a draft kind `draft`; every other kind is `voice`, whatever the
    /// token: a web client is never the user's voice (LW-D6), nor the lead's tool server. A terminal's kinds are
    /// `unknown-kind` but on a scratch server that takes them (`terminals`, LW-D12), where they need `read`: the
    /// user's node opens no terminal.
    public static func refusal(for request: NodeWire.Request, rights: LiveRights, terminals: Bool = false) -> NodeWire.Reply? {
        let kind = ConfigSeal.inert(request.kind, limit: 80)
        switch NodeWire.kinds[request.kind] {
        case nil:
            return .init(re: request.id, error: .init(.unknownKind, "this server doesn't take \(kind)"))
        case .anyone?:
            return rights.contains(.read) ? nil : .init(re: request.id, error: .init(.voice, "this page's token doesn't read"))
        case .webDraft?:
            return rights.contains(.draft) ? nil : .init(re: request.id, error: .init(.voice, "this page's token doesn't draft"))
        case .user?:
            return .init(re: request.id, error: .init(.voice, "\(kind) is the user's voice: a web page is never that; run it with `vibeswitcher` in a terminal"))
        case .leadToolServer?:
            return .init(re: request.id, error: .init(.voice, "\(kind) is the lead's tool server's alone"))
        case .webTerminal?:
            guard terminals else { return .init(re: request.id, error: .init(.unknownKind, "this server doesn't take \(kind)")) }
            return rights.contains(.read) ? nil : .init(re: request.id, error: .init(.voice, "this page's token doesn't read"))
        }
    }

    /// The kinds a web connection with `rights` may send that this server takes: `hello`'s `kinds` on a WebSocket.
    public static func kinds(for rights: LiveRights) -> [String] {
        NodeWire.taken.filter { refusal(for: NodeWire.Request(id: "", kind: $0), rights: rights) == nil }
    }
}

/// What stands between the listener and the hub (I1 hands the listener one around the hub): every request a web
/// connection sends is judged by `WebAccess.refusal(for:rights:)` before any handler sees it, and a refused one is
/// answered here and goes no further. What isn't a request (not JSON, not an object) goes on, for the hub to close.
public final class WebRequestScreen: WebSocketHandler, @unchecked Sendable {
    private let inner: WebSocketHandler
    private let note: @Sendable (String) -> Void
    /// A scratch server's: the terminal's kinds go on to the hub (LW-D12).
    private let terminals: Bool
    private let lock = NSLock()
    private var rights: [ObjectIdentifier: LiveRights] = [:]

    public init(_ inner: WebSocketHandler, terminals: Bool = false, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.inner = inner
        self.terminals = terminals
        self.note = note
    }

    public func opened(_ transport: LiveTransport, rights: LiveRights) {
        lock.withLock { self.rights[ObjectIdentifier(transport)] = rights }
        inner.opened(transport, rights: rights)
    }

    public func text(_ message: Data, on transport: LiveTransport) {
        guard let request = NodeWire.decode(NodeWire.Request.self, message) else { return inner.text(message, on: transport) }
        let rights = lock.withLock { self.rights[ObjectIdentifier(transport)] } ?? []
        guard let refused = WebAccess.refusal(for: request, rights: rights, terminals: terminals) else { return inner.text(message, on: transport) }
        note("refused \(ConfigSeal.inert(request.kind, limit: 80)) from a web connection: \(refused.error?.code ?? "")")
        transport.send(Data(NodeWire.line(refused).dropLast()))
        if refused.error?.code == NodeWire.Code.unknownKind.rawValue, request.must == true {
            transport.close(code: "must", reason: "a request this server must understand and doesn't")
        }
    }

    public func binary(_ message: Data, on transport: LiveTransport) { inner.binary(message, on: transport) }

    public func closed(_ transport: LiveTransport) {
        lock.withLock { _ = rights.removeValue(forKey: ObjectIdentifier(transport)) }
        inner.closed(transport)
    }
}
