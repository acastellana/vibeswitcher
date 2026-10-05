import Foundation
import Testing
@testable import VibeCore

/// Dev servers' own login cookies stay on the Mac: kept per preview session in the proxy, never handed to
/// the phone's browser (where every preview port would see them, cookies ignore ports).
struct PreviewCookieJarTests {
    let target = PreviewTarget(connectHost: "localhost", hostHeader: "localhost:3000", port: 3000)

    @Test func httpOnlyCookiesGoToTheJarAndNotToTheBrowser() {
        var jar = PreviewCookieJar()
        let response = PreviewGate.clientResponse(responseHead(
            "HTTP/1.1 200 OK\r\nSet-Cookie: sid=SECRET; Path=/; HttpOnly; Secure\r\nSet-Cookie: theme=dark; Path=/\r\n"
            + "Set-Cookie: csrftoken=abc; Path=/\r\n"), target: target, jar: &jar)
        // The browser keeps what its own scripts may read; the session cookie stays here.
        #expect(response.values("set-cookie") == ["theme=dark; Path=/", "csrftoken=abc; Path=/"])
        #expect(jar.cookies == ["sid": "SECRET"])
    }

    @Test func theJarRidesAlongToTheDevServerAndWinsOverTheBrowser() {
        var jar = PreviewCookieJar()
        jar.store(setCookie: "sid=SECRET; HttpOnly")
        // Another preview's script planted its own `sid` (scripts can set cookies for every port).
        let upstream = PreviewGate.upstreamRequest(requestHead(
            "GET / HTTP/1.1\r\nCookie: sid=PLANTED; theme=dark; vs_preview_8444=T\r\n"),
            target: target, ownOrigin: "https://mac.example.ts.net:8444", publicPort: 8444, jar: jar)
        #expect(upstream.values("cookie") == ["theme=dark; sid=SECRET"])
    }

    @Test func deletionsAndReplacementsFollowTheServer() {
        var jar = PreviewCookieJar()
        jar.store(setCookie: "sid=one; HttpOnly")
        jar.store(setCookie: "sid=two; HttpOnly; Path=/")
        #expect(jar.cookies == ["sid": "two"])
        jar.store(setCookie: "sid=; HttpOnly; Max-Age=0")
        #expect(jar.cookies.isEmpty)
        jar.store(setCookie: "sid=three; HttpOnly")
        jar.store(setCookie: "sid=gone; HttpOnly; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(jar.cookies.isEmpty)
    }

    @Test func aJarCantGrowWithoutBound() {
        var jar = PreviewCookieJar()
        for i in 0..<500 { jar.store(setCookie: "c\(i)=\(String(repeating: "v", count: 100)); HttpOnly") }
        #expect(jar.cookies.count <= PreviewCookieJar.maxCookies)
        jar.store(setCookie: "big=\(String(repeating: "x", count: 10_000)); HttpOnly")
        #expect(jar.cookies["big"] == nil)
    }

    @Test func slotCookiesNeverEnterTheJar() {
        var jar = PreviewCookieJar()
        jar.store(setCookie: "vs_preview_8444=evil; HttpOnly")
        #expect(jar.cookies.isEmpty)
    }
}

extension PreviewProxyTests {
    @Test func aDevServersLoginCookieStaysOnTheMacAndComesBack() async throws {
        let upstream = try FakeUpstream()
        upstream.reply = Data("HTTP/1.1 200 OK\r\nSet-Cookie: sid=SECRET; Path=/; HttpOnly\r\nContent-Length: 2\r\n\r\nok".utf8)
        let upstreamPort = await upstream.start()
        let target = PreviewTarget(connectHost: "127.0.0.1", hostHeader: "localhost:\(upstreamPort)", port: Int(upstreamPort))
        let (proxy, port) = try await startProxy(target: target)
        defer { proxy.stop(); upstream.stop() }
        let login = text(await exchange(port: port, "POST /login HTTP/1.1\r\n\(Self.me)\(Self.ours)Content-Length: 0\r\n\r\n"))
        #expect(login.hasPrefix("HTTP/1.1 200"))
        #expect(!login.contains("SECRET"))      // the phone's browser never sees it
        _ = await exchange(port: port, "GET /me HTTP/1.1\r\n\(Self.me)\(Self.ours)\r\n")
        let second = try #require(upstream.recorded.last)
        #expect(second.contains("Cookie: sid=SECRET"))   // the dev server still gets its session back
    }
}
