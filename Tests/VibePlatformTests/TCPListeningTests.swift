import Foundation
import Testing
import VibePlatform

/// `Platform.TCP.isListening` (H1's check of what the host hands its server), on both systems: a TCP listener is, on
/// IPv4 and IPv6; a TCP socket bound but not listening, a connection's end and a Unix stream listener aren't. The Mac's
/// kernel answers no `SO_ACCEPTCONN`, so its form reads the descriptor's options (`proc_pidfdinfo`): the v2 macos run
/// on 350ced4d failed H1's tests here.
struct TCPListeningTests {
    @Test func aListenerIsListeningAndNothingElseIs() throws {
        let listener = try Platform.TCP.listen(family: .ipv4, address: "127.0.0.1", port: 0, backlog: 1).get()
        defer { Sys.close(listener) }
        #expect(Platform.TCP.isListening(listener))
        // For the record (the cause on the Mac): what getsockopt(SO_ACCEPTCONN) answers for a listener here.
        var on: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let asked = getsockopt(listener, SOL_SOCKET, SO_ACCEPTCONN, &on, &length)
        print("TCPListeningTests: getsockopt(SO_ACCEPTCONN) on a listener: \(asked == 0 ? "value \(on)" : "errno \(errno)")")
        if case .success(let six) = Platform.TCP.listen(family: .ipv6, address: "::1", port: 0, backlog: 1) {
            #expect(Platform.TCP.isListening(six))
            Sys.close(six)
        }
        let port = try #require(Platform.TCP.localPort(listener))
        let client = try Platform.TCP.connect(family: .ipv4, address: "127.0.0.1", port: port).get()
        defer { Sys.close(client) }
        #expect(!Platform.TCP.isListening(client))
        // Bound, not listening.
        let bound = socket(AF_INET, Platform.Sockets.stream, 0)
        defer { Sys.close(bound) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(bound, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(didBind == 0)
        #expect(!Platform.TCP.isListening(bound))
        // A Unix stream listener: no TCP port.
        let unix = socket(AF_UNIX, Platform.Sockets.stream, 0)
        defer { Sys.close(unix) }
        #expect(!Platform.TCP.isListening(unix))
        #expect(!Platform.TCP.isListening(-1))
    }
}
