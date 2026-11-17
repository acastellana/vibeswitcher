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
/// **Which listener.** Lane A's `WebListener` (A2) is built in parallel and isn't on this branch, and the plan has F2
/// test it once it is merged. Until then these cases drive `StandInListener` below, a minimal listener written to the
/// contract's §1, through `WebSecurityRig.listener` alone; the gate (`WebAccess`), the screen in front of the handler
/// (`WebRequestScreen`) and the rights are the real ones. At the join, `WebSecurityRig.listener` returns lane A's
/// listener and the stand-in is deleted: every case then holds the real one. The cases need nothing of the listener
/// but its port, its stop, `closeAll` (what I1 wires to `WebAccess.onRevoke`) and the clock its deadlines are on.
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

    /// A socket that never authenticates is closed when the 5 s are up, on the listener's clock (injected, advanced by
    /// the test): `bye` and 4401, and nothing before them. One that authenticated in time is left open past them.
    @Test func aSocketThatNeverAuthenticatesIsClosed() async throws {
        let rig = try WebSecurityRig(scratch)
        defer { rig.stop() }
        let idle = try rig.upgraded()
        let issued = try rig.access.tokens.issue(now: rig.now)
        let authed = try rig.upgraded()
        try authed.sendText(#"{"v":1,"id":"0","kind":"auth","args":{"token":"\#(issued.token)","client":"test"}}"#)
        #expect(try authed.nextFrame()?.json?["kind"]?.string == "hello")
        rig.clock.advance(4.9)
        rig.clock.advance(0.2)
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
        for name in ["answer", "hold", "stop", "lead", "start", "web.open", "web.revoke", "hooks.install", "build.switch",
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
    let clock: ManualClock
    let listener: WebListenerUnderTest
    private let notes: Locked<[String]>
    let now: Date

    init(_ scratch: Scratch) throws {
        let notes = Locked<[String]>([]), handler = RecordingHandler(), clock = ManualClock()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let note: @Sendable (String) -> Void = { line in notes.mutate { $0.append(line) } }
        let access = WebAccess(tokens: WebTokens(root: scratch.url("web-root")), now: { now }, note: note)
        (self.notes, self.handler, self.clock, self.now, self.access) = (notes, handler, clock, now, access)
        listener = try Self.listener(gate: access, handler: WebRequestScreen(handler, note: note), clock: clock, note: note)
    }

    /// A listener on 127.0.0.1 and a port the kernel picks: lane A's `WebListener` once the lanes join (the live
    /// plan's A2 merged into this branch for F2), `StandInListener` until then. The one line that changes at the join.
    static func listener(gate: WebGate, handler: WebSocketHandler, clock: ManualClock,
                         note: @escaping @Sendable (String) -> Void) throws -> WebListenerUnderTest {
        try StandInListener(gate: gate, handler: handler, clock: clock, note: note)
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

// MARK: - The stand-in listener

/// A minimal listener to the live wire contract's §1, standing in for lane A's until the lanes join (see the suite's
/// note): 127.0.0.1 only; `GET` only; `Host` exactly `127.0.0.1:<port>`, once (else 421, no body); `/ws` upgraded
/// only with `Origin` exactly `http://127.0.0.1:<port>`, once, and a `Sec-Fetch-Site` that is absent or `same-origin`
/// (else 403); every other path 404 (it serves no file); then nothing sent until a first text frame that is an `auth`
/// the gate admits, inside 5 s of its clock; `bye` and the close otherwise. Unfragmented masked frames only.
final class StandInListener: WebListenerUnderTest, @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let gate: WebGate
    private let handler: WebSocketHandler
    private let clock: ManualClock
    private let note: @Sendable (String) -> Void
    private let lock = NSLock()
    private var connections: [StandInConnection] = []
    private var stopped = false

    init(gate: WebGate, handler: WebSocketHandler, clock: ManualClock, note: @escaping @Sendable (String) -> Void) throws {
        (self.gate, self.handler, self.clock, self.note) = (gate, handler, clock, note)
        let fd = socket(AF_INET, Platform.Sockets.stream, 0)
        guard fd >= 0 else { throw RawClient.Failure("socket: \(errno)") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            throw RawClient.Failure("bind or listen: \(errno)")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in acceptLoop() }.start()
    }

    private func acceptLoop() {
        while !lock.withLock({ stopped }) {
            var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 50) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            let connection = StandInConnection(fd: client, port: port, gate: gate, handler: handler, clock: clock, note: note)
            lock.withLock { connections.append(connection) }
            Thread { connection.run() }.start()
        }
        close(fd)
    }

    func closeAll(code: String, reason: String) {
        for connection in lock.withLock({ connections }) where connection.admitted { connection.close(code: code, reason: reason) }
    }

    func stop() {
        let all = lock.withLock { () -> [StandInConnection] in
            stopped = true
            return connections
        }
        for connection in all { connection.end() }
    }
}

final class StandInConnection: LiveTransport, @unchecked Sendable {
    private let fd: Int32
    private let port: UInt16
    private let gate: WebGate
    private let handler: WebSocketHandler
    private let clock: ManualClock
    private let note: @Sendable (String) -> Void
    private let lock = NSLock()
    private var _admitted = false
    private var ended = false
    var onWritable: (() -> Void)?
    var writable: Bool { true }

    init(fd: Int32, port: UInt16, gate: WebGate, handler: WebSocketHandler, clock: ManualClock, note: @escaping @Sendable (String) -> Void) {
        (self.fd, self.port, self.gate, self.handler, self.clock, self.note) = (fd, port, gate, handler, clock, note)
    }

    var admitted: Bool { lock.withLock { _admitted } }

    static func closeNumber(_ code: String) -> UInt16 {
        switch code {
        case "auth": return 4401
        case "revoked": return 4403
        case "stopping": return 1001
        case "too-long": return 1009
        case "version": return 4426
        default: return 4400
        }
    }

    func run() {
        var buffer = Data()
        guard let head = readHead(&buffer) else { return end() }
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        let headers: [(String, String)] = lines.dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        func all(_ name: String) -> [String] { headers.filter { $0.0 == name }.map(\.1) }
        guard request.count == 3, request[0] == "GET" else { return respond("405 Method Not Allowed") }
        let hosts = all("host")
        guard hosts.count == 1, hosts[0] == "127.0.0.1:\(port)" else { return respond("421 Misdirected Request") }
        guard request[1] == "/ws" else { return respond("404 Not Found") }
        let origins = all("origin")
        guard origins.count == 1, origins[0] == "http://127.0.0.1:\(port)" else { return respond("403 Forbidden") }
        guard all("sec-fetch-site").allSatisfy({ $0 == "same-origin" }) else { return respond("403 Forbidden") }
        let keys = all("sec-websocket-key")
        guard keys.count == 1, all("upgrade").contains(where: { $0.lowercased() == "websocket" }) else { return respond("400 Bad Request") }
        let accept = Data(Insecure.SHA1.hash(data: Data((keys[0] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        // Armed before the 101 is written, so a client that has read it finds the deadline on the clock.
        clock.schedule(5) { [weak self] in
            guard let self, !self.admitted else { return }
            self.close(code: "auth", reason: WebAccess.refusedReason)
        }
        write(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
        while let frame = readFrame(&buffer) {
            switch frame.opcode {
            case 0x1:
                if admitted {
                    handler.text(frame.payload, on: self)
                } else {
                    guard let auth = NodeWire.decode(NodeWire.Request.self, frame.payload), auth.kind == "auth",
                          let admission = gate.admit(auth.args ?? [:]) else { return close(code: "auth", reason: WebAccess.refusedReason) }
                    lock.withLock { _admitted = true }
                    let hello = NodeWire.Hello(node: NodeIds.node, epoch: "stand-in", server: .init(commit: "stand-in", startedAt: "", pid: 0),
                                               host: .init(startedAt: nil, notes: nil), kinds: WebAccess.kinds(for: admission.rights),
                                               peer: .init(voice: "other", why: WebAccess.peerWhy), rule: "stand-in", auth: admission.auth)
                    send(Data(NodeWire.line(hello).dropLast()))
                    handler.opened(self, rights: admission.rights)
                }
            case 0x8: return end()
            case 0x9: write(Self.frame(0xA, frame.payload))
            default: break
            }
        }
        end()
    }

    func send(_ message: Data) { write(Self.frame(0x1, message)) }

    func close(code: String, reason: String) {
        send(Data(NodeWire.line(NodeWire.Bye(reason: reason, code: code)).dropLast()))
        let number = Self.closeNumber(code)
        write(Self.frame(0x8, Data([UInt8(number >> 8), UInt8(number & 0xff)])))
        end()
    }

    func end() {
        let first = lock.withLock { () -> Bool in
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        if admitted { handler.closed(self) }
    }

    private func respond(_ status: String) {
        write(Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        end()
    }

    private func write(_ data: Data) {
        guard !lock.withLock({ ended }) else { return }
        _ = data.withUnsafeBytes { RawClient.writeAll(fd, $0) }
    }

    private func readHead(_ buffer: inout Data) -> String? {
        let end = Data("\r\n\r\n".utf8)
        while buffer.range(of: end) == nil {
            guard buffer.count <= 8192, RawClient.readSome(fd, into: &buffer) else { return nil }
        }
        let range = buffer.range(of: end)!
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return head
    }

    /// One whole masked frame; nil at the end, or on a frame this stand-in doesn't take (unmasked, fragmented, over
    /// 64 KiB).
    private func readFrame(_ buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        while true {
            if let parsed = RawClient.parseFrame(&buffer, masked: true) {
                guard let frame = parsed, frame.fin else { return nil }
                return (frame.opcode, frame.payload)
            }
            guard buffer.count <= 70_000, RawClient.readSome(fd, into: &buffer) else { return nil }
        }
    }

    static func frame(_ opcode: UInt8, _ payload: Data) -> Data {
        var data = Data([0x80 | opcode])
        if payload.count < 126 {
            data.append(UInt8(payload.count))
        } else if payload.count <= 0xffff {
            data.append(126)
            data.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        } else {
            data.append(127)
            data.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xff) })
        }
        data.append(payload)
        return data
    }
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
