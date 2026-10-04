import Foundation
import Network
import Testing
@testable import VibeCore

/// Findings from the dev-pages review: cookies of other slots, cross-slot requests, idle sessions,
/// header injection, interim responses, truncated answers, and the request shapes dev servers see.
struct PreviewGateHardeningTests {
    let own = "https://mac.example.ts.net:8444"
    let siblings: Set<String> = Set((8443...8447).map { "https://mac.example.ts.net:\($0)" })
    let me = "Tailscale-User-Login: me@example.com\r\n"
    let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173)

    func decide(_ raw: String) -> PreviewGate.Decision {
        PreviewGate.decide(requestHead(raw), owner: "me@example.com", ownOrigin: own, siblingOrigins: siblings, publicPort: 8444)
    }

    @Test func noSlotsCookieReachesADevServer() {
        // Cookies ignore ports: every slot's cookie is sent to every slot. None of them is the dev server's.
        let rewritten = PreviewGate.upstreamRequest(requestHead(
            "GET / HTTP/1.1\r\nCookie: vs_preview_8445=A; theme=dark; vs_preview_8444=T\r\nCookie: vs_preview_8447=B\r\n"),
            target: target, ownOrigin: own, publicPort: 8444)
        #expect(rewritten.values("cookie") == ["theme=dark"])
    }

    @Test func aDevServerCannotSetASlotsCookie() {
        let response = PreviewGate.clientResponse(responseHead(
            "HTTP/1.1 200 OK\r\nSet-Cookie: vs_preview_8445=evil; Path=/\r\nSet-Cookie: sid=1; Path=/\r\nSet-Cookie: VS_PREVIEW_8444=x\r\n"),
            target: target)
        #expect(response.values("set-cookie") == ["sid=1; Path=/"])
    }

    @Test func requestsFromAnotherSlotAreRefusedEvenWithoutOrigin() {
        // An <img>, <script> or <iframe> in another slot's page sends no Origin, but the browser marks it same-site
        // (another port of the same host) and attaches every slot's cookie.
        #expect(decide("GET /api/me HTTP/1.1\r\n\(me)Cookie: vs_preview_8444=T\r\nSec-Fetch-Site: same-site\r\n")
                == .reject(status: 403, message: PreviewGate.crossOriginMessage))
        #expect(decide("GET /api/me HTTP/1.1\r\n\(me)Cookie: vs_preview_8444=T\r\nSec-Fetch-Site: cross-site\r\n")
                == .reject(status: 403, message: PreviewGate.crossOriginMessage))
        // The page's own requests, and the user's own navigations, go through.
        #expect(decide("GET /a.js HTTP/1.1\r\n\(me)Cookie: vs_preview_8444=T\r\nSec-Fetch-Site: same-origin\r\n")
                == .forward(sessionToken: "T"))
        #expect(decide("GET / HTTP/1.1\r\n\(me)Cookie: vs_preview_8444=T\r\nSec-Fetch-Site: none\r\n") == .forward(sessionToken: "T"))
        // The link from the phone app (another port) is how a slot is entered.
        #expect(decide("GET /__vibeswitcher/enter?t=abc HTTP/1.1\r\n\(me)Sec-Fetch-Site: same-site\r\n") == .enter(ticket: "abc"))
    }

    @Test func interimResponsesStayInterim() {
        let continued = PreviewGate.clientResponse(responseHead("HTTP/1.1 100 Continue\r\n"), target: target)
        #expect(continued.value("connection") == nil)
        let early = PreviewGate.clientResponse(responseHead("HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n"), target: target)
        #expect(early.value("connection") == nil)
    }
}

struct HTTPHeadHardeningTests {
    @Test func bareLineBreaksInsideAFieldAreRefused() {
        // A lone CR or LF could smuggle a second header past the proxy's rewriting.
        #expect(HTTPHead.parse(Data("GET / HTTP/1.1\r\nX-A: 1\nCookie: vs_preview_8444=T\r\n\r\n".utf8), kind: .request) == .invalid)
        #expect(HTTPHead.parse(Data("GET / HTTP/1.1\r\nX-A: 1\rHost: evil\r\n\r\n".utf8), kind: .request) == .invalid)
        #expect(HTTPHead.parse(Data("HTTP/1.1 200 OK\r\nLocation: /a\nSet-Cookie: x=1\r\n\r\n".utf8), kind: .response) == .invalid)
    }

    @Test func targetsWithControlCharactersOrSpacesAreRefused() {
        #expect(HTTPHead.parse(Data("GET /a\tb HTTP/1.1\r\n\r\n".utf8), kind: .request) == .invalid)
        #expect(HTTPHead.parse(Data("GET /a b HTTP/1.1\r\n\r\n".utf8), kind: .request) == .invalid)
        #expect(HTTPHead.parse(Data("GET /a%20b HTTP/1.1\r\n\r\n".utf8), kind: .request) != .invalid)
    }
}

struct PreviewSessionExpiryTests {
    let vite = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:5173", port: 5173)
    let t0 = Date(timeIntervalSince1970: 1000)

    @Test func anIdleSessionExpires() throws {
        var slots = PreviewSlots(count: 1)
        let opened = slots.open(vite, path: "/", now: t0, newToken: { "ticket" })
        let ticket = try #require(opened).ticket
        let redeemed = slots.redeem(ticket, slot: 0, now: t0, newToken: { "session" })
        #expect(redeemed?.sessionToken == "session")
        // In use, the session stays alive.
        let later = slots.target(slot: 0, sessionToken: "session", now: t0.addingTimeInterval(PreviewSlots.idleLimit - 60))
        #expect(later == vite)
        // Left alone longer than the idle limit, it is gone for good.
        let idle = slots.target(slot: 0, sessionToken: "session",
                                now: t0.addingTimeInterval(2 * PreviewSlots.idleLimit))
        #expect(idle == nil)
        let afterwards = slots.target(slot: 0, sessionToken: "session", now: t0.addingTimeInterval(2 * PreviewSlots.idleLimit + 1))
        #expect(afterwards == nil)
    }
}

struct PhonePortsTests {
    @Test func reservedPortsAreTheServerAndItsPreviewSlots() {
        #expect(DevPages.reservedPorts == Int(PhonePorts.server)...Int(PhonePorts.server) + PhonePorts.previewSlots)
        #expect(PhonePorts.previewLocal(0) == PhonePorts.server + 1)
        #expect(PhonePorts.previewPublic(PhonePorts.previewSlots - 1) == PhonePorts.https + PhonePorts.previewSlots)
    }
}

/// A one-shot server that answers `reply` and then resets the connection (SO_LINGER 0): what the proxy
/// sees when a dev server's connection breaks mid-answer. (Network.framework's forceCancel doesn't
/// reliably send a reset.)
final class ResettingServer: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32

    init(reply: Data) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        listen(fd, 1)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        socketFD = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            var received = Data()
            while received.range(of: Data("\r\n\r\n".utf8)) == nil {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                received.append(contentsOf: buffer[0..<count])
            }
            _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
            usleep(100_000)
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(client, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
            close(client)
        }
    }

    func stop() { close(socketFD) }
}

extension PreviewProxyTests {
    @Test func aDevServerConnectionThatBreaksMidAnswerResetsThePhonesConnection() async throws {
        // No length, not chunked: the end of the connection is the end of the file.
        let upstream = try ResettingServer(reply: Data("HTTP/1.1 200 OK\r\nContent-Type: text/javascript\r\n\r\nexport const a".utf8))
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstream.port)", port: Int(upstream.port))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let result = await exchangeDetailed(port: port, "GET /bundle.js HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n")
        #expect(text(result.data).hasSuffix("export const a"))
        // Closing cleanly here would make the cut-off file look complete.
        #expect(result.endedWithError)
    }

    @Test func reachesServersListeningOnlyOnIPv4BehindLocalhost() async throws {
        let upstream = try FakeUpstream(host: "127.0.0.1")
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let response = text(await exchange(port: port, "GET / HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n"))
        #expect(response.hasPrefix("HTTP/1.1 200"))
    }

    @Test func forwardsRequestBodies() async throws {
        let upstream = try FakeUpstream()
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let body = #"{"title":"hello"}"#
        let response = text(await exchange(port: port,
            "POST /api/posts HTTP/1.1\r\n\(Self.me)\(Self.ours)Origin: https://mac.example.ts.net:8444\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"))
        #expect(response.hasPrefix("HTTP/1.1 200"))
        #expect(upstream.recordedBodies.first == Data(body.utf8))
    }

    @Test func streamsServerSentEventsAsTheyCome() async throws {
        let upstream = try FakeUpstream()
        upstream.reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n6\r\ndata:1\r\n".utf8)
        upstream.stages = [(1.2, Data("6\r\ndata:2\r\n0\r\n\r\n".utf8))]
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let result = await exchangeDetailed(port: port, "GET /events HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n")
        let first = try #require(result.arrivals.first { String(decoding: $0.1, as: UTF8.self).contains("data:1") })
        #expect(first.0 < 0.8)   // not held back until the stream ends
        #expect(text(result.data).hasSuffix("6\r\ndata:2\r\n0\r\n\r\n"))
        #expect(!result.endedWithError)
    }
}

struct ChromeReadFailureTests {
    @Test func appleEventErrorsMapToWhatThePhoneShows() {
        #expect(ChromeReadFailure(appleEventCode: -1743) == .notAllowed)
        // Chrome quit while being read: it isn't running any more, not "error -609".
        #expect(ChromeReadFailure(appleEventCode: -609) == .notRunning)
        #expect(ChromeReadFailure(appleEventCode: -600) == .notRunning)
        #expect(ChromeReadFailure(appleEventCode: -1712) == .failed("Chrome didn't answer in time"))
        #expect(ChromeReadFailure(appleEventCode: -1728) == .failed("Apple Event error -1728"))
    }
}
