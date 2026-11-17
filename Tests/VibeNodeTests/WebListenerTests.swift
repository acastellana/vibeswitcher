import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The web listener, in this process, on a port the system picks on loopback, against a client that writes its own
/// bytes (`WebTestClient`): requests and their limits, the WebSocket handshake and its policy, frames, the close
/// handshake, pings, a client that doesn't read, the connection limit, the bind, and what is left open.
///
/// One at a time: a test counts the sockets on its listener's port, and a port just let go is the next listener's.
@Suite(.serialized)
struct WebListenerTests {
    // MARK: Requests

    @Test func aGetIsAnsweredByTheHandler() throws {
        let seen = WebEvents()
        let world = try WebWorld(onRequest: { request in
            seen.add("\(request.path)|\(request.query ?? "-")|\(request.host)|\(request.headers["x-kind"] ?? "-")")
            return WebResponse(status: 200, headers: [("Content-Type", "text/plain; charset=utf-8"), ("Cache-Control", "no-store")],
                               body: Data("hello".utf8))
        })
        let answer = try world.exchange("GET /hello/there?x=1 HTTP/1.1\r\nHost: \(world.host)\r\nX-Kind:  plain \r\n\r\n")
        #expect(answer.head.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(answer.head)")
        #expect(answer.body == "hello")
        for line in ["Content-Type: text/plain; charset=utf-8", "Cache-Control: no-store", "Content-Length: 5", "Connection: close",
                     "X-Content-Type-Options: nosniff"] {
            #expect(answer.head.contains("\r\n\(line)\r\n"), "\(line) isn't in \(answer.head)")
        }
        #expect(seen.all == ["/hello/there|x=1|\(world.host)|plain"])
        #expect(world.until { world.listener.connectionCount == 0 })
    }

    @Test func aPathNobodyAnswersIsNotFoundAndRepeatsNothing() throws {
        let world = try WebWorld()
        let answer = try world.exchange("GET /zq-marker-path?zq-marker-query HTTP/1.1\r\nHost: zq-marker-host\r\nX-Zq: zq-marker-field\r\n\r\n")
        #expect(answer.head.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(answer.head.contains("\r\nX-Content-Type-Options: nosniff\r\n"))
        #expect(answer.body == "404 Not Found\n")
        #expect(!(answer.head + answer.body).lowercased().contains("zq"))
    }

    @Test func aBodyWithNoTypeIsNeverSniffed() throws {
        let world = try WebWorld(onRequest: { _ in WebResponse(status: 200, body: Data("<script>".utf8)) })
        let answer = try world.exchange("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(answer.head.contains("\r\nContent-Type: application/octet-stream\r\n"))
        #expect(answer.head.contains("\r\nX-Content-Type-Options: nosniff\r\n"))
    }

    /// A handler's field that would start a line of its own, and a handler's copies of the listener's own fields.
    @Test func aHandlersFieldsCantBreakTheResponse() throws {
        let split = try WebWorld(onRequest: { _ in WebResponse(status: 200, headers: [("X-A", "b\r\nSet-Cookie: stolen=1")], body: Data("x".utf8)) })
        let broken = try split.exchange("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(broken.head.hasPrefix("HTTP/1.1 500 "))
        #expect(!broken.head.contains("Set-Cookie") && !broken.body.contains("stolen"))

        let own = try WebWorld(onRequest: { _ in
            WebResponse(status: 200, headers: [("Content-Length", "999"), ("Connection", "keep-alive"), ("X-Content-Type-Options", "sniff"),
                                               ("Transfer-Encoding", "chunked")], body: Data("abc".utf8))
        })
        let answer = try own.exchange("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(answer.head.hasPrefix("HTTP/1.1 200 "))
        #expect(answer.head.contains("\r\nContent-Length: 3\r\n") && !answer.head.contains("999"))
        #expect(answer.head.contains("\r\nConnection: close\r\n") && !answer.head.contains("keep-alive"))
        #expect(answer.head.contains("\r\nX-Content-Type-Options: nosniff\r\n") && answer.head.components(separatedBy: "X-Content-Type-Options").count == 2)
        #expect(!answer.head.lowercased().contains("transfer-encoding"))
        #expect(answer.body == "abc")
    }

    @Test func onlyAPlainGetIsTaken() throws {
        let world = try WebWorld(onRequest: { _ in WebResponse(status: 200, body: Data("ok".utf8)) })
        let cases: [(request: String, status: String)] = [
            ("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n", "405 Method Not Allowed"),
            ("HEAD / HTTP/1.1\r\nHost: h\r\n\r\n", "405 Method Not Allowed"),
            ("get / HTTP/1.1\r\nHost: h\r\n\r\n", "405 Method Not Allowed"),
            ("GET / HTTP/1.0\r\nHost: h\r\n\r\n", "505 HTTP Version Not Supported"),
            ("GET / HTTP/2.0\r\nHost: h\r\n\r\n", "505 HTTP Version Not Supported"),
            ("GET / HTTPS/1.1\r\nHost: h\r\n\r\n", "400 Bad Request"),
            ("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello", "413 Content Too Large"),
            ("GET / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", "413 Content Too Large"),
            ("GET / HTTP/1.1\r\nHost: h\r\nContent-Length: five\r\n\r\n", "400 Bad Request"),
            ("GET / HTTP/1.1\nHost: h\n\n", "400 Bad Request"),
            ("GET / HTTP/1.1\r\nHost: h\rX: y\r\n\r\n", "400 Bad Request"),
            ("\r\nGET / HTTP/1.1\r\nHost: h\r\n\r\n", "400 Bad Request"),
            ("GET / HTTP/1.1\r\n\r\n", "421 Misdirected Request"),
            ("GET / HTTP/1.1\r\nHost: h\r\nHost: other\r\n\r\n", "421 Misdirected Request"),
            ("GET / HTTP/1.1\r\nHost : h\r\n\r\n", "400 Bad Request"),
            ("GET / HTTP/1.1\r\nHost: h\r\nX-Folded: a\r\n b\r\n\r\n", "400 Bad Request"),
            ("GET / HTTP/1.1\r\nHost: h\r\nX-Nul: a\u{0}b\r\n\r\n", "400 Bad Request"),
            ("GET / HTTP/1.1\r\nHost: h\r\nNo colon here\r\n\r\n", "400 Bad Request"),
            ("GET  / HTTP/1.1\r\nHost: h\r\n\r\n", "400 Bad Request"),
            ("GET http://h/ HTTP/1.1\r\nHost: h\r\n\r\n", "400 Bad Request"),
            ("GET * HTTP/1.1\r\nHost: h\r\n\r\n", "400 Bad Request"),
            ("GET /a#b HTTP/1.1\r\nHost: h\r\n\r\n", "400 Bad Request"),
            ("GET /a\u{7F} HTTP/1.1\r\nHost: h\r\n\r\n", "400 Bad Request"),
        ]
        for entry in cases {
            let answer = try world.exchange(entry.request)
            #expect(answer.head.hasPrefix("HTTP/1.1 \(entry.status)\r\n"), "\(entry.request.debugDescription) was answered \(answer.head.prefix(40))")
            #expect(answer.head.contains("\r\nX-Content-Type-Options: nosniff\r\n"))
            #expect(answer.body == "\(entry.status)\n")
        }
        #expect(try world.exchange("POST / HTTP/1.1\r\nHost: h\r\n\r\n").head.contains("\r\nAllow: GET\r\n"))
        // What is taken: a length of 0, a field's value with bytes over 127 (another site's cookie), a query.
        for request in ["GET / HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n", "GET /?a=b HTTP/1.1\r\nHost: h\r\nCookie: a=caf\u{E9}\r\n\r\n"] {
            #expect(try world.exchange(request).head.hasPrefix("HTTP/1.1 200 OK\r\n"), "\(request.debugDescription)")
        }
    }

    @Test func aRequestsSizesAreLimited() throws {
        var limits = WebLimits()
        limits.maxRequestLineBytes = 64
        limits.maxHeaderBytes = 512
        limits.maxHeaderCount = 4
        let world = try WebWorld(limits, onRequest: { _ in WebResponse(status: 200) })
        func status(_ request: String) throws -> String {
            String(try world.exchange(request).head.prefix(12))
        }
        // "GET " and " HTTP/1.1" are 13 of the line's bytes.
        #expect(try status("GET /\(String(repeating: "a", count: 50)) HTTP/1.1\r\nHost: h\r\n\r\n") == "HTTP/1.1 200")
        #expect(try status("GET /\(String(repeating: "a", count: 51)) HTTP/1.1\r\nHost: h\r\n\r\n") == "HTTP/1.1 414")
        // A line that never ends is refused as soon as it is too long, not when it ends.
        let endless = try world.connect()
        endless.send("GET /" + String(repeating: "a", count: 100))
        #expect(endless.response()?.head.hasPrefix("HTTP/1.1 414 ") == true)

        let fields = (1...3).map { "X-\($0): v\r\n" }.joined()
        #expect(try status("GET / HTTP/1.1\r\nHost: h\r\n\(fields)\r\n") == "HTTP/1.1 200")
        #expect(try status("GET / HTTP/1.1\r\nHost: h\r\n\(fields)X-4: v\r\n\r\n") == "HTTP/1.1 431")

        // The head's bytes, its last empty line included: 512 are taken, 513 aren't.
        func head(_ total: Int) -> String {
            let fixed = "GET / HTTP/1.1\r\nHost: h\r\nX-Pad: \r\n\r\n"
            return fixed.replacingOccurrences(of: "X-Pad: ", with: "X-Pad: " + String(repeating: "p", count: total - fixed.utf8.count))
        }
        #expect(head(512).utf8.count == 512)
        #expect(try status(head(512)) == "HTTP/1.1 200")
        #expect(try status(head(513)) == "HTTP/1.1 431")
        // Fields that never end are refused at the limit, with no empty line.
        let padded = try world.connect()
        padded.send("GET / HTTP/1.1\r\nHost: h\r\nX-Pad: " + String(repeating: "p", count: 600))
        #expect(padded.response()?.head.hasPrefix("HTTP/1.1 431 ") == true)
    }

    /// A head that comes too slowly is cut off by the clock, however its bytes keep coming.
    @Test func aSlowHeadIsAnswered408() throws {
        var limits = WebLimits()
        limits.headSeconds = 3
        let world = try WebWorld(limits)
        let client = try world.connect()
        client.send("GET / HTTP/1.1\r\nHost: h\r\n")
        #expect(world.until { world.listener.connectionCount == 1 })
        world.time.advance(2)
        client.send("X-Slow: 1\r\n")
        world.time.advance(1)
        world.settle()
        #expect(client.nothingWaits(), "cut off before its \(limits.headSeconds) s")
        #expect(world.listener.connectionCount == 1)
        client.send("X-Slower: 2\r\n")
        world.time.advance(1)
        let answer = try #require(client.response())
        #expect(answer.head.hasPrefix("HTTP/1.1 408 Request Timeout\r\n"), "\(answer.head)")
        client.close()
        #expect(world.until { world.listener.connectionCount == 0 })
        // A head that ends in time isn't: the clock's seconds before it don't count against its answer.
        let prompt = try world.connect()
        #expect(world.until { world.listener.connectionCount == 1 })
        world.time.advance(3)
        prompt.send("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(prompt.response()?.head.hasPrefix("HTTP/1.1 404 ") == true)
    }

    @Test func aClientThatEndsItsWritesStillGetsItsAnswer() throws {
        let world = try WebWorld(onRequest: { _ in WebResponse(status: 200, body: Data(repeating: 0x61, count: 300_000)) })
        let client = try world.connect()
        client.send("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
        client.endWrites()
        let answer = try #require(client.response())
        #expect(answer.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(answer.body.utf8.count == 300_000)
        #expect(world.until { world.listener.connectionCount == 0 })
    }

    /// A response its client never reads is given up by the clock, and its connection closed.
    @Test func aResponseNobodyReadsIsGivenUp() throws {
        var limits = WebLimits()
        limits.responseSeconds = 4
        let world = try WebWorld(limits, onRequest: { _ in WebResponse(status: 200, body: Data(count: 24 << 20)) })
        let client = try world.connect()
        client.send("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
        #expect(client.head()?.hasPrefix("HTTP/1.1 200 OK\r\n") == true)
        world.time.advance(4)
        world.settle()
        #expect(world.listener.connectionCount == 1)
        world.time.advance(1)
        #expect(world.until { world.listener.connectionCount == 0 })
        #expect(world.until { world.listener.descriptorCount == 1 })
        // What the client can still read is less than the whole.
        #expect(client.rest().count < 24 << 20)
    }

    // MARK: The handshake

    @Test func theHandshakeOpensAWebSocket() throws {
        let world = try WebWorld(subprotocols: ["vibe.2", "vibe.1"])
        let client = try world.connect()
        let head = try #require(client.upgrade(path: "/live?since=4", host: world.host, origin: world.origin, connection: "Upgrade",
                                               extra: ["Sec-WebSocket-Protocol: other, vibe.1, vibe.2", "Sec-WebSocket-Extensions: permessage-deflate"]))
        #expect(head.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"), "\(head)")
        for line in ["Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Accept: \(WebTestClient.sampleAccept)",
                     "Sec-WebSocket-Protocol: vibe.2", "X-Content-Type-Options: nosniff"] {
            #expect(head.contains("\r\n\(line)\r\n"), "\(line) isn't in \(head)")
        }
        // No extension is agreed to, whatever was offered.
        #expect(!head.lowercased().contains("sec-websocket-extensions"))
        let socket = try world.socket()
        #expect(socket.request.path == "/live" && socket.request.query == "since=4")
        #expect(socket.request.host == world.host && socket.request.origin == world.origin)
        #expect(socket.subprotocol == "vibe.2")
        // Field names and the upgrade's tokens in any case.
        let shouting = try world.connect()
        shouting.send("GET /live HTTP/1.1\r\nHOST: \(world.host)\r\nUPGRADE: WebSocket\r\nCONNECTION: UPGRADE\r\nORIGIN: \(world.origin)\r\n"
            + "SEC-WEBSOCKET-KEY: \(WebTestClient.sampleKey)\r\nSEC-WEBSOCKET-VERSION: 13\r\n\r\n")
        #expect(shouting.head()?.hasPrefix("HTTP/1.1 101 ") == true)
        #expect(try world.socket(1).subprotocol == nil)
    }

    @Test func aBadHandshakeIsRefused() throws {
        let world = try WebWorld()
        func refused(_ status: String, _ ask: (WebTestClient) -> String?) throws -> String {
            let client = try world.connect()
            let head = try #require(ask(client))
            #expect(head.hasPrefix("HTTP/1.1 \(status)\r\n"), "\(head)")
            #expect(head.contains("\r\nX-Content-Type-Options: nosniff\r\n"))
            #expect(client.rest() == Array("\(status)\n".utf8))
            return head
        }
        let (host, origin) = (world.host, world.origin)
        let old = try refused("426 Upgrade Required") { $0.upgrade(host: host, origin: origin, version: "8") }
        #expect(old.contains("\r\nSec-WebSocket-Version: 13\r\n"))
        _ = try refused("426 Upgrade Required") { $0.upgrade(host: host, origin: origin, version: nil) }
        _ = try refused("426 Upgrade Required") { $0.upgrade(host: host, origin: origin, version: "13, 8") }
        _ = try refused("400 Bad Request") { $0.upgrade(host: host, origin: origin, key: nil) }
        _ = try refused("400 Bad Request") { $0.upgrade(host: host, origin: origin, key: "c2hvcnQ=") }
        _ = try refused("400 Bad Request") { $0.upgrade(host: host, origin: origin, key: "not base64 at all !!!!!!") }
        _ = try refused("400 Bad Request") { $0.upgrade(host: host, origin: origin, extra: ["Sec-WebSocket-Key: \(WebTestClient.sampleKey)"]) }
        _ = try refused("400 Bad Request") { $0.upgrade(host: host, origin: origin, connection: "keep-alive") }
        _ = try refused("403 Forbidden") { $0.upgrade(host: host, origin: origin, extra: ["Origin: \(origin)"]) }
        world.settle()
        #expect(world.events.all.isEmpty, "a refused handshake opened a WebSocket: \(world.events.all)")
    }

    /// The policy sees the Host, the Origin, the path and the fields, and its no is 403: another site's page (its
    /// Origin), a name that isn't this listener's (its Host), no Origin at all.
    @Test func thePolicyDecidesWhoseWebSocketOpens() throws {
        let world = try WebWorld()
        func status(host: String, origin: String?) throws -> String {
            let client = try world.connect()
            return String(try #require(client.upgrade(host: host, origin: origin)).prefix(12))
        }
        #expect(try status(host: world.host, origin: "https://evil.example") == "HTTP/1.1 403")
        #expect(try status(host: world.host, origin: "http://127.0.0.1:1") == "HTTP/1.1 403")
        #expect(try status(host: world.host, origin: "null") == "HTTP/1.1 403")
        #expect(try status(host: world.host, origin: nil) == "HTTP/1.1 403")
        #expect(try status(host: "rebound.example:\(world.port)", origin: world.origin) == "HTTP/1.1 403")
        #expect(try status(host: "127.0.0.1", origin: world.origin) == "HTTP/1.1 403")
        world.settle()
        #expect(world.events.all.isEmpty, "\(world.events.all)")
        #expect(try status(host: world.host, origin: world.origin) == "HTTP/1.1 101")

        let asked = WebEvents()
        let recording = try WebWorld(policy: .some({ host, origin, path, headers in
            asked.add("\(host)|\(origin ?? "-")|\(path)|\(headers["x-device"] ?? "-")")
            return false
        }))
        let client = try recording.connect()
        let head = try #require(client.upgrade(path: "/live/7?k=v", host: "name.example", origin: "https://page.example", extra: ["X-Device: d1"]))
        #expect(head.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(!(head + String(decoding: client.rest(), as: UTF8.self)).contains("example"))
        #expect(asked.all == ["name.example|https://page.example|/live/7|d1"])
    }

    @Test func withNoPolicyNoWebSocketOpens() throws {
        let world = try WebWorld(policy: .some(nil))
        let client = try world.connect()
        #expect(client.upgrade(host: world.host, origin: world.origin)?.hasPrefix("HTTP/1.1 403 Forbidden\r\n") == true)
        world.settle()
        #expect(world.events.all.isEmpty)
        // A plain GET is still answered.
        #expect(try world.exchange("GET / HTTP/1.1\r\nHost: h\r\n\r\n").head.hasPrefix("HTTP/1.1 404 "))
    }

    // MARK: Frames

    @Test func textAndBinaryAreEchoedAtEveryLength() throws {
        let world = try WebWorld()
        let client = try world.socketClient()
        for text in ["", "hello", "caf\u{E9} \u{1F600} \u{4E2D}", String(repeating: "x", count: 126), String(repeating: "y", count: 70_000)] {
            client.send(WebTestClient.text(text))
            let echo = try #require(client.frame())
            #expect(echo.opcode == WebTestClient.text && echo.fin && !echo.masked && echo.rsv == 0)
            #expect(echo.text == text, "\(text.utf8.count) bytes of text")
        }
        for count in [0, 1, 125, 126, 127, 65_535, 65_536, 200_000] {
            let bytes = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ count) }
            client.send(WebTestClient.frame(WebTestClient.binary, bytes, mask: [UInt8(count & 0xFF), 0, 0xFF, 0x5A]))
            let echo = try #require(client.frame())
            #expect(echo.opcode == WebTestClient.binary && echo.fin && !echo.masked && echo.rsv == 0)
            #expect(echo.payload == bytes, "\(count) bytes")
        }
        // The longer forms of a length are refused only when a shorter one would do: here they are the shortest.
        client.send(WebTestClient.frame(WebTestClient.binary, [UInt8](repeating: 7, count: 126), length: .two))
        #expect(client.frame()?.payload.count == 126)
    }

    @Test func aFragmentedMessageIsPutTogether() throws {
        let world = try WebWorld()
        let client = try world.socketClient()
        // A character cut between two fragments, an empty fragment, and a ping in the middle, answered at once.
        let text = Array("frag\u{E9}ment\u{1F600}ed".utf8)
        client.send(WebTestClient.frame(WebTestClient.text, Array(text[0..<5]), fin: false))
        client.send(WebTestClient.frame(WebTestClient.ping, Array("mid".utf8)))
        client.send(WebTestClient.frame(WebTestClient.continuation, [], fin: false))
        client.send(WebTestClient.frame(WebTestClient.continuation, Array(text[5..<12]), fin: false))
        client.send(WebTestClient.frame(WebTestClient.continuation, Array(text[12...])))
        let pong = try #require(client.frame())
        #expect(pong.opcode == WebTestClient.pong && pong.text == "mid")
        let echo = try #require(client.frame())
        #expect(echo.opcode == WebTestClient.text && echo.payload == text)

        client.send(WebTestClient.frame(WebTestClient.binary, [1, 2], fin: false) + WebTestClient.frame(WebTestClient.continuation, [3]))
        #expect(client.frame()?.payload == [1, 2, 3])
        // A frame whose bytes come one at a time.
        for byte in WebTestClient.text("slow") { client.send([byte]) }
        #expect(client.frame()?.text == "slow")
        #expect(world.events.all.filter { $0.hasPrefix("text:") } == ["text:frag\u{E9}ment\u{1F600}ed", "text:slow"])
    }

    /// Frames RFC 6455 forbids a client, each with the code it closes the connection with, for a message limit of 1024
    /// bytes: read by the decoder alone (`Parsing`) and sent to a listener.
    static let forbidden: [(what: String, bytes: [UInt8], code: UInt16)] = {
        typealias Client = WebTestClient
        return [
            ("a frame not masked", Client.frame(Client.text, Array("hi".utf8), mask: nil), 1002),
            ("the first reserved bit", Client.frame(Client.text, Array("hi".utf8), rsv: 0b100), 1002),
            ("the second reserved bit", Client.frame(Client.binary, [1], rsv: 0b010), 1002),
            ("the third reserved bit", Client.frame(Client.ping, [], rsv: 0b001), 1002),
            ("an opcode nobody has", Client.frame(0x3, [1]), 1002),
            ("a control opcode nobody has", Client.frame(0xB, []), 1002),
            ("a ping in fragments", Client.frame(Client.ping, [1], fin: false), 1002),
            ("a ping of 126 bytes", Client.frame(Client.ping, [UInt8](repeating: 0, count: 126)), 1002),
            ("a continuation of nothing", Client.frame(Client.continuation, [1]), 1002),
            ("a message inside another", Client.frame(Client.text, [0x61], fin: false) + Client.frame(Client.text, [0x62]), 1002),
            ("a short length in two bytes", Client.frame(Client.binary, [1, 2, 3], length: .two), 1002),
            ("a short length in eight bytes", Client.frame(Client.binary, [1, 2, 3], length: .eight), 1002),
            ("a length with its top bit set", Client.frame(Client.binary, [], length: .claiming(1 << 63 | 5)), 1002),
            ("a close frame of one byte", Client.frame(Client.close, [3]), 1002),
            ("a close code never sent (1005)", Client.closing(1005), 1002),
            ("a close code never sent (1006)", Client.closing(1006), 1002),
            ("a close code under 1000", Client.closing(999), 1002),
            ("a close code over 4999", Client.closing(5000), 1002),
            ("a close reason that isn't UTF-8", Client.frame(Client.close, [0x03, 0xE8, 0xFF]), 1007),
            ("text that isn't UTF-8", Client.frame(Client.text, [0x68, 0xC0, 0xAF]), 1007),
            ("a surrogate in text", Client.frame(Client.text, [0xED, 0xA0, 0x80]), 1007),
            ("text cut inside a character", Client.frame(Client.text, [0xE2, 0x82]), 1007),
            ("fragments that aren't UTF-8 together", Client.frame(Client.text, [0xE2], fin: false) + Client.frame(Client.continuation, [0x28, 0xA1]), 1007),
            ("a message over the limit", Client.frame(Client.binary, [UInt8](repeating: 0, count: 1_025)), 1009),
            ("a length over the limit, with no payload sent", Array(Client.frame(Client.binary, [], length: .claiming(1 << 40)).prefix(10)), 1009),
            ("fragments over the limit together", Client.frame(Client.binary, [UInt8](repeating: 0, count: 600), fin: false)
                + Client.frame(Client.continuation, [UInt8](repeating: 0, count: 425)), 1009),
        ]
    }()

    /// What RFC 6455 forbids a client closes the connection with the code that fits, told to the client in a close
    /// frame and to the handler; and nothing of the frame is delivered.
    @Test func whatTheProtocolForbidsClosesWithItsCode() throws {
        var limits = WebLimits()
        limits.maxMessageBytes = 1_024
        let world = try WebWorld(limits)
        typealias Client = WebTestClient
        let cases = Self.forbidden
        for (index, entry) in cases.enumerated() {
            let client = try world.socketClient(path: "/case/\(index)")
            #expect(world.events.wait(for: "open:/case/\(index)"))
            let before = world.events.all.count
            client.send(entry.bytes)
            let closing = try #require(client.frame(), "\(entry.what): the connection ended with no close frame")
            #expect(closing.opcode == Client.close && closing.closeCode == entry.code, "\(entry.what): \(closing)")
            #expect(!closing.masked && closing.fin)
            // Then the end, and nothing else.
            #expect(client.ended(), "\(entry.what)")
            #expect(world.events.wait { $0.count > before })
            let since = Array(world.events.all[before...])
            #expect(since.count == 1 && since[0].hasPrefix("close:\(entry.code):"), "\(entry.what): \(since)")
        }
        // Exactly the limit is a message like another.
        let client = try world.socketClient()
        client.send(Client.frame(Client.binary, [UInt8](repeating: 9, count: 1_024)))
        #expect(client.frame()?.payload.count == 1_024)
        client.send(Client.frame(Client.binary, [UInt8](repeating: 9, count: 1_000), fin: false) + Client.frame(Client.continuation, [UInt8](repeating: 9, count: 24)))
        #expect(client.frame()?.payload.count == 1_024)
    }

    @Test func aPingIsAnsweredWithItsPayload() throws {
        let world = try WebWorld()
        let client = try world.socketClient()
        for payload in [[], Array("ping".utf8), [UInt8](repeating: 0xA5, count: 125)] as [[UInt8]] {
            client.send(WebTestClient.frame(WebTestClient.ping, payload))
            let pong = try #require(client.frame())
            #expect(pong.opcode == WebTestClient.pong && pong.payload == payload && pong.fin && !pong.masked)
        }
        // A pong nobody asked for is let by.
        client.send(WebTestClient.frame(WebTestClient.pong, [1]) + WebTestClient.text("still here"))
        #expect(client.frame()?.text == "still here")
    }

    /// The server pings on the clock; a client that answers stays, one that sends nothing from one ping to the next
    /// is closed.
    @Test func theServerPingsAndClosesASilentClient() throws {
        var limits = WebLimits()
        limits.pingSeconds = 20
        let world = try WebWorld(limits)
        let client = try world.socketClient()
        _ = try world.socket()
        world.settle()
        world.time.advance(19)
        world.settle()
        #expect(client.nothingWaits())
        world.time.advance(1)
        let first = try #require(client.frame())
        #expect(first.opcode == WebTestClient.ping && first.fin && !first.masked)
        // The pong, then a message whose echo says the server has read both.
        client.send(WebTestClient.frame(WebTestClient.pong, first.payload) + WebTestClient.text("read"))
        #expect(client.frame()?.text == "read")
        world.time.advance(20)
        #expect(client.frame()?.opcode == WebTestClient.ping)
        #expect(world.listener.connectionCount == 1)
        // Silent from that ping on: one more ping, and at the one after, the close.
        world.time.advance(20)
        #expect(client.frame()?.opcode == WebTestClient.ping)
        world.settle()
        #expect(world.listener.connectionCount == 1)
        world.time.advance(20)
        #expect(client.ended())
        #expect(world.events.wait(for: "close:1006:no answer to a ping"))
        #expect(world.until { world.listener.connectionCount == 0 })
    }

    // MARK: Closing

    @Test func theClientsCloseIsAnsweredAndTheConnectionEnds() throws {
        let world = try WebWorld()
        let client = try world.socketClient()
        client.send(WebTestClient.closing(1000, "bye"))
        let answer = try #require(client.frame())
        #expect(answer.opcode == WebTestClient.close && answer.closeCode == 1000 && !answer.masked)
        #expect(client.ended())
        #expect(world.events.wait(for: "close:1000:bye"))
        client.close()
        #expect(world.until { world.listener.connectionCount == 0 })

        // A code of the client's own comes back; a close frame with none is answered 1000 and told as 1005.
        let own = try world.socketClient()
        own.send(WebTestClient.closing(4321, "mine"))
        #expect(own.frame()?.closeCode == 4321)
        #expect(world.events.wait(for: "close:4321:mine"))
        let bare = try world.socketClient()
        bare.send(WebTestClient.frame(WebTestClient.close) + WebTestClient.text("after the close"))
        #expect(bare.frame()?.closeCode == 1000)
        #expect(bare.ended())
        #expect(world.events.wait(for: "close:1005:"))
        // Nothing sent after a close frame is delivered.
        world.settle()
        #expect(!world.events.all.contains { $0.hasPrefix("text:") })
        // A client that goes with no close frame.
        let gone = try world.socketClient(path: "/gone")
        #expect(world.events.wait(for: "open:/gone"))
        gone.close()
        #expect(world.events.wait(for: "close:1006:"))
        #expect(world.events.all.filter { $0.hasPrefix("close:") }.count == 4)
    }

    @Test func theServersCloseFollowsWhatWasQueued() throws {
        let world = try WebWorld()
        let client = try world.socketClient()
        let socket = try world.socket()
        #expect(socket.send(text: "last words"))
        socket.close(code: 4001, reason: "done")
        // Nothing is taken after the close, and a second close changes nothing.
        #expect(!socket.send(text: "too late"))
        socket.close(code: 4002, reason: "again")
        #expect(client.frame()?.text == "last words")
        let closing = try #require(client.frame())
        #expect(closing.opcode == WebTestClient.close && closing.closeCode == 4001 && closing.closeReason == "done")
        #expect(world.events.wait(for: "close:4001:done"))
        // The server has ended its writes and waits for the client's end.
        #expect(client.ended())
        #expect(world.listener.connectionCount == 1)
        client.send(WebTestClient.closing(4001))
        client.close()
        #expect(world.until { world.listener.connectionCount == 0 })
        #expect(world.events.all.filter { $0.hasPrefix("close:") } == ["close:4001:done"])

        // A code that may not travel goes as 1000; a reason too long is cut between characters.
        let other = try world.socketClient()
        try world.socket(1).close(code: 1006, reason: String(repeating: "\u{E9}", count: 100))
        let cut = try #require(other.frame())
        #expect(cut.closeCode == 1000 && cut.payload.count == 124 && cut.closeReason == String(repeating: "\u{E9}", count: 61))
    }

    /// A client told the end that never closes its side is closed by the clock.
    @Test func aClientThatNeverClosesIsClosedByTheClock() throws {
        var limits = WebLimits()
        limits.closeSeconds = 3
        let world = try WebWorld(limits)
        let client = try world.socketClient()
        try world.socket().close()
        #expect(client.frame()?.closeCode == 1000)
        #expect(client.ended())
        world.settle()
        world.time.advance(3)
        world.settle()
        #expect(world.listener.connectionCount == 1)
        world.time.advance(1)
        #expect(world.until { world.listener.connectionCount == 0 })
        #expect(world.until { world.listener.descriptorCount == 1 })
    }

    @Test func stoppingTellsEachClientAndClosesEverything() throws {
        let world = try WebWorld()
        let client = try world.socketClient()
        let idle = try world.connect()
        #expect(world.until { world.listener.connectionCount == 2 })
        #expect(world.descriptors().count == 5, "the listener, two connections and their two clients: \(world.descriptors())")
        world.stop()
        let told = try #require(client.frame())
        #expect(told.opcode == WebTestClient.close && told.closeCode == 1001)
        #expect(client.ended() && idle.ended())
        #expect(world.events.all.filter { $0.hasPrefix("close:") } == ["close:1001:the listener stopped"])
        #expect(world.listener.descriptorCount == 0)
        #expect(try world.socket().send(text: "nobody") == false)
        client.close()
        idle.close()
        #expect(world.descriptors().isEmpty, "\(world.descriptors())")
        #expect(throws: WebListener.Failure.alreadyStarted) { try world.listener.start() }
    }

    // MARK: A client that falls behind

    /// A message: its number, then bytes that follow from it.
    private static func numbered(_ number: Int, count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<4 { bytes[index] = UInt8(number >> (8 * index) & 0xFF) }
        for index in 4..<count { bytes[index] = UInt8(truncatingIfNeeded: number &+ index) }
        return Data(bytes)
    }

    /// A client that doesn't read: the queue fills to its limit and no further, the handler is told once, and every
    /// message from then on is dropped until the handler resumes. The client gets every message that was taken, in
    /// order and whole; the handler is told when the last has been written; and what it sends once it has resumed
    /// arrives right after.
    @Test func aClientThatDoesntReadLosesMessagesNotMemory() throws {
        var limits = WebLimits()
        limits.maxQueuedBytes = 256 * 1_024
        limits.overflow = .drop
        let world = try WebWorld(limits)
        let client = try world.socketClient()
        let socket = try world.socket()
        let size = 32 * 1_024
        var taken = 0
        while socket.send(binary: Self.numbered(taken, count: size)) {
            taken += 1
            #expect(socket.queuedBytes <= limits.maxQueuedBytes)
            try #require(taken < 100_000, "the queue never filled")
        }
        #expect(taken >= 7, "the queue alone holds seven messages")
        #expect(world.events.wait(for: "behind"))
        for _ in 0..<50 { #expect(!socket.send(binary: Self.numbered(-1, count: size))) }
        #expect(!socket.send(text: "small, and dropped too"))
        #expect(socket.queuedBytes <= limits.maxQueuedBytes)

        // The client reads: every message taken, in order and whole.
        for number in 0..<taken {
            let frame = try #require(client.frame(), "the connection ended at message \(number) of \(taken)")
            try #require(frame.opcode == WebTestClient.binary && Data(frame.payload) == Self.numbered(number, count: size), "message \(number)")
        }
        #expect(world.events.wait(for: "drained"))
        #expect(socket.queuedBytes == 0)
        // Told, and still nothing is taken until the handler says so; then what it sends is the next thing read.
        #expect(!socket.send(text: "before the handler resumed"))
        socket.resume()
        #expect(socket.send(text: "resync"))
        #expect(client.frame()?.text == "resync")
        #expect(world.events.all.filter { $0 == "behind" || $0 == "drained" } == ["behind", "drained"])
        // Falling behind a second time is told a second time.
        while socket.send(binary: Self.numbered(0, count: size)) {}
        #expect(world.events.wait { $0.filter { $0 == "behind" }.count == 2 })
        #expect(world.listener.connectionCount == 1)
    }

    /// Under the other policy the client that doesn't read is closed.
    @Test func aClientThatDoesntReadIsClosedWhenThePolicySaysSo() throws {
        var limits = WebLimits()
        limits.maxQueuedBytes = 256 * 1_024
        limits.overflow = .close
        let world = try WebWorld(limits)
        let client = try world.socketClient()
        let socket = try world.socket()
        var taken = 0
        while socket.send(binary: Self.numbered(taken, count: 32 * 1_024)) {
            taken += 1
            try #require(taken < 100_000, "the queue never filled")
        }
        #expect(world.events.wait(for: "close:1006:fell behind"))
        #expect(world.events.all.filter { $0 == "behind" || $0.hasPrefix("close:") } == ["behind", "close:1006:fell behind"])
        #expect(!socket.send(text: "nobody"))
        #expect(socket.queuedBytes == 0)
        #expect(world.until { world.listener.connectionCount == 0 })
        #expect(world.until { world.listener.descriptorCount == 1 })
        // What the client reads ends, with whole messages or a reset, and never with a close frame.
        var last: WebTestClient.Frame?
        while let frame = client.frame() { last = frame }
        #expect(last?.opcode != WebTestClient.close)
    }

    /// A message larger than the queue's limit is never taken: dropped and told like any other, with nothing queued.
    @Test func aMessageOverTheQueuesLimitIsNotQueued() throws {
        var limits = WebLimits()
        limits.maxQueuedBytes = 1_024
        let world = try WebWorld(limits)
        let client = try world.socketClient()
        let socket = try world.socket()
        #expect(!socket.send(binary: Data(count: 2_048)))
        #expect(world.events.wait(for: "behind"))
        #expect(world.events.wait(for: "drained"))
        #expect(!socket.send(text: "not yet"))
        socket.resume()
        #expect(socket.send(text: "fits"))
        #expect(client.frame()?.text == "fits")
    }

    // MARK: Limits and hygiene

    @Test func connectionsOverTheLimitAreRefused() throws {
        var limits = WebLimits()
        limits.maxConnections = 2
        let world = try WebWorld(limits, onRequest: { _ in WebResponse(status: 200, body: Data("ok".utf8)) })
        let first = try world.connect()
        let second = try world.socketClient()
        #expect(world.until { world.listener.connectionCount == 2 })
        for _ in 0..<3 {
            let third = try world.connect()
            let answer = try #require(third.response())
            #expect(answer.head.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"), "\(answer.head)")
            #expect(answer.head.contains("\r\nX-Content-Type-Options: nosniff\r\n"))
        }
        #expect(world.listener.connectionCount == 2)
        #expect(world.listener.descriptorCount == 3)
        // Those open are served as before, and a place freed is a place again.
        second.send(WebTestClient.text("still served"))
        #expect(second.frame()?.text == "still served")
        first.close()
        #expect(world.until { world.listener.connectionCount == 1 })
        #expect(try world.exchange("GET / HTTP/1.1\r\nHost: h\r\n\r\n").head.hasPrefix("HTTP/1.1 200 OK\r\n"))
    }

    @Test func theListenerBindsToLoopbackOnly() throws {
        let queue = DispatchQueue(label: "web-listener-tests.bind")
        let clock = WebTestTime().clock()
        let refused: [(Platform.TCP.Family, String)] = [
            (.ipv4, "0.0.0.0"), (.ipv4, "192.0.2.1"), (.ipv4, "10.0.0.1"), (.ipv4, "128.0.0.1"), (.ipv4, "localhost"), (.ipv4, ""),
            (.ipv4, "127.0.0.1.example"), (.ipv4, "127.1"), (.ipv4, " 127.0.0.1"), (.ipv4, "::1"),
            (.ipv6, "::"), (.ipv6, "::ffff:127.0.0.1"), (.ipv6, "fe80::1"), (.ipv6, "2001:db8::1"), (.ipv6, "127.0.0.1"), (.ipv6, "::2"),
        ]
        for (family, address) in refused {
            let listener = WebListener(queue: queue, clock: clock, family: family, address: address)
            #expect(throws: WebListener.Failure.notLoopback(address)) { try listener.start() }
            #expect(listener.port == nil && listener.descriptorCount == 0)
        }
        for (family, address) in [(Platform.TCP.Family.ipv4, "127.0.0.1"), (.ipv4, "127.8.9.10"), (.ipv6, "::1"), (.ipv6, "0:0:0:0:0:0:0:1")] {
            #expect(WebListener.refusal(family: family, address: address, allowBeyondLoopback: false) == nil, "\(address)")
        }
        // Only a caller that says so gets another address, and what isn't an address is refused then too.
        #expect(WebListener.refusal(family: .ipv4, address: "0.0.0.0", allowBeyondLoopback: true) == nil)
        let named = WebListener(queue: queue, clock: clock, address: "localhost", allowBeyondLoopback: true)
        #expect(throws: WebListener.Failure.system(.notAnAddress)) { try named.start() }
        #expect(named.descriptorCount == 0)

        // Port 0 is a port the system picks, read back; and a listener starts once.
        let listener = WebListener(queue: queue, clock: clock)
        #expect(listener.port == nil)
        let port = try listener.start()
        #expect(port != 0 && listener.port == port)
        #expect(throws: WebListener.Failure.alreadyStarted) { try listener.start() }
        let held = WebWorld.descriptors(on: port)
        #expect(held.count == 1 && Platform.TCP.peerPort(held[0]) == nil)
        // Bound where it was told, as the kernel says.
        #expect(held.first.flatMap(Platform.TCP.localAddress) == "127.0.0.1")
        // A port in use is refused, with nothing left open.
        let second = WebListener(queue: queue, clock: clock, port: port)
        #expect(throws: WebListener.Failure.system(.system("bind", EADDRINUSE))) { try second.start() }
        #expect(second.descriptorCount == 0 && WebWorld.descriptors(on: port).count == 1)
        let done = DispatchSemaphore(value: 0)
        listener.stop { done.signal() }
        #expect(done.wait(timeout: .now() + hangGuard) == .success)
        #expect(WebWorld.descriptors(on: port).isEmpty)
    }

    /// Every way a connection ends leaves no descriptor: counted by the kernel's own list of this process's sockets
    /// on the listener's port, which holds only this test's. And each is close-on-exec while it is open.
    @Test func noDescriptorIsLeftAndEachIsCloseOnExec() throws {
        var limits = WebLimits()
        limits.maxConnections = 6
        limits.maxMessageBytes = 1_024
        let world = try WebWorld(limits, onRequest: { _ in WebResponse(status: 200, body: Data("ok".utf8)) })
        func closeOnExec(_ descriptors: [Int32]) -> Bool {
            descriptors.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 }
        }
        #expect(world.descriptors().count == 1)
        #expect(closeOnExec(world.descriptors()))
        for round in 0..<8 {
            // A request answered; one refused; one never sent; one cut short.
            _ = try world.exchange("GET / HTTP/1.1\r\nHost: h\r\n\r\n")
            _ = try world.exchange("BREW / HTTP/1.1\r\nHost: h\r\n\r\n")
            try world.connect().close()
            let half = try world.connect()
            half.send("GET / HTTP/1.1\r\nHo")
            half.close()
            // A refused upgrade.
            let refused = try world.connect()
            _ = refused.upgrade(host: world.host, origin: "https://evil.example")
            refused.close()
            #expect(world.until { world.listener.descriptorCount == 1 }, "round \(round)")
            // WebSockets: closed by the client's close frame; left with none; closed by the server; closed for a
            // frame the protocol forbids; open when the client's socket goes mid-frame.
            let polite = try world.socketClient(path: "/polite/\(round)")
            let rude = try world.socketClient(path: "/rude/\(round)")
            let served = try world.socketClient(path: "/served/\(round)")
            let wrong = try world.socketClient(path: "/wrong/\(round)")
            let cut = try world.socketClient(path: "/cut/\(round)")
            #expect(world.events.wait(for: "open:/cut/\(round)"))
            if round == 0 {
                // Five open: the listener, and both ends of each.
                let open = world.descriptors()
                #expect(open.count == 11, "\(open)")
                #expect(closeOnExec(open))
                #expect(world.listener.descriptorCount == 6)
            }
            // Over the limit while they are open.
            let sixth = try world.connect()
            #expect(world.until { world.listener.connectionCount == 6 })
            #expect(try world.connect().response()?.head.hasPrefix("HTTP/1.1 503 ") == true)
            sixth.close()

            polite.send(WebTestClient.closing(1000))
            #expect(polite.frame()?.closeCode == 1000)
            polite.close()
            rude.close()
            let index = round * 5 + 2
            try world.socket(index).send(text: "going")
            try world.socket(index).close(code: 4000)
            #expect(served.frame()?.text == "going")
            #expect(served.frame()?.closeCode == 4000)
            served.close()
            wrong.send(WebTestClient.frame(WebTestClient.text, [0xFF]))
            #expect(wrong.frame()?.closeCode == 1007)
            wrong.close()
            cut.send(Array(WebTestClient.frame(WebTestClient.binary, [UInt8](repeating: 1, count: 500)).prefix(100)))
            cut.close()
            #expect(world.until { world.listener.connectionCount == 0 }, "round \(round)")
        }
        #expect(world.events.all.filter { $0.hasPrefix("close:") }.count == 8 * 5)
        // Each connection's socket is closed once its sources have ended: the listener's own count says when.
        #expect(world.until { world.listener.descriptorCount == 1 })
        let left = world.descriptors()
        #expect(left.count == 1, "left open on port \(world.port): \(left)")
        world.stop()
        #expect(world.listener.descriptorCount == 0)
        #expect(world.descriptors().isEmpty, "left open on port \(world.port) after the stop: \(world.descriptors())")
    }

    /// A listener let go without `stop` closes what it held.
    @Test func aListenerLetGoClosesItsSockets() throws {
        let queue = DispatchQueue(label: "web-listener-tests.released")
        var listener: WebListener? = WebListener(queue: queue, clock: WebTestTime().clock())
        let port = try #require(try listener?.start())
        let client = try WebTestClient(port: port)
        client.send("GET / HTTP/1.1\r\nHo")
        let accepted = MacTime.real.awake() + hangGuard
        while listener?.connectionCount != 1, MacTime.real.awake() < accepted { usleep(2_000) }
        #expect(listener?.connectionCount == 1)
        #expect(WebWorld.descriptors(on: port).count == 3)
        listener = nil
        // The server's end is closed by its source's cancel handler: the client reads the end when it has run.
        #expect(client.ended())
        client.close()
        let deadline = MacTime.real.awake() + hangGuard
        while !WebWorld.descriptors(on: port).isEmpty, MacTime.real.awake() < deadline { queue.sync {} }
        #expect(WebWorld.descriptors(on: port).isEmpty, "\(WebWorld.descriptors(on: port))")
    }
}

// MARK: The parsers, with no socket

extension WebListenerTests {
    struct Parsing {
        @Test func theAcceptKeyIsTheRFCs() {
            #expect(WebSocketHandshake.accept(key: WebTestClient.sampleKey) == WebTestClient.sampleAccept)
        }

        /// A head read a byte at a time is the head read whole.
        @Test func aHeadReadByteByByteIsTheSameHead() throws {
            let text = "GET /a/b?c=d HTTP/1.1\r\nHost: h:1\r\nX-One:  padded \t\r\nx-two:\r\nX-One: again\r\n\r\nrest"
            var whole = HTTPHead()
            let expected = whole.take(Array(text.utf8), limits: WebLimits())
            guard case .request(let request, let rest) = expected else {
                Issue.record("not a request: \(expected)")
                return
            }
            #expect(request.target == "/a/b?c=d" && request.path == "/a/b" && request.query == "c=d" && request.host == "h:1")
            #expect(request.headers.all("X-ONE") == ["padded", "again"] && request.headers["x-one"] == nil && request.headers["X-Two"] == "")
            #expect(rest == Array("rest".utf8))
            var slow = HTTPHead()
            var last = HTTPHead.Step.more
            for byte in text.utf8.dropLast(4) {
                #expect(last == .more)
                last = slow.take([byte], limits: WebLimits())
            }
            #expect(last == .request(request, rest: []))
        }

        @Test func aPathsSegmentsNeverLeaveTheirFolder() {
            func segments(_ target: String) -> [String]? {
                WebRequest(target: target, headers: WebHeaders()).segments
            }
            #expect(segments("/") == [])
            #expect(segments("/app/main.js?v=1") == ["app", "main.js"])
            #expect(segments("/a%20b/caf%C3%A9") == ["a b", "caf\u{E9}"])
            for unsafe in ["/..", "/a/../b", "/a/./b", "/%2e%2e/secret", "/a/%2E%2E", "//etc/passwd", "/a//b", "/a/", "/a%2Fb", "/a%5Cb",
                           "/a%00b", "/a%0Ab", "/%ff", "/a%2", "/%zz", "/a/.", "/a/%2e"] {
                #expect(segments(unsafe) == nil, "\(unsafe)")
            }
        }

        @Test func utf8IsCheckedAsTheRFCHasIt() {
            let valid: [[UInt8]] = [
                [], Array("plain".utf8), [0xC2, 0x80], [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF], [0xEE, 0x80, 0x80],
                [0xEF, 0xBF, 0xBF], [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF], Array("\u{1F600}a\u{E9}".utf8), [0x00],
            ]
            for bytes in valid { #expect(UTF8Check.isValid(bytes), "\(bytes)") }
            let invalid: [[UInt8]] = [
                [0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xC2], [0xC2, 0x41], [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF], [0xE0, 0xA0],
                [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xF0, 0x80, 0x80, 0x80], [0xF0, 0x8F, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80],
                [0xF5, 0x80, 0x80, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80], [0xFE], [0xFF], [0xF0, 0x90, 0x80], [0x61, 0xE2, 0x82],
                [0xE2, 0x28, 0xA1], [0xF0, 0x90, 0x28, 0xBC], [0xF0, 0x90, 0x80, 0x28],
            ]
            for bytes in invalid { #expect(!UTF8Check.isValid(bytes), "\(bytes)") }
            // The same answer as the standard library's own decoder gives, for every pair of bytes.
            for first in UInt8.min...UInt8.max {
                for second in UInt8.min...UInt8.max {
                    let repaired = String(decoding: [first, second], as: UTF8.self)
                    #expect(UTF8Check.isValid([first, second]) == (Array(repaired.utf8) == [first, second]), "\([first, second])")
                }
            }
        }

        /// Frames read a byte at a time give the events the frames read whole give, and hold no more than they must.
        @Test func framesReadByteByByteAreTheSameEvents() throws {
            typealias Client = WebTestClient
            let bytes = Client.text("one") + Client.frame(Client.binary, [UInt8](repeating: 3, count: 300), fin: false)
                + Client.frame(Client.ping, [9]) + Client.frame(Client.continuation, [4, 5]) + Client.frame(Client.pong, [1])
                + Client.closing(1001, "going")
            func events(_ pieces: [[UInt8]]) throws -> [WebSocketDecoder.Event] {
                var decoder = WebSocketDecoder(maxMessageBytes: 1_024)
                var found: [WebSocketDecoder.Event] = []
                for piece in pieces {
                    decoder.append(piece)
                    while let event = try decoder.next() { found.append(event) }
                    #expect(decoder.heldBytes <= 1_024 + 14)
                }
                #expect(decoder.heldBytes == 0)
                return found
            }
            let whole = try events([bytes])
            #expect(whole == [.text("one"), .ping(Data([9])), .binary(Data([UInt8](repeating: 3, count: 300) + [4, 5])), .pong,
                              .close(code: 1001, reason: "going")])
            #expect(try events(bytes.map { [$0] }) == whole)
            // A frame refused by its header is refused before its payload comes.
            var decoder = WebSocketDecoder(maxMessageBytes: 1_024)
            decoder.append(Client.frame(Client.binary, [], length: .claiming(70_000)).prefix(10))
            #expect(throws: WebSocketDecoder.Failure(code: 1009, reason: "a message too big")) { try decoder.next() }
        }

        /// Each frame the protocol forbids is refused by the decoder with its code, and nothing of it is delivered.
        @Test func theDecoderRefusesWhatTheProtocolForbids() {
            for entry in WebListenerTests.forbidden {
                var decoder = WebSocketDecoder(maxMessageBytes: 1_024)
                decoder.append(entry.bytes)
                var events: [WebSocketDecoder.Event] = []
                var refused: UInt16?
                do {
                    while let event = try decoder.next() { events.append(event) }
                } catch let failure as WebSocketDecoder.Failure {
                    refused = failure.code
                } catch {
                    Issue.record("\(entry.what): \(error)")
                }
                #expect(refused == entry.code, "\(entry.what): \(refused.map(String.init) ?? "taken"), events \(events)")
                #expect(events.isEmpty, "\(entry.what): \(events)")
            }
        }

        @Test func aServersFrameIsNeverMaskedAndItsLengthIsTheShortest() {
            #expect(WebSocketFrame.encode(.text, Data("hi".utf8)) == Data([0x81, 0x02, 0x68, 0x69]))
            #expect(WebSocketFrame.encode(.binary, Data(count: 125)).prefix(2) == Data([0x82, 125]))
            #expect(WebSocketFrame.encode(.binary, Data(count: 126)).prefix(4) == Data([0x82, 126, 0, 126]))
            #expect(WebSocketFrame.encode(.binary, Data(count: 65_535)).prefix(4) == Data([0x82, 126, 0xFF, 0xFF]))
            #expect(WebSocketFrame.encode(.binary, Data(count: 65_536)).prefix(10) == Data([0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0]))
            #expect(WebSocketFrame.close(code: 1001, reason: "x") == Data([0x88, 0x03, 0x03, 0xE9, 0x78]))
            for code in [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 3000, 4999] as [UInt16] {
                #expect(WebSocketClose.isSendable(code), "\(code)")
            }
            for code in [0, 999, 1004, 1005, 1006, 1015, 1016, 2999, 5000, 65_535] as [UInt16] {
                #expect(!WebSocketClose.isSendable(code), "\(code)")
            }
        }
    }
}
