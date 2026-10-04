import Foundation
import Network

/// One preview slot's listener on 127.0.0.1 (the way in from the phone is `tailscale serve`).
/// Each request is checked by `PreviewGate`:
/// - `/__vibeswitcher/enter?t=` redeems a ticket into the slot's cookie;
/// - anything else needs that cookie, and is relayed to the dev server with local headers.
/// Responses are streamed back. Websocket upgrades are piped both ways until either side closes.
public final class PreviewProxy: @unchecked Sendable {
    public struct Context: Sendable {
        public var owner: String
        public var ownOrigin: String
        public var siblingOrigins: Set<String>
        public var publicPort: Int

        public init(owner: String, ownOrigin: String, siblingOrigins: Set<String>, publicPort: Int) {
            self.owner = owner
            self.ownOrigin = ownOrigin
            self.siblingOrigins = siblingOrigins
            self.publicPort = publicPort
        }
    }

    private final class Flag { var value = false }

    /// tailscale serve opens one backend connection per in-flight request (we close each after its
    /// response), and a cold Vite load has well over 64 module requests in flight.
    private static let maxConnections = 512
    private let queue: DispatchQueue
    private var listener: NWListener?
    /// Everything below is touched on `queue` only.
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var upstreams: [ObjectIdentifier: NWConnection] = [:]   // keyed by their client
    private let context: () -> Context?
    private let redeem: (String) -> (path: String, sessionToken: String, clearSite: Bool)?
    private let resolve: (String) -> PreviewTarget?

    public init(label: String, context: @escaping () -> Context?,
                redeem: @escaping (String) -> (path: String, sessionToken: String, clearSite: Bool)?,
                resolve: @escaping (String) -> PreviewTarget?) {
        queue = DispatchQueue(label: label)
        self.context = context
        self.redeem = redeem
        self.resolve = resolve
    }

    /// Exactly one callback runs, on `callbackQueue`. Port 0: any free port (see `port`).
    public func start(port: UInt16, callbackQueue: DispatchQueue = .main,
                      onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters) else {
            callbackQueue.async { onFailure("Couldn't open local port \(port).") }
            return
        }
        var reported = false
        let report: (String?) -> Void = { failure in     // on `queue`
            guard !reported else { return }
            reported = true
            callbackQueue.async { if let failure { onFailure(failure) } else { onReady() } }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: report(nil)
            case .failed(let error), .waiting(let error):
                listener.cancel()
                report("Local port \(port) unavailable (\(error)).")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public var port: UInt16? { listener?.port?.rawValue }
    public var isListening: Bool { listener?.state == .ready }

    /// Stops listening and closes every open preview connection (live reload included).
    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.clients.values.forEach { $0.cancel() }
            self.upstreams.values.forEach { $0.cancel() }
        }
    }

    private func accept(_ client: NWConnection) {
        guard Self.isLoopback(client.endpoint) else {
            client.cancel()
            return
        }
        guard clients.count < Self.maxConnections else {
            // A clear answer rather than a reset connection.
            client.start(queue: queue)
            return reply(client, Self.page(503, "Too many requests at once. Try again."))
        }
        let id = ObjectIdentifier(client)
        clients[id] = client
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: client.cancel()
            case .cancelled:
                self?.clients[id] = nil
                self?.upstreams.removeValue(forKey: id)?.cancel()
            default: break
            }
        }
        client.start(queue: queue)
        let timeout = DispatchWorkItem { client.cancel() }
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        readHead(client, buffer: Data(), timeout: timeout)
    }

    private func readHead(_ client: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPHead.parse(buffer, kind: .request) {
            case .incomplete:
                if isComplete || error != nil { client.cancel(); return }
                self.readHead(client, buffer: buffer, timeout: timeout)
            case .invalid:
                timeout.cancel()
                self.reply(client, Self.page(400, "Bad request."))
            case .tooLarge:
                timeout.cancel()
                self.reply(client, Self.page(431, "Request headers too large."))
            case .complete(let head, let consumed):
                timeout.cancel()
                self.handle(head, rest: buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex), client: client)
            }
        }
    }

    private func handle(_ head: HTTPHead, rest: Data, client: NWConnection) {
        guard let context = context() else { return reply(client, Self.page(503, "Dev pages are off.")) }
        switch PreviewGate.decide(head, owner: context.owner, ownOrigin: context.ownOrigin,
                                  siblingOrigins: context.siblingOrigins, publicPort: context.publicPort) {
        case .reject(let status, let message):
            reply(client, Self.page(status, message))
        case .enter(let ticket):
            guard let entry = redeem(ticket) else { return reply(client, Self.page(403, PreviewGate.expiredMessage)) }
            reply(client, Self.enterPage(path: entry.path,
                                         cookie: PreviewGate.setCookie(publicPort: context.publicPort, token: entry.sessionToken),
                                         clearSite: entry.clearSite))
        case .forward(let token):
            guard let target = resolve(token) else { return reply(client, Self.page(403, PreviewGate.expiredMessage)) }
            relay(head, rest: rest, client: client, target: target, context: context)
        }
    }

    private func relay(_ head: HTTPHead, rest: Data, client: NWConnection, target: PreviewTarget, context: Context) {
        let upgrade = PreviewGate.isUpgrade(head)
        var first = PreviewGate.upstreamRequest(head, target: target, ownOrigin: context.ownOrigin,
                                                publicPort: context.publicPort).serialized
        first.append(rest)
        // "localhost" lets the system try ::1 and 127.0.0.1, like the browser on the Mac did.
        let host: NWEndpoint.Host = target.connectHost == "localhost" ? .name("localhost", nil) : NWEndpoint.Host(target.connectHost)
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: target.port)) else {
            return reply(client, Self.page(502, PreviewGate.unreachableMessage(target)))
        }
        let upstream = NWConnection(host: host, port: port, using: .tcp)
        upstreams[ObjectIdentifier(client)] = upstream
        let settled = Flag()
        let fail = { [weak self] in
            guard !settled.value else { client.cancel(); return }
            settled.value = true
            upstream.cancel()
            self?.reply(client, Self.page(502, PreviewGate.unreachableMessage(target)))
        }
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard !settled.value else { return }
                settled.value = true
                upstream.send(content: first, completion: .contentProcessed { error in
                    if error != nil { client.cancel(); return }
                    // Whatever else the client sends: the rest of a request body, or websocket frames.
                    // The client going away ends the exchange either way: a hung dev server must not keep
                    // both connections (and a slot's connection budget) forever.
                    self?.pump(from: client, to: upstream, onEnd: { client.cancel(); upstream.cancel() })
                })
                self?.forwardResponse(upstream, to: client, buffer: Data(), ended: false, target: target)
            case .waiting, .failed:
                fail()
            default: break
            }
        }
        upstream.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { if !settled.value { fail() } }
    }

    private func forwardResponse(_ upstream: NWConnection, to client: NWConnection, buffer: Data, ended: Bool,
                                 target: PreviewTarget) {
        switch HTTPHead.parse(buffer, kind: .response) {
        case .incomplete:
            guard !ended else {
                upstream.cancel()
                return reply(client, Self.page(502, PreviewGate.unreachableMessage(target)))
            }
            upstream.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                var buffer = buffer
                if let data { buffer.append(data) }
                self?.forwardResponse(upstream, to: client, buffer: buffer, ended: isComplete || error != nil, target: target)
            }
        case .invalid, .tooLarge:
            upstream.cancel()
            reply(client, Self.page(502, "The dev server didn't answer with HTTP."))
        case .complete(let head, let consumed):
            let status = head.status ?? 0
            let interim = (100...199).contains(status) && status != 101   // e.g. 100 Continue: the real head follows
            let rest = buffer.subdata(in: (buffer.startIndex + consumed)..<buffer.endIndex)
            var out = PreviewGate.clientResponse(head, target: target).serialized
            if !interim { out.append(rest) }
            client.send(content: out, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { client.cancel(); return }
                if interim { return self.forwardResponse(upstream, to: client, buffer: rest, ended: ended, target: target) }
                if ended { client.cancel(); return }
                self.pump(from: upstream, to: client, onEnd: { client.cancel() })
            })
        }
    }

    /// Copies bytes until `source` ends. The next read waits for the previous write, so a slow phone
    /// slows the dev server down instead of filling memory.
    private func pump(from source: NWConnection, to destination: NWConnection, onEnd: (() -> Void)?) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            let ended = isComplete || error != nil
            guard let data, !data.isEmpty else {
                if ended { onEnd?() } else { self?.pump(from: source, to: destination, onEnd: onEnd) }
                return
            }
            destination.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil { source.cancel(); destination.cancel(); return }
                if ended { onEnd?() } else { self?.pump(from: source, to: destination, onEnd: onEnd) }
            })
        }
    }

    private func reply(_ client: NWConnection, _ data: Data) {
        client.send(content: data, completion: .contentProcessed { _ in client.cancel() })
    }

    /// Sets the slot's cookie, then moves on to the page by itself. Not a redirect: a 302 continues the
    /// phone's navigation, which Android starts outside the browser (cross-site), so the browser would
    /// withhold the SameSite=Strict cookie on the request that follows; a page navigating on its own
    /// makes that request same-site.
    /// `clearSite`: the port now shows another server; drop the old one's cache, storage and service
    /// worker (not its cookies: that would also log out the other slots, which share this host).
    public static func enterPage(path: String, cookie: String, clearSite: Bool = false) -> Data {
        let link = escaped(path)
        let html = "<!doctype html><meta name=\"viewport\" content=\"width=device-width\">"
            + "<meta http-equiv=\"refresh\" content=\"0;url=\(link)\"><title>VibeSwitcher</title>"
            + "<body style=\"font:16px -apple-system,system-ui,sans-serif;padding:24px\"><a href=\"\(link)\">Open the page</a>"
        var headers = [("Content-Type", "text/html; charset=utf-8"), ("Set-Cookie", cookie)]
        if clearSite { headers.append(("Clear-Site-Data", "\"cache\", \"storage\"")) }
        return response(200, headers, body: Data(html.utf8))
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func page(_ status: Int, _ message: String) -> Data {
        let escaped = escaped(message)
        let html = "<!doctype html><meta name=\"viewport\" content=\"width=device-width\"><title>VibeSwitcher</title>"
            + "<body style=\"font:16px -apple-system,system-ui,sans-serif;padding:24px;line-height:1.4\"><p>\(escaped)</p>"
        return response(status, [("Content-Type", "text/html; charset=utf-8")], body: Data(html.utf8))
    }

    static func response(_ status: Int, _ headers: [(String, String)], body: Data = Data()) -> Data {
        let reasons = [200: "OK", 302: "Found", 400: "Bad Request", 403: "Forbidden", 431: "Request Header Fields Too Large",
                       502: "Bad Gateway", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback
        case .name(let name, _): return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default: return false
        }
    }
}
