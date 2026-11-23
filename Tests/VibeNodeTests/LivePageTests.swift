import Foundation
import Testing
import VibeCore
@testable import VibeNode

/// The tests' page client (`LivePage`) against a stand-in listener on loopback, so what it does with a frame is told
/// without a node: the keepalive ping that came before a subscription's snapshot under load (2026-11-23) answered and
/// read past, without waiting out the real listener's 15 s.
struct LivePageTests {
    /// A one-connection WebSocket listener on loopback: it answers the upgrade, then `serve` runs with the
    /// connection, its frames read through `RawClient`'s own parser (masked, as a client's are).
    final class StandIn: @unchecked Sendable {
        let fd: Int32
        let port: UInt16
        private let done = DispatchSemaphore(value: 0)

        init() throws {
            let fd = socket(AF_INET, Platform.Sockets.stream, 0)
            guard fd >= 0 else { throw RawClient.Failure("socket: \(errno)") }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw RawClient.Failure("bind or listen: \(errno)") }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            self.fd = fd
            port = UInt16(bigEndian: address.sin_port)
        }

        /// Accepts one connection on a thread of its own, answers its upgrade, and runs `serve` with it.
        func start(_ serve: @escaping @Sendable (Connection) -> Void) {
            Thread.detachNewThread { [self] in
                defer { done.signal() }
                let peer = accept(fd, nil, nil)
                guard peer >= 0 else { return }
                defer { close(peer) }
                let connection = Connection(fd: peer)
                guard connection.readHead() else { return }
                connection.write(Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8))
                serve(connection)
            }
        }

        /// Waits for `serve` to end (a hang guard), then closes the listener.
        func finish() async {
            _ = await offPool { [done] in done.wait(timeout: .now() + hangGuard) }
            close(fd)
        }
    }

    /// The stand-in's end of the connection.
    final class Connection: @unchecked Sendable {
        let fd: Int32
        private var buffer = Data()
        init(fd: Int32) { self.fd = fd }

        func readHead() -> Bool {
            let deadline = Date().addingTimeInterval(RawClient.wait)
            while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
                guard RawClient.readSome(fd, into: &buffer, until: deadline) else { return false }
            }
            buffer.removeSubrange(buffer.startIndex..<buffer.range(of: Data("\r\n\r\n".utf8))!.upperBound)
            return true
        }

        func write(_ bytes: [UInt8]) {
            _ = Data(bytes).withUnsafeBytes { RawClient.writeAll(fd, $0) }
        }

        /// An unmasked frame, as a server sends (a payload under 126 bytes).
        func send(opcode: UInt8, _ payload: [UInt8]) {
            write([0x80 | opcode, UInt8(payload.count)] + payload)
        }

        /// The client's next frame; nil when it closed or sent nothing within `RawClient.wait`.
        func nextFrame() -> RawClient.Frame? {
            let deadline = Date().addingTimeInterval(RawClient.wait)
            while true {
                if let parsed = RawClient.parseFrame(&buffer, masked: true) { return parsed }
                guard RawClient.readSome(fd, into: &buffer, until: deadline) else { return nil }
            }
        }
    }

    /// A ping before the snapshot: the client answers it with a pong carrying its payload and reads on to the snapshot,
    /// which the stand-in sends only once that pong is in. Before the fix, `next()` took the ping (not JSON) for the
    /// connection's end and gave nil.
    @Test func aPingBeforeTheSnapshotIsAnsweredAndReadPast() async throws {
        let standIn = try StandIn()
        let pong = Locked<RawClient.Frame?>(nil)
        standIn.start { connection in
            connection.send(opcode: 0x9, Array("keep".utf8))
            pong.value = connection.nextFrame()
            guard pong.value?.opcode == 0xA else { return }
            connection.send(opcode: 0x1, Array(#"{"kind":"snapshot","re":"1"}"#.utf8))
            // Open until the client has read it: a close here could reach the client first.
            _ = connection.nextFrame()
        }
        let frame = try await offPool { () throws -> NodeWire.Value? in
            let page = try LivePage(port: standIn.port)
            defer { shutdown(page.client.fd, Int32(SHUT_RDWR)) }
            return try page.next()
        }
        await standIn.finish()
        #expect(pong.value?.opcode == 0xA, "\(String(describing: pong.value))")
        #expect(pong.value?.payload == Data("keep".utf8))
        #expect(frame?["kind"]?.string == "snapshot", "\(String(describing: frame))")
    }
}

