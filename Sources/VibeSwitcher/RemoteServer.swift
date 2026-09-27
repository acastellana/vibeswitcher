import Foundation
import Network
import VibeCore

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var cacheable = false

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message], status: status)
    }

    func serialized() -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 409: "Conflict", 413: "Payload Too Large", 423: "Locked",
                      429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        // Everything is served from our own origin; nothing may be framed, sniffed or leaked via referrers.
        head += "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            + "connect-src 'self'; worker-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
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
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        receive(on: connection, buffer: Data(), timeout: timeout)
    }

    private func receive(on connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel(); return }
                self.receive(on: connection, buffer: buffer, timeout: timeout)
            case .invalid:
                self.send(.error(400, "bad request"), on: connection, timeout: timeout)
            case .tooLarge:
                self.send(.error(413, "too large"), on: connection, timeout: timeout)
            case .complete(let request):
                self.handler(request) { response in
                    self.queue.async { self.send(response, on: connection, timeout: timeout) }
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
