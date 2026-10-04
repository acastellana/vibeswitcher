import Foundation
import Network
import Testing
@testable import VibeCore

struct DevPagesTests {
    @Test func onlyLocalHttpPagesQualify() throws {
        let page = try #require(DevPages.page(url: "http://localhost:5173/settings?tab=2#top", title: " Settings "))
        #expect(page.title == "Settings")
        #expect(page.path == "/settings?tab=2#top")
        #expect(page.target == PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173))
        #expect(DevPages.page(url: "http://127.0.0.1:3000", title: "")?.title == "127.0.0.1:3000")
        #expect(DevPages.page(url: "http://127.0.0.1:3000", title: "")?.path == "/")
        #expect(DevPages.page(url: "http://[::1]:8080/", title: "x")?.target
                == PreviewTarget(connectHost: "::1", hostHeader: "[::1]:8080", port: 8080))
        #expect(DevPages.page(url: "http://app.localhost:3000/", title: "x")?.target.connectHost == "localhost")
        #expect(DevPages.page(url: "http://app.localhost:3000/", title: "x")?.target.hostHeader == "app.localhost:3000")
        for url in ["https://localhost:5173/", "http://example.com:5173/", "http://192.168.1.4:3000/",
                    "http://localhost/", "http://localhost:47823/", "http://localhost:47826/",
                    "http://user:pw@localhost:3000/", "chrome://settings", "http://localhost.evil.com:3000/"] {
            #expect(DevPages.page(url: url, title: "x") == nil, "\(url)")
        }
    }

    @Test func pathsCanNeverRedirectOffTheMac() {
        #expect(DevPages.page(url: "http://localhost:3000//evil.example/x", title: "x")?.path == "/evil.example/x")
        #expect(DevPages.safePath("/\\evil.example") == "/evil.example")
        #expect(DevPages.safePath("/ok/path?a=1") == "/ok/path?a=1")
        #expect(DevPages.safePath("") == "/")
    }

    @Test func listsEachPageOnceInTabOrder() throws {
        let pages = DevPages.pages(fromTabs: [("http://localhost:5173/", "A"), ("https://github.com/", "B"),
                                              ("http://localhost:5173/", "A again"), ("http://localhost:3000/x", "C")])
        #expect(pages.map(\.title) == ["A", "C"])
        #expect(DevPages.id(for: pages[0]) != DevPages.id(for: pages[1]))
        let renamed = try #require(DevPages.page(url: "http://localhost:5173/", title: "renamed"))
        #expect(DevPages.id(for: pages[0]) == DevPages.id(for: renamed))
    }
}

struct PreviewSlotsTests {
    let vite = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173)
    let next = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:3000", port: 3000)
    let other = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "127.0.0.1:8080", port: 8080)
    let t0 = Date(timeIntervalSince1970: 1000)

    func counter() -> () -> String {
        var n = 0
        return { n += 1; return "token\(n)" }
    }

    // The test macros can't wrap mutating calls, so each call goes into a local first.

    @Test func ticketsWorkOnceOnTheirOwnSlotWithinAMinute() throws {
        var slots = PreviewSlots(count: 2)
        let tokens = counter()
        let firstResult = slots.open(vite, path: "/a", now: t0, newToken: tokens)
        let first = try #require(firstResult)
        // Presented on the wrong slot, a ticket is burned.
        let wrongSlot = slots.redeem(first.ticket, slot: first.slot == 0 ? 1 : 0, now: t0, newToken: tokens)
        #expect(wrongSlot == nil)
        let afterBurn = slots.redeem(first.ticket, slot: first.slot, now: t0, newToken: tokens)
        #expect(afterBurn == nil)
        let secondResult = slots.open(vite, path: "/b", now: t0, newToken: tokens)
        let second = try #require(secondResult)
        let entryResult = slots.redeem(second.ticket, slot: second.slot, now: t0.addingTimeInterval(59), newToken: tokens)
        let entry = try #require(entryResult)
        #expect(entry.path == "/b")
        let reused = slots.redeem(second.ticket, slot: second.slot, now: t0, newToken: tokens)
        #expect(reused == nil)
        let good = slots.target(slot: second.slot, sessionToken: entry.sessionToken, now: t0)
        #expect(good == vite)
        let wrongToken = slots.target(slot: second.slot, sessionToken: "nope", now: t0)
        #expect(wrongToken == nil)
        let noToken = slots.target(slot: second.slot, sessionToken: nil, now: t0)
        #expect(noToken == nil)
        let lateResult = slots.open(vite, path: "/c", now: t0, newToken: tokens)
        let late = try #require(lateResult)
        let expired = slots.redeem(late.ticket, slot: late.slot, now: t0.addingTimeInterval(61), newToken: tokens)
        #expect(expired == nil)
    }

    @Test func reusesASlotPerServerAndTakesOverTheLeastRecentlyUsed() throws {
        var slots = PreviewSlots(count: 1)
        let tokens = counter()
        let firstResult = slots.open(vite, path: "/", now: t0, newToken: tokens)
        let first = try #require(firstResult)
        let viteSessionResult = slots.redeem(first.ticket, slot: 0, now: t0, newToken: tokens)
        let viteSession = try #require(viteSessionResult).sessionToken
        // The same server again: same slot, same session, so tabs already open keep working.
        let secondResult = slots.open(vite, path: "/x", now: t0, newToken: tokens)
        let second = try #require(secondResult)
        #expect(second.slot == 0)
        let againResult = slots.redeem(second.ticket, slot: 0, now: t0, newToken: tokens)
        let again = try #require(againResult)
        #expect(again.sessionToken == viteSession)
        // Another server takes the only slot: the old session stops working and never sees the new server.
        let thirdResult = slots.open(next, path: "/", now: t0.addingTimeInterval(1), newToken: tokens)
        let third = try #require(thirdResult)
        #expect(third.slot == 0)
        let oldTab = slots.target(slot: 0, sessionToken: viteSession, now: t0)
        #expect(oldTab == nil)
        let takeoverResult = slots.redeem(third.ticket, slot: 0, now: t0, newToken: tokens)
        let takeover = try #require(takeoverResult)
        #expect(takeover.sessionToken != viteSession)
    }

    @Test func picksTheLeastRecentlyUsedSlotAndSkipsUnavailableOnes() throws {
        var slots = PreviewSlots(count: 3)
        let tokens = counter()
        slots.setAvailable(2, false)
        let aResult = slots.open(vite, path: "/", now: t0, newToken: tokens)
        let a = try #require(aResult)
        let bResult = slots.open(next, path: "/", now: t0.addingTimeInterval(1), newToken: tokens)
        let b = try #require(bResult)
        #expect(a.slot == 0)
        #expect(b.slot == 1)
        let aSessionResult = slots.redeem(a.ticket, slot: a.slot, now: t0, newToken: tokens)
        let aSession = try #require(aSessionResult).sessionToken
        _ = slots.target(slot: a.slot, sessionToken: aSession, now: t0.addingTimeInterval(2))   // slot 0 used last
        let cResult = slots.open(other, path: "/", now: t0.addingTimeInterval(3), newToken: tokens)
        let c = try #require(cResult)
        #expect(c.slot == 1)
        slots.setAvailable(0, false)
        slots.setAvailable(1, false)
        let none = slots.open(vite, path: "/", now: t0, newToken: tokens)
        #expect(none == nil)
    }
}

func requestHead(_ raw: String) -> HTTPHead {
    guard case .complete(let head, _) = HTTPHead.parse(Data((raw + "\r\n").utf8), kind: .request) else {
        fatalError("test request didn't parse: \(raw)")
    }
    return head
}

func responseHead(_ raw: String) -> HTTPHead {
    guard case .complete(let head, _) = HTTPHead.parse(Data((raw + "\r\n").utf8), kind: .response) else {
        fatalError("test response didn't parse: \(raw)")
    }
    return head
}

struct HTTPHeadTests {
    @Test func parsesAndReserializesHeads() throws {
        let raw = "GET /a?b=1 HTTP/1.1\r\nHost: x\r\nCookie: a=1\r\nCookie: b=2\r\n\r\nBODY"
        guard case .complete(let head, let consumed) = HTTPHead.parse(Data(raw.utf8), kind: .request) else {
            Issue.record("not parsed"); return
        }
        #expect(consumed == raw.utf8.count - 4)
        #expect(head.method == "GET")
        #expect(head.path == "/a")
        #expect(head.query == ["b": "1"])
        #expect(head.values("COOKIE") == ["a=1", "b=2"])
        #expect(String(decoding: head.serialized, as: UTF8.self) == String(raw.dropLast(4)))
        #expect(responseHead("HTTP/1.1 204\r\n").status == 204)
        #expect(HTTPHead.parse(Data("GET / HTTP/1.1\r\nHost".utf8), kind: .request) == .incomplete)
        #expect(HTTPHead.parse(Data("GET http://x/ HTTP/1.1\r\n\r\n".utf8), kind: .request) == .invalid)
        #expect(HTTPHead.parse(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8), kind: .response) == .invalid)
        #expect(HTTPHead.parse(Data(String(repeating: "a", count: 70_000).utf8), kind: .request) == .tooLarge)
    }

    @Test func editsKeepOneValuePerName() {
        var head = requestHead("GET / HTTP/1.1\r\nConnection: keep-alive\r\nconnection: x\r\n")
        head.set("Connection", "close")
        #expect(head.values("connection") == ["close"])
        head.remove("CONNECTION")
        #expect(head.value("connection") == nil)
        head.set("Host", "a")
        #expect(head.fields.last == HTTPHead.Field(name: "Host", value: "a"))
    }
}

struct PreviewGateTests {
    let own = "https://mac.example.ts.net:8444"
    let siblings: Set<String> = Set((8443...8447).map { "https://mac.example.ts.net:\($0)" })
    let me = "Tailscale-User-Login: me@example.com\r\n"

    func decide(_ raw: String) -> PreviewGate.Decision {
        PreviewGate.decide(requestHead(raw), owner: "me@example.com", ownOrigin: own, siblingOrigins: siblings, publicPort: 8444)
    }

    @Test func decidesWhoGetsThrough() {
        #expect(decide("GET / HTTP/1.1\r\nCookie: vs_preview_8444=T\r\n")
                == .reject(status: 403, message: PreviewGate.wrongAccountMessage))
        #expect(decide("GET / HTTP/1.1\r\nTailscale-User-Login: other@example.com\r\nCookie: vs_preview_8444=T\r\n")
                == .reject(status: 403, message: PreviewGate.wrongAccountMessage))
        #expect(decide("GET /__vibeswitcher/enter?t=abc HTTP/1.1\r\n\(me)") == .enter(ticket: "abc"))
        #expect(decide("GET /x HTTP/1.1\r\n\(me)Cookie: a=1; vs_preview_8444=T\r\n") == .forward(sessionToken: "T"))
        #expect(decide("GET /x HTTP/1.1\r\n\(me)") == .reject(status: 403, message: PreviewGate.expiredMessage))
        // Another slot's cookie is not this slot's (cookies ignore ports).
        #expect(decide("GET /x HTTP/1.1\r\n\(me)Cookie: vs_preview_8445=T\r\n")
                == .reject(status: 403, message: PreviewGate.expiredMessage))
        // A page in another slot (or the app itself) may not use this slot's session.
        #expect(decide("POST /x HTTP/1.1\r\n\(me)Cookie: vs_preview_8444=T\r\nOrigin: https://mac.example.ts.net:8445\r\n")
                == .reject(status: 403, message: PreviewGate.crossOriginMessage))
        #expect(decide("POST /x HTTP/1.1\r\n\(me)Cookie: vs_preview_8444=T\r\nOrigin: \(own)\r\n") == .forward(sessionToken: "T"))
    }

    @Test func rewritesRequestsForTheDevServer() {
        let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173)
        let rewritten = PreviewGate.upstreamRequest(requestHead(
            "GET /src/main.ts HTTP/1.1\r\nHost: mac.example.ts.net:8444\r\n\(me)Tailscale-User-Name: Me\r\n"
            + "Origin: \(own)\r\nReferer: \(own)/settings\r\nCookie: theme=dark; vs_preview_8444=T\r\n"
            + "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n"), target: target, ownOrigin: own, publicPort: 8444)
        #expect(rewritten.startLine == "GET /src/main.ts HTTP/1.1")
        #expect(rewritten.value("host") == "localhost:5173")
        #expect(rewritten.value("origin") == "http://localhost:5173")
        #expect(rewritten.value("referer") == "http://localhost:5173/settings")
        #expect(rewritten.values("cookie") == ["theme=dark"])
        #expect(rewritten.value("tailscale-user-login") == nil)
        #expect(rewritten.value("tailscale-user-name") == nil)
        #expect(rewritten.value("connection") == "close")
        #expect(rewritten.value("keep-alive") == nil)
        let bare = PreviewGate.upstreamRequest(requestHead("GET / HTTP/1.1\r\nCookie: vs_preview_8444=T\r\n"),
                                               target: target, ownOrigin: own, publicPort: 8444)
        #expect(bare.value("cookie") == nil)
        let upgrade = PreviewGate.upstreamRequest(requestHead("GET /hmr HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"),
                                                  target: target, ownOrigin: own, publicPort: 8444)
        #expect(upgrade.value("connection") == "Upgrade")
    }

    @Test func rewritesDevServerRedirectsAndCookies() {
        let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:3000", port: 3000)
        let response = PreviewGate.clientResponse(responseHead(
            "HTTP/1.1 302 Found\r\nLocation: http://localhost:3000/login?next=%2F\r\n"
            + "Set-Cookie: sid=abc; Domain=localhost; Path=/; HttpOnly\r\nSet-Cookie: theme=dark; domain=.localhost\r\n"
            + "Connection: keep-alive\r\n"), target: target)
        #expect(response.value("location") == "/login?next=%2F")
        #expect(response.values("set-cookie") == ["sid=abc; Path=/; HttpOnly", "theme=dark"])
        #expect(response.value("connection") == "close")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 301 Moved\r\nLocation: http://127.0.0.1:3000\r\n"),
                                           target: target).value("location") == "/")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 302 Found\r\nLocation: http://localhost:3000//evil.example\r\n"),
                                           target: target).value("location") == "/evil.example")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 302 Found\r\nLocation: https://accounts.example.com/o\r\n"),
                                           target: target).value("location") == "https://accounts.example.com/o")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 302 Found\r\nLocation: http://localhost:4000/\r\n"),
                                           target: target).value("location") == "http://localhost:4000/")
        #expect(PreviewGate.clientResponse(responseHead("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"),
                                           target: target).value("connection") == "Upgrade")
    }
}

/// A one-request-per-connection HTTP server for proxy tests. It records each request head, answers with
/// `reply`, and then closes, or with `echoAfterReply` keeps echoing (an upgraded connection).
final class FakeUpstream: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-upstream")
    private var heads: [String] = []
    var reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8)
    var echoAfterReply = false

    init(host: String = "127.0.0.1") throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard case .ready = state, !resumed else { return }
                resumed = true
                continuation.resume(returning: listener.port!.rawValue)
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.readHead(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    var recorded: [String] { queue.sync { heads } }
    func stop() { listener.cancel() }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !done { self.readHead(connection, buffer: buffer) }
                return
            }
            self.heads.append(String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self))
            connection.send(content: self.reply, completion: .contentProcessed { _ in
                if self.echoAfterReply { self.echo(connection) } else { connection.cancel() }
            })
        }
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
            if done { connection.cancel() } else { self?.echo(connection) }
        }
    }
}

/// Sends `request` to 127.0.0.1:`port`; returns everything received until the server closes.
func exchange(port: UInt16, _ request: String, timeout: TimeInterval = 5) async -> Data {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test-client")
        var received = Data()
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            connection.cancel()
            continuation.resume(returning: received)
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                if let data { received.append(data) }
                if done || error != nil { finish() } else { read() }
            }
        }
        connection.start(queue: queue)
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in read() })
        queue.asyncAfter(deadline: .now() + timeout) { finish() }
    }
}

/// Sends an upgrade request; once the response head arrives, sends `payload` and waits for it to come back.
func upgradeExchange(port: UInt16, _ request: String, payload: Data) async -> (head: String, echoed: Data) {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "test-upgrade")
        var buffer = Data()
        var head: String?
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            connection.cancel()
            continuation.resume(returning: (head ?? String(decoding: buffer, as: UTF8.self), head == nil ? Data() : buffer))
        }
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { buffer.append(data) }
                if head == nil, let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    head = String(decoding: buffer[buffer.startIndex..<end.upperBound], as: UTF8.self)
                    buffer = Data(buffer[end.upperBound...])
                    connection.send(content: payload, completion: .contentProcessed { _ in })
                }
                if head != nil, buffer.count >= payload.count { return finish() }
                if done || error != nil { finish() } else { read() }
            }
        }
        connection.start(queue: queue)
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in read() })
        queue.asyncAfter(deadline: .now() + 5) { finish() }
    }
}

struct ProxyStartFailure: Error { let message: String }

struct PreviewProxyTests {
    @Test func theOnwardLinkIsEscaped() {
        let page = String(decoding: PreviewProxy.enterPage(path: "/a?b=\"><script>x</script>&c=1", cookie: "k=v"), as: UTF8.self)
        #expect(!page.contains("<script>x"))
        #expect(page.contains("&quot;&gt;&lt;script&gt;"))
    }

    static let me = "Tailscale-User-Login: me@example.com\r\n"
    static let ours = "Cookie: vs_preview_8444=TOK\r\n"

    func startProxy(target: PreviewTarget?, redeemed: (path: String, sessionToken: String)? = nil) async throws -> (PreviewProxy, UInt16) {
        let proxy = PreviewProxy(label: "test-proxy", context: {
            PreviewProxy.Context(owner: "me@example.com", ownOrigin: "https://mac.example.ts.net:8444",
                                 siblingOrigins: Set((8443...8447).map { "https://mac.example.ts.net:\($0)" }), publicPort: 8444)
        }, redeem: { $0 == "TICKET" ? redeemed : nil }, resolve: { $0 == "TOK" ? target : nil })
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            proxy.start(port: 0, callbackQueue: .global(), onReady: { continuation.resume(returning: proxy.port!) },
                        onFailure: { continuation.resume(throwing: ProxyStartFailure(message: $0)) })
        }
        return (proxy, port)
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func ticketSetsTheSlotCookieAndRedirects() async throws {
        let (proxy, port) = try await startProxy(target: nil, redeemed: ("/app?x=1", "TOK"))
        defer { proxy.stop() }
        let response = text(await exchange(port: port, "GET /__vibeswitcher/enter?t=TICKET HTTP/1.1\r\n\(Self.me)\r\n"))
        // Not a 302: a redirect continues the phone's cross-site navigation (Android opens the link from
        // the app), so the browser would withhold the SameSite=Strict cookie on the next request. A page
        // that moves on by itself makes that next request same-site.
        #expect(response.hasPrefix("HTTP/1.1 200"))
        #expect(response.contains("Set-Cookie: vs_preview_8444=TOK; Path=/; Secure; HttpOnly; SameSite=Strict\r\n"))
        #expect(response.contains(#"<meta http-equiv="refresh" content="0;url=/app?x=1">"#))
        #expect(!response.contains("Location:"))
        let wrong = text(await exchange(port: port, "GET /__vibeswitcher/enter?t=WRONG HTTP/1.1\r\n\(Self.me)\r\n"))
        #expect(wrong.hasPrefix("HTTP/1.1 403"))
    }

    @Test func forwardsToTheDevServerWithLocalHeaders() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = await upstream.start()
        upstream.reply = Data(("HTTP/1.1 302 Found\r\nLocation: http://localhost:\(upstreamPort)/login\r\n"
                               + "Set-Cookie: sid=1; Domain=localhost; Path=/\r\nContent-Length: 2\r\n\r\nok").utf8)
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let response = text(await exchange(port: port,
            "GET /x?y=1 HTTP/1.1\r\nHost: mac.example.ts.net:8444\r\n\(Self.me)Tailscale-User-Name: Me\r\n"
            + "Origin: https://mac.example.ts.net:8444\r\nCookie: theme=dark; vs_preview_8444=TOK\r\nConnection: keep-alive\r\n\r\n"))
        let seen = try #require(upstream.recorded.first)
        #expect(seen.hasPrefix("GET /x?y=1 HTTP/1.1\r\n"))
        #expect(seen.contains("Host: localhost:\(upstreamPort)"))
        #expect(seen.contains("Origin: http://localhost:\(upstreamPort)"))
        #expect(seen.contains("Cookie: theme=dark"))
        #expect(!seen.contains("vs_preview"))
        #expect(!seen.lowercased().contains("tailscale-"))
        #expect(seen.contains("Connection: close"))
        #expect(response.contains("Location: /login\r\n"))
        #expect(response.contains("Set-Cookie: sid=1; Path=/\r\n"))
        #expect(response.hasSuffix("\r\n\r\nok"))
    }

    @Test func refusesOtherAccountsAndStaleCookiesWithoutContactingTheServer() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let other = text(await exchange(port: port, "GET / HTTP/1.1\r\nTailscale-User-Login: someone@else.com\r\n\(Self.ours)\r\n"))
        #expect(other.hasPrefix("HTTP/1.1 403"))
        let stale = text(await exchange(port: port, "GET / HTTP/1.1\r\n\(Self.me)Cookie: vs_preview_8444=OLD\r\n\r\n"))
        #expect(stale.hasPrefix("HTTP/1.1 403"))
        #expect(stale.contains("Open it again from VibeSwitcher"))
        let crossSlot = text(await exchange(port: port,
            "POST / HTTP/1.1\r\n\(Self.me)\(Self.ours)Origin: https://mac.example.ts.net:8445\r\nContent-Length: 0\r\n\r\n"))
        #expect(crossSlot.hasPrefix("HTTP/1.1 403"))
        #expect(upstream.recorded.isEmpty)
    }

    @Test func streamsLargeResponsesIntact() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = await upstream.start()
        let body = Data((0..<5_000_000).map { UInt8($0 % 251) })
        upstream.reply = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let response = await exchange(port: port, "GET /big.js HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n", timeout: 15)
        let split = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        #expect(Data(response[split.upperBound...]) == body)
    }

    @Test func reachesServersListeningOnlyOnIPv6Loopback() async throws {
        let upstream = try FakeUpstream(host: "::1")
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let response = text(await exchange(port: port, "GET / HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n"))
        #expect(response.hasPrefix("HTTP/1.1 200"))
        #expect(response.hasSuffix("ok"))
    }

    @Test func answers502WhenTheDevServerIsDown() async throws {
        let probe = try FakeUpstream()
        let deadPort = await probe.start()
        probe.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(deadPort)", port: Int(deadPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop() }
        let response = text(await exchange(port: port, "GET / HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n", timeout: 10))
        #expect(response.hasPrefix("HTTP/1.1 502"))
        #expect(response.contains("isn't answering"))
    }

    @Test func pipesUpgradedConnectionsBothWays() async throws {
        let upstream = try FakeUpstream()
        upstream.echoAfterReply = true
        upstream.reply = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let result = await upgradeExchange(port: port,
            "GET /hmr HTTP/1.1\r\n\(Self.me)\(Self.ours)Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n", payload: Data("ping".utf8))
        #expect(result.head.hasPrefix("HTTP/1.1 101"))
        #expect(!result.head.contains("Connection: close"))
        #expect(result.echoed == Data("ping".utf8))
        let seen = try #require(upstream.recorded.first)
        #expect(seen.contains("Connection: Upgrade"))
    }
}

struct AutomationAccessTests {
    @Test func macOSAnswersMapToWhatThePhoneAccessWindowShows() {
        #expect(AutomationAccess(status: 0) == .allowed)
        #expect(AutomationAccess(status: -1743) == .denied)
        #expect(AutomationAccess(status: -1744) == .notAsked)
        #expect(AutomationAccess(status: -600) == .appNotRunning)
        #expect(AutomationAccess(status: -50) == .unknown(-50))
    }
}
