import Foundation
import VibeCore

/// The egress proxy (the session sandbox plan's SB9): a mode of the host's image, `vibeswitcher-host --egress-proxy
/// --control N`, one per node, which the host starts from its sealed copy (`EgressChild`). Each confined session's box
/// binds a listener in its own network namespace (`127.0.0.1:3128` there) and hands it out; the host passes it here
/// with the session's id and its `EgressRules`, and the proxy accepts on it. A socket belongs to the namespace it was
/// made in, whoever holds it (measured), so a box reaches the proxy and nothing else, and each listener is one
/// session's, with its own list.
///
/// What it carries, and for whom:
/// - `CONNECT host:port`: a tunnel, once the rules admit the name and port and every address the name resolved to.
/// - A plain HTTP request in absolute form (`GET http://host/…`): sent on to the host, the request line made
///   origin-form, its Host the URL's, `Connection: close`, and the proxy's own headers left out; then the connection
///   carried to that host only.
/// - Anything else: 400.
///
/// The name a box chose is resolved only once the rules have admitted it (`EgressRules.admits`), and the proxy connects
/// to the addresses the rules judged, never resolving the name again, so a box can neither make the proxy look up a
/// name off its list nor slip a different address in between. Nothing is ever sent to a host the request didn't name.
///
/// Limits (`Limits`): connections per session and in all (past them a request gets 503 and the connection closes), the
/// request's header in bytes and in time, so a slow or silent client holds up only its own connection, the wait for a
/// connection, a tunnel's idle time and its bytes. A refused request gets 403 and one line in the log: the session,
/// the host and port it asked for, the reason. Never a header, nor a byte of a tunnel.
public enum EgressProxy {
    public static let flag = "--egress-proxy"
    public static let controlFlag = "--control"

    public struct Limits: Sendable {
        public var connectionsPerSession = 64
        public var connections = 512
        public var headerBytes = 16 << 10
        public var headerSeconds: TimeInterval = 10
        public var connectSeconds: TimeInterval = 10
        public var idleSeconds: TimeInterval = 15 * 60
        /// Both ways together, per connection.
        public var bytesPerConnection = 4 << 30
        public init() {}
    }

    /// How names are resolved and addresses reached: the system's, or a test's.
    public struct Dialer: Sendable {
        public var resolve: @Sendable (String) -> [EgressRules.Address]?
        public var connect: @Sendable (EgressRules.Address, UInt16, TimeInterval) -> Int32?

        public init(resolve: @escaping @Sendable (String) -> [EgressRules.Address]?,
                    connect: @escaping @Sendable (EgressRules.Address, UInt16, TimeInterval) -> Int32?) {
            self.resolve = resolve
            self.connect = connect
        }

        public static let system = Dialer(resolve: { name in
            (try? Platform.TCP.resolve(name).get())?.map(EgressRules.Address.init)
        }, connect: { address, port, timeout in
            try? Platform.TCP.connect(to: address.bytes, port: port, timeout: timeout).get()
        })
    }

    /// What the host says on the control socket, one message each: a session's listener (the one descriptor the
    /// message carries) with its rules, or a session's end.
    public enum Control: Codable, Equatable, Sendable {
        case add(session: UUID, rules: EgressRules)
        case end(session: UUID)
    }

    /// The most a control message holds.
    public static let maxControl = 256 << 10

    /// `vibeswitcher-host --egress-proxy --control N`: the proxy, which never returns. Anything else: returns at once.
    /// Its first statements are the server's: the image it was started from closed, hardened, a traced proxy's exit 75,
    /// its control socket marked close-on-exec, then SIGPIPE settled. It ends when its control socket closes (the
    /// host has gone).
    public static func runIfAsked(_ arguments: [String]) {
        guard arguments.count >= 2, arguments[1] == flag else { return }
        Platform.ProcessSelf.closeInheritedImage()
        _ = Platform.ProcessSelf.harden()
        if !Platform.CodeIdentity.isAvailable, Platform.ProcessSelf.tracer() != 0 { _exit(75) }
        let control = arguments.firstIndex(of: controlFlag).flatMap { $0 + 1 < arguments.count ? Int32(arguments[$0 + 1]) : nil }
        if let control, control > STDERR_FILENO { _ = fcntl(control, F_SETFD, fcntl(control, F_GETFD) | FD_CLOEXEC) }
        signal(SIGPIPE, SIG_IGN)
        func say(_ line: String) { Platform.Stdio.error("vibeswitcher-egress: \(line)\n") }
        guard !Platform.CodeIdentity.isAvailable else {
            say("not started: this system has no session sandbox")
            exit(69)
        }
        guard let control, control > STDERR_FILENO else {
            say("not started: \(controlFlag) needs a descriptor above 2")
            exit(64)
        }
        let server = Server(dialer: .system, log: say)
        serve(control: control, server: server, say: say)
        exit(0)
    }

    /// Reads `control`'s messages and does what each says, until it closes.
    static func serve(control: Int32, server: Server, say: (String) -> Void) {
        while true {
            guard let got = Platform.Sockets.receive(over: control, count: maxControl, room: 1) else {
                if errno == EINTR { continue }
                return
            }
            if got.bytes.isEmpty, got.descriptors.isEmpty { return }
            guard !got.cut, let message = try? JSONDecoder().decode(Control.self, from: Data(got.bytes)) else {
                got.descriptors.forEach { Sys.close($0) }
                say("a control message that isn't one: dropped")
                continue
            }
            switch message {
            case .add(let session, let rules):
                guard got.descriptors.count == 1 else {
                    got.descriptors.forEach { Sys.close($0) }
                    say("session \(session.uuidString): an add without its listener: dropped")
                    continue
                }
                server.add(listener: got.descriptors[0], session: session, rules: rules)
            case .end(let session):
                got.descriptors.forEach { Sys.close($0) }
                server.end(session: session)
            }
        }
    }

    /// `text` fit for a log line: printable ASCII only, at most 200 characters.
    static func loggable(_ text: Substring) -> String {
        String(String(text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f ? Character($0) : "?" }).prefix(200))
    }
}

extension EgressProxy {
    /// The proxy's work, in this process: the listeners it serves and the connections on them.
    public final class Server: @unchecked Sendable {
        let dialer: Dialer
        let limits: Limits
        let log: @Sendable (String) -> Void
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "egress.accept")
        private var sessions: [UUID: Session] = [:]
        private var total = 0

        final class Session {
            let source: DispatchSourceRead
            let rules: EgressRules
            var open: [Connection] = []
            init(source: DispatchSourceRead, rules: EgressRules) {
                self.source = source
                self.rules = rules
            }
        }

        /// One accepted connection: the client's socket, and the upstream's once made. Shut both ways when its session
        /// ends, which ends the thread that carries it.
        final class Connection: @unchecked Sendable {
            private let lock = NSLock()
            /// The client's socket; -1 once closed here, so a number the system has given out again since is never
            /// shut by `end()`.
            private var clientFd: Int32
            private var upstream: Int32 = -1
            private var ended = false
            init(client: Int32) { clientFd = client }

            var client: Int32 { lock.withLock { clientFd } }

            /// Holds `fd` as the upstream; false (and it is closed) when the connection already ended.
            func hold(_ fd: Int32) -> Bool {
                lock.withLock {
                    guard !ended else { Sys.close(fd); return false }
                    upstream = fd
                    return true
                }
            }

            /// Cuts the connection both ways: only descriptors it still owns.
            func end() {
                lock.withLock {
                    ended = true
                    if clientFd >= 0 { shutdown(clientFd, Int32(SHUT_RDWR)) }
                    if upstream >= 0 { shutdown(upstream, Int32(SHUT_RDWR)) }
                }
            }

            /// Closes both descriptors and forgets their numbers: an `end()` after this touches nothing, whatever
            /// the numbers name by then.
            func close() {
                lock.withLock {
                    ended = true
                    if clientFd >= 0 { Sys.close(clientFd) }
                    if upstream >= 0 { Sys.close(upstream) }
                    clientFd = -1
                    upstream = -1
                }
            }
        }

        public init(dialer: Dialer = .system, limits: Limits = Limits(), log: @escaping @Sendable (String) -> Void) {
            self.dialer = dialer
            self.limits = limits
            self.log = log
        }

        /// Serves `listener` (taken: closed when the session ends) for `session` under `rules`. A session added again
        /// ends its earlier listener first.
        public func add(listener: Int32, session: UUID, rules: EgressRules) {
            end(session: session)
            _ = fcntl(listener, F_SETFD, fcntl(listener, F_GETFD) | FD_CLOEXEC)
            _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(listener, session: session) }
            source.setCancelHandler { Sys.close(listener) }
            lock.withLock { sessions[session] = Session(source: source, rules: rules) }
            source.resume()
        }

        /// Stops serving `session`: its listener closed, its connections cut.
        public func end(session: UUID) {
            guard let ended = lock.withLock({ sessions.removeValue(forKey: session) }) else { return }
            ended.source.cancel()
            lock.withLock { ended.open }.forEach { $0.end() }
        }

        /// The sessions served now.
        public var served: Set<UUID> { lock.withLock { Set(sessions.keys) } }

        private func accept(_ listener: Int32, session: UUID) {
            while true {
                let client = Platform.Sockets.accept(listener)
                guard client >= 0 else { return }
                let admitted: (Connection, EgressRules)? = lock.withLock {
                    guard let held = sessions[session], total < limits.connections,
                          held.open.count < limits.connectionsPerSession else { return nil }
                    let connection = Connection(client: client)
                    held.open.append(connection)
                    total += 1
                    return (connection, held.rules)
                }
                guard let (connection, rules) = admitted else {
                    log("session \(session.uuidString): refused a connection: too many at once")
                    Self.reply(client, 503, "too many connections at once")
                    Sys.close(client)
                    continue
                }
                let thread = Thread { [self] in
                    carry(connection, session: session, rules: rules)
                    // Off the session's list first, so its end can't reach it, then closed.
                    lock.withLock {
                        total -= 1
                        sessions[session]?.open.removeAll { $0 === connection }
                    }
                    connection.close()
                }
                thread.name = "egress.connection"
                thread.start()
            }
        }

        /// A request: what it asks for, and what it brought after its header.
        struct Request: Equatable {
            var host: String
            var port: UInt16
            /// CONNECT's tunnel, or plain HTTP's request (its header to send on, then `rest`).
            var tunnel: Bool
            var header: [UInt8]
            var rest: [UInt8]
        }

        /// The request in `bytes` (its header ends in a blank line, and may be followed by its first bytes); nil, and
        /// why, when it isn't one the proxy carries.
        static func request(_ bytes: [UInt8]) -> Result<Request, DoorProtocol.Refusal> {
            let end = [UInt8]("\r\n\r\n".utf8)
            guard let at = bytes.firstRange(of: end) else { return .failure(.init("no whole header")) }
            let header = Array(bytes[..<at.lowerBound])
            let rest = Array(bytes[at.upperBound...])
            // Lines end in CRLF and hold nothing a host could take for another line's end or for a line carried on: a
            // bare CR or LF (or any other control character but a tab) in a line, and a line that isn't `name: value`
            // with nothing between the name and its colon, would let a request name a second Host past the one written
            // here, to a host that reads its lines more loosely than this does.
            guard let whole = String(bytes: header, encoding: .utf8) else { return .failure(.init("a header that isn't UTF-8")) }
            let lines = whole.components(separatedBy: "\r\n")
            for (index, line) in lines.enumerated() {
                guard !line.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 9) || $0.value == 0x7f }) else {
                    return .failure(.init("a header line holds a control character"))
                }
                guard index > 0 else { continue }
                let name = line.prefix { $0 != ":" }
                guard name.count < line.count, !name.isEmpty, name.unicodeScalars.allSatisfy({ headerName.contains($0) }) else {
                    return .failure(.init("a header line that isn't `name: value`"))
                }
            }
            let words = lines[0].split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 3, words[2] == "HTTP/1.1" || words[2] == "HTTP/1.0" else { return .failure(.init("not an HTTP/1 request")) }
            let method = words[0], target = words[1]
            if method == "CONNECT" {
                guard let (host, port) = authority(target, defaultPort: nil) else { return .failure(.init("CONNECT names no host and port")) }
                return .success(Request(host: host, port: port, tunnel: true, header: [], rest: rest))
            }
            guard method.allSatisfy({ $0.isUppercase }), !method.isEmpty else { return .failure(.init("not an HTTP method")) }
            guard target.lowercased().hasPrefix("http://") else {
                return .failure(.init("only CONNECT, or plain HTTP in absolute form, goes through this proxy"))
            }
            let afterScheme = target.dropFirst("http://".count)
            let slash = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterScheme.endIndex
            guard let (host, port) = authority(afterScheme[..<slash], defaultPort: 80) else { return .failure(.init("the URL names no host")) }
            var path = String(afterScheme[slash...])
            if path.isEmpty { path = "/" } else if path.hasPrefix("?") { path = "/" + path }
            // The proxy's own headers stay here, and so do the request's Host and Connection: the host is the URL's,
            // so a shared address's other sites aren't reached by naming them, and the connection ends with this
            // request's answer, so no request after it goes to that host in its stead. The rest go on as they came.
            let dropped: Set<String> = ["host", "connection", "keep-alive"]
            let kept = lines.dropFirst().filter { line in
                let name = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                return !name.hasPrefix("proxy-") && !dropped.contains(name)
            }
            let named = port == 80 ? host : "\(host):\(port)"
            let sent = (["\(method) \(path) \(words[2])", "Host: \(named)"] + kept + ["Connection: close"]).joined(separator: "\r\n") + "\r\n\r\n"
            return .success(Request(host: host, port: port, tunnel: false, header: Array(sent.utf8), rest: rest))
        }

        /// What a header's name is made of (RFC 9110's token).
        static let headerName = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

        /// `host:port` (or `[v6]:port`, `host` alone where `defaultPort` is given) read; nil for anything else. A host
        /// in brackets comes back with them, so the rules see an address literal.
        static func authority(_ text: Substring, defaultPort: UInt16?) -> (String, UInt16)? {
            guard !text.isEmpty, !text.contains("@") else { return nil }
            if text.hasPrefix("[") {
                guard let close = text.firstIndex(of: "]") else { return nil }
                let host = String(text[...close])
                let after = text[text.index(after: close)...]
                if after.isEmpty { return defaultPort.map { (host, $0) } }
                guard after.hasPrefix(":"), let port = UInt16(after.dropFirst()), port > 0 else { return nil }
                return (host, port)
            }
            guard let colon = text.lastIndex(of: ":") else { return defaultPort.map { (String(text), $0) } }
            guard text.firstIndex(of: ":") == colon else { return (String(text), defaultPort ?? 0) }
            guard let port = UInt16(text[text.index(after: colon)...]), port > 0 else { return nil }
            return (String(text[..<colon]), port)
        }

        /// One connection, from its request to its end.
        private func carry(_ connection: Connection, session: UUID, rules: EgressRules) {
            let client = connection.client
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            // The header, within its bytes and its time.
            var bytes: [UInt8] = []
            let deadline = Date().addingTimeInterval(limits.headerSeconds)
            while bytes.firstRange(of: [13, 10, 13, 10]) == nil {
                guard bytes.count < limits.headerBytes else { return Self.reply(client, 431, "the request's header is too long") }
                let left = deadline.timeIntervalSinceNow
                guard left > 0, Self.wait(client, seconds: left) else { return }
                var buffer = [UInt8](repeating: 0, count: min(4_096, limits.headerBytes - bytes.count + 4))
                let count = Sys.read(client, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                bytes += buffer[0..<count]
            }
            let request: Request
            switch Self.request(bytes) {
            case .failure(let refusal):
                log("session \(session.uuidString): refused a request: \(refusal.description)")
                return Self.reply(client, 400, refusal.description)
            case .success(let read):
                request = read
            }
            let asked = "\(EgressProxy.loggable(Substring(request.host))):\(request.port)"
            if let why = rules.admits(host: request.host, port: request.port) {
                log("session \(session.uuidString): refused \(asked): \(EgressProxy.loggable(Substring(why)))")
                return Self.reply(client, 403, why)
            }
            let resolved = dialer.resolve(request.host) ?? []
            let addresses: [EgressRules.Address]
            switch rules.decision(host: request.host, port: request.port, resolved: resolved) {
            case .refuse(let why):
                log("session \(session.uuidString): refused \(asked): \(EgressProxy.loggable(Substring(why)))")
                return Self.reply(client, 403, why)
            case .allow(let judged):
                addresses = judged
            }
            // In order, each tried once (a lazy compactMap's `first` would connect twice).
            var reached: Int32?
            for address in addresses where reached == nil {
                reached = dialer.connect(address, request.port, limits.connectSeconds)
            }
            guard let upstream = reached else {
                log("session \(session.uuidString): \(asked) couldn't be reached")
                return Self.reply(client, 502, "\(request.host) couldn't be reached")
            }
            guard connection.hold(upstream) else { return }
            if request.tunnel {
                guard Self.writeAll(client, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else { return }
            } else {
                guard Self.writeAll(upstream, request.header) else { return }
            }
            var budget = limits.bytesPerConnection
            if !request.rest.isEmpty {
                guard Self.writeAll(upstream, request.rest) else { return }
                budget -= request.rest.count
            }
            tunnel(client, upstream, budget: budget)
        }

        /// Carries bytes both ways until both have ended, the connection has been idle for `idleSeconds`, or `budget`
        /// bytes have gone. One side's end is passed on as a shut write to the other.
        private func tunnel(_ client: Int32, _ upstream: Int32, budget: Int) {
            var left = budget
            var open = [client: true, upstream: true]
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while open[client]! || open[upstream]! {
                var waiting = [client, upstream].filter { open[$0]! }.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                let ready = poll(&waiting, nfds_t(waiting.count), Int32(limits.idleSeconds * 1_000))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { return }
                for entry in waiting where entry.revents != 0 {
                    let from = entry.fd, to = from == client ? upstream : client
                    let count = Sys.read(from, &buffer, min(buffer.count, max(left, 0)))
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    guard count > 0 else {
                        open[from] = false
                        shutdown(to, Int32(SHUT_WR))
                        if left <= 0 { return }
                        continue
                    }
                    guard Self.writeAll(to, Array(buffer[0..<count])) else { return }
                    left -= count
                    if left <= 0 { return }
                }
            }
        }

        static func wait(_ fd: Int32, seconds: TimeInterval) -> Bool {
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while true {
                let ready = poll(&waiting, 1, Int32(max(1, seconds * 1_000)))
                if ready < 0, errno == EINTR { continue }
                return ready > 0
            }
        }

        static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
            var done = 0
            while done < bytes.count {
                let count = bytes[done...].withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                done += count
            }
            return true
        }

        /// An HTTP answer with `status` and `why` as its body, the connection then closed.
        static func reply(_ fd: Int32, _ status: Int, _ why: String) {
            let reason = [400: "Bad Request", 403: "Forbidden", 431: "Request Header Fields Too Large", 502: "Bad Gateway",
                          503: "Service Unavailable"][status] ?? "Error"
            let body = why + "\n"
            let text = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = writeAll(fd, Array(text.utf8))
        }
    }
}
