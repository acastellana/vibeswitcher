import Foundation
import VibeCore

/// A plugin's one-request page, served by the core (the definition's "The page is the core's", rule 6): the plugin gives
/// the page as data (`Spec`: its HTML, the hashes of its scripts and styles for the content security policy, how long it
/// may live, 15 minutes at most); the core serves it once on an origin of its own, 127.0.0.1 on a port the session host
/// binds and holds (`HostWebListen.Place.page`, as H1 holds the web's), under its own one-time token
/// (`http://127.0.0.1:<port>/<token>/`); checks Host, Origin, path and token. The page is served once (a second load
/// is 410), and that one load is given a second secret, an HttpOnly SameSite=Strict cookie, that the answer needs: a
/// process that learned the address after the load can't answer. It takes one answer of bounded size over a WebSocket
/// at `/<token>/answer` with the page's own Host and Origin and the cookie (one such socket at a time, one answer in
/// flight), and hands its bytes to the plugin (which says whether it takes them, or refuses a garbled one: the page may
/// send again, a few times; a refused upgrade costs no try, an answer over the size does). Then, or at the end of its
/// life, it stops and the host lets the port go. One page at a time on a node. The token goes only to the answering
/// terminal: never on a card, the wire, the log or to the plugin.
///
/// Its limits (accepted, the review of 6e91f053's L4 and L5): after a server death the host holds the page's port until
/// the next page or a release; any local process can fill the page's connection slots until it stops.
public final class PluginPage: @unchecked Sendable {
    /// The page as a plugin gives it: data.
    public struct Spec: Codable, Equatable, Sendable {
        public var html: String
        /// SHA-256 of each inline script and style, base64 (`'sha256-…'` in the policy): nothing else runs or styles.
        public var scripts: [String]
        public var styles: [String]
        /// Seconds it may live, `longestLife` at most.
        public var life: TimeInterval
        public init(html: String, scripts: [String], styles: [String], life: TimeInterval) {
            self.html = html
            self.scripts = scripts
            self.styles = styles
            self.life = life
        }

        public static let longestLife: TimeInterval = 15 * 60
        public static let htmlBytesAtMost = 256 * 1024

        /// Why this page isn't served (nil: it may be): too big, a life past 15 minutes, a hash that isn't one.
        public var refusal: String? {
            guard html.utf8.count <= Self.htmlBytesAtMost else { return "its page is over \(Self.htmlBytesAtMost / 1024) KiB" }
            guard life > 0, life <= Self.longestLife else { return "its page may live \(Int(Self.longestLife / 60)) minutes at most" }
            guard scripts.count + styles.count <= 16, (scripts + styles).allSatisfy(Self.isHash) else {
                return "its page's hashes are SHA-256 digests in base64, 16 at most"
            }
            return nil
        }

        static func isHash(_ text: String) -> Bool { text.count == 44 && Data(base64Encoded: text)?.count == 32 }

        /// The policy: only the page's own scripts and styles, connections only to its own origin.
        public var csp: String {
            let names = { (hashes: [String]) in hashes.isEmpty ? "'none'" : hashes.map { "'sha256-\($0)'" }.joined(separator: " ") }
            return "default-src 'none'; script-src \(names(scripts)); style-src \(names(styles)); connect-src 'self'; img-src 'none'; "
                + "font-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        }
    }

    /// The most an answer holds, and how many garbled ones are taken before the page stops.
    public static let answerBytesAtMost = 16 * 1024
    public static let triesAtMost = 8

    let token: String
    private let spec: Spec
    private let queue = DispatchQueue(label: "vibenode.plugins.page")
    private let lock = NSLock()
    private var listener: WebListener?
    private var bind: WebBind?
    private var bound: UInt16 = 0
    private var done = false
    private var tries = 0
    /// The one load's second secret (nil until the page was loaded), the answer socket open, an answer with the plugin.
    private var loaded: String?
    private var socketOpen = false
    private var inFlight = false
    /// Hands an answer's bytes to the plugin, which says (later) whether it took it.
    private var take: ((Data, @escaping (Bool) -> Void) -> Void)?
    private var ended: ((Bool) -> Void)?

    init(spec: Spec, token: String = Base64URL.encode(WebPush.randomBytes(32))) {
        self.spec = spec
        self.token = token
    }

    /// The page's address once started.
    var url: URL? { lock.withLock { bound == 0 ? nil : URL(string: "http://127.0.0.1:\(bound)/\(token)/") } }

    /// Listens (the socket from `bind`) and serves; `take` hears each answer (true: taken, the page stops); `ended` once,
    /// with whether an answer was taken, when it stops (taken, its life over, too many garbled answers, or `stop`).
    /// Throws when the page is refused or can't listen.
    func start(bind: WebBind, clock: NodeClock, take: @escaping (Data, @escaping (Bool) -> Void) -> Void, ended: @escaping (Bool) -> Void) throws -> URL {
        lock.withLock {
            self.take = take
            self.ended = ended
        }
        if let why = spec.refusal {
            stop(taken: false)
            throw PluginRefusal(why)
        }
        var limits = WebLimits()
        // An answer over the size is closed by the listener (1009), and counts as a try (below).
        limits.maxMessageBytes = Self.answerBytesAtMost
        limits.maxConnections = 16
        let listener = WebListener(queue: queue, clock: clock, limits: limits, policy: { [weak self] host, origin, path, headers in
            guard let self else { return false }
            return self.lock.withLock {
                let place = "127.0.0.1:\(self.bound)"
                guard !self.done, !self.socketOpen, self.tries < Self.triesAtMost, let secret = self.loaded,
                      host == place, origin == "http://" + place, RemoteAuth.constantTimeEquals(path, "/\(self.token)/answer"),
                      let given = Self.cookie(headers["cookie"]), RemoteAuth.constantTimeEquals(given, secret) else { return false }
                self.socketOpen = true
                return true
            }
        })
        listener.bindWith = { [weak self] _, address, port, backlog in
            let made = bind.listen(.page, address, port, backlog)
            if case .success(let fd) = made, let port = Platform.TCP.localPort(fd) { self?.lock.withLock { self?.bound = port } }
            return made
        }
        listener.admitPeer = { $0 == "127.0.0.1" }
        listener.refuse = { [weak self] request in
            guard let self else { return .plain(410) }
            let (place, over) = self.lock.withLock { ("127.0.0.1:\(self.bound)", self.done) }
            // A page under another name that resolves here (DNS rebinding) sends its own name.
            guard request.host == place else { return .plain(421) }
            return over ? .plain(410) : nil
        }
        let page = Data(spec.html.utf8), csp = spec.csp
        let token = self.token
        listener.onRequest = { [weak self] request in
            guard let self, RemoteAuth.constantTimeEquals(request.path, "/\(token)/") else { return .plain(404) }
            // Served once: the one load gets the answer's secret.
            let secret: String? = self.lock.withLock {
                guard self.loaded == nil, !self.done else { return nil }
                let made = Base64URL.encode(WebPush.randomBytes(32))
                self.loaded = made
                return made
            }
            guard let secret else { return .plain(410) }
            let cookie = "\(Self.cookieName)=\(secret); Path=/\(token)/; HttpOnly; SameSite=Strict"
            return WebResponse(status: 200, headers: Self.headers(contentType: "text/html; charset=utf-8", csp: csp) + [("Set-Cookie", cookie)], body: page)
        }
        listener.onSocket = { [weak self] socket in
            socket.onClose = { code, _ in
                guard let self else { return }
                let over: Bool = self.lock.withLock {
                    self.socketOpen = false
                    if code == WebSocketClose.tooBig { self.tries += 1 }
                    return self.tries >= Self.triesAtMost && !self.inFlight
                }
                if over { self.stop(taken: false) }
            }
            socket.onText = { text in
                guard let self else { return socket.close() }
                let bytes = Data(text.utf8)
                enum Turn { case take((Data, @escaping (Bool) -> Void) -> Void), busy, over }
                // One answer in flight; marked before the taker is called, cleared when the plugin refused it.
                let turn: Turn = self.lock.withLock {
                    guard !self.done, self.tries < Self.triesAtMost else { return .over }
                    guard !self.inFlight else { return .busy }
                    guard bytes.count <= Self.answerBytesAtMost, let take = self.take else { self.tries += 1; return .over }
                    self.tries += 1
                    self.inFlight = true
                    return .take(take)
                }
                switch turn {
                case .busy: _ = socket.send(text: "busy")
                case .over:
                    _ = socket.send(text: "refused")
                    if self.lock.withLock({ self.tries >= Self.triesAtMost }) { socket.close(); self.stop(taken: false) }
                case .take(let taker):
                    taker(bytes) { taken in
                        self.queue.async {
                            let over: Bool = self.lock.withLock {
                                self.inFlight = false
                                return self.tries >= Self.triesAtMost
                            }
                            _ = socket.send(text: taken ? "ok" : "refused")
                            if taken || over {
                                socket.close()
                                self.stop(taken: taken)
                            }
                        }
                    }
                }
            }
        }
        let stopped: Bool = lock.withLock {
            guard !done else { return true }
            self.listener = listener
            self.bind = bind
            return false
        }
        guard !stopped else { throw PluginRefusal("the page was stopped before it opened") }
        do {
            try listener.start()
        } catch {
            stop(taken: false)
            throw PluginRefusal("the page couldn't listen: \(error)")
        }
        guard let url else {
            stop(taken: false)
            throw PluginRefusal("the page has no port")
        }
        queue.asyncAfter(deadline: .now() + spec.life) { [weak self] in self?.stop(taken: false) }
        return url
    }

    /// Stops serving, once; the host lets the port go and `ended` hears whether an answer was taken.
    func stop(taken: Bool = false) {
        let (listener, bind, ended) = lock.withLock { () -> (WebListener?, WebBind?, ((Bool) -> Void)?) in
            guard !done else { return (nil, nil, nil) }
            done = true
            defer { self.listener = nil; self.bind = nil; self.take = nil; self.ended = nil }
            return (self.listener, self.bind, self.ended)
        }
        // The engine's one-page slot is freed (`ended`) only once the host has let the port go.
        guard let listener else { return ended?(taken) ?? () }
        listener.stop {
            bind?.release(.page)
            ended?(taken)
        }
    }

    static let cookieName = "vs-page"

    /// The page's secret from a Cookie header, when it has exactly one.
    static func cookie(_ header: String?) -> String? {
        let found = (header ?? "").split(separator: ";").compactMap { pair -> String? in
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == cookieName ? parts[1] : nil
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Every answer's headers: the page's own policy, no framing, sniffing, referrer or cache.
    static func headers(contentType: String, csp: String) -> [(String, String)] {
        [("Content-Type", contentType), ("Content-Security-Policy", csp), ("X-Frame-Options", "DENY"),
         ("Referrer-Policy", "no-referrer"), ("Cross-Origin-Resource-Policy", "same-origin"), ("Cache-Control", "no-store")]
    }

    /// `'sha256-…'`'s digest of `text`, base64: what a plugin gives for an inline script or style.
    public static func hash(_ text: String) -> String {
        let hex = BuildInfo.sha256(of: Data(text.utf8))
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes).base64EncodedString()
    }
}
