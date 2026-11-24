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

    /// Acting from the page (`ActingPages`): the loopback page's gate only (`NodeLive` sets it); nil on the tailnet's,
    /// so no tailnet page acts.
    public var acting: ActingPages? {
        get { lock.withLock { actingPages } }
        set { lock.withLock { actingPages = newValue } }
    }
    private var actingPages: ActingPages?

    /// The authority on this gate's tokens (the acting review's fix B): the host's vault as `ActingPages` keeps it, for
    /// `scope` (`loopback`, `tailnet`). Set, a token is admitted only when the vault knows it, whatever the token file
    /// says (any process of the user's writes it); unset (a test's gate), the file alone.
    public var tokenAuthority: (pages: ActingPages, scope: String)? {
        get { lock.withLock { authority } }
        set { lock.withLock { authority = newValue } }
    }
    private var authority: (pages: ActingPages, scope: String)?
    /// The pairings taken and waiting for the terminal's confirmation (the loopback gate's), by code id.
    private var pairings: [String: PagePairing] = [:]
    /// The codes taken, by digest: their id, while a second try with one is worth saying (`PagePairing.contested`).
    private var takenCodes: [(digest: [UInt8], id: String, until: Date)] = []
    /// `hello`'s `peer.why` on a confirmed pairing's connection that watches but doesn't act.
    public static let watchingWhy = "a web client on this machine's loopback, its pairing confirmed in a terminal: it watches the terminals"
    /// `hello`'s `peer.why` on an acting page's connection.
    public static let actingWhy = "a web client on this machine's loopback, paired while acting from the page is on: it acts as the user"
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
        /// The code's id (`PagePairing.codeID`): what the terminal waits on for the page that takes it.
        public var code: String = ""
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
    private var hostName = "127.0.0.1"
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

    /// `http://127.0.0.1:<port>/#pair=<code>`: the one origin (LW-D5), the code in the fragment. On the tailnet the
    /// host is the MagicDNS name (`TailnetWeb`).
    public static func url(port: UInt16, code: String, host: String = "127.0.0.1") -> String { "http://\(host):\(port)/#pair=\(code)" }

    /// The listener's name in the address `open` gives: 127.0.0.1, or the tailnet's MagicDNS name, set before `listen`
    /// returns (`TailnetWeb`).
    public var host: String {
        get { lock.withLock { hostName } }
        set { lock.withLock { hostName = newValue } }
    }

    // MARK: Codes

    /// A new pairing code, alive `codeLife` from `now`.
    public func openCode(now: Date) -> String {
        let code = WebTokens.randomText(bytes: Self.codeBytes)
        lock.withLock {
            codes = codes.filter { $0.expiresAt > now }
            codes.append((WebTokens.digest(code), now.addingTimeInterval(Self.codeLife)))
            if codes.count > Self.codesKept { codes.removeFirst(codes.count - Self.codesKept) }
        }
        // Never shown to a page in a terminal or a transcript while it lives (`PairingMask`).
        PairingMask.made(code, until: now.addingTimeInterval(Self.codeLife))
        return code
    }

    /// The code in `url` (its `#pair=`) dropped while it is still alive and untaken: true when it was (no page can pair
    /// with it now), false when it was taken already, or ran out. A `web.open` whose reply was lost (`Requests.kept`).
    public func dropCode(inURL url: String) -> Bool {
        guard let range = url.range(of: "#pair=") else { return false }
        let digest = WebTokens.digest(String(url[range.upperBound...]))
        let at = now()
        return lock.withLock {
            let before = codes.count
            codes.removeAll { $0.expiresAt > at && WebTokens.same($0.digest, digest) }
            return codes.count < before
        }
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
            let host = host
            note("web.open: a pairing code made, taken once in the next \(Int(Self.codeLife)) s; the web listens on \(host):\(port)")
            onChange?()
            return .success(Opened(url: Self.url(port: port, code: code, host: host), port: port, expiresIn: Int(Self.codeLife),
                                   code: PagePairing.codeID(digest: WebTokens.digest(code))))
        }
    }

    /// `web.revoke`: every code and token dropped, then `onRevoke` and `onChange`. Returns how many tokens were alive.
    public func revoke() -> Result<Int, WebTokens.Refusal> {
        lock.withLock {
            codes = []
            pairings = [:]
            revocations += 1
        }
        if let authority = tokenAuthority { authority.pages.dropPages(scope: authority.scope) }
        let dropped: Int
        do { dropped = try tokens.revokeAll(now: now()) } catch let refusal as WebTokens.Refusal {
            return .failure(refusal)
        } catch {
            return .failure(WebTokens.Refusal("\(error)"))
        }
        note("web.revoke: \(dropped) tokens dropped; their connections are closed")
        acting?.revoked()
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
    public func holds(_ token: String) -> Bool {
        guard tokens.check(token, now: now()) else { return false }
        guard let authority = tokenAuthority else { return true }
        return authority.pages.admits(scope: authority.scope, token: token)
    }

    public func admit(_ args: [String: NodeWire.Value]) -> WebAdmission? {
        let pair = args["pair"]?.string, token = args["token"]?.string
        let at = now()
        switch (pair, token) {
        case (let pair?, nil):
            // The revocations seen before the code is taken, and again once its token is issued: a revoke between the
            // two (it dropped every token, but not this one, issued after it) leaves this one dropped and the page out.
            let before = lock.withLock { revocations }
            guard pair.utf8.count <= 64, let code = take(pair, now: at) else {
                // A code taken already, tried again: said in the terminal that waits on it (another page may have read
                // the address first).
                if pair.utf8.count <= 64 { contest(pair, now: at) }
                return refused()
            }
            betweenTakeAndIssue?()
            guard let issued = try? tokens.issue(now: at) else { return refused() }
            guard lock.withLock({ revocations }) == before else {
                try? tokens.drop(issued.token)
                onChange?()
                return refused()
            }
            note("a pairing code was taken: a web token issued")
            if let authority = tokenAuthority { authority.pages.issued(scope: authority.scope, token: issued.token, until: issued.expiresAt) }
            // The loopback page's gate (the only one with `acting`): the pairing waits for the terminal's confirmation,
            // the page shows its phrase meanwhile and reads and drafts.
            var phrase: String?
            if acting != nil {
                let pairing = PagePairing(code: code, token: issued.token, tokenEnds: issued.expiresAt, phrase: PagePairing.phrase(token: issued.token),
                                          at: at, contested: false)
                phrase = pairing.phrase
                lock.withLock {
                    pairings = pairings.filter { at.timeIntervalSince($0.value.at) < PagePairing.waits }
                    pairings[code] = pairing
                }
            }
            onChange?()
            afterAdmit?()
            var auth = Self.auth(token: issued.token, expiresAt: issued.expiresAt)
            if let phrase, case .object(var fields) = auth {
                fields["phrase"] = .string(phrase)
                auth = .object(fields)
            }
            return WebAdmission(rights: Self.rights, auth: auth, token: issued.token, pairing: phrase == nil ? nil : code)
        case (nil, let token?):
            guard let expiresAt = tokens.expiry(of: token, now: at) else { return refused() }
            // Only a token the vault knows (never what the token file says).
            if let authority = tokenAuthority, !authority.pages.admits(scope: authority.scope, token: token) { return refused() }
            // Watching and acting only with the secret a confirmed pairing gave (from the page's memory), live in the
            // vault's list as this server keeps it.
            let secret = args["act"]?.string.flatMap { $0.utf8.count <= 64 ? $0 : nil }
            var rights = Self.rights
            if let acting, acting.watches(token: token, secret: secret) {
                rights.insert(.watch)
                if acting.acts(token: token, secret: secret) { rights.insert(.act) }
            }
            afterAdmit?()
            return WebAdmission(rights: rights, auth: Self.auth(token: nil, expiresAt: expiresAt, rights: rights), token: token,
                                act: rights.contains(.watch) ? secret : nil)
        default:
            return refused()
        }
    }

    /// Where a taken code's pairing stands, for the terminal that made it (`web.pairing`).
    public enum PairingState: Equatable, Sendable {
        /// Not taken yet (or it ran out: the terminal's own clock says).
        case waiting
        case taken(phrase: String, contested: Bool)
    }

    public func pairing(code: String) -> PairingState {
        let at = now()
        return lock.withLock {
            guard let pairing = pairings[code], at.timeIntervalSince(pairing.at) < PagePairing.waits else { return .waiting }
            return .taken(phrase: pairing.phrase, contested: pairing.contested)
        }
    }

    /// The pairing of `code`, taken out (`web.confirm`): once only.
    public func takePairing(code: String) -> PagePairing? {
        let at = now()
        return lock.withLock {
            guard let pairing = pairings.removeValue(forKey: code), at.timeIntervalSince(pairing.at) < PagePairing.waits else { return nil }
            return pairing
        }
    }

    /// A taken code tried again: its pairing marked contested.
    private func contest(_ code: String, now: Date) {
        let candidate = WebTokens.digest(code)
        lock.withLock {
            takenCodes = takenCodes.filter { $0.until > now }
            guard let taken = takenCodes.first(where: { WebTokens.same($0.digest, candidate) }) else { return }
            // Said to the terminal waiting on it (`web.pairing`), not in the log: every refusal notes the same line.
            pairings[taken.id]?.contested = true
        }
    }

    /// One note for every refusal, saying nothing of why.
    private func refused() -> WebAdmission? {
        note("a web connection's auth was refused")
        return nil
    }

    /// Whether `code` is a live code's: its id, and it is taken (dropped) when it is. Every live code compared, none
    /// skipped. A taken code is remembered a while, so a second try with it is said (`contest`).
    private func take(_ code: String, now: Date) -> String? {
        let candidate = WebTokens.digest(code)
        return lock.withLock {
            codes = codes.filter { $0.expiresAt > now }
            var found: Int?
            for (index, live) in codes.enumerated() where WebTokens.same(live.digest, candidate) && found == nil { found = index }
            guard let found else { return nil }
            codes.remove(at: found)
            let id = PagePairing.codeID(digest: candidate)
            takenCodes = takenCodes.filter { $0.until > now } + [(candidate, id, now.addingTimeInterval(PagePairing.waits))]
            return id
        }
    }

    /// `hello`'s `auth`: the rights, the token (only in answer to a code) and when it runs out.
    static func auth(token: String?, expiresAt: Date, rights: LiveRights = WebAccess.rights, act: String? = nil) -> NodeWire.Value {
        var fields: [String: NodeWire.Value] = ["rights": .array(names(rights).map(NodeWire.Value.string)), "expiresAt": .date(expiresAt)]
        // The acting secret, once, in answer to the pairing (the page keeps it in its memory only).
        if let act { fields["act"] = .string(act) }
        if let token { fields["token"] = .string(token) }
        return .object(fields)
    }

    /// The rights' names on the wire, in order.
    public static func names(_ rights: LiveRights) -> [String] {
        [(LiveRights.read, "read"), (LiveRights.draft, "draft"), (LiveRights.watch, "watch"), (LiveRights.act, "act")].filter { rights.contains($0.0) }.map(\.1)
    }

    // MARK: What a web connection may send

    /// Why a web connection with `rights` may not send `request` (nil: it may): a kind no server names is
    /// `unknown-kind`; a read kind needs `read` and a draft kind `draft`; every other kind is `voice`, whatever the
    /// token: a web client is never the user's voice (LW-D6), nor the lead's tool server. A terminal's kinds are
    /// `unknown-kind` but on a server that takes them (`terminals`), where they need `read`: the user's node's
    /// terminals are watched only (`TerminalRelay.Mode.watch`), a scratch server's may be typed into (LW-D12).
    public static func refusal(for request: NodeWire.Request, rights: LiveRights, terminals: Bool = false) -> NodeWire.Reply? {
        Principal.page(rights, terminals: terminals).refusal(request)
    }

    /// The kinds a web connection with `rights` may send that this server takes: `hello`'s `kinds` on a WebSocket.
    public static func kinds(for rights: LiveRights) -> [String] { Principal.page(rights, terminals: false).kinds }
}

/// What an acting page's connection came in with: its token and its acting secret.
public struct PageCredentials: Sendable, Equatable {
    public var token: String
    public var act: String?
    public init(token: String, act: String?) {
        self.token = token
        self.act = act
    }
}

/// What stands between the listener and the hub (I1 hands the listener one around the hub): every request a web
/// connection sends is judged by `WebAccess.refusal(for:rights:)` before any handler sees it, and a refused one is
/// answered here and goes no further. What isn't a request (not JSON, not an object) goes on, for the hub to close.
public final class WebRequestScreen: WebSocketHandler, @unchecked Sendable {
    private let inner: WebSocketHandler
    private let note: @Sendable (String) -> Void
    /// A server with terminals (the user's node's watched, a scratch server's typed: LW-D12): the terminal's kinds go
    /// on to the hub.
    private let terminals: Bool
    private let lock = NSLock()
    /// Each connection's peer, resolved at its open (`Principal.page`), with its token and acting secret (an acting
    /// page's requests are judged and marked with them) and the connection (an acting one is closed when acting ends).
    private var opens: [ObjectIdentifier: Open] = [:]
    private var actingHandler: (@Sendable (NodeWire.Request, PageCredentials, LiveTransport) -> Void)?
    private var actingPages: ActingPages?

    struct Open {
        var principal: Principal
        var credentials: PageCredentials?
        /// A pairing taken on this connection and waiting for the terminal's confirmation: its code id.
        var pairing: String?
        weak var transport: LiveTransport?
    }

    /// Where an acting page's user's request goes (`Principal.Route.pageVoice`), with its credentials: `NodeLive` sets it
    /// on the loopback page's screen alone. Unset (the tailnet's screen), such a request is refused whatever the rights.
    public var onPageVoice: (@Sendable (NodeWire.Request, PageCredentials, LiveTransport) -> Void)? {
        get { lock.withLock { actingHandler } }
        set { lock.withLock { actingHandler = newValue } }
    }

    /// What says, at each request, whether an acting connection still acts (`ActingPages.acts`: its pairing's end, an
    /// off, a revoke count at once); unset, none acts.
    public var acting: ActingPages? {
        get { lock.withLock { actingPages } }
        set { lock.withLock { actingPages = newValue } }
    }

    /// The admission a connection came in under (the listener's transport keeps it; a test's says its own).
    private let admissionOf: @Sendable (LiveTransport) -> WebAdmission?

    public init(_ inner: WebSocketHandler, terminals: Bool = false, note: @escaping @Sendable (String) -> Void = { _ in },
                admissionOf: (@Sendable (LiveTransport) -> WebAdmission?)? = nil) {
        self.inner = inner
        self.terminals = terminals
        self.note = note
        self.admissionOf = admissionOf ?? { ($0 as? NodeWebTransport)?.admission }
    }

    public func opened(_ transport: LiveTransport, rights: LiveRights) {
        let admission = admissionOf(transport)
        let credentials = admission.map { PageCredentials(token: $0.token, act: $0.act) }
        lock.withLock {
            opens[ObjectIdentifier(transport)] = Open(principal: .page(rights, terminals: terminals), credentials: credentials,
                                                      pairing: admission?.pairing, transport: transport)
        }
        inner.opened(transport, rights: rights)
    }

    public func text(_ message: Data, on transport: LiveTransport) {
        guard let request = NodeWire.decode(NodeWire.Request.self, message) else { return inner.text(message, on: transport) }
        let (open, handler, acting) = lock.withLock { (opens[ObjectIdentifier(transport)], actingHandler, actingPages) }
        let principal = open?.principal ?? .page([], terminals: terminals)
        let route = principal.route(request.kind)
        if route == .pageVoice {
            // Judged again at each request: still acting as the vault's list stands now (its end, the level, a revoke).
            if let handler, let acting, let credentials = open?.credentials, acting.acts(token: credentials.token, secret: credentials.act) {
                return handler(request, credentials, transport)
            }
            note("refused \(ConfigSeal.inert(request.kind, limit: 80)) from a web connection: it doesn't act (now)")
            return transport.send(Data(NodeWire.line(NodeWire.Reply(re: request.id, error: .init(.actsEnded, Self.notActing))).dropLast()))
        }
        if route == .terminal {
            // Watching too, judged at each request against the confirmed pairing.
            guard let acting, let credentials = open?.credentials, acting.watches(token: credentials.token, secret: credentials.act) else {
                note("refused \(ConfigSeal.inert(request.kind, limit: 80)) from a web connection: its pairing doesn't watch (now)")
                return transport.send(Data(NodeWire.line(NodeWire.Reply(re: request.id, error: .init(.actsEnded, Self.notActing))).dropLast()))
            }
        }
        guard let refused = principal.refusal(request) else { return inner.text(message, on: transport) }
        note("refused \(ConfigSeal.inert(request.kind, limit: 80)) from a web connection: \(refused.error?.code ?? "")")
        transport.send(Data(NodeWire.line(refused).dropLast()))
        if refused.error?.code == NodeWire.Code.unknownKind.rawValue, request.must == true {
            transport.close(code: "must", reason: "a request this server must understand and doesn't")
        }
    }

    /// What a page that doesn't act or watch (any more) is told for a user's request or a terminal.
    public static let notActing = "this page doesn't act or watch now: pair it again with `vibeswitcher web` and confirm it in the terminal"

    /// Whether the connection that took pairing `code` is open (the terminal's confirmation needs it).
    public func holdsPairing(_ code: String) -> Bool {
        lock.withLock { opens.values.contains { $0.pairing == code && $0.transport != nil } }
    }

    /// The pairing `code`'s connection confirmed: given `secret` once (the `paired` message), its rights now `rights`
    /// (the hub told too), its requests judged with the secret from here. False when that connection is gone.
    public func confirmPairing(_ code: String, secret: String, rights: LiveRights) -> Bool {
        let confirmed = lock.withLock { () -> LiveTransport? in
            guard let (id, open) = opens.first(where: { $0.value.pairing == code && $0.value.transport != nil }), let transport = open.transport else { return nil }
            opens[id]?.pairing = nil
            opens[id]?.credentials?.act = secret
            opens[id]?.principal = .page(rights, terminals: terminals)
            return transport
        }
        guard let transport = confirmed else { return false }
        inner.opened(transport, rights: rights)
        // The kinds it may send now, as `hello.kinds` says them.
        let kinds = Principal.page(rights, terminals: terminals).kinds
        let message = NodeWire.Value.object(["v": .int(NodeWire.version), "kind": .string("paired"), "act": .string(secret),
                                             "rights": .array(WebAccess.names(rights).map(NodeWire.Value.string)),
                                             "kinds": .array(kinds.map(NodeWire.Value.string))])
        transport.send(Data(NodeWire.line(message).dropLast()))
        return true
    }

    /// Every acting connection marked not acting at once (no request of it acts from here), then told `code` and closed
    /// (acting from the page turned off): a reconnect watches, if its pairing still does, and doesn't act. The closes on
    /// `closeOn` (the listener's queue).
    public func endActing(code: String, reason: String, closeOn queue: DispatchQueue) {
        let ended = lock.withLock { () -> [LiveTransport] in
            var ended: [LiveTransport] = []
            for (id, open) in opens where open.principal.acts {
                if case .page(let rights, let terminals) = open.principal {
                    opens[id]?.principal = .page(rights.subtracting(.act), terminals: terminals)
                }
                if let transport = open.transport { ended.append(transport) }
            }
            return ended
        }
        queue.async { for transport in ended { transport.close(code: code, reason: reason) } }
    }

    /// The connections whose acting pairing is `key` (`ActingPages.key`) marked not acting and closed: its acting
    /// couldn't be kept.
    public func endActing(key: String, closeOn queue: DispatchQueue) {
        let ended = lock.withLock { () -> [LiveTransport] in
            var ended: [LiveTransport] = []
            for (id, open) in opens where open.credentials?.act != nil {
                guard let credentials = open.credentials, let act = credentials.act, ActingPages.key(token: credentials.token, secret: act) == key,
                      case .page(let rights, let terminals) = open.principal else { continue }
                opens[id]?.principal = .page(rights.subtracting([.act, .watch]), terminals: terminals)
                if let transport = open.transport { ended.append(transport) }
            }
            return ended
        }
        queue.async { for transport in ended { transport.close(code: "acts-off", reason: "this page's acting wasn't kept: pair it again to act") } }
    }

    /// How many acting connections are open.
    public var actingCount: Int { lock.withLock { opens.values.filter { $0.principal.acts && $0.transport != nil }.count } }

    public func binary(_ message: Data, on transport: LiveTransport) { inner.binary(message, on: transport) }

    public func closed(_ transport: LiveTransport) {
        lock.withLock { _ = opens.removeValue(forKey: ObjectIdentifier(transport)) }
        inner.closed(transport)
    }
}
