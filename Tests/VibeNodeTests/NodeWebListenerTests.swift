import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The files a test serves.
private struct StubAssets: WebAssetSource {
    var files: [String: WebAsset]
    func asset(path: String) -> WebAsset? { files[path] }
}

/// Who may connect: the token "good" reads, the code "code" reads and drafts and is answered a token.
private final class StubGate: WebGate, @unchecked Sendable {
    private let lock = NSLock()
    private var isWanted = true
    private var asked: [[String: NodeWire.Value]] = []

    var wanted: Bool {
        get { lock.withLock { isWanted } }
        set { lock.withLock { isWanted = newValue } }
    }

    var admissions: [[String: NodeWire.Value]] { lock.withLock { asked } }

    func admit(_ args: [String: NodeWire.Value]) -> WebAdmission? {
        lock.withLock { asked.append(args) }
        if args["token"] == .string("good") {
            return WebAdmission(rights: [.read], auth: .object(["rights": .array([.string("read")])]), token: "good")
        }
        if args["pair"] == .string("code") {
            return WebAdmission(rights: [.read, .draft], auth: .object(["token": .string("minted")]), token: "minted")
        }
        return nil
    }
}

/// The hub's stand-in: it records what it is handed, and keeps each transport for the test to write to.
private final class StubHub: WebSocketHandler, @unchecked Sendable {
    let events = WebEvents()
    private let lock = NSLock()
    private var held: [LiveTransport] = []

    func transport(_ index: Int = 0) -> LiveTransport? {
        lock.withLock { index < held.count ? held[index] : nil }
    }

    func opened(_ transport: LiveTransport, rights: LiveRights) {
        let index = lock.withLock { () -> Int in
            held.append(transport)
            return held.count - 1
        }
        transport.onWritable = { [events] in events.add("writable:\(index)") }
        events.add("opened:\(index):\(rights.rawValue)")
    }

    private func index(of transport: LiveTransport) -> Int {
        lock.withLock { held.firstIndex { $0 === transport } ?? -1 }
    }

    func text(_ message: Data, on transport: LiveTransport) {
        events.add("text:\(index(of: transport)):\(String(decoding: message, as: UTF8.self))")
    }

    func binary(_ message: Data, on transport: LiveTransport) {
        events.add("binary:\(index(of: transport)):\(message.count)")
    }

    func closed(_ transport: LiveTransport) {
        events.add("closed:\(index(of: transport))")
    }
}

/// The node's web listener with stand-ins behind its seams, on a port the kernel picks.
private final class WiredWorld: @unchecked Sendable {
    let time = WebTestTime()
    let queue = DispatchQueue(label: "node-web-listener-tests")
    let gate = StubGate()
    let hub = StubHub()
    let web: NodeWebListener
    let port: UInt16

    var host: String { "127.0.0.1:\(port)" }
    var origin: String { "http://127.0.0.1:\(port)" }

    init(_ limits: WebLimits = NodeWebListener.limits, files: [String: WebAsset] = [:]) throws {
        web = NodeWebListener(port: 0, assets: StubAssets(files: files), gate: gate, handler: hub, queue: queue, clock: time.clock(),
                              limits: limits, hello: { admission in
                                  NodeWire.line(["kind": NodeWire.Value.string("hello"), "auth": admission.auth]).dropLast()
                              })
        port = try web.start()
    }

    deinit {
        let done = DispatchSemaphore(value: 0)
        web.stop { done.signal() }
        _ = done.wait(timeout: .now() + hangGuard)
    }

    func connect() throws -> WebTestClient {
        try WebTestClient(port: port)
    }

    func exchange(_ request: String) throws -> (head: String, body: String) {
        let client = try connect()
        client.send(request)
        return try #require(client.response(), "no answer to \(request.prefix(60))")
    }

    /// A client whose WebSocket is open and has said nothing yet.
    func socketClient() throws -> WebTestClient {
        let client = try connect()
        let head = try #require(client.upgrade(path: "/ws", host: host, origin: origin))
        try #require(head.hasPrefix("HTTP/1.1 101 "), "\(head)")
        return client
    }

    /// A client admitted under `token`: its `hello` read.
    func admitted(token: String = "good") throws -> WebTestClient {
        let client = try socketClient()
        client.send(WebTestClient.text(#"{"v":1,"id":"0","kind":"auth","args":{"token":"\#(token)","client":"webapp"}}"#))
        let hello = try #require(client.frame())
        try #require(hello.opcode == WebTestClient.text && hello.text.contains(#""kind":"hello""#), "\(hello.text)")
        return client
    }

    func settle() {
        queue.sync {}
    }

    func until(_ holds: () -> Bool) -> Bool {
        let deadline = MacTime.real.awake() + hangGuard
        while !holds() {
            guard MacTime.real.awake() < deadline else { return false }
            usleep(2_000)
        }
        return true
    }

    /// The next frame as a `bye`'s code, then the close frame's code, then the end.
    func farewell(_ client: WebTestClient) -> (bye: String?, close: UInt16?, ended: Bool) {
        let first = client.frame()
        let bye = first.flatMap { NodeWire.decode(NodeWire.Bye.self, Data($0.payload)) }
        let closing = bye == nil ? first : client.frame()
        return (bye?.kind == "bye" ? bye?.code : nil, closing?.closeCode, client.ended())
    }
}

extension WebListenerTests {
    /// `NodeWebListener`: the listener behind the plan's seams, as the live wire contract has it.
    struct Wired {
        @Test func theLimitsAreTheContracts() {
            let limits = NodeWebListener.limits
            #expect(limits.maxHeaderBytes == 8 * 1_024 && limits.headSeconds == 5 && limits.maxMessageBytes == 64 * 1_024)
            #expect(limits.maxConnections == 32 && limits.pingSeconds == 15 && limits.maxMissedPings == 2)
            #expect(limits.overflow == .close && limits.maxQueuedBytes > NodeWebListener.busyBytes + (1 << 20))
            #expect(NodeWebListener.authSeconds == 5)
            for (code, number) in [("stopping", 1001), ("too-long", 1009), ("not-object", 4400), ("not-request", 4400), ("auth", 4401),
                                   ("revoked", 4403), ("version", 4426)] as [(String, UInt16)] {
                #expect(NodeWebListener.closeCode(code) == number, "\(code)")
                #expect(WebSocketClose.isSendable(number))
            }
        }

        /// A request under any name but the listener's own two (`127.0.0.1:PORT`, and on the loopback `localhost:PORT`,
        /// the origin a passkey works on) is 421 with no body, whatever it asks for, an upgrade too: another host,
        /// localhost on another port, `LOCALHOST`, a trailing dot. On its own names, an upgrade whose Origin is the other
        /// name's is refused (403): a pairing belongs to the origin it was made on.
        @Test func aRequestUnderAnotherNameIs421() throws {
            let world = try WiredWorld(files: ["/": WebAsset(body: Data("page".utf8), headers: [("Content-Type", "text/html")])])
            let localhost = "localhost:\(world.port)"
            for host in ["evil.example:\(world.port)", "127.0.0.1", "127.0.0.1:1", "127.0.0.1:\(world.port).evil.example",
                         "[::1]:\(world.port)", "0.0.0.0:\(world.port)", "127.1:\(world.port)", "localhost", "localhost:1", "LOCALHOST:\(world.port)",
                         "Localhost:\(world.port)", "localhost.:\(world.port)", "localhost:\(world.port).", "127.0.0.1.:\(world.port)",
                         "localhost:\(world.port).evil.example", "evil.localhost:\(world.port)"] {
                let answer = try world.exchange("GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
                #expect(answer.head.hasPrefix("HTTP/1.1 421 Misdirected Request\r\n"), "\(host): \(answer.head)")
                #expect(answer.body.isEmpty && answer.head.contains("\r\nContent-Length: 0\r\n"))
                #expect(answer.head.contains("\r\nX-Content-Type-Options: nosniff\r\n"))
                let upgrade = try world.connect()
                #expect(upgrade.upgrade(path: "/ws", host: host, origin: world.origin)?.hasPrefix("HTTP/1.1 421 ") == true, "\(host)")
            }
            // Its second name: the page, and an upgrade from its own origin; each name's Origin the other's: refused.
            #expect(try world.exchange("GET / HTTP/1.1\r\nHost: \(localhost)\r\n\r\n").body == "page")
            #expect(try world.connect().upgrade(path: "/ws", host: localhost, origin: "http://" + localhost)?.hasPrefix("HTTP/1.1 101 ") == true)
            #expect(try world.connect().upgrade(path: "/ws", host: localhost, origin: world.origin)?.hasPrefix("HTTP/1.1 403 ") == true)
            #expect(try world.connect().upgrade(path: "/ws", host: world.host, origin: "http://" + localhost)?.hasPrefix("HTTP/1.1 403 ") == true)
            // No Host, and two, are refused alike (the live wire contract's §1).
            #expect(try world.exchange("GET / HTTP/1.1\r\n\r\n").head.hasPrefix("HTTP/1.1 421 "))
            #expect(try world.exchange("GET / HTTP/1.1\r\nHost: \(world.host)\r\nHost: \(world.host)\r\n\r\n").head.hasPrefix("HTTP/1.1 421 "))
            #expect(try world.exchange("GET / HTTP/1.1\r\nHost: \(world.host)\r\n\r\n").body == "page")
            world.settle()
            #expect(world.gate.admissions.isEmpty && world.hub.events.all.isEmpty)
        }

        @Test func aGetServesTheAssetWithItsHeaders() throws {
            let files = [
                "/": WebAsset(body: Data("<!doctype html>".utf8), headers: [
                    ("Content-Type", "text/html; charset=utf-8"), ("Content-Security-Policy", "default-src 'none'"),
                    ("X-Content-Type-Options", "nosniff"), ("Cache-Control", "no-cache"), ("Link", "</a.js>; rel=preload"), ("Link", "</b.js>; rel=preload"),
                ]),
                "/app/main.js": WebAsset(body: Data("export {}".utf8), headers: [("Content-Type", "text/javascript")]),
            ]
            let world = try WiredWorld(files: files)
            let page = try world.exchange("GET /?utm=1 HTTP/1.1\r\nHost: \(world.host)\r\n\r\n")
            #expect(page.head.hasPrefix("HTTP/1.1 200 OK\r\n") && page.body == "<!doctype html>")
            for line in ["Content-Type: text/html; charset=utf-8", "Content-Security-Policy: default-src 'none'", "Cache-Control: no-cache",
                         "Link: </a.js>; rel=preload", "Link: </b.js>; rel=preload", "Content-Length: 15", "X-Content-Type-Options: nosniff"] {
                #expect(page.head.contains("\r\n\(line)\r\n"), "\(line) isn't in \(page.head)")
            }
            #expect(page.head.components(separatedBy: "X-Content-Type-Options").count == 2)
            #expect(!page.head.lowercased().contains("set-cookie"))
            #expect(try world.exchange("GET /app/main.js HTTP/1.1\r\nHost: \(world.host)\r\n\r\n").body == "export {}")
            for missing in ["/app", "/app/", "/app/main.js/", "/app/../app/main.js", "/app/%6dain.js", "//", "/ws", "/APP/MAIN.JS"] {
                #expect(try world.exchange("GET \(missing) HTTP/1.1\r\nHost: \(world.host)\r\n\r\n").head.hasPrefix("HTTP/1.1 404 "), "\(missing)")
            }
        }

        /// `/ws` is the only upgrade, and only for the page's own origin.
        @Test func onlyThePagesOwnOriginOpensTheSocket() throws {
            let world = try WiredWorld()
            func status(path: String = "/ws", origin: String?, extra: [String] = []) throws -> String {
                let client = try world.connect()
                return String(try #require(client.upgrade(path: path, host: world.host, origin: origin, extra: extra)).prefix(12))
            }
            #expect(try status(origin: "https://evil.example") == "HTTP/1.1 403")
            #expect(try status(origin: "http://127.0.0.1:\(world.port == 1 ? 2 : 1)") == "HTTP/1.1 403")
            #expect(try status(origin: "http://localhost:\(world.port)") == "HTTP/1.1 403")
            #expect(try status(origin: "https://127.0.0.1:\(world.port)") == "HTTP/1.1 403")
            #expect(try status(origin: "null") == "HTTP/1.1 403")
            #expect(try status(origin: nil) == "HTTP/1.1 403")
            #expect(try status(origin: world.origin, extra: ["Sec-Fetch-Site: cross-site"]) == "HTTP/1.1 403")
            #expect(try status(origin: world.origin, extra: ["Sec-Fetch-Site: same-site"]) == "HTTP/1.1 403")
            #expect(try status(origin: world.origin, extra: ["Sec-Fetch-Site: same-origin", "Sec-Fetch-Site: none"]) == "HTTP/1.1 403")
            #expect(try status(path: "/", origin: world.origin) == "HTTP/1.1 404")
            #expect(try status(path: "/ws/2", origin: world.origin) == "HTTP/1.1 404")
            #expect(try status(origin: world.origin, extra: ["Sec-Fetch-Site: same-origin"]) == "HTTP/1.1 101")
            #expect(try status(path: "/ws?since=3", origin: world.origin) == "HTTP/1.1 101")
            // No subprotocol is agreed to.
            let client = try world.connect()
            let head = try #require(client.upgrade(path: "/ws", host: world.host, origin: world.origin, extra: ["Sec-WebSocket-Protocol: vibe"]))
            #expect(head.hasPrefix("HTTP/1.1 101 ") && !head.lowercased().contains("sec-websocket-protocol"))
        }

        /// The server says nothing before `auth`; an `auth` the gate admits is answered `hello`, and from then on the
        /// handler has the connection: each message whole, and what it sends as text frames.
        @Test func authOpensTheHandlersConnection() throws {
            let world = try WiredWorld()
            let client = try world.socketClient()
            world.settle()
            #expect(client.nothingWaits())
            #expect(world.hub.events.all.isEmpty)
            // A page's own `_origin` is never taken: the listener writes the name the connection came on (its Origin's,
            // checked at the upgrade) over it.
            client.send(WebTestClient.text(#"{"v":1,"id":"0","kind":"auth","args":{"pair":"code","client":"webapp","assets":"9f2c61d0","_origin":"localhost:1"}}"#))
            let hello = try #require(client.frame())
            #expect(hello.opcode == WebTestClient.text && hello.text == #"{"auth":{"token":"minted"},"kind":"hello"}"#)
            #expect(world.hub.events.wait(for: "opened:0:3"))
            #expect(world.gate.admissions == [["pair": .string("code"), "client": .string("webapp"), "assets": .string("9f2c61d0"),
                                               WebAccess.originArg: .string(world.host)]])

            // A message in fragments reaches the handler whole; a binary one too.
            client.send(WebTestClient.text(#"{"v":1,"id":"1","#, fin: false) + WebTestClient.frame(WebTestClient.continuation, Array(#""kind":"status"}"#.utf8)))
            #expect(world.hub.events.wait(for: #"text:0:{"v":1,"id":"1","kind":"status"}"#))
            client.send(WebTestClient.frame(WebTestClient.binary, [1, 0, 0, 0, 7, 0x6C, 0x73]))
            #expect(world.hub.events.wait(for: "binary:0:7"))
            // What the handler sends is one text frame a message.
            let transport = try #require(world.hub.transport())
            #expect(transport.writable)
            transport.send(Data(#"{"v":1,"re":"1","ok":true}"#.utf8))
            let reply = try #require(client.frame())
            #expect(reply.opcode == WebTestClient.text && reply.fin && reply.text == #"{"v":1,"re":"1","ok":true}"#)
            // A second connection is a second transport, under its own token.
            let second = try world.admitted()
            #expect(world.hub.events.wait(for: "opened:1:1"))
            client.send(WebTestClient.closing(1000))
            #expect(world.hub.events.wait(for: "closed:0"))
            second.close()
            #expect(world.hub.events.wait(for: "closed:1"))
            #expect(world.hub.events.all.filter { $0.hasPrefix("closed:") }.count == 2)
        }

        /// Anything but an admitted `auth` first is `bye` (`auth`) and 4401, and the handler never hears of it.
        @Test func aRefusedAuthIsByeAnd4401() throws {
            let world = try WiredWorld()
            let firsts: [[UInt8]] = [
                WebTestClient.text(#"{"v":1,"id":"0","kind":"auth","args":{"token":"wrong"}}"#),
                WebTestClient.text(#"{"v":1,"id":"0","kind":"auth"}"#),
                WebTestClient.text(#"{"v":1,"id":"0","kind":"status"}"#),
                WebTestClient.text(#"{"kind":"auth","args":{"token":"good"}}"#),
                WebTestClient.text(#"["auth"]"#),
                WebTestClient.text("not json"),
                WebTestClient.text(""),
                WebTestClient.frame(WebTestClient.binary, Array(#"{"v":1,"id":"0","kind":"auth","args":{"token":"good"}}"#.utf8)),
            ]
            var reasons = Set<String>()
            for (index, first) in firsts.enumerated() {
                let client = try world.socketClient()
                client.send(first)
                let said = try #require(client.frame(), "case \(index)")
                let bye = try #require(NodeWire.decode(NodeWire.Bye.self, Data(said.payload)), "case \(index): \(said.text)")
                #expect(bye.kind == "bye" && bye.code == "auth", "case \(index): \(said.text)")
                reasons.insert(bye.reason)
                #expect(client.frame()?.closeCode == 4401, "case \(index)")
                #expect(client.ended())
            }
            // The refusal never says what was wrong.
            #expect(reasons.count == 1)
            let newer = try world.socketClient()
            newer.send(WebTestClient.text(#"{"v":\#(NodeWire.version + 1),"id":"0","kind":"auth","args":{"token":"good"}}"#))
            let farewell = world.farewell(newer)
            #expect(farewell.bye == "version" && farewell.close == 4426 && farewell.ended)
            world.settle()
            #expect(world.hub.events.all.isEmpty, "\(world.hub.events.all)")
            #expect(world.gate.admissions.count == 2, "only an auth request with args or without reaches the gate: \(world.gate.admissions)")
        }

        /// A WebSocket that never sends its `auth` is closed by the clock.
        @Test func noAuthInTimeIsByeAnd4401() throws {
            let world = try WiredWorld()
            let client = try world.socketClient()
            let admitted = try world.admitted()
            world.settle()
            world.time.advance(NodeWebListener.authSeconds)
            world.settle()
            #expect(client.nothingWaits())
            world.time.advance(1)
            let farewell = world.farewell(client)
            #expect(farewell.bye == "auth" && farewell.close == 4401 && farewell.ended)
            // The one that did stays.
            admitted.send(WebTestClient.text(#"{"v":1,"id":"1","kind":"status"}"#))
            #expect(world.hub.events.wait { $0.contains { $0.hasPrefix("text:0:") } })
            #expect(!world.hub.events.all.contains { $0.hasPrefix("closed:") })
        }

        @Test func aMessageTooLongIsByeAnd1009() throws {
            let world = try WiredWorld()
            let client = try world.admitted()
            #expect(world.hub.events.wait(for: "opened:0:1"))
            client.send(Array(WebTestClient.frame(WebTestClient.text, [UInt8](repeating: 0x61, count: 64 * 1_024 + 1)).prefix(12)))
            let farewell = world.farewell(client)
            #expect(farewell.bye == "too-long" && farewell.close == 1009 && farewell.ended)
            #expect(world.hub.events.wait(for: "closed:0"))
            #expect(!world.hub.events.all.contains { $0.hasPrefix("text:") })
            // Exactly the limit is taken.
            let other = try world.admitted()
            other.send(WebTestClient.frame(WebTestClient.text, [UInt8](repeating: 0x61, count: 64 * 1_024)))
            #expect(world.hub.events.wait { $0.contains { $0.hasPrefix("text:1:aaaa") } })
        }

        /// The hub's close, and the listener's for a token, are a `bye` with the code and the close with its number.
        @Test func aCloseSaysByeFirst() throws {
            let world = try WiredWorld()
            let first = try world.admitted()
            let second = try world.admitted()
            let paired = try world.socketClient()
            paired.send(WebTestClient.text(#"{"v":1,"id":"0","kind":"auth","args":{"pair":"code"}}"#))
            #expect(paired.frame()?.text.contains("hello") == true)
            #expect(world.hub.events.wait(for: "opened:2:3"))
            try #require(world.hub.transport(0)).close(code: "not-request", reason: "v, id and kind are needed")
            var farewell = world.farewell(first)
            #expect(farewell.bye == "not-request" && farewell.close == 4400 && farewell.ended)
            #expect(world.hub.events.wait(for: "closed:0"))
            // The token "good" is revoked: its connection, and not the one that came in under another.
            world.web.close(token: "good", code: "revoked", reason: "the token was revoked")
            farewell = world.farewell(second)
            #expect(farewell.bye == "revoked" && farewell.close == 4403 && farewell.ended)
            #expect(world.hub.events.wait(for: "closed:1"))
            world.settle()
            #expect(paired.nothingWaits())
            world.web.closeAll(code: "revoked", reason: "every token was revoked")
            farewell = world.farewell(paired)
            #expect(farewell.bye == "revoked" && farewell.close == 4403 && farewell.ended)
            #expect(world.hub.events.wait(for: "closed:2"))
        }

        /// A client that doesn't read: the transport stops being writable with a bounded queue, nothing is lost, and
        /// the hub is told when it may write again.
        @Test func aClientThatDoesntReadMakesItsTransportUnwritableThenWritable() throws {
            let world = try WiredWorld()
            let client = try world.admitted()
            #expect(world.hub.events.wait(for: "opened:0:1"))
            let transport = try #require(world.hub.transport())
            let filler = String(repeating: "x", count: 64 * 1_024)
            var sent = 0
            while transport.writable {
                transport.send(Data("\(sent):\(filler)".utf8))
                sent += 1
                try #require(sent < 100_000, "the transport never stopped being writable")
            }
            #expect(sent >= 16, "the transport is writable until \(NodeWebListener.busyBytes) bytes wait")
            // One more, as a hub would that looked a moment before: it still fits.
            transport.send(Data("\(sent):\(filler)".utf8))
            sent += 1
            for number in 0..<sent {
                let frame = try #require(client.frame(), "the connection ended at message \(number) of \(sent)")
                try #require(frame.opcode == WebTestClient.text && frame.text == "\(number):\(filler)", "message \(number)")
            }
            #expect(world.hub.events.wait(for: "writable:0"))
            #expect(transport.writable)
            #expect(!world.hub.events.all.contains("closed:0"))
        }

        @Test func stoppingSaysByeAndTellsTheHandler() throws {
            let world = try WiredWorld()
            let client = try world.admitted()
            let silent = try world.socketClient()
            #expect(world.hub.events.wait(for: "opened:0:1"))
            #expect(world.until { world.web.connectionCount == 2 })
            let port = world.port
            let done = DispatchSemaphore(value: 0)
            world.web.stop { done.signal() }
            #expect(done.wait(timeout: .now() + hangGuard) == .success)
            let farewell = world.farewell(client)
            #expect(farewell.bye == "stopping" && farewell.close == 1001 && farewell.ended)
            #expect(world.farewell(silent).close == 1001)
            #expect(world.hub.events.wait(for: "closed:0"))
            #expect(world.hub.events.all.filter { $0.hasPrefix("closed:") } == ["closed:0"], "one that never authenticated was never the handler's")
            #expect(world.web.state == .off && world.web.port == nil)
            client.close()
            silent.close()
            #expect(WebWorld.descriptors(on: port).isEmpty)
        }

        /// The listener is up only while the gate wants it, and a port already taken is said, not worked around.
        @Test func theListenerFollowsTheGate() throws {
            let world = try WiredWorld()
            let first = world.port
            #expect(world.web.follow() == .on(port: first))
            let client = try world.admitted()
            world.gate.wanted = false
            #expect(world.web.follow() == .off)
            let farewell = world.farewell(client)
            #expect(farewell.bye == "revoked" && farewell.close == 4403 && farewell.ended)
            client.close()
            #expect(world.until { WebWorld.descriptors(on: first).isEmpty })
            #expect(world.web.follow() == .off && world.web.port == nil)
            world.gate.wanted = true
            guard case .on(let second) = world.web.follow() else {
                Issue.record("not up again: \(world.web.state)")
                return
            }
            #expect(world.web.follow() == .on(port: second))
            let again = try WebTestClient(port: second)
            #expect(again.upgrade(path: "/ws", host: "127.0.0.1:\(second)", origin: "http://127.0.0.1:\(second)")?.hasPrefix("HTTP/1.1 101 ") == true)

            // A second listener on that port is refused, and says so; it holds nothing.
            let taken = NodeWebListener(port: second, assets: StubAssets(files: [:]), gate: world.gate, handler: world.hub, queue: world.queue,
                                        clock: world.time.clock())
            guard case .refused(let why) = taken.follow() else {
                Issue.record("bound a port in use: \(taken.state)")
                return
            }
            #expect(why.contains("127.0.0.1:\(second)") && why.contains("bind"), "\(why)")
            #expect(taken.port == nil && taken.connectionCount == 0)
            #expect(throws: WebListener.Failure.system(.system("bind", EADDRINUSE))) { try taken.start() }
        }

        /// H1: a listener whose socket comes from the session host (`WebBind.host`) and is refused says why, as its
        /// state, and binds nothing of its own. The web going off (nothing alive) never has the host let its socket go:
        /// only the user's revoke does (`revoked`), once.
        @Test func aSocketTheHostRefusesIsTheStateAndNothingIsBoundHere() throws {
            let asked = Locked<[String]>([])
            let refusing = WebBind(listen: { place, address, port, _ in
                asked.value.append("\(place.rawValue) \(address):\(port)")
                return .failure(.host("the user's node listens on port 47830 only, not 0"))
            }, release: { asked.value.append("release \($0.rawValue)") })
            let gate = StubGate()
            let queue = DispatchQueue(label: "node-web-listener-host-refused")
            let web = NodeWebListener(port: 0, assets: StubAssets(files: [:]), gate: gate, handler: StubHub(), queue: queue,
                                      clock: WebTestTime().clock(), bind: refusing)
            guard case .refused(let why) = web.follow() else {
                Issue.record("\(web.state)")
                return
            }
            #expect(why.contains("the session host gave no web socket: the user's node listens on port 47830 only"), "\(why)")
            #expect(web.port == nil && web.connectionCount == 0)
            gate.wanted = false
            #expect(web.follow() == .off)
            #expect(web.follow() == .off)
            #expect(asked.value == ["loopback 127.0.0.1:0"], "nothing alive is no release: \(asked.value)")
            web.revoked()
            #expect(asked.value == ["loopback 127.0.0.1:0", "release loopback"], "\(asked.value)")
            #expect(web.follow() == .off)
            #expect(asked.value.count == 2)
        }

        /// H1 on both systems: the server's socket is always the host's, over its connector (Linux's `SOCK_SEQPACKET` and
        /// the Mac's stream alike, the Mac's H1): with no host to ask it has none, and never binds its own.
        @Test func theServersBindIsAlwaysTheHosts() throws {
            let bind = WebBind.forServer(connector: -1, note: { _ in })
            guard case .failure(.host) = bind.listen(.loopback, "127.0.0.1", 0, 4) else {
                Issue.record("bound without a host")
                return
            }
        }

        /// H1: a listener the host's socket was up for, stopped because nothing is alive any more (codes and tokens ran
        /// out), keeps the host's socket held; stopped after the user's revoke, it has the host let it go once its own
        /// descriptor is closed.
        @Test func onlyARevokeHasTheHostLetItsSocketGo() throws {
            let asked = Locked<[String]>([])
            let direct = WebBind.direct
            let counting = WebBind(listen: { place, address, port, backlog in
                asked.value.append("listen \(place.rawValue)")
                return direct.listen(place, address, port, backlog)
            }, release: { asked.value.append("release \($0.rawValue)") })
            let gate = StubGate()
            let queue = DispatchQueue(label: "node-web-listener-revoke")
            let web = NodeWebListener(port: 0, assets: StubAssets(files: [:]), gate: gate, handler: StubHub(), queue: queue,
                                      clock: WebTestTime().clock(), bind: counting)
            guard case .on = web.follow() else { Issue.record("\(web.state)"); return }
            gate.wanted = false
            let stopped = DispatchSemaphore(value: 0)
            #expect(web.follow() == .off)
            web.stop { stopped.signal() }
            #expect(stopped.wait(timeout: .now() + hangGuard) == .success)
            #expect(asked.value == ["listen loopback"], "\(asked.value)")
            gate.wanted = true
            guard case .on = web.follow() else { Issue.record("\(web.state)"); return }
            web.revoked()
            gate.wanted = false
            let released = DispatchSemaphore(value: 0)
            web.stop { released.signal() }
            #expect(released.wait(timeout: .now() + hangGuard) == .success)
            #expect(asked.value == ["listen loopback", "listen loopback", "release loopback"], "\(asked.value)")
        }

    }
}
