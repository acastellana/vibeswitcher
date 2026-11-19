import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The web listener's security (the live plan's F2 and its Security table; the live wire contract's §1 and §2), driven
/// from outside with a raw TCP client, so headers a browser would never send can be sent: the listener answers on
/// `127.0.0.1` alone; `Host` and `Origin` are matched exactly (DNS rebinding, cross-site WebSocket hijacking); nothing
/// is sent before a valid `auth`, and a socket that never sends one is closed; a web connection changes nothing; no
/// code or token reaches the log.
///
/// **Which listener.** The node's own, `NodeWebListener` (lane A's, joined at I1), behind the real gate (`WebAccess`),
/// the screen in front of the handler (`WebRequestScreen`) and the rights. The cases need nothing of it but its port,
/// its stop, `closeAll` (what I1 wires to `WebAccess.onRevoke`) and the clock its deadlines are on.
@Suite(.timeLimit(.minutes(5)))
struct WebSecurityTests {
    private let scratch = Scratch()

    // MARK: Host: DNS rebinding

    /// A page on another name resolving to 127.0.0.1 sends its own name as `Host`: 421 with no body, for a file and for
    /// the upgrade alike. Only `127.0.0.1:<port>`, once, is taken.
    @Test func aRequestUnderAnotherHostNameIsRefused() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        let port = rig.port
        let wrong: [[String]] = [
            ["Host: evil.example:\(port)"], ["Host: localhost:\(port)"], ["Host: 127.0.0.1"], ["Host: 127.0.0.1:\(port + 1)"],
            ["Host: 127.0.0.1:\(port)."], ["Host: 127.0.0.1:\(port).evil.example"], ["Host: 127.0.0.2:\(port)"],
            ["Host: [::1]:\(port)"], ["Host: 0x7f.0.0.1:\(port)"], ["Host: 127.0.0.1:0\(port)"], ["Host: "],
            [], ["Host: 127.0.0.1:\(port)", "Host: 127.0.0.1:\(port)"], ["Host: 127.0.0.1:\(port)", "Host: evil.example:\(port)"],
            ["Host: evil.example:\(port)", "Host: 127.0.0.1:\(port)"],
        ]
        for headers in wrong {
            for target in ["/", "/ws"] {
                let upgrade = target == "/ws" ? RawClient.upgradeHeaders(origin: rig.origin) : []
                let answer = try RawClient.ask(port: port, "GET \(target) HTTP/1.1", headers + upgrade)
                #expect(answer.status == 421, "\(headers) \(target): \(answer.head)")
                #expect(answer.body.isEmpty, "\(headers) \(target): a body \(answer.body.count) bytes")
            }
        }
        // The exact one is taken.
        let right = try RawClient.ask(port: port, "GET /ws HTTP/1.1", ["Host: \(rig.host)"] + RawClient.upgradeHeaders(origin: rig.origin))
        #expect(right.status == 101, "\(right.head)")
    }

    // MARK: Origin: cross-site WebSocket hijacking

    /// Another origin's page opening `/ws` sends its own `Origin`: 403, never 101. Compared whole: never a prefix, a
    /// suffix, another scheme or name, nor two of them.
    @Test func anUpgradeFromAnotherOriginIsRefused() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        let port = rig.port
        let wrong: [[String]] = [
            ["Origin: http://evil.example"], ["Origin: http://127.0.0.1:\(port).evil.example"], ["Origin: http://127.0.0.1:\(port)/"],
            ["Origin: https://127.0.0.1:\(port)"], ["Origin: http://localhost:\(port)"], ["Origin: null"], ["Origin: HTTP://127.0.0.1:\(port)"],
            ["Origin: http://127.0.0.1"], ["Origin: http://evil.example/http://127.0.0.1:\(port)"], ["Origin: "],
            ["Origin: \(rig.origin)", "Origin: http://evil.example"], ["Origin: http://evil.example", "Origin: \(rig.origin)"],
            // The right origin, from a fetch the browser says isn't the page's own.
            ["Origin: \(rig.origin)", "Sec-Fetch-Site: cross-site"], ["Origin: \(rig.origin)", "Sec-Fetch-Site: same-site"],
            ["Origin: \(rig.origin)", "Sec-Fetch-Site: none"],
        ]
        for origin in wrong {
            let answer = try RawClient.ask(port: port, "GET /ws HTTP/1.1", ["Host: \(rig.host)"] + RawClient.upgradeHeaders(origin: nil) + origin)
            #expect(answer.status == 403, "\(origin): \(answer.head)")
        }
        let right = try RawClient.ask(port: port, "GET /ws HTTP/1.1",
                                      ["Host: \(rig.host)", "Sec-Fetch-Site: same-origin"] + RawClient.upgradeHeaders(origin: rig.origin))
        #expect(right.status == 101, "\(right.head)")
    }

    @Test func anUpgradeWithNoOriginIsRefused() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        let answer = try RawClient.ask(port: rig.port, "GET /ws HTTP/1.1", ["Host: \(rig.host)"] + RawClient.upgradeHeaders(origin: nil))
        #expect(answer.status == 403, "\(answer.head)")
    }

    /// Another local server's page (same address, another port) is another origin.
    @Test func anUpgradeFromAnotherPortIsRefused() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        for other in [rig.port &+ 1, rig.port &- 1, 47823, 80] where other != rig.port {
            let answer = try RawClient.ask(port: rig.port, "GET /ws HTTP/1.1",
                                           ["Host: \(rig.host)"] + RawClient.upgradeHeaders(origin: "http://127.0.0.1:\(other)"))
            #expect(answer.status == 403, "\(other): \(answer.head)")
        }
    }

    // MARK: Loopback

    /// Bound to `127.0.0.1` and nothing else: the port is free on every other address of this machine (each of its
    /// other IPv4 addresses, and 127.0.0.2 where the loopback has it), so a socket of the test binds it there; a
    /// listener on `0.0.0.0` would hold it everywhere (EADDRINUSE). A bind answers at once, where a connect to an
    /// address that drops packets would only time out.
    @Test func theListenerHoldsTheLoopbackAddressOnly() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        #expect(try RawClient.connects(address: "127.0.0.1", port: rig.port))
        #expect(RawClient.bindError(address: "127.0.0.1", port: rig.port) == EADDRINUSE, "the probe finds the listener where it is")
        var probed = 0
        for address in Set(RawClient.ownIPv4Addresses() + ["127.0.0.2"]) where address != "127.0.0.1" {
            let error = RawClient.bindError(address: address, port: rig.port)
            if error == EADDRNOTAVAIL { continue }
            probed += 1
            #expect(error == 0, "\(address):\(rig.port) is held (errno \(error))")
        }
        #expect(probed > 0, "no other address to probe")
    }

    // MARK: Nothing before auth

    /// The client's first frame must be `auth`: anything else first gets `bye` (`auth`) and 4401, and nothing else:
    /// no reply, no `hello`, no event.
    @Test func nothingIsSentBeforeAuth() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        _ = rig.access.openCode(now: rig.now)
        let issued = try rig.access.tokens.issue(now: rig.now)
        for first in [#"{"v":1,"id":"1","kind":"status"}"#, #"{"v":1,"id":"1","kind":"subscribe","args":{"collection":"sessions"}}"#,
                      #"{"v":1,"id":"1","kind":"auth","args":{"token":"\#(issued.token)x"}}"#, #"{"v":1,"id":"1","kind":"auth"}"#,
                      #"[1,2]"#, "not json"] {
            let client = try rig.upgraded()
            try client.sendText(first)
            let frames = try client.framesUntilClosed()
            #expect(frames.count == 2, "\(first): \(frames)")
            #expect(frames.first?.json?["kind"]?.string == "bye" && frames.first?.json?["code"]?.string == "auth", "\(first): \(frames)")
            #expect(frames.last?.closeCode == 4401, "\(first): \(frames)")
            #expect(rig.handler.opened == 0 && rig.handler.texts.isEmpty, "\(first): the handler heard of it")
        }
    }

    /// A socket that never authenticates is closed once the 5 s are up, on the listener's clock (injected, advanced by
    /// the test; it counts the node clock's whole seconds, so the close comes in the second after them): `bye` and
    /// 4401, and nothing before them. One that authenticated in time is left open past them.
    @Test func aSocketThatNeverAuthenticatesIsClosed() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        let idle = try rig.upgraded()
        let issued = try rig.access.tokens.issue(now: rig.now)
        let authed = try rig.upgraded()
        try authed.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"token":"\#(issued.token)","client":"test"}}"#)
        #expect(try authed.nextFrame()?.json?["kind"]?.string == "hello")
        rig.clock.advance(4)
        rig.clock.advance(2)
        let frames = try idle.framesUntilClosed()
        #expect(frames.count == 2, "\(frames)")
        #expect(frames.first?.json?["code"]?.string == "auth", "\(frames)")
        #expect(frames.last?.closeCode == 4401, "\(frames)")
        // The authenticated one still talks.
        try authed.sendText(#"{"v":1,"id":"1","kind":"status"}"#)
        #expect(try authed.nextFrame()?.json?["re"]?.string == "1")
    }

    // MARK: What a token may do

    /// Every kind the protocol names but the read and draft ones is refused on a WebSocket (`voice`), before the
    /// handler hears of it: `answer`, `hold`, `stop`, `lead`, `web.open` and every other the user's, the lead's tool
    /// server's, the terminal's. A read kind reaches the handler (the control).
    @Test func aWebConnectionChangesNothing() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        let code = rig.access.openCode(now: rig.now)
        let client = try rig.upgraded()
        try client.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"pair":"\#(code)","client":"test"}}"#)
        let hello = try #require(try client.nextFrame()?.json)
        #expect(hello["auth"]?["rights"] == .array([.string("read"), .string("draft")]), "\(hello)")
        #expect(hello["peer"]?["voice"]?.string == "other", "\(hello)")
        let closed = NodeWire.kinds.filter { $0.value != .anyone && $0.value != .webDraft }.map(\.key).sorted()
        for name in ["answer", "hold", "tell", "stop", "lead", "start", "web.open", "web.revoke", "hooks.install", "build.switch",
                     "config.accept", "question.post", "term.open"] {
            #expect(closed.contains(name), "\(name)")
        }
        for (index, kind) in closed.enumerated() {
            try client.sendText(String(decoding: NodeWire.line(NodeWire.Request(
                id: "k\(index)", kind: kind, args: ["card": .string("local:card:x"), "code": .string("ABCD"), "text": .string("Yes"), "folder": .string("/nonexistent/project")],
                action: UUID().uuidString.lowercased())).dropLast(), as: UTF8.self))
            let reply = try #require(try client.nextFrame()?.json, "\(kind): no reply")
            #expect(reply["re"]?.string == "k\(index)" && reply["ok"]?.bool == false, "\(kind): \(reply)")
            #expect(reply["error"]?["code"]?.string == NodeWire.Code.voice.rawValue, "\(kind): \(reply)")
        }
        // A second `auth`, and a kind nobody names, are no way past it either.
        try client.sendText(#"{"v":1,"id":"again","kind":"auth","args":{"pair":"\#(code)"}}"#)
        #expect(try client.nextFrame()?.json?["error"]?["code"]?.string == NodeWire.Code.unknownKind.rawValue)
        #expect(rig.handler.kinds.isEmpty, "the handler heard \(rig.handler.kinds)")
        // The control: a read kind goes through.
        try client.sendText(#"{"v":1,"id":"read","kind":"status"}"#)
        #expect(try client.nextFrame()?.json?["re"]?.string == "read")
        #expect(rig.handler.kinds == ["status"])
    }

    // MARK: Logs

    /// No pairing code, address or token in any line of the log, through a whole session: the code made and printed,
    /// taken, a reconnect with the token, a wrong code, a used one, a revoke.
    @Test func noSecretReachesTheLog() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        rig.access.listen = { [port = rig.port] in .success(port) }
        let opened = try rig.access.open().get()
        let code = try #require(opened.url.components(separatedBy: "#pair=").last)
        let first = try rig.upgraded()
        try first.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"pair":"\#(code)","client":"test"}}"#)
        let token = try #require(try first.nextFrame()?.json?["auth"]?["token"]?.string)
        try first.sendText(#"{"v":1,"id":"1","kind":"answer","args":{"card":"c","code":"ABCD","text":"\#(token)"}}"#)
        _ = try first.nextFrame()
        let again = try rig.upgraded()
        try again.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"token":"\#(token)"}}"#)
        #expect(try again.nextFrame()?.json?["kind"]?.string == "hello")
        for refused in [code, String(code.reversed())] {
            let late = try rig.upgraded()
            try late.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"pair":"\#(refused)"}}"#)
            _ = try late.framesUntilClosed()
        }
        rig.access.onRevoke = { [listener = rig.listener] in listener.closeAll(code: "revoked", reason: "every web token was dropped") }
        _ = try rig.access.revoke().get()
        _ = try first.framesUntilClosed()
        let log = rig.log
        #expect(!log.isEmpty)
        for secret in [code, token, opened.url, WebTokens.hex(WebTokens.digest(token))] {
            #expect(!log.contains { $0.contains(secret) }, "a secret in the log: \(log)")
        }
    }
}

// MARK: - The rig

/// The listener under test with the real gate and screen: `WebAccess` on a scratch root and an injected clock, a
/// recording handler behind `WebRequestScreen`, and every note kept.
final class WebSecurityRig: @unchecked Sendable {
    let access: WebAccess
    let handler: RecordingHandler
    let clock: WebTestTime
    let listener: WebListenerUnderTest
    private let notes: Locked<[String]>
    let now: Date

    init(_ scratch: Scratch) throws {
        let notes = Locked<[String]>([]), handler = RecordingHandler(), clock = WebTestTime()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let note: @Sendable (String) -> Void = { line in notes.mutate { $0.append(line) } }
        let access = WebAccess(tokens: WebTokens(root: scratch.url("web-root")), now: { now }, note: note)
        (self.notes, self.handler, self.clock, self.now, self.access) = (notes, handler, clock, now, access)
        listener = try Self.listener(gate: access, handler: WebRequestScreen(handler, note: note), clock: clock, note: note)
    }

    /// The node's listener on 127.0.0.1 and a port the kernel picks, serving no file, its `hello` the web's shape (the
    /// rights, the voice), on `clock` (the test moves it a second at a time, as the node's clock beats).
    static func listener(gate: WebGate, handler: WebSocketHandler, clock: WebTestTime,
                         note: @escaping @Sendable (String) -> Void) throws -> WebListenerUnderTest {
        let queue = DispatchQueue(label: "web-security-tests")
        let web = NodeWebListener(port: 0, assets: NoAssets(), gate: gate, handler: handler, queue: queue, clock: clock.clock(),
                                  hello: { admission in
                                      NodeWire.line(NodeWire.Value.object([
                                          "v": .int(NodeWire.version), "kind": .string("hello"), "auth": admission.auth,
                                          "peer": .object(["voice": .string("other"), "why": .string(WebAccess.peerWhy)]),
                                      ])).dropLast()
                                  }, note: note)
        return NodeListenerUnderTest(web, port: try web.start())
    }

    var port: UInt16 { listener.port }
    var host: String { "127.0.0.1:\(port)" }
    var origin: String { "http://127.0.0.1:\(port)" }
    var log: [String] { notes.value }

    /// A client whose upgrade to `/ws` was taken (101), from the page's own origin.
    func upgraded() throws -> RawClient {
        let client = try RawClient(port: port)
        let status = try client.upgrade(host: host, origin: origin)
        guard status == 101 else { throw RawClient.Failure("the upgrade was answered \(status)") }
        return client
    }

    func stop() { listener.stop() }
}

/// What F2's cases need of a listener.
protocol WebListenerUnderTest: AnyObject, Sendable {
    var port: UInt16 { get }
    /// Every connection closed with `code` (`bye`, then the close): what I1 wires to `WebAccess.onRevoke`.
    func closeAll(code: String, reason: String)
    func stop()
}

/// `NodeWebListener` as the cases see it.
final class NodeListenerUnderTest: WebListenerUnderTest, @unchecked Sendable {
    let web: NodeWebListener
    let port: UInt16

    init(_ web: NodeWebListener, port: UInt16) {
        self.web = web
        self.port = port
    }

    func closeAll(code: String, reason: String) { web.closeAll(code: code, reason: reason) }

    func stop() {
        let done = DispatchSemaphore(value: 0)
        web.stop { done.signal() }
        _ = done.wait(timeout: .now() + 10)
    }
}

/// No file at all: these cases are about the socket.
struct NoAssets: WebAssetSource {
    func asset(path: String) -> WebAsset? { nil }
}

/// A handler that answers every request it is handed `ok`, and records what reached it.
final class RecordingHandler: WebSocketHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened = 0
    private var _texts: [Data] = []

    var opened: Int { lock.withLock { _opened } }
    var texts: [Data] { lock.withLock { _texts } }
    var kinds: [String] { texts.compactMap { NodeWire.decode(NodeWire.Request.self, $0)?.kind } }

    func opened(_ transport: LiveTransport, rights: LiveRights) { lock.withLock { _opened += 1 } }
    func text(_ message: Data, on transport: LiveTransport) {
        lock.withLock { _texts.append(message) }
        if let request = NodeWire.decode(NodeWire.Request.self, message) {
            transport.send(Data(NodeWire.line(NodeWire.Reply(re: request.id, result: .object([:]))).dropLast()))
        }
    }
    func binary(_ message: Data, on transport: LiveTransport) {}
    func closed(_ transport: LiveTransport) {}
}

// MARK: - The raw client

/// A TCP client that writes what it is told, byte for byte, and reads frames: what a browser would never send.
final class RawClient {
    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    struct Frame: CustomStringConvertible {
        var fin: Bool
        var opcode: UInt8
        var payload: Data
        var json: NodeWire.Value? { opcode == 0x1 ? NodeWire.decode(NodeWire.Value.self, payload) : nil }
        var closeCode: UInt16? { opcode == 0x8 && payload.count >= 2 ? UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]) : nil }
        var description: String { opcode == 0x1 ? String(decoding: payload, as: UTF8.self) : "opcode \(opcode) \(closeCode.map(String.init) ?? "")" }
    }

    /// How long any one read waits for its event before the case fails (a hang guard, never a pace).
    static let wait: TimeInterval = 30

    let fd: Int32
    private var buffer = Data()

    init(port: UInt16, address: String = "127.0.0.1") throws {
        guard let fd = Self.dial(address: address, port: port) else { throw Failure("connect to \(address):\(port): \(errno)") }
        self.fd = fd
    }

    deinit { close(fd) }

    /// A connected socket to `address:port`; nil when nothing answers there.
    static func dial(address: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, Platform.Sockets.stream, 0)
        guard fd >= 0 else { return nil }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr.s_addr = inet_addr(address)
        let done = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard done == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func connects(address: String, port: UInt16) throws -> Bool {
        guard let fd = dial(address: address, port: port) else { return false }
        close(fd)
        return true
    }

    /// What binding a fresh socket (no `SO_REUSEADDR`) to `address:port` gives: 0, or its errno. Closed after.
    static func bindError(address: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, Platform.Sockets.stream, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr.s_addr = inet_addr(address)
        let done = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return done == 0 ? 0 : errno
    }

    /// This machine's IPv4 addresses, each as dotted text.
    static func ownIPv4Addresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var found: [String] = []
        var next = first
        while let entry = next {
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                var text = [CChar](repeating: 0, count: 64)
                var inet = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if inet_ntop(AF_INET, &inet, &text, socklen_t(text.count)) != nil { found.append(String(cString: text)) }
            }
            next = entry.pointee.ifa_next
        }
        return found
    }

    /// The headers of an upgrade to `/ws`, with `origin` when given.
    static func upgradeHeaders(origin: String?) -> [String] {
        ["Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="]
            + (origin.map { ["Origin: \($0)"] } ?? [])
    }

    /// One request on a new connection: the status, the head, and the body read until the server closed.
    static func ask(port: UInt16, _ line: String, _ headers: [String]) throws -> (status: Int, head: String, body: Data) {
        let client = try RawClient(port: port)
        try client.write(([line] + headers).joined(separator: "\r\n") + "\r\n\r\n")
        let head = try client.readHead()
        var body = Data()
        if head.status != 101 { body = client.readToEnd() }
        return (head.status, head.text, body)
    }

    func upgrade(host: String, origin: String) throws -> Int {
        try write((["GET /ws HTTP/1.1", "Host: \(host)"] + Self.upgradeHeaders(origin: origin)).joined(separator: "\r\n") + "\r\n\r\n")
        return try readHead().status
    }

    func write(_ text: String) throws {
        let done = Data(text.utf8).withUnsafeBytes { Self.writeAll(fd, $0) }
        guard done else { throw Failure("write: \(errno)") }
    }

    /// `text` as one masked text frame.
    func sendText(_ text: String) throws {
        let payload = Array(text.utf8)
        var frame: [UInt8] = [0x81]
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        let done = Data(frame).withUnsafeBytes { Self.writeAll(fd, $0) }
        guard done else { throw Failure("write: \(errno)") }
    }

    func readHead() throws -> (status: Int, text: String) {
        let end = Data("\r\n\r\n".utf8)
        let deadline = Date().addingTimeInterval(Self.wait)
        while buffer.range(of: end) == nil {
            guard Self.readSome(fd, into: &buffer, until: deadline) else {
                throw Failure("no head: \(String(decoding: buffer, as: UTF8.self))")
            }
        }
        let range = buffer.range(of: end)!
        let text = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        let words = text.split(separator: " ", maxSplits: 2)
        guard words.count >= 2, let status = Int(words[1]) else { throw Failure("not a status line: \(text)") }
        return (status, text)
    }

    /// The next frame from the server; nil when it closed first.
    func nextFrame() throws -> Frame? {
        let deadline = Date().addingTimeInterval(Self.wait)
        while true {
            if let parsed = Self.parseFrame(&buffer, masked: false) {
                guard let frame = parsed else { throw Failure("a frame the server shouldn't send") }
                return frame
            }
            guard Self.readSome(fd, into: &buffer, until: deadline) else { return nil }
        }
    }

    /// Every frame until the server closed the connection.
    func framesUntilClosed() throws -> [Frame] {
        var frames: [Frame] = []
        while let frame = try nextFrame() { frames.append(frame) }
        return frames
    }

    func readToEnd() -> Data {
        let deadline = Date().addingTimeInterval(Self.wait)
        while Self.readSome(fd, into: &buffer, until: deadline) {}
        defer { buffer = Data() }
        return buffer
    }

    // MARK: Bytes

    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var done = 0
        while done < bytes.count {
            let wrote = Platform.Sockets.send(fd, bytes.baseAddress! + done, bytes.count - done)
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return false }
            done += wrote
        }
        return true
    }

    /// Reads what is there into `buffer` once something is, or `until` passes; false at the end (or the deadline).
    @discardableResult
    static func readSome(_ fd: Int32, into buffer: inout Data, until deadline: Date = .distantFuture) -> Bool {
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, Int32(min(left, 3600) * 1000))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return false }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            buffer.append(contentsOf: chunk[0..<count])
            return true
        }
    }

    /// The first frame in `buffer`, taken out of it: nil when it isn't whole yet; `.some(nil)` when it isn't masked as
    /// `masked` says or is longer than 64 KiB.
    static func parseFrame(_ buffer: inout Data, masked: Bool) -> Frame?? {
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let isMasked = bytes[1] & 0x80 != 0
        guard isMasked == masked else { return .some(nil) }
        var length = Int(bytes[1] & 0x7f)
        var at = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            at = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            at = 10
        }
        guard length <= 65536 else { return .some(nil) }
        let key = masked ? Array(bytes[at..<min(at + 4, bytes.count)]) : []
        if masked { at += 4 }
        guard bytes.count >= at + length else { return nil }
        var payload = Array(bytes[at..<at + length])
        if masked { for index in payload.indices { payload[index] ^= key[index % 4] } }
        buffer = Data(bytes[(at + length)...])
        return .some(Frame(fin: bytes[0] & 0x80 != 0, opcode: bytes[0] & 0x0f, payload: Data(payload)))
    }
}
