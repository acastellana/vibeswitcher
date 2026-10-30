import Foundation
import Network
import VibeCore

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var cacheable = false

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        // An invalid value (e.g. an Optional boxed in `Any`) makes JSONSerialization raise, not throw.
        guard JSONSerialization.isValidJSONObject(object) else {
            return HTTPResponse(status: 500, contentType: "application/json; charset=utf-8", body: Data(#"{"error":"internal"}"#.utf8))
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    func serialized() -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 409: "Conflict", 413: "Payload Too Large", 415: "Unsupported Media Type", 421: "Misdirected Request",
                      423: "Locked", 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway",
                      503: "Service Unavailable"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        // Everything is served from our own origin; nothing may be framed, sniffed or leaked via referrers.
        head += "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            + "media-src 'self' blob:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
        head += "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
        head += "Cross-Origin-Opener-Policy: same-origin\r\n"
        head += "Cache-Control: \(cacheable ? "no-cache" : "no-store")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// HTTP server for Phone Access. It listens on 127.0.0.1 only: the one way in from other devices is
/// `tailscale serve`, which terminates HTTPS and tells us which Tailscale account is asking.
final class RemoteServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let queue = DispatchQueue(label: "vibeswitcher.remote-server")
    private var listener: NWListener?
    private var connections = 0
    private let handler: Handler
    private static let maxConnections = 32
    /// How long a client has to send its request, and how long a handler then has to answer it (a backstop: none
    /// waits this long, and the phone gives up after 30 s). Tests shorten them.
    var receiveLimit: TimeInterval = 15
    var answerLimit: TimeInterval = 120
    /// How long a request that's allowed a big body (a dictation's recording) has to finish sending it, from when it
    /// passes the usual limit: a phone on a slow uplink takes longer than `receiveLimit` for a few hundred KB.
    var uploadLimit: TimeInterval = 60

    /// The paired phones now, read off the main thread for `bodyLimit` (Phone Access keeps it current).
    var paired: @Sendable () -> [PairedDevice] = { [] }

    /// How big a request's body may be: a recording for `POST /api/dictation` from a paired phone (its token, from the
    /// account that paired it, checked as its headers come in, before its body is taken), the usual 64 KB otherwise: a
    /// made-up token gets no big upload. At most `maxConnections` such uploads are held at once.
    static func bodyLimit(method: String, path: String, headers: [String: String], devices: [PairedDevice]) -> Int {
        guard method == "POST", path == PhoneAccess.dictationPath,
              RemoteAuth.authenticate(authorization: headers["authorization"], login: headers["tailscale-user-login"],
                                      devices: devices) != nil else { return HTTPParser.defaultMaxBodyBytes }
        return DictationLimits.phoneMaxBytes
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Exactly one of the callbacks is called, on the main thread: `onReady` once the port is really
    /// listening, `onFailure` if it can't be (e.g. the port is still held by a quitting copy of the app).
    func start(port: UInt16, onReady: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        // No address reuse: two listeners on one port would split requests between them.
        parameters.allowLocalEndpointReuse = false
        guard let listener = try? NWListener(using: parameters) else {
            onFailure("Couldn't open local port \(port).")
            return
        }
        var reported = false
        // nil: ready; otherwise the failure message.
        let report: (String?) -> Void = { failure in
            DispatchQueue.main.async {
                guard !reported else { return }
                reported = true
                if let failure { onFailure(failure) } else { onReady() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: report(nil)
            case .failed(let error), .waiting(let error):
                // `.waiting` is how a busy port shows up; don't sit there, let the owner retry.
                listener.cancel()   // `isListening` turns false; `listener` itself is only touched on main
                report("Local port \(port) unavailable (\(error)).")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    var isListening: Bool { listener?.state == .ready }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        // Only tailscaled (on this Mac) should ever connect; refuse anything that isn't loopback.
        guard connections < Self.maxConnections, Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: connection.cancel()                     // ends in .cancelled, counted once there
            case .cancelled: self?.connections -= 1                 // handlers run on `queue`
            default: break
            }
        }
        connection.start(queue: queue)
        // 15 s to send the request. Answering it may take longer (a reply typed behind a jump in progress): cut then,
        // the phone would hear Tailscale's bare 502, as if VibeSwitcher weren't running, while the reply still went in.
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + receiveLimit, execute: timeout)
        receive(on: connection, buffer: Data(), timeout: timeout)
    }

    private func receive(on connection: NWConnection, buffer: Data, timeout: DispatchWorkItem, extended: Bool = false) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let paired = self.paired
            switch HTTPParser.parse(buffer, bodyLimit: { Self.bodyLimit(method: $0, path: $1, headers: $2, devices: paired()) }) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel(); return }
                // Past the usual size and still coming: only a request allowed a big body gets here. It has
                // `uploadLimit` from now, once.
                var timeout = timeout
                let extend = !extended && buffer.count > HTTPParser.defaultMaxBodyBytes + 16 * 1024
                if extend {
                    timeout.cancel()
                    timeout = DispatchWorkItem { connection.cancel() }
                    self.queue.asyncAfter(deadline: .now() + self.uploadLimit, execute: timeout)
                }
                self.receive(on: connection, buffer: buffer, timeout: timeout, extended: extended || extend)
            case .invalid:
                self.send(.error(400, "bad request"), on: connection, timeout: timeout)
            case .tooLarge:
                self.send(.error(413, "too large"), on: connection, timeout: timeout)
            case .complete(let request):
                timeout.cancel()
                let answerTimeout = DispatchWorkItem { connection.cancel() }
                self.queue.asyncAfter(deadline: .now() + self.answerLimit, execute: answerTimeout)
                self.handler(request) { response in
                    self.queue.async { self.send(response, on: connection, timeout: answerTimeout) }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, timeout: DispatchWorkItem) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            timeout.cancel()
            connection.cancel()
        })
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
