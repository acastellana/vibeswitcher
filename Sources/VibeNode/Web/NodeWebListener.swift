import Foundation
import VibeCore

/// The node's web listener (the live wire contract's "The WebSocket listener", the live plan's A2): `WebListener`
/// behind the seams (WebSeams.swift, LiveSeams.swift), so the integrator joins the lanes by handing this the files
/// (`WebAssetSource`), who may connect (`WebGate`) and the hub (`WebSocketHandler`).
///
/// - **One name.** Every request whose Host isn't exactly `127.0.0.1:<port>` is 421 with no body, an upgrade too:
///   no other name is this listener's, not `localhost`. (No Host, an empty one, or two, are 421 alike.)
/// - **Files.** A GET is answered with the source's file for its path, with the file's own headers, or 404.
/// - **One upgrade.** `/ws`, and only for a request whose Origin is exactly `http://127.0.0.1:<port>` and whose
///   `Sec-Fetch-Site`, when it sends one, is `same-origin`: else 403. Another path is 404. No subprotocol.
/// - **`auth` first.** The server says nothing on a WebSocket until its first text message is an `auth` request the
///   gate admits, within `authSeconds`. Anything else first, a refusal, or no message in time is `bye` (`auth`) and
///   4401. Then `hello` (what the `hello` closure gives), and the handler has the connection as a `LiveTransport`.
/// - **Closing.** Each close the server makes follows a `bye` whose code says why (`closeCode`).
/// - **Up while wanted.** `follow()` starts a listener while the gate wants one and stops it when it doesn't; a port
///   already taken is `State.refused`, never another port.
///
/// The limits are the contract's (`limits`). A client that doesn't read makes its transport not `writable` from
/// `busyBytes` queued, and `onWritable` is called when all of it has been written; a hub that sends on regardless
/// reaches the queue's limit (`WebLimits.maxQueuedBytes`), where the connection is closed and the client connects
/// again: no message is ever dropped from the middle of what a client is sent.
public final class NodeWebListener: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        /// No listener: nothing wants one.
        case off
        case on(port: UInt16)
        /// Wanted, and it couldn't be bound: why.
        case refused(String)
    }

    /// The contract's limits: 8 KiB of head and 5 s for it, a client's message at most 64 KiB, 32 connections, a ping
    /// every 15 s and the close after two missed; and at most 4 MiB queued for a client, where it is closed.
    public static var limits: WebLimits {
        var limits = WebLimits()
        limits.maxConnections = 32
        limits.maxHeaderBytes = 8 * 1_024
        limits.headSeconds = 5
        limits.maxMessageBytes = 64 * 1_024
        limits.maxQueuedBytes = 4 << 20
        // A file is at most 256 KiB on loopback: a client that takes longer than 5 s to read one holds a slot for
        // nothing (the security review at I1).
        limits.responseSeconds = 5
        limits.overflow = .close
        limits.pingSeconds = 15
        limits.maxMissedPings = 2
        return limits
    }

    /// Seconds an open WebSocket has to send its `auth`.
    public static let authSeconds = 5
    /// A transport stops being `writable` from this many bytes queued: the largest frame the server sends, so one
    /// more message after it still fits the queue.
    public static let busyBytes = 1 << 20
    /// What a client refused at `auth` is told, whatever was wrong with what it sent.
    static let authRefusal = "not admitted: run `vibeswitcher web` again"

    /// The WebSocket close code that goes with a `bye`'s code: 1001 `stopping`, 1009 `too-long`, 4400 `not-object`,
    /// `not-request` and `must`, 4401 `auth`, 4403 `revoked`, 4426 `version`; 1000 for any other.
    public static func closeCode(_ code: String) -> UInt16 {
        switch code {
        case "stopping": return 1001
        case "too-long": return 1009
        case "not-object", "not-request", "must": return 4400
        case "auth": return 4401
        case "revoked": return 4403
        case "version": return 4426
        default: return 1000
        }
    }

    /// A `bye` as one message: compact JSON, no newline.
    static func bye(code: String, reason: String) -> Data {
        NodeWire.line(NodeWire.Bye(reason: reason, code: code)).dropLast()
    }

    public let queue: DispatchQueue
    private let requestedPort: UInt16
    private let assets: WebAssetSource
    private let gate: WebGate
    private let handler: WebSocketHandler
    private let clock: NodeClock
    private let limits: WebLimits
    private let hello: ((WebAdmission) -> Data?)?
    private let note: (String) -> Void

    private let lock = NSLock()
    private var listener: WebListener?
    private var current = State.off

    // On `queue`.
    private var transports: [ObjectIdentifier: NodeWebTransport] = [:]
    private var everySecond: Subscription?
    private var generation = 0

    /// `port`: the one port (0: the kernel's pick, for tests). `hello`: the `hello` message for an admitted
    /// connection, as compact JSON (the integrator's: `Requests.hello` with the admission's `auth`); none, or nil:
    /// nothing is sent before the handler has the connection. `limits`: the contract's unless a test says otherwise;
    /// a full queue closes the connection whatever they say. Handlers and the gate are called on `queue`.
    public init(port: UInt16 = NodeWeb.port, assets: WebAssetSource, gate: WebGate, handler: WebSocketHandler, queue: DispatchQueue,
                clock: NodeClock, limits: WebLimits = NodeWebListener.limits, hello: ((WebAdmission) -> Data?)? = nil,
                note: @escaping (String) -> Void = { _ in }) {
        requestedPort = port
        self.assets = assets
        self.gate = gate
        self.handler = handler
        self.queue = queue
        self.clock = clock
        var limits = limits
        limits.overflow = .close
        self.limits = limits
        self.hello = hello
        self.note = note
    }

    public var state: State { lock.withLock { current } }

    /// The port bound; nil while there is no listener.
    public var port: UInt16? {
        if case .on(let port) = state { return port }
        return nil
    }

    /// The connections open now, in any state; 0 with no listener (tests).
    public var connectionCount: Int { lock.withLock { listener }?.connectionCount ?? 0 }

    /// Brings the listener to what the gate wants: up while a code or a token is alive, down otherwise, its
    /// connections told `revoked`. Called at the server's start and each time the gate changes; from any thread.
    @discardableResult
    public func follow() -> State {
        if gate.wanted {
            if port == nil { _ = try? start() }
        } else if port != nil {
            closeAll(code: "revoked", reason: "the web was closed: run `vibeswitcher web` again")
            stop()
        } else {
            lock.withLock { current = .off }
        }
        return state
    }

    /// Binds a listener, whatever the gate wants: the port bound. Throws, and the state says why, when it can't be;
    /// throws `alreadyStarted` when one is up.
    @discardableResult
    public func start() throws -> UInt16 {
        guard port == nil else { throw WebListener.Failure.alreadyStarted }
        let own = OwnName()
        let assets = assets
        let made = WebListener(queue: queue, clock: clock, limits: limits, policy: { host, origin, path, headers in
            guard let name = own.name, let origin else { return false }
            // Compared byte for byte: String's == is canonical equivalence, and these are one exact string each.
            return path == "/ws" && host.utf8.elementsEqual(name.utf8) && origin.utf8.elementsEqual(("http://" + name).utf8)
                && headers.all("sec-fetch-site").allSatisfy { $0 == "same-origin" }
        }, port: requestedPort, note: note)
        made.refuse = { request in
            guard let name = own.name, let host = request.headers["host"], host.utf8.elementsEqual(name.utf8) else {
                return WebResponse(status: 421)
            }
            if WebSocketHandshake.isAsked(by: request), request.path != "/ws" { return .plain(404) }
            return nil
        }
        made.onRequest = { request in
            guard let asset = assets.asset(path: request.path) else { return .plain(404) }
            // A file the browser holds already (its ETag in If-None-Match) is 304 with no body (`WebAssets.response`).
            let answer = WebAssets.response(to: asset, ifNoneMatch: request.headers["if-none-match"])
            var response = WebResponse(status: answer.status, body: answer.body)
            response.headers = answer.headers.map { WebHeaders.Field(name: $0.0, value: $0.1) }
            return response
        }
        made.onSocket = { [weak self] socket in self?.opened(socket) }
        do {
            let port = try made.start()
            own.set("127.0.0.1:\(port)")
            lock.withLock {
                listener = made
                current = .on(port: port)
            }
            return port
        } catch {
            let why = "127.0.0.1:\(requestedPort): \(error)"
            lock.withLock { current = .refused(why) }
            note("the web listener couldn't start: \(why)")
            throw error
        }
    }

    /// Stops the listener: each client is sent `bye` (`stopping`, unless it was told another already) and 1001 if its
    /// socket takes them at once, and the handler is told each has closed. `done` is called on `queue` once every
    /// descriptor is closed; at once when there is no listener.
    public func stop(_ done: (() -> Void)? = nil) {
        let stopped = lock.withLock { () -> WebListener? in
            defer {
                listener = nil
                current = .off
            }
            return listener
        }
        guard let stopped else {
            if let done { queue.async { done() } }
            return
        }
        stopped.stop(done)
    }

    /// `bye` with `code` and `reason`, then the close, to every connection (`revoked`: every token was dropped).
    public func closeAll(code: String, reason: String) {
        queue.async { [self] in
            for transport in Array(transports.values) { transport.close(code: code, reason: reason) }
        }
    }

    /// The same to the connections that came in under `token` (it ran out, or was revoked alone).
    public func close(token: String, code: String, reason: String) {
        queue.async { [self] in
            for transport in Array(transports.values) where transport.admission?.token == token { transport.close(code: code, reason: reason) }
        }
    }

    /// Every connection whose token the gate no longer holds (it ran out, or was revoked) told `revoked` and closed: the
    /// sweep the integration runs on its clock.
    public func closeUnheld() {
        queue.async { [self] in
            for transport in Array(transports.values) {
                guard let token = transport.admission?.token, !gate.holds(token) else { continue }
                transport.close(code: "revoked", reason: "this page's access ran out: run `vibeswitcher web` again")
            }
        }
    }

    /// This listener's one name, known once it is bound: read by its checks, on the queue.
    private final class OwnName: @unchecked Sendable {
        private let lock = NSLock()
        private var held: String?
        var name: String? { lock.withLock { held } }
        func set(_ name: String) { lock.withLock { held = name } }
    }

    // MARK: A connection, on `queue`

    private func opened(_ socket: WebSocketConnection) {
        let transport = NodeWebTransport(socket: socket)
        transports[ObjectIdentifier(transport)] = transport
        socket.onText = { [weak self, weak transport] text in
            guard let self, let transport else { return }
            self.took(Data(text.utf8), isText: true, on: transport)
        }
        socket.onBinary = { [weak self, weak transport] data in
            guard let self, let transport else { return }
            self.took(data, isText: false, on: transport)
        }
        socket.onDrained = { [weak transport] in transport?.drained() }
        socket.onClose = { [weak self, weak transport] _, _ in
            guard let self, let transport else { return }
            self.closed(transport)
        }
        let most = limits.maxMessageBytes
        socket.lastWords = { code in
            switch code {
            case WebSocketClose.tooBig:
                return String(decoding: NodeWebListener.bye(code: "too-long", reason: "a message over \(most) bytes"), as: UTF8.self)
            case WebSocketClose.goingAway:
                return String(decoding: NodeWebListener.bye(code: "stopping", reason: "the node's web listener is stopping"), as: UTF8.self)
            default: return nil
            }
        }
        rearmClock()
    }

    private func took(_ message: Data, isText: Bool, on transport: NodeWebTransport) {
        guard transport.admission != nil else {
            guard isText else { return transport.close(code: "auth", reason: Self.authRefusal) }
            return authenticate(message, transport)
        }
        if isText {
            handler.text(message, on: transport)
        } else {
            handler.binary(message, on: transport)
        }
    }

    /// The first message: an `auth` request the gate admits, or the connection's end.
    private func authenticate(_ message: Data, _ transport: NodeWebTransport) {
        guard let request = NodeWire.decode(NodeWire.Request.self, message), request.kind == "auth" else {
            return transport.close(code: "auth", reason: Self.authRefusal)
        }
        guard request.v <= NodeWire.version else {
            return transport.close(code: "version", reason: "this server speaks version \(NodeWire.version)")
        }
        guard let admission = gate.admit(request.args ?? [:]) else {
            return transport.close(code: "auth", reason: Self.authRefusal)
        }
        // A revoke may have landed since the gate said yes: nothing is said to a connection whose token is gone.
        guard gate.holds(admission.token) else {
            return transport.close(code: "revoked", reason: "this page's access was revoked: run `vibeswitcher web` again")
        }
        transport.admission = admission
        rearmClock()
        if let hello, let message = hello(admission) { transport.send(message) }
        handler.opened(transport, rights: admission.rights)
    }

    private func closed(_ transport: NodeWebTransport) {
        guard transports.removeValue(forKey: ObjectIdentifier(transport)) != nil else { return }
        rearmClock()
        if transport.admission != nil { handler.closed(transport) }
    }

    /// The clock's seconds, kept only while a connection has yet to send its `auth`.
    private func rearmClock() {
        let waiting = transports.values.contains { $0.admission == nil }
        if waiting, everySecond == nil {
            generation += 1
            let armed = generation
            everySecond = clock.every(1) { [weak self] in
                self?.queue.async { [weak self] in self?.second(armed) }
            }
        } else if !waiting, everySecond != nil {
            everySecond?.cancel()
            everySecond = nil
            generation += 1
        }
    }

    private func second(_ armed: Int) {
        guard armed == generation else { return }
        for transport in Array(transports.values) where transport.admission == nil {
            transport.seconds += 1
            if transport.seconds > Self.authSeconds { transport.close(code: "auth", reason: Self.authRefusal) }
        }
    }
}

/// One web connection as the hub sees it: a WebSocket whose text messages are the wire's JSON objects.
final class NodeWebTransport: LiveTransport, @unchecked Sendable {
    private let socket: WebSocketConnection
    private let lock = NSLock()
    private var whenWritable: (() -> Void)?
    /// `onWritable` is owed: the queue was found busy, and its drain has been asked for.
    private var owed = false
    /// Who it is, once admitted; and the clock's seconds it has been open without. On the listener's queue.
    var admission: WebAdmission?
    var seconds = 0

    init(socket: WebSocketConnection) {
        self.socket = socket
    }

    /// One message, as a text frame. Never dropped while the hub sends only when `writable`: past that, a queue that
    /// reaches its limit closes the connection.
    func send(_ message: Data) {
        socket.send(text: String(decoding: message, as: UTF8.self))
        if socket.queuedBytes >= NodeWebListener.busyBytes { owe() }
    }

    /// One binary message (the terminal's, slice 4): false when it wasn't queued.
    @discardableResult
    func send(binary: Data) -> Bool {
        let sent = socket.send(binary: binary)
        if socket.queuedBytes >= NodeWebListener.busyBytes { owe() }
        return sent
    }

    /// False from `NodeWebListener.busyBytes` queued; `onWritable` follows once all of it has been written.
    var writable: Bool {
        guard socket.queuedBytes >= NodeWebListener.busyBytes else { return true }
        owe()
        return false
    }

    var onWritable: (() -> Void)? {
        get { lock.withLock { whenWritable } }
        set { lock.withLock { whenWritable = newValue } }
    }

    private func owe() {
        let ask = lock.withLock { () -> Bool in
            defer { owed = true }
            return !owed
        }
        if ask { socket.awaitDrain() }
    }

    /// Everything queued has been written. On the listener's queue.
    func drained() {
        let call = lock.withLock { () -> (() -> Void)? in
            guard owed else { return nil }
            owed = false
            return whenWritable
        }
        call?()
    }

    /// `bye` with `code` and `reason` after what is queued, then the close with the code's number.
    func close(code: String, reason: String) {
        socket.send(text: String(decoding: NodeWebListener.bye(code: code, reason: reason), as: UTF8.self))
        socket.close(code: NodeWebListener.closeCode(code), reason: code)
    }
}
