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
        #expect(HostWebListen.answer(refusal: nil) == Array("web ok".utf8) && HostWebListen.answer(refusal: "why") == Array("web no: why".utf8))
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
