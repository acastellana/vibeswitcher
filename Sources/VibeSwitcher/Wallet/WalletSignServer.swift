import Foundation
import Network
import VibeCore

/// Serves `WalletSignPage` for one wallet request, on 127.0.0.1 only, on a port the system picks, under a one-time
/// unguessable token (`http://127.0.0.1:<port>/<token>/`), and takes back what the browser's wallet did (`POST
/// /<token>/result`, checked strictly: `WalletBrowser.outcome`). It stops once an answer is taken, or when stopped (the
/// desk stops it after `WalletBrowser.pageLifetime`). Anything unusual (another Host, another Origin, another path, a
/// second answer) is refused.
final class WalletSignServer: @unchecked Sendable {
    /// What a request gets, and the answer it carried when it was taken.
    struct Reply: Equatable {
        var status: Int
        var contentType = "text/plain; charset=utf-8"
        var body = Data()
        var outcome: WalletBrowser.Outcome?
    }

    let token: String
    private let page: Data
    private let queue = DispatchQueue(label: "dev.vibeswitcher.wallet-sign-server")
    private var listener: NWListener?
    private var connections = 0
    /// An answer was taken: nothing more is served.
    private var answered = false
    private var heard: ((WalletBrowser.Outcome) -> Void)?
    private(set) var port: UInt16 = 0

    static let maxConnections = 8
    static let maxBodyBytes = 1024

    init(page: String, token: String = Base64URL.encode(WebPush.randomBytes(32))) {
        self.page = Data(page.utf8)
        self.token = token
    }

    /// The page's address once `start` returned it.
    var url: URL? { port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)/\(token)/") }

    /// Listens on 127.0.0.1 on a free port, waiting (up to `timeout`) until it really does; `heard` is called once, on
    /// the server's queue, with the answer the page posts. Throws when it can't listen.
    func start(timeout: TimeInterval = 10, heard: @escaping (WalletBrowser.Outcome) -> Void) throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        queue.sync {
            self.heard = heard
            self.listener = listener
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error), .waiting(let error):
                failure = "\(error)"
                listener.cancel()
                ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            stop()
            throw WalletAsk.Refusal("the local page didn't start listening in time")
        }
        let (port, failed) = queue.sync { (self.port, failure) }
        guard failed == nil, port != 0, let url else {
            stop()
            throw WalletAsk.Refusal("the local page couldn't listen: \(failed ?? "no port")")
        }
        return url
    }

    /// Stops listening; nothing more is served or taken.
    func stop() {
        queue.async { [self] in
            answered = true
            heard = nil
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: Requests

    /// The reply to `request` (`port`: the one listened on; `answered`: an answer was taken already). Pure, for tests.
    static func reply(to request: HTTPRequest, token: String, port: UInt16, page: Data, answered: Bool) -> Reply {
        let origin = "127.0.0.1:\(port)"
        // A page under another name that resolves here (DNS rebinding) sends its own name.
        guard request.header("host") == origin else { return Reply(status: 421) }
        guard !answered else { return Reply(status: 410) }
        let parts = request.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, RemoteAuth.constantTimeEquals(String(parts[1]), token) else { return Reply(status: 404) }
        switch (request.method, parts[2]) {
        case ("GET", ""):
            return Reply(status: 200, contentType: "text/html; charset=utf-8", body: page)
        case ("POST", "result"):
            guard request.header("origin") == "http://" + origin else { return Reply(status: 403) }
            guard request.header("content-type")?.lowercased().hasPrefix("application/json") == true else { return Reply(status: 415) }
            guard let outcome = WalletBrowser.outcome(request.body) else { return Reply(status: 400) }
            return Reply(status: 204, outcome: outcome)
        default:
            return Reply(status: 404)
        }
    }

    static func serialized(_ reply: Reply) -> Data {
        let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 410: "Gone",
                       413: "Payload Too Large", 415: "Unsupported Media Type", 421: "Misdirected Request"]
        var head = "HTTP/1.1 \(reply.status) \(reasons[reply.status] ?? "Status")\r\n"
        head += "Content-Type: \(reply.contentType)\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\n"
        head += "Content-Security-Policy: \(WalletSignPage.csp)\r\n"
        head += "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
        head += "Cross-Origin-Resource-Policy: same-origin\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + reply.body
    }

    private func accept(_ connection: NWConnection) {
        guard connections < Self.maxConnections, RemoteServer.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed: connection.cancel()
            case .cancelled: self?.connections -= 1
            default: break
            }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        receive(on: connection, buffer: Data(), timeout: timeout)
    }

    private func receive(on connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            let reply: Reply
            switch HTTPParser.parse(buffer, maxHeaderBytes: 8 * 1024, maxBodyBytes: Self.maxBodyBytes) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel(); return }
                return self.receive(on: connection, buffer: buffer, timeout: timeout)
            case .invalid: reply = Reply(status: 400)
            case .tooLarge: reply = Reply(status: 413)
            case .complete(let request):
                reply = Self.reply(to: request, token: self.token, port: self.port, page: self.page, answered: self.answered)
            }
            if let outcome = reply.outcome {
                // Taken once: the listener stops, and nothing more is served.
                self.answered = true
                let heard = self.heard
                self.heard = nil
                self.listener?.cancel()
                self.listener = nil
                heard?(outcome)
            }
            connection.send(content: Self.serialized(reply), completion: .contentProcessed { _ in
                timeout.cancel()
                connection.cancel()
            })
        }
    }
}
