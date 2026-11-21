import Foundation
import Testing
@testable import VibeCore

/// H1's messages on the connector (`HostWebListen`): each request said and read back exactly, anything else not a
/// request; the host's check: loopback is 127.0.0.1, the tailnet 100.64.0.0/10, the user's host the node's one port.
struct HostWebListenTests {
    @Test func aRequestIsSaidAndReadBackExactly() {
        for request in [HostWebListen.Request.listen(.loopback, address: "127.0.0.1", port: 47830), .listen(.tailnet, address: "100.101.2.3", port: 0),
                        .release(.loopback), .release(.tailnet)] {
            let bytes = HostWebListen.bytes(request)
            #expect(HostWebListen.isWeb(bytes) && HostWebListen.parse(bytes) == request, "\(request)")
        }
        #expect(String(decoding: HostWebListen.bytes(.listen(.loopback, address: "127.0.0.1", port: 47830)), as: UTF8.self) == "web listen loopback 127.0.0.1 47830")
        for text in ["web listen loopback 127.0.0.1", "web listen loopback localhost 47830", "web listen phone 127.0.0.1 1", "web listen loopback 127.0.0.1 65536",
                     "web listen loopback 127.0.0.1 +80", "web listen loopback 127.0.0.01 80", "web listen loopback 127.0.0.1 80 more", "web release",
                     "web release loopback now", "web bind loopback", "web  listen loopback 127.0.0.1 80", "c"] {
            #expect(HostWebListen.parse(Array(text.utf8)) == nil, "\(text)")
        }
        #expect(!HostWebListen.isWeb([UInt8(ascii: "c")]))
        let loopback = HostWebListen.Request.listen(.loopback, address: "127.0.0.1", port: 0)
        #expect(String(decoding: HostWebListen.answer(loopback, refusal: nil), as: UTF8.self) == "web ok listen loopback 127.0.0.1 0")
        #expect(String(decoding: HostWebListen.answer(loopback, refusal: "why"), as: UTF8.self) == "web no listen loopback 127.0.0.1 0: why")
    }

    /// An answer is its own request's only: a stale loopback answer isn't a tailnet listen's, nor a release's, nor
    /// another port's; a message that is no answer (a connection's byte, an unasked refusal) is nobody's.
    @Test func anAnswerIsItsOwnRequestsOnly() {
        let loopback = HostWebListen.Request.listen(.loopback, address: "127.0.0.1", port: 0)
        let tailnet = HostWebListen.Request.listen(.tailnet, address: "100.64.0.1", port: 0)
        let otherPort = HostWebListen.Request.listen(.loopback, address: "127.0.0.1", port: 47830)
        let release = HostWebListen.Request.release(.loopback)
        let ok = HostWebListen.answer(loopback, refusal: nil), no = HostWebListen.answer(loopback, refusal: "taken")
        #expect(HostWebListen.answers(loopback, ok) == .some(nil))
        #expect(HostWebListen.answers(loopback, no) == .some("taken"))
        for other in [tailnet, otherPort, release] {
            #expect(HostWebListen.answers(other, ok) == nil, "\(other)")
            #expect(HostWebListen.answers(other, no) == nil, "\(other)")
        }
        #expect(HostWebListen.answers(release, HostWebListen.answer(release, refusal: nil)) == .some(nil))
        #expect(HostWebListen.answers(loopback, HostWebListen.answer(release, refusal: nil)) == nil)
        #expect(HostWebListen.answers(loopback, [UInt8(ascii: "d")]) == nil)
        #expect(HostWebListen.answers(loopback, HostWebListen.unasked("not a web request")) == nil)
        #expect(HostWebListen.answers(loopback, Array("web ok listen loopback 127.0.0.1 0 ".utf8)) == nil)
    }

    @Test func theHostsCheck() {
        #expect(HostWebListen.refusal(.loopback, address: "127.0.0.1", port: 47830, usersHost: true) == nil)
        #expect(HostWebListen.refusal(.loopback, address: "127.0.0.1", port: 0, usersHost: false) == nil)
        #expect(HostWebListen.refusal(.loopback, address: "127.0.0.1", port: 0, usersHost: true) != nil)
        #expect(HostWebListen.refusal(.loopback, address: "127.0.0.2", port: 47830, usersHost: true) != nil)
        #expect(HostWebListen.refusal(.loopback, address: "0.0.0.0", port: 47830, usersHost: true) != nil)
        for inside in ["100.64.0.0", "100.100.100.100", "100.127.255.255"] {
            #expect(HostWebListen.refusal(.tailnet, address: inside, port: 47830, usersHost: true) == nil, "\(inside)")
        }
        for outside in ["100.63.255.255", "100.128.0.0", "10.0.0.1", "127.0.0.1", "0.0.0.0", "192.168.1.2"] {
            #expect(HostWebListen.refusal(.tailnet, address: outside, port: 47830, usersHost: true) != nil, "\(outside)")
        }
        #expect(HostWebListen.port == 47830)
    }
}
