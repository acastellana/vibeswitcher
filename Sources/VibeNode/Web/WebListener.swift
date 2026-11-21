import Foundation
import VibeCore

/// The node's web listener (the design's "Listeners are split": the local one, a loopback port that trusts no
/// header): HTTP/1.1 GET and WebSocket (RFC 6455) on a TCP port of this machine's loopback, with nothing but
/// Foundation, the platform layer and SHA-1 under it.
///
/// - **The bind.** A numeric address, 127.0.0.1 by default; anything that isn't loopback is refused before a socket
///   is made, unless the caller says `allowBeyondLoopback`. Port 0 is a port the system picks, which `start` returns.
/// - **A request** is a GET with no body, read under limits (`WebLimits`, `HTTPHead`) and a deadline. `onRequest`
///   answers it; with none it is 404. Every response carries `X-Content-Type-Options: nosniff` and
///   `Connection: close` (one request a connection), and none repeats anything the client sent: the listener's own
///   answers are a status and its name.
/// - **A WebSocket** is opened only when `policy` allows it, having seen the request's Host and Origin: with no
///   policy every upgrade is 403. The check that the Host is this listener's own name (a page of another site that
///   resolves to this machine) and the Origin the web client's (another site's page in the user's browser) is the
///   policy's to make. A plain GET isn't shown to the policy: `onRequest` reads `WebRequest.host` itself.
/// - **Limits.** `WebLimits.maxConnections` connections at once; each read and each wait bounded; each client's
///   outbound queue capped (`WebSocketConnection.onFellBehind`).
/// - **Descriptors.** Each is close-on-exec from its making (`Platform.TCP.listen`, `Platform.Sockets.accept`) and
///   closed once the last dispatch source on it has ended, whichever way its connection ends.
///
/// Everything runs on `queue`: the handlers are called there. Timeouts and pings come from `clock`, to its whole
/// seconds: a wait of N seconds ends between N and N + 1.
///
/// Not here: TLS (the listener is loopback's; the remote one is `tailscale serve`'s), permessage-deflate or any
/// other extension, connections kept alive between requests, request bodies, any method but GET, a Date field.
public final class WebListener: @unchecked Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The address isn't a numeric loopback address, and nothing allowed another.
        case notLoopback(String)
        /// Started before (a listener starts once), or stopped.
        case alreadyStarted
        case system(Platform.TCP.Failure)
        /// The session host, which holds the node's web sockets (H1, `WebBind.host`), didn't give one: why.
        case host(String)

        public var description: String {
            switch self {
            case .notLoopback(let address): return "\(address) isn't a loopback address: the web listener binds to loopback only"
            case .alreadyStarted: return "the web listener was started before"
            case .system(let failure): return "the web listener's socket: \(failure)"
            case .host(let why): return "the session host gave no web socket: \(why)"
            }
        }
    }

    /// Where the listening socket comes from (H1): nil, made here (`Platform.TCP.listen`); else this, which on the
    /// user's node asks the session host for the socket it holds (`WebBind.host`). Called on `queue` by `start`, with
    /// the family, the address, the port and the backlog; the socket it gives is this listener's to close.
    public var bindWith: ((Platform.TCP.Family, String, UInt16, Int32) -> Result<Int32, Failure>)?

    /// Whether a WebSocket may be opened for a request with this Host, this Origin (nil: it sent none), this path
    /// and these fields.
    public typealias Policy = (_ host: String, _ origin: String?, _ path: String, _ headers: WebHeaders) -> Bool

    public let queue: DispatchQueue
    public let limits: WebLimits
    public let family: Platform.TCP.Family
    public let address: String
    private let requestedPort: UInt16
    private let allowBeyondLoopback: Bool
    private let clock: NodeClock
    private let policy: Policy?
    private let note: (String) -> Void

    /// Asked of every request, an upgrade too, before anything else: an answer refuses it. For what holds whatever
    /// the path (a Host that isn't this listener's own name). Set before `start`; called on `queue`.
    public var refuse: ((WebRequest) -> WebResponse?)?
    /// Answers a GET that isn't an upgrade. Set before `start`; called on `queue`.
    public var onRequest: ((WebRequest) -> WebResponse)?
    /// Takes a WebSocket the policy allowed, to set its handlers. Set before `start`; called on `queue`. With none,
    /// an upgrade is 404.
    public var onSocket: ((WebSocketConnection) -> Void)?
    /// Whether a connection from this peer address (numbers) is kept: one it refuses is closed as it is accepted, with
    /// nothing read or written. None: every peer is. Set before `start`; called on `queue`.
    public var admitPeer: ((String) -> Bool)?
    /// The subprotocols this server speaks, the one it prefers first: a client that offers some gets the first of
    /// these among them, or none. Set before `start`.
    public var subprotocols: [String] = []

    private let portLock = NSLock()
    private var boundPort: UInt16?
    /// Set on `queue`, so a call that waits for the queue knows when it is on it already.
    private let onQueueKey = DispatchSpecificKey<Bool>()

    // On `queue`, all below.
    private var listener: Int32 = -1
    private var listening: DispatchSourceRead?
    /// The accept source is suspended until the clock's next second: accept failed for want of descriptors or memory.
    private var acceptPaused = false
    private var connections: [ObjectIdentifier: WebConnection] = [:]
    /// The descriptors this listener holds open: its socket and each connection's.
    private var descriptors = 0
    private var stopping = false
    private var whenStopped: [() -> Void] = []
    /// This listener, held from `stop` until its last descriptor is closed: one let go meanwhile still calls `done`.
    private var untilStopped: WebListener?
    private var everySecond: Subscription?
    private var everyPing: Subscription?
    /// Counts each subscription, so a tick already on its way from one cancelled does nothing.
    private var secondsGeneration = 0
    private var pingGeneration = 0
    /// A refusal at the connection limit has been noted since a connection last closed.
    private var capNoted = false
    /// A peer `admitPeer` refused has been noted (once a listener: the note says nothing of who).
    private var peerNoted = false
    private var chunk = [UInt8](repeating: 0, count: 64 * 1_024)

    /// `queue`: where everything runs and every handler is called. `clock`: the timeouts' and the pings' seconds.
    /// `policy`: which upgrades are allowed (none: none). `family`, `address`, `port`: the bind, a numeric address.
    /// `allowBeyondLoopback`: binds to an address that isn't loopback too; nothing does today. `note`: the log, which
    /// gets nothing a client sent.
    public init(queue: DispatchQueue, clock: NodeClock, limits: WebLimits = WebLimits(), policy: Policy? = nil,
                family: Platform.TCP.Family = .ipv4, address: String = "127.0.0.1", port: UInt16 = 0,
                allowBeyondLoopback: Bool = false, note: @escaping (String) -> Void = { _ in }) {
        self.queue = queue
        self.clock = clock
        self.limits = limits
        self.policy = policy
        self.family = family
        self.address = address
        requestedPort = port
        self.allowBeyondLoopback = allowBeyondLoopback
        self.note = note
        queue.setSpecific(key: onQueueKey, value: true)
    }

    /// Runs `work` on `queue` and waits for it: at once when the caller is on the queue already.
    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: onQueueKey) == true { return try work() }
        return try queue.sync(execute: work)
    }

    deinit {
        queue.setSpecific(key: onQueueKey, value: nil)
        // Released without `stop`: the sources are cancelled, and their cancel handlers close what they watch.
        if acceptPaused { listening?.resume() }
        listening?.cancel()
        for connection in connections.values {
            connection.phase = .closed
            connection.reading?.cancel()
            connection.writing?.cancel()
            connection.closeWhenUnwatched()
        }
    }

    /// Why a bind to `address` is refused; nil when it isn't.
    public static func refusal(family: Platform.TCP.Family, address: String, allowBeyondLoopback: Bool) -> Failure? {
        allowBeyondLoopback || Platform.TCP.isLoopback(family: family, address: address) ? nil : .notLoopback(address)
    }

    /// The port bound; nil before `start`.
    public var port: UInt16? { portLock.withLock { boundPort } }

    /// The connections open now, in any state (tests).
    public var connectionCount: Int { onQueue { connections.count } }

    /// The descriptors held now: the listener's socket and each connection's, until each is closed (tests).
    public var descriptorCount: Int { onQueue { descriptors } }

    /// Binds and listens, and from then on accepts: the port bound. Throws when the address is refused or the socket
    /// can't be made. From any thread, `queue`'s too.
    @discardableResult
    public func start() throws -> UInt16 {
        if let refusal = Self.refusal(family: family, address: address, allowBeyondLoopback: allowBeyondLoopback) { throw refusal }
        return try onQueue {
            guard listener < 0, !stopping else { throw Failure.alreadyStarted }
            let fd: Int32
            if let bindWith {
                switch bindWith(family, address, requestedPort, limits.backlog) {
                case .success(let given): fd = given
                case .failure(let failure): throw failure
                }
            } else {
                switch Platform.TCP.listen(family: family, address: address, port: requestedPort, backlog: limits.backlog) {
                case .success(let made): fd = made
                case .failure(let failure): throw Failure.system(failure)
                }
            }
            guard let port = Platform.TCP.localPort(fd) else {
                let code = errno
                Sys.close(fd)
                throw Failure.system(.system("getsockname", code))
            }
            listener = fd
            descriptors += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll(fd) }
            source.setCancelHandler { [weak self] in
                Sys.close(fd)
                self?.descriptorClosed()
            }
            listening = source
            source.resume()
            portLock.withLock { boundPort = port }
            return port
        }
    }

    /// Stops accepting and closes every connection: a WebSocket's client is sent its handler's last words and a close
    /// frame (1001) if its socket takes them at once, and its `onClose` is called. `done` is called on `queue` once
    /// every descriptor is closed.
    public func stop(_ done: (() -> Void)? = nil) {
        queue.async { [self] in
            if let done { whenStopped.append(done) }
            stopping = true
            untilStopped = self
            if acceptPaused {
                acceptPaused = false
                listening?.resume()
            }
            listening?.cancel()
            listening = nil
            listener = -1
            for connection in Array(connections.values) {
                if connection.phase == .open {
                    connection.out.seal(last: lastWords(connection, WebSocketClose.goingAway) + WebSocketFrame.close(code: WebSocketClose.goingAway, reason: ""),
                                        dropUnsent: true)
                    _ = connection.out.flush(to: connection.fd)
                }
                drop(connection, code: WebSocketClose.goingAway, reason: "the listener stopped")
            }
            rearmClock()
            finishStopping()
        }
    }

    private func descriptorClosed() {
        descriptors -= 1
        finishStopping()
    }

    private func finishStopping() {
        guard stopping, descriptors == 0 else { return }
        let handlers = whenStopped
        whenStopped = []
        for handler in handlers { handler() }
        untilStopped = nil
    }

    // MARK: Accepting

    /// Takes the connections waiting, at most 64 a turn: a burst of them doesn't keep the queue from the connections
    /// open (the source fires again while more wait).
    private func acceptAll(_ listener: Int32) {
        for _ in 0..<64 where !stopping {
            let fd = Platform.Sockets.accept(listener)
            guard fd >= 0 else {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                if code != EAGAIN, code != EWOULDBLOCK { pauseAccepting(code) }
                return
            }
            if let admitPeer, !(Platform.TCP.peerAddress(fd).map(admitPeer) ?? false) {
                Sys.close(fd)
                if !peerNoted {
                    peerNoted = true
                    note("the web listener closed a connection from outside the addresses it takes")
                }
                continue
            }
            Platform.TCP.configure(fd)
            guard connections.count < limits.maxConnections else {
                // One write, whatever of it the new socket takes, and the close: nothing is kept for a connection
                // over the limit.
                let refusal = WebResponse.plain(503).serialized()
                _ = refusal.withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
                Sys.close(fd)
                if !capNoted {
                    capNoted = true
                    note("the web listener has \(limits.maxConnections) connections open: more are refused")
                }
                continue
            }
            adopt(fd)
        }
    }

    /// Accept failed for a reason that lasts (no descriptor left, no memory): the listener's source, which would
    /// fire again at once for as long as a connection waits, is suspended until the clock's next second.
    private func pauseAccepting(_ code: Int32) {
        guard !acceptPaused, let listening else { return }
        note("the web listener couldn't accept (errno \(code)): it tries again in a second")
        acceptPaused = true
        listening.suspend()
        rearmClock()
    }

    private func adopt(_ fd: Int32) {
        descriptors += 1
        let connection = WebConnection(fd: fd, limits: limits)
        connection.onDescriptorClosed = { [weak self] in self?.descriptorClosed() }
        connections[ObjectIdentifier(connection)] = connection
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.readable(connection)
        }
        read.setCancelHandler { connection.sourceEnded() }
        connection.sources += 1
        connection.reading = read
        read.resume()
        rearmClock()
    }

    // MARK: Reading

    /// Reads what has come, at most sixteen chunks a turn: one busy connection doesn't keep the queue from the others.
    private func readable(_ connection: WebConnection) {
        for _ in 0..<16 {
            guard connection.phase != .closed, connection.reading != nil else { return }
            let count = chunk.withUnsafeMutableBytes { Sys.read(connection.fd, $0.baseAddress, $0.count) }
            if count == 0 { return ended(connection) }
            if count < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return }
                return drop(connection, code: WebSocketClose.abnormal, reason: "")
            }
            switch connection.phase {
            case .head: takeHead(connection, chunk[0..<count])
            case .open: feed(connection, chunk[0..<count])
            case .finishing, .lingering, .closed: break
            }
            if count < chunk.count { return }
        }
    }

    /// The client ended its side.
    private func ended(_ connection: WebConnection) {
        switch connection.phase {
        case .head, .open, .lingering:
            drop(connection, code: WebSocketClose.abnormal, reason: "")
        case .finishing:
            // It may still read what is leaving (a client that sends its request and ends its writes).
            connection.peerEnded = true
            connection.reading?.cancel()
            connection.reading = nil
        case .closed:
            break
        }
    }

    private func takeHead(_ connection: WebConnection, _ bytes: ArraySlice<UInt8>) {
        switch connection.head.take(bytes, limits: limits) {
        case .more:
            return
        case .refused(let response):
            respond(connection, response)
        case .request(let request, let rest):
            connection.head = HTTPHead()
            route(connection, request, rest)
        }
    }

    private func route(_ connection: WebConnection, _ request: WebRequest, _ rest: [UInt8]) {
        if let refusal = refuse?(request) { return respond(connection, refusal) }
        guard WebSocketHandshake.isAsked(by: request) else {
            return respond(connection, onRequest?(request) ?? .plain(404))
        }
        let key: String
        switch WebSocketHandshake.key(of: request) {
        case .success(let found): key = found
        case .failure(let refusal): return respond(connection, refusal.response)
        }
        guard let policy, policy(request.host, request.origin, request.path, request.headers) else {
            return respond(connection, .plain(403))
        }
        guard let onSocket else { return respond(connection, .plain(404)) }
        let offered = request.headers.list("sec-websocket-protocol")
        let subprotocol = subprotocols.first { offered.contains($0) }
        let socket = WebSocketConnection(request: request, subprotocol: subprotocol, queue: queue, overflow: limits.overflow, out: connection.out)
        socket.listener = self
        socket.connection = connection
        connection.socket = socket
        connection.enter(.open)
        connection.out.push(WebSocketHandshake.opening(key: key, subprotocol: subprotocol))
        onSocket(socket)
        flush(connection)
        rearmClock()
        if !rest.isEmpty { feed(connection, rest[...]) }
    }

    /// The answer queued, then the connection's end.
    private func respond(_ connection: WebConnection, _ response: WebResponse) {
        connection.out.seal(last: response.serialized(), dropUnsent: true)
        finish(connection, within: limits.responseSeconds)
    }

    /// What is queued leaves, within `seconds`; then the writes are ended and the client's own end awaited.
    private func finish(_ connection: WebConnection, within seconds: Int) {
        guard connection.phase != .closed else { return }
        connection.enter(.finishing, for: seconds)
        flush(connection)
        rearmClock()
    }

    // MARK: A WebSocket's frames

    private func feed(_ connection: WebConnection, _ bytes: ArraySlice<UInt8>) {
        connection.decoder.append(bytes)
        while connection.phase == .open, let socket = connection.socket, !connection.out.isSealed {
            let event: WebSocketDecoder.Event?
            do {
                event = try connection.decoder.next()
            } catch let failure as WebSocketDecoder.Failure {
                return end(connection, sending: failure.code, reason: failure.reason, reporting: failure.code, failure.reason,
                           after: lastWords(connection, failure.code))
            } catch {
                return end(connection, sending: WebSocketClose.internalError, reason: "", reporting: WebSocketClose.internalError, "")
            }
            guard let event else { return }
            socket.heard = true
            switch event {
            case .text(let text):
                socket.onText?(text)
            case .binary(let data):
                socket.onBinary?(data)
            case .ping(let payload):
                connection.out.control(pong: WebSocketFrame.encode(.pong, payload))
                flush(connection)
            case .pong:
                break
            case .close(let code, let reason):
                // Its own code back, as the handshake has it.
                return end(connection, sending: code ?? WebSocketClose.normal, reason: "", reporting: code ?? WebSocketClose.noStatus, reason)
            }
        }
    }

    /// The handler's last words for a WebSocket the listener closes with `code`, as a text frame; nothing when it
    /// has none.
    private func lastWords(_ connection: WebConnection, _ code: UInt16) -> Data {
        guard let words = connection.socket?.lastWords?(code) else { return Data() }
        return WebSocketFrame.encode(.text, Data(words.utf8))
    }

    /// The WebSocket ended from this side of the wire: a close frame (`words` before it) in place of what hadn't
    /// started, `onClose`, and the connection's end.
    private func end(_ connection: WebConnection, sending code: UInt16, reason: String, reporting reported: UInt16, _ reportedReason: String,
                     after words: Data = Data()) {
        guard connection.phase == .open else { return }
        connection.out.seal(last: words + WebSocketFrame.close(code: code, reason: reason), dropUnsent: true)
        let socket = connection.socket
        connection.socket = nil
        socket?.reportClosed(reported, reportedReason)
        finish(connection, within: limits.closeSeconds)
    }

    /// `WebSocketConnection.close`, which has queued its close frame already.
    func closed(by socket: WebSocketConnection, code: UInt16, reason: String) {
        guard let connection = socket.connection, connection.phase == .open else { return }
        connection.socket = nil
        socket.reportClosed(code, reason)
        finish(connection, within: limits.closeSeconds)
    }

    // MARK: Writing

    func flush(_ connection: WebConnection) {
        guard connection.phase == .open || connection.phase == .finishing else { return }
        switch connection.out.flush(to: connection.fd) {
        case .failed:
            drop(connection, code: WebSocketClose.abnormal, reason: "")
        case .blocked:
            guard connection.writing == nil else { return }
            let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.flush(connection)
            }
            source.setCancelHandler { connection.sourceEnded() }
            connection.sources += 1
            connection.writing = source
            source.resume()
        case .empty(let drained):
            connection.writing?.cancel()
            connection.writing = nil
            if connection.phase == .finishing {
                if connection.peerEnded {
                    drop(connection, code: WebSocketClose.abnormal, reason: "")
                } else {
                    // The client reads the end after the last byte, and its own end is awaited: a socket closed with
                    // bytes unread would be reset, and the reset can take the last bytes with it.
                    Platform.TCP.endWrites(connection.fd)
                    connection.enter(.lingering, for: limits.closeSeconds)
                    rearmClock()
                }
            } else if drained {
                connection.socket?.onDrained?()
            }
        }
    }

    /// The connection closed now: its sources cancelled, its socket closed once the last of them has ended, and a
    /// WebSocket still open told so (`onClose`).
    func drop(_ connection: WebConnection, code: UInt16, reason: String) {
        guard connection.phase != .closed else { return }
        connection.phase = .closed
        connection.out.discard()
        connection.reading?.cancel()
        connection.writing?.cancel()
        connection.reading = nil
        connection.writing = nil
        connections[ObjectIdentifier(connection)] = nil
        capNoted = false
        connection.closeWhenUnwatched()
        let socket = connection.socket
        connection.socket = nil
        rearmClock()
        socket?.reportClosed(code, reason)
    }

    // MARK: The clock

    /// The clock's subscriptions, kept only while something waits on them: every second while a connection is in a
    /// state it may stay in only so long (or accepting is paused), every `pingSeconds` while a WebSocket is open.
    private func rearmClock() {
        let timed = !stopping && (acceptPaused || connections.values.contains { $0.phase.isTimed })
        if timed, everySecond == nil {
            secondsGeneration += 1
            let generation = secondsGeneration
            everySecond = clock.every(1) { [weak self] in
                self?.queue.async { [weak self] in self?.second(generation) }
            }
        } else if !timed, everySecond != nil {
            everySecond?.cancel()
            everySecond = nil
            secondsGeneration += 1
        }
        let pinging = !stopping && limits.pingSeconds > 0 && connections.values.contains { $0.phase == .open }
        if pinging, everyPing == nil {
            pingGeneration += 1
            let generation = pingGeneration
            everyPing = clock.every(limits.pingSeconds) { [weak self] in
                self?.queue.async { [weak self] in self?.pingAll(generation) }
            }
        } else if !pinging, everyPing != nil {
            everyPing?.cancel()
            everyPing = nil
            pingGeneration += 1
        }
    }

    /// A second of the clock: each connection that has stayed its time is ended: a request's head still coming gets
    /// 408; last bytes still leaving, or a client's end still awaited, the close.
    private func second(_ generation: Int) {
        guard generation == secondsGeneration, !stopping else { return }
        if acceptPaused {
            acceptPaused = false
            listening?.resume()
        }
        for connection in Array(connections.values) where connection.phase.isTimed {
            connection.seconds += 1
            guard connection.seconds > connection.allowed else { continue }
            if connection.phase == .head {
                respond(connection, .plain(408))
            } else {
                drop(connection, code: WebSocketClose.abnormal, reason: "")
            }
        }
        rearmClock()
    }

    /// A ping to each open WebSocket; one that has sent nothing since `maxMissedPings` pings in a row is closed.
    private func pingAll(_ generation: Int) {
        guard generation == pingGeneration, !stopping else { return }
        for connection in Array(connections.values) where connection.phase == .open {
            guard let socket = connection.socket else { continue }
            socket.missed = socket.heard ? 0 : socket.missed + 1
            if socket.missed >= max(1, limits.maxMissedPings) {
                drop(connection, code: WebSocketClose.abnormal, reason: "no answer to a ping")
                continue
            }
            socket.heard = false
            connection.out.control(ping: WebSocketFrame.encode(.ping, Data()))
            flush(connection)
        }
    }
}
