import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// A client of the web listener over a raw socket, so a test decides every byte: a request's lines, a frame's mask,
/// its fragments, its reserved bits, a length that lies. Its reads wait for the bytes they need (a poll, to the hang
/// guard), never for a time.
final class WebTestClient {
    /// A frame as the server sent it.
    struct Frame: Equatable {
        var fin: Bool
        var rsv: UInt8
        var opcode: UInt8
        var masked: Bool
        var payload: [UInt8]

        var text: String { String(decoding: payload, as: UTF8.self) }
        /// A close frame's code; nil for another frame, or a close frame without one.
        var closeCode: UInt16? {
            opcode == WebTestClient.close && payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : nil
        }
        var closeReason: String { String(decoding: payload.dropFirst(2), as: UTF8.self) }
    }

    /// How a frame's length is written.
    enum Length {
        /// As the RFC asks: the shortest form.
        case shortest
        /// In two more bytes, whatever the length.
        case two
        /// In eight more bytes, whatever the length.
        case eight
        /// In eight more bytes, and this number, whatever the payload's length.
        case claiming(UInt64)
    }

    static let continuation: UInt8 = 0x0, text: UInt8 = 0x1, binary: UInt8 = 0x2, close: UInt8 = 0x8, ping: UInt8 = 0x9, pong: UInt8 = 0xA
    /// RFC 6455's own example: this key is answered `sampleAccept`.
    static let sampleKey = "dGhlIHNhbXBsZSBub25jZQ=="
    static let sampleAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    let fd: Int32
    private var buffer: [UInt8] = []
    private var closed = false
    /// A read waited to the hang guard: recorded as an issue where it happened.
    private(set) var hung = false

    init(port: UInt16) throws {
        fd = try Platform.TCP.connect(family: .ipv4, address: "127.0.0.1", port: port).get()
    }

    deinit { close() }

    /// Closes the socket: the server reads the end (or a reset, when it had sent what wasn't read).
    func close() {
        guard !closed else { return }
        closed = true
        Sys.close(fd)
    }

    /// Ends this side's writes: the server reads the end, and can still answer.
    func endWrites() {
        Platform.TCP.endWrites(fd)
    }

    /// Writes all of `bytes`; false when the server has gone.
    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { Platform.Sockets.send(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return false }
            sent += wrote
        }
        return true
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        send(Array(text.utf8))
    }

    /// Reads what has come into the buffer, waiting for some: false at the end (the server closed, or reset), and
    /// when nothing came to the hang guard.
    private func fill() -> Bool {
        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var ready: Int32
        repeat { ready = poll(&waiting, 1, Int32(hangGuard * 1_000)) } while ready < 0 && errno == EINTR
        guard ready > 0 else {
            hung = true
            Issue.record("the client waited \(Int(hangGuard)) s for the server and nothing came")
            return false
        }
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Sys.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            buffer.append(contentsOf: chunk[0..<count])
            return true
        }
    }

    /// Whether nothing has come that wasn't read: a look that doesn't wait.
    func nothingWaits() -> Bool {
        guard buffer.isEmpty else { return false }
        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&waiting, 1, 0) == 0
    }

    /// The response's head, up to its empty line; nil when the connection ended before one.
    func head() -> String? {
        let end = Array("\r\n\r\n".utf8)
        while true {
            if let found = buffer.firstRange(of: end) {
                let head = String(decoding: buffer[..<found.upperBound], as: UTF8.self)
                buffer.removeFirst(found.upperBound)
                return head
            }
            guard fill() else { return nil }
        }
    }

    /// Everything from here to the connection's end.
    func rest() -> [UInt8] {
        while fill() {}
        defer { buffer = [] }
        return buffer
    }

    /// A whole response of a connection the server closes after it: its head and its body.
    func response() -> (head: String, body: String)? {
        guard let head = head() else { return nil }
        return (head, String(decoding: rest(), as: UTF8.self))
    }

    /// Whether the connection has ended with nothing left to read. Waits for the end, or for bytes.
    func ended() -> Bool {
        while buffer.isEmpty {
            guard fill() else { return true }
        }
        return false
    }

    /// The server's next frame; nil when the connection ended first.
    func frame() -> Frame? {
        func need(_ count: Int) -> Bool {
            while buffer.count < count {
                guard fill() else { return false }
            }
            return true
        }
        guard need(2) else { return nil }
        let first = buffer[0], second = buffer[1]
        var length = Int(second & 0x7F)
        var header = 2
        if length == 126 {
            guard need(4) else { return nil }
            length = Int(buffer[2]) << 8 | Int(buffer[3])
            header = 4
        } else if length == 127 {
            guard need(10) else { return nil }
            length = buffer[2..<10].reduce(0) { $0 << 8 | Int($1) }
            header = 10
        }
        let masked = second & 0x80 != 0
        if masked { header += 4 }
        guard need(header + length) else { return nil }
        let payload = Array(buffer[header..<(header + length)])
        buffer.removeFirst(header + length)
        return Frame(fin: first & 0x80 != 0, rsv: (first >> 4) & 0x7, opcode: first & 0x0F, masked: masked, payload: payload)
    }

    /// The next frame that isn't a ping or a pong.
    func message() -> Frame? {
        while let next = frame() {
            if next.opcode != Self.ping, next.opcode != Self.pong { return next }
        }
        return nil
    }

    /// A client's frame as bytes: masked unless `mask` is nil, final unless `fin` is false.
    static func frame(_ opcode: UInt8, _ payload: [UInt8] = [], fin: Bool = true, rsv: UInt8 = 0,
                      mask: [UInt8]? = [0x37, 0xFA, 0x21, 0x3D], length: Length = .shortest) -> [UInt8] {
        var bytes: [UInt8] = [(fin ? 0x80 : 0) | (rsv << 4) | opcode]
        let masked: UInt8 = mask == nil ? 0 : 0x80
        func wide(_ value: UInt64) {
            bytes.append(masked | 127)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
        }
        func two() {
            bytes.append(masked | 126)
            bytes.append(UInt8(payload.count >> 8 & 0xFF))
            bytes.append(UInt8(payload.count & 0xFF))
        }
        switch length {
        case .shortest:
            if payload.count <= 125 {
                bytes.append(masked | UInt8(payload.count))
            } else if payload.count <= 0xFFFF {
                two()
            } else {
                wide(UInt64(payload.count))
            }
        case .two: two()
        case .eight: wide(UInt64(payload.count))
        case .claiming(let claimed): wide(claimed)
        }
        if let mask {
            bytes.append(contentsOf: mask)
            bytes.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
        } else {
            bytes.append(contentsOf: payload)
        }
        return bytes
    }

    static func text(_ text: String, fin: Bool = true) -> [UInt8] {
        frame(Self.text, Array(text.utf8), fin: fin)
    }

    /// A close frame with `code` and `reason`.
    static func closing(_ code: UInt16, _ reason: String = "") -> [UInt8] {
        frame(close, [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(reason.utf8))
    }

    /// Asks for a WebSocket and returns the answer's head. A nil `origin`, `key` or `version` leaves its field out.
    func upgrade(path: String = "/live", host: String, origin: String?, key: String? = WebTestClient.sampleKey,
                 version: String? = "13", connection: String = "keep-alive, Upgrade", extra: [String] = []) -> String? {
        var lines = ["GET \(path) HTTP/1.1", "Host: \(host)", "Upgrade: websocket", "Connection: \(connection)"]
        if let origin { lines.append("Origin: \(origin)") }
        if let key { lines.append("Sec-WebSocket-Key: \(key)") }
        if let version { lines.append("Sec-WebSocket-Version: \(version)") }
        send((lines + extra).joined(separator: "\r\n") + "\r\n\r\n")
        return head()
    }
}

/// A clock's time, moved by the test a second at a time: each wake the clock armed fires as its second comes. Under
/// a lock: the listener subscribes on its own queue while the test moves time.
final class WebTestTime: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 1_000
    private var armed: [Int: (at: TimeInterval, fire: () -> Void)] = [:]
    private var nextID = 0

    func clock() -> NodeClock {
        NodeClock(queue: DispatchQueue(label: "web-test-clock"), now: { [self] in lock.withLock { now } }) { [self] seconds, fire in
            let id = lock.withLock { () -> Int in
                nextID += 1
                armed[nextID] = (now + seconds, fire)
                return nextID
            }
            return { [self] in lock.withLock { armed[id] = nil } }
        }
    }

    /// Moves time on by `seconds`, one at a time, firing what is due at each (and what the clock arms for at once).
    func advance(_ seconds: Int) {
        for _ in 0..<seconds {
            lock.withLock { now += 1 }
            while true {
                let due = lock.withLock { () -> [() -> Void] in
                    let ids = armed.filter { $0.value.at <= now }.keys.sorted()
                    let fires = ids.compactMap { armed[$0]?.fire }
                    for id in ids { armed[id] = nil }
                    return fires
                }
                if due.isEmpty { break }
                for fire in due { fire() }
            }
        }
    }
}

/// What the server's side of a test saw, in order, from any thread: a test waits for the entry it checks.
final class WebEvents: @unchecked Sendable {
    private let condition = NSCondition()
    private var entries: [String] = []

    func add(_ entry: String) {
        condition.lock()
        entries.append(entry)
        condition.broadcast()
        condition.unlock()
    }

    var all: [String] {
        condition.lock()
        defer { condition.unlock() }
        return entries
    }

    /// Waits until `holds` of the entries so far; false at the hang guard.
    func wait(_ holds: ([String]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(hangGuard)
        condition.lock()
        defer { condition.unlock() }
        while !holds(entries) {
            guard condition.wait(until: deadline) else { return holds(entries) }
        }
        return true
    }

    func wait(for entry: String) -> Bool {
        wait { $0.contains(entry) }
    }
}

/// A listener on a port of its own for one test, with a driven clock, an echoing WebSocket handler and a policy that
/// allows this listener's own name and origin. Stopped, and waited for, when the test lets it go.
final class WebWorld: @unchecked Sendable {
    let time = WebTestTime()
    let queue = DispatchQueue(label: "web-listener-tests")
    let events: WebEvents
    let listener: WebListener
    let port: UInt16
    private let opened: Opened
    private let lock = NSLock()
    private var stopped = false

    /// This listener's own name, as a browser on this machine sends it.
    var host: String { "127.0.0.1:\(port)" }
    var origin: String { "http://127.0.0.1:\(port)" }

    /// `policy`: nil for the default, which allows `host` with `origin`; `.some(nil)` for a listener with none.
    init(_ limits: WebLimits = WebLimits(), policy: WebListener.Policy?? = nil, onRequest: ((WebRequest) -> WebResponse)? = nil,
         subprotocols: [String] = []) throws {
        let own = Own()
        let events = WebEvents()
        let opened = Opened()
        let given: WebListener.Policy? = policy ?? .some({ host, origin, _, _ in
            host == "127.0.0.1:\(own.port)" && origin == "http://127.0.0.1:\(own.port)"
        })
        listener = WebListener(queue: queue, clock: time.clock(), limits: limits, policy: given)
        listener.onRequest = onRequest
        listener.subprotocols = subprotocols
        listener.onSocket = { socket in
            opened.add(socket)
            socket.onText = { [weak socket] in
                events.add("text:\($0)")
                socket?.send(text: $0)
            }
            socket.onBinary = { [weak socket] in
                events.add("binary:\($0.count)")
                socket?.send(binary: $0)
            }
            socket.onClose = { events.add("close:\($0):\($1)") }
            socket.onFellBehind = { events.add("behind") }
            socket.onDrained = { events.add("drained") }
            events.add("open:\(socket.request.path)")
        }
        self.events = events
        self.opened = opened
        port = try listener.start()
        own.port = port
    }

    /// The port, for the policy made before the listener is bound: written once, before any connection.
    private final class Own: @unchecked Sendable {
        var port: UInt16 = 0
    }

    /// The WebSockets opened, in order.
    private final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var sockets: [WebSocketConnection] = []
        func add(_ socket: WebSocketConnection) { lock.withLock { sockets.append(socket) } }
        func at(_ index: Int) -> WebSocketConnection? { lock.withLock { index < sockets.count ? sockets[index] : nil } }
    }

    deinit { stop() }

    func connect() throws -> WebTestClient {
        try WebTestClient(port: port)
    }

    /// A client whose WebSocket is open.
    func socketClient(path: String = "/live") throws -> WebTestClient {
        let client = try connect()
        let head = try #require(client.upgrade(path: path, host: host, origin: origin))
        try #require(head.hasPrefix("HTTP/1.1 101 "), "\(head)")
        return client
    }

    /// The server's end of the `index`th WebSocket opened, once it has been.
    func socket(_ index: Int = 0) throws -> WebSocketConnection {
        try #require(until { opened.at(index) != nil })
        return try #require(opened.at(index))
    }

    /// One request, sent whole, and its answer.
    func exchange(_ request: String) throws -> (head: String, body: String) {
        let client = try connect()
        client.send(request)
        return try #require(client.response(), "no answer to \(request.prefix(60))")
    }

    /// Everything the listener's queue was given before this call has run.
    func settle() {
        _ = listener.connectionCount
    }

    /// Runs `body` with the listener's queue held: nothing asked of the queue meanwhile has run when `body` returns,
    /// and all of it runs after, in the order it was asked. For an order of events that otherwise only a busy machine
    /// brings about. `body` asks the listener nothing that waits for its queue (its counts, `settle`).
    func whileQueueIsHeld(_ body: () throws -> Void) throws {
        let held = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        queue.async {
            held.signal()
            released.wait()
        }
        defer { released.signal() }
        try #require(held.wait(timeout: .now() + hangGuard) == .success, "the listener's queue never ran")
        try body()
    }

    /// Looks every few milliseconds until `holds`; false at the hang guard. For what the listener says of itself
    /// (its counts), which no event tells.
    func until(_ holds: () -> Bool) -> Bool {
        let deadline = MacTime.real.awake() + hangGuard
        while !holds() {
            guard MacTime.real.awake() < deadline else { return false }
            usleep(2_000)
        }
        return true
    }

    /// Stops the listener and waits until its last descriptor is closed.
    func stop() {
        guard !lock.withLock({ () -> Bool in
            defer { stopped = true }
            return stopped
        }) else { return }
        let done = DispatchSemaphore(value: 0)
        listener.stop { done.signal() }
        if done.wait(timeout: .now() + hangGuard) == .timedOut { Issue.record("the listener never finished stopping") }
    }

    /// This process's sockets on the listener's port, at either end: the listener's, each connection the server
    /// holds, each client's. Only what is this listener's: its port is nobody else's while it is bound, so the
    /// descriptors of the tests running beside this one never count.
    func descriptors() -> [Int32] {
        Self.descriptors(on: port)
    }

    static func descriptors(on port: UInt16) -> [Int32] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return names.compactMap { Int32($0) }.filter {
            Platform.TCP.localPort($0) == port || Platform.TCP.peerPort($0) == port
        }.sorted()
    }
}
